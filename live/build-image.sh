#!/bin/bash
# Our live image (docs/uni/live-image.md): void-mklive at the pinned commit (live/mklive.pins),
# the kernel series of the installed system, the official base image's packages and services
# plus the installer's tools, the repository at the commit of PREBUILT in /root/vh, and the
# programs of live/prebuilt.sh in /usr/local/lib/vh/prebuilt. Into OUT: the ISO, its SHA256SUMS,
# the image's package list and BUILD. The image is of the host's architecture, x86_64 or aarch64
# (mklive -a; the prebuilt programs must be of it too: BUILD's ARCH).
#   bash live/build-image.sh PREBUILT OUT   (root, in a privileged Void container of that
#                                            architecture: mklive needs chroot and loop devices;
#                                            the live-image workflow)
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
pre=${1:?"the prebuilt directory (live/prebuilt.sh)"} out=${2:?"output directory"}
. "$repo/live/mklive.pins"
die() { echo "live/build-image.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
# mklive does not stop when mkfs.vfat or mkfs.ext3 is missing: it made an unformatted EFI boot
# image and root image (live-image run 39375727335)
for t in mkfs.vfat mkfs.ext3 losetup mksquashfs xorriso; do
	command -v "$t" >/dev/null || die "no $t on this host: xbps-install -S $LIVE_HOST_PKGS (live/mklive.pins)"
done
losetup -f >/dev/null || die "no free loop device (a privileged container: docker run --privileged)"
[ -r "$pre/BUILD" ] && [ -r "$pre/SHA256SUMS" ] || die "$pre: no BUILD or SHA256SUMS (live/prebuilt.sh)"
( cd "$pre" && sha256sum -c --quiet SHA256SUMS ) || die "$pre: a file does not match SHA256SUMS"
commit=$(sed -n 's/^COMMIT=//p' "$pre/BUILD")
[ -n "$commit" ] || die "$pre/BUILD: no COMMIT"
short=${commit:0:12}
# the architecture: the host's (mklive chroots into the image's root, which runs natively), and
# the prebuilt programs' (a BUILD without ARCH is of the x86_64 image before U5)
arch=$(xbps-uhelper arch)
pre_arch=$(sed -n 's/^ARCH=//p' "$pre/BUILD")
[ "${pre_arch:-x86_64}" = "$arch" ] || die "$pre: programs for ${pre_arch:-x86_64}, this host builds the $arch image"
case $arch in
	x86_64) grub_pkgs=$LIVE_PKGS_GRUB_x86_64 efi_boot=bootx64.efi ;;
	aarch64) grub_pkgs=$LIVE_PKGS_GRUB_aarch64 efi_boot=bootaa64.efi ;;
	*) die "no live image for $arch (x86_64, aarch64)" ;;
esac
work=$(mktemp -d /tmp/vh-live.XXXXXX)
mkdir -p "$out"

echo "== void-mklive $MKLIVE_COMMIT"
git init -q "$work/mklive"
git -C "$work/mklive" fetch -q --depth 1 "$MKLIVE_REPO" "$MKLIVE_COMMIT"
git -C "$work/mklive" checkout -q FETCH_HEAD
[ "$(git -C "$work/mklive" rev-parse HEAD)" = "$MKLIVE_COMMIT" ] || die "void-mklive is not at $MKLIVE_COMMIT"

echo "== the image's own files: /root/vh at $short, the prebuilt programs, modprobe.d, /etc/vh-live"
inc=$work/include
mkdir -p "$inc/root/vh" "$inc/usr/local/lib/vh" "$inc/etc/modprobe.d"
git -C "$repo" archive "$commit" | tar -x -C "$inc/root/vh"
echo "$commit" > "$inc/root/vh/.vh-commit"
chmod 0700 "$inc/root/vh"
cp -a "$pre" "$inc/usr/local/lib/vh/prebuilt"
# the installed system's modprobe.d at the commit: the live system's stage 1 then loads what
# this machine uses and not every module of modules.devname, and the probe of the installation
# (hw.zon) lists only that (rootfs/etc/modprobe.d/vh-devnodes.conf)
cp "$inc/root/vh/rootfs/etc/modprobe.d/"*.conf "$inc/etc/modprobe.d/"
cat > "$inc/etc/vh-live" <<EOT
# UniVoidDistro's live image (docs/uni/live-image.md)
COMMIT=$commit
RUN=${GITHUB_RUN_ID:-local}
ARCH=$arch
KERNEL=$LIVE_KERNEL
MKLIVE=$MKLIVE_COMMIT
EOT
# run by mklive on the image's root before its initramfs: the package list, in the image and
# beside it (VH_LIVE_OUT: mklive passes its environment on)
cat > "$work/postsetup.sh" <<'EOT'
#!/bin/sh
set -e
xbps-query -r "$1" -l | awk '{print $2}' | LC_ALL=C sort > "$1/usr/local/lib/vh/live-packages.txt"
cp "$1/usr/local/lib/vh/live-packages.txt" "$VH_LIVE_OUT/live-packages.txt"
EOT
chmod 0755 "$work/postsetup.sh"
export VH_LIVE_OUT=$out

iso=$out/univoiddistro-live-$arch-$short.iso
echo "== mklive.sh: $iso"
( cd "$work/mklive" && ./mklive.sh -a "$arch" -v "$LIVE_KERNEL" \
	-p "$LIVE_PKGS_OFFICIAL $grub_pkgs $LIVE_PKGS_INSTALLER" -S "$LIVE_SERVICES" \
	-I "$inc" -x "$work/postsetup.sh" -T "UniVoidDistro $short" -o "$iso" )
[ -s "$iso" ] || die "no $iso"

# UEFI starts the ISO from its El Torito image boot/grub/efiboot.img, a FAT with GRUB in it;
# mklive fills it on a loop mount whose failure it does not check
echo "== the EFI boot image: El Torito UEFI, FAT, EFI/BOOT/${efi_boot^^}"
xorriso -indev "$iso" -report_el_torito plain 2>/dev/null | grep -E '^El Torito (boot img|img path)'
xorriso -indev "$iso" -report_el_torito plain 2>/dev/null | grep -Eq '^El Torito boot img : +[0-9]+ +UEFI ' \
	|| die "$iso: no UEFI El Torito image"
xorriso -osirrox on -indev "$iso" -extract /boot/grub/efiboot.img "$work/efiboot.img" >/dev/null 2>&1 \
	|| die "$iso: no /boot/grub/efiboot.img"
mkdir "$work/efi"
mount -o loop,ro "$work/efiboot.img" "$work/efi" || die "$iso: the EFI boot image is not a FAT file system"
efi=$(cd "$work/efi" && find . -type f -size +0 | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')
umount "$work/efi"
echo "efiboot.img: $efi"
case " ${efi,,}" in *" efi/boot/$efi_boot "*) ;; *) die "$iso: no EFI/BOOT/${efi_boot^^} in the EFI boot image" ;; esac
# the kernel the rig boots directly (tests/vm/vhvm.py -kernel): vmlinuz on x86_64, the
# uncompressed Image as vmlinux on aarch64 (mklive's names)
case $arch in x86_64) kimg=boot/vmlinuz ;; aarch64) kimg=boot/vmlinux ;; esac
xorriso -indev "$iso" -find /"$kimg" -type f 2>/dev/null | grep -q . || die "$iso: no /$kimg"

echo "== SHA256SUMS, the package list, BUILD"
( cd "$out" && sha256sum "$(basename "$iso")" > SHA256SUMS )
cp "$pre/BUILD" "$out/BUILD"
{ echo "MKLIVE=$MKLIVE_COMMIT"; echo "KERNEL=$LIVE_KERNEL"; echo "ISO=$(basename "$iso")"; } >> "$out/BUILD"
grep -q '^ARCH=' "$out/BUILD" || echo "ARCH=$arch" >> "$out/BUILD"
[ -s "$out/live-packages.txt" ] || die "no package list (the post-setup script)"
grep -q "^$LIVE_KERNEL-[0-9]" "$out/live-packages.txt" || die "the image has no $LIVE_KERNEL"
ls -l "$out"
rm -rf "$work"
