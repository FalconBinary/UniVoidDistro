#!/bin/bash
# Our live image (docs/uni/live-image.md): void-mklive at the pinned commit (live/mklive.pins),
# the kernel series of the installed system, the official base image's packages and services
# plus the installer's tools, the repository at the commit of PREBUILT in /root/vh, and the
# programs of live/prebuilt.sh in /usr/local/lib/vh/prebuilt. Into OUT: the ISO, its SHA256SUMS,
# the image's package list and BUILD.
#   bash live/build-image.sh PREBUILT OUT   (root, in a privileged Void container: mklive needs
#                                            chroot and loop devices; the live-image workflow)
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
pre=${1:?"the prebuilt directory (live/prebuilt.sh)"} out=${2:?"output directory"}
. "$repo/live/mklive.pins"
die() { echo "live/build-image.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -r "$pre/BUILD" ] && [ -r "$pre/SHA256SUMS" ] || die "$pre: no BUILD or SHA256SUMS (live/prebuilt.sh)"
( cd "$pre" && sha256sum -c --quiet SHA256SUMS ) || die "$pre: a file does not match SHA256SUMS"
commit=$(sed -n 's/^COMMIT=//p' "$pre/BUILD")
[ -n "$commit" ] || die "$pre/BUILD: no COMMIT"
short=${commit:0:12}
work=$(mktemp -d /tmp/vh-live.XXXXXX)
mkdir -p "$out"

echo "== void-mklive $MKLIVE_COMMIT"
git init -q "$work/mklive"
git -C "$work/mklive" fetch -q --depth 1 "$MKLIVE_REPO" "$MKLIVE_COMMIT"
git -C "$work/mklive" checkout -q FETCH_HEAD
[ "$(git -C "$work/mklive" rev-parse HEAD)" = "$MKLIVE_COMMIT" ] || die "void-mklive is not at $MKLIVE_COMMIT"

echo "== the image's own files: /root/vh at $short, the prebuilt programs, /etc/vh-live"
inc=$work/include
mkdir -p "$inc/root/vh" "$inc/usr/local/lib/vh" "$inc/etc"
git -C "$repo" archive "$commit" | tar -x -C "$inc/root/vh"
echo "$commit" > "$inc/root/vh/.vh-commit"
chmod 0700 "$inc/root/vh"
cp -a "$pre" "$inc/usr/local/lib/vh/prebuilt"
cat > "$inc/etc/vh-live" <<EOT
# UniVoidDistro's live image (docs/uni/live-image.md)
COMMIT=$commit
RUN=${GITHUB_RUN_ID:-local}
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

iso=$out/univoiddistro-live-x86_64-$short.iso
echo "== mklive.sh: $iso"
( cd "$work/mklive" && ./mklive.sh -a x86_64 -v "$LIVE_KERNEL" \
	-p "$LIVE_PKGS_OFFICIAL $LIVE_PKGS_INSTALLER" -S "$LIVE_SERVICES" \
	-I "$inc" -x "$work/postsetup.sh" -T "UniVoidDistro $short" -o "$iso" )
[ -s "$iso" ] || die "no $iso"

echo "== SHA256SUMS, the package list, BUILD"
( cd "$out" && sha256sum "$(basename "$iso")" > SHA256SUMS )
cp "$pre/BUILD" "$out/BUILD"
{ echo "MKLIVE=$MKLIVE_COMMIT"; echo "KERNEL=$LIVE_KERNEL"; echo "ISO=$(basename "$iso")"; } >> "$out/BUILD"
[ -s "$out/live-packages.txt" ] || die "no package list (the post-setup script)"
grep -q "^$LIVE_KERNEL-[0-9]" "$out/live-packages.txt" || die "the image has no $LIVE_KERNEL"
ls -l "$out"
rm -rf "$work"
