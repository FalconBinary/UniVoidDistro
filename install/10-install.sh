#!/bin/bash
# Stage 1: installation from the live USB (glibc; x86_64, or aarch64 with UEFI since U5), as root.
#
#   cp vh.conf.example vh.conf && vi vh.conf      -- at minimum: VH_DISK
#   ./install/10-install.sh --dry-run             -- show the plan without changing anything
#   ./install/10-install.sh                       -- install
#
# What it does (the same steps by hand: docs/01...docs/03):
#   0. probes the machine and plans it (install/plan.sh: hwdb/ decides packages, firmware,
#      the kernel command line, services, initrd drivers and LUKS parameters); the security
#      gate (VH_SECURITY) stops here when the machine misses a protection;
#   1. partitions the disk as GPT: ESP (FAT32) + LUKS2 (XFS inside), no swap partition;
#   2. builds thor (xbps + security policy, docs/18) in the live environment's RAM and
#      installs the packages into /mnt through it from an HTTPS mirror, in parallel,
#      with the xbps keys taken from the live environment;
#   3. builds RefursWM and RefursLine (desktop/) with the Zig compiler in the live
#      environment's RAM (the compiler never reaches the installed system);
#   4. configures the system in a chroot (install/chroot.sh): users, PAM, network,
#      sysctl, AppArmor, UKI, Secure Boot keys, Limine, the NVRAM boot entry.
#
# Secure Boot must be OFF during installation (the Void live image is unsigned).
# Enrolling your own keys is stage 2 (install/20-firstboot.sh), after the first boot.

. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/packages.sh"

CFG=$VH_ROOT/vh.conf
while [ $# -gt 0 ]; do
	case $1 in
		--dry-run) DRY_RUN=1 ;;
		--config) CFG=$2; shift ;;
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
	shift
done

need_root
load_config "$CFG"
# the RAM at every heading (lib.sh: say_mem): the installation builds in the live environment's RAM
if [ "$DRY_RUN" = 0 ] && [ -r /proc/meminfo ]; then
	export VH_SAY_MEM=1
	: > "$VH_MEM_LOW"
	mem_sampler &
	# "|| true": under set -e a kill of a sampler that already ended would make the whole
	# installation exit 1 after "done" (kvm-smoke run 40394832080)
	trap 'kill '"$!"' 2>/dev/null || true' EXIT
fi
MNT=/mnt
# the repository of this architecture: MIRROR/current on x86_64, MIRROR/current/aarch64 on aarch64
REPO=$VH_MIRROR/current$(vh_repo_sub)
NONFREE=$REPO/nonfree
# the live environment's own xbps (the headers, Zig's dependencies, xbps itself) takes the same
# mirror: /etc/xbps.d overrides the image's /usr/share/xbps.d file of this name (the default
# mirror was unreachable for hours on 2026-10-26; the rig passes another through VH_MIRROR)
[ "$DRY_RUN" = 1 ] || { mkdir -p /etc/xbps.d && echo "repository=$REPO" > /etc/xbps.d/00-repository-main.conf; }

# ---------------------------------------------------------------- checks
say "checks"
[ -d /sys/firmware/efi/efivars ] || die "not booted in UEFI mode"
# x86_64 or aarch64, both through UEFI (checked above); the boot files by architecture (lib.sh)
VH_ARCH=$(vh_arch)
VH_EFI_BOOT=$(vh_efi_boot)
[ -n "$VH_DISK" ] || die "VH_DISK is not set in vh.conf"
[ -b "$VH_DISK" ] || die "$VH_DISK is not a block device"
case $(lsblk -dno TYPE "$VH_DISK") in disk) ;; *) die "$VH_DISK is not a whole disk" ;; esac
if lsblk -no MOUNTPOINTS "$VH_DISK" 2>/dev/null | grep -q .; then
	die "$VH_DISK has mounted partitions (is this the live USB itself?)"
fi
size_gib=$(( $(blockdev --getsize64 "$VH_DISK") / 1073741824 ))
[ "$size_gib" -ge 20 ] || die "disk smaller than 20 GiB"
# a firmware without Secure Boot support has no SecureBoot variable at all (QEMU's own AAVMF
# build, the aarch64 rig under hvf): then od finds no file, which pipefail would turn into an
# exit; the gate names the missing Secure Boot itself
sb=$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | tr -d ' ' || true)
[ "${sb:-0}" = 0 ] || warn "Secure Boot is on: the live image could not have booted this way; check the firmware"
ESP_PART=$(part "$VH_DISK" 1)
LUKS_PART=$(part "$VH_DISK" 2)
ok "disk $VH_DISK, $size_gib GiB: $ESP_PART (ESP $VH_ESP_SIZE) + $LUKS_PART (LUKS2)"
# the programs are built in RAM unless our live image of this commit brings them: building
# needs 3 GiB, refused here before anything is downloaded or written (lib.sh: need_build_ram)
rc=0
vh_prebuilt >/dev/null 2>&1 || rc=$?
[ "$DRY_RUN" = 1 ] || [ "$rc" != 1 ] || need_build_ram

# ---------------------------------------------------------------- the plan of this machine
say "the plan of this machine (install/plan.sh: the probe and the rules of hwdb/)"
if [ -n "${VH_PLAN_ENV:-}" ]; then
	# tests: a plan made beforehand
	PLAN_DIR=$(dirname "$VH_PLAN_ENV")
else
	PLAN_DIR=${VH_PLAN_DIR:-/tmp/vh}
	rc=0
	VH_PLAN_DIR=$PLAN_DIR bash "$VH_ROOT/install/plan.sh" --config "$CFG" || rc=$?
	[ "$rc" = 0 ] || [ "$rc" = 3 ] || die "the plan failed ($rc)"
fi
load_plan "$PLAN_DIR/plan.env"
# our live image brings thor, the desktop and the Zig tools built (docs/uni/live-image.md):
# PREBUILT is their directory there, empty elsewhere (they are built in RAM below)
rc=0
PREBUILT=$(vh_prebuilt) || rc=$?
[ "$rc" != 2 ] || die "the live image's programs do not match its SHA256SUMS"
security_gate "$PLAN_DIR/plan-report.txt"
# a USB keyboard always; the drivers on the way to this machine's own keyboards
VH_DRACUT_DRIVERS=$(printf '%s\n' xhci_pci usbhid hid_generic ${VH_PLAN_DRACUT:-} | awk '!seen[$0]++' | paste -sd' ' -)
export VH_DRACUT_DRIVERS
# Argon2id memory: vh.conf's value, unless the machine's RAM caps it (the plan; tiered only)
LUKS_MEM=$VH_LUKS_MEM_KIB
[ "${VH_PLAN_LUKS_MEM_KIB:-$LUKS_MEM}" -lt "$LUKS_MEM" ] && LUKS_MEM=$VH_PLAN_LUKS_MEM_KIB

cat <<EOF

Installation plan:
  disk            $VH_DISK ($(lsblk -dno MODEL "$VH_DISK"))  -- EVERYTHING ON IT WILL BE ERASED
  host            $VH_HOSTNAME, $VH_TIMEZONE, $VH_LOCALE, keymap $VH_KEYMAP, Wi-Fi regulatory domain $VH_REGDOM
  users           $VH_ADMIN (admin, tty2), $VH_USER (tty1), $VH_BROWSER_USER (browser)
  kernel          $VH_KERNEL, initramfs $VH_INITRD_COMPRESS, Limine timeout $VH_LIMINE_TIMEOUT
  machine         $VH_PLAN_CLASS ($VH_PLAN_ARCH), protection $VH_PLAN_TIER ($VH_SECURITY), $PLAN_DIR/plan-report.txt
  GPU             $VH_GPU   Bluetooth $VH_BLUETOOTH   Ethernet $VH_ETH   IPv6 $VH_IPV6
  MAC             $VH_MAC$( [ "$VH_MAC" = selinux ] && printf ' (%s at boot)' "$VH_SELINUX_MODE")
  hardware        $(printf '%s' "$VH_PLAN_PACKAGES" | fold -s -w 80 | sed '2,$s/^/                  /')
  TRIM            $VH_TRIM  zram $VH_ZRAM_ALGO ${VH_ZRAM_PERCENT}%
  desktop         RefursWM + RefursLine from desktop/ (built in the live environment's RAM)
  mirror          $VH_MIRROR
EOF
[ "$DRY_RUN" = 1 ] || confirm_exact "$VH_DISK" "All data on $VH_DISK will be destroyed irreversibly."

# ---------------------------------------------------------------- live environment
say "live environment tools (installed into RAM)"
run xbps-install -Syu xbps
run xbps-install -Sy cryptsetup xfsprogs dosfstools
run xbps-install -Sy minisign xz

# ---------------------------------------------------------------- partitioning
say "partitioning $VH_DISK (GPT: ESP + LUKS2)"
run wipefs -af "$VH_DISK"
if [ "$VH_TRIM" = yes ]; then
	# Tell the SSD that every block is free: old data is no longer reachable through the
	# disk interface and does not interfere with wear levelling. Not a guaranteed erase (docs/01).
	run blkdiscard -f "$VH_DISK" || warn "blkdiscard is not supported: skipped"
fi
if [ "$DRY_RUN" = 1 ]; then
	echo "   + sfdisk $VH_DISK (ESP $VH_ESP_SIZE, the rest LUKS)"
else
	sfdisk --wipe always --wipe-partitions always "$VH_DISK" <<EOF
label: gpt
size=$VH_ESP_SIZE, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ESP"
type=CA7D7CCB-63ED-4C53-861C-1742536059CC, name="cryptroot"
EOF
	udevadm settle
	for _ in 1 2 3 4 5; do [ -b "$LUKS_PART" ] && break; sleep 1; done
	[ -b "$LUKS_PART" ] || die "partition $LUKS_PART did not appear"
fi

# ---------------------------------------------------------------- LUKS2
say "LUKS2: $VH_PLAN_LUKS_CIPHER, $VH_PLAN_LUKS_KEY_SIZE bits, 4096-byte sectors, Argon2id (${VH_LUKS_ITER_MS} ms, $((LUKS_MEM/1024)) MiB, $VH_PLAN_LUKS_PARALLEL threads)"
LUKS_ARGS=(--type luks2 --cipher "$VH_PLAN_LUKS_CIPHER" --key-size "$VH_PLAN_LUKS_KEY_SIZE" --hash sha512
	--pbkdf argon2id --pbkdf-memory "$LUKS_MEM" --pbkdf-parallel "$VH_PLAN_LUKS_PARALLEL"
	--iter-time "$VH_LUKS_ITER_MS" --sector-size 4096 --label cryptroot)
OPEN_ARGS=(--perf-no_read_workqueue --perf-no_write_workqueue --persistent)
[ "$VH_TRIM" = yes ] && OPEN_ARGS+=(--allow-discards)
if [ -n "${VH_TEST_PASSPHRASE:-}" ]; then
	# Only for the automated VM tests (tests/vm). On a real machine the passphrase is typed.
	run_key() { printf '%s' "$VH_TEST_PASSPHRASE" | "$@" --key-file=-; }
	[ "$DRY_RUN" = 1 ] || run_key cryptsetup luksFormat -q "${LUKS_ARGS[@]}" "$LUKS_PART"
	[ "$DRY_RUN" = 1 ] || run_key cryptsetup open "${OPEN_ARGS[@]}" "$LUKS_PART" cryptroot
else
	echo "LUKS passphrase: 7 diceware words (docs/01). It is only ever typed in the initramfs at boot."
	run cryptsetup luksFormat "${LUKS_ARGS[@]}" "$LUKS_PART"
	run cryptsetup open "${OPEN_ARGS[@]}" "$LUKS_PART" cryptroot
fi

# ---------------------------------------------------------------- file systems
say "file systems"
run mkfs.vfat -F 32 -n ESP "$ESP_PART"
run mkfs.xfs -f -L voidroot -s size=4096 /dev/mapper/cryptroot
run mount -o noatime,logbsize=256k /dev/mapper/cryptroot "$MNT"
run mkdir -p "$MNT/boot/efi"
run mount -o nosuid,nodev,noexec,fmask=0177,dmask=0077 "$ESP_PART" "$MNT/boot/efi"

if [ "$DRY_RUN" = 1 ]; then
	VH_LUKS_UUID=DRYRUN-LUKS VH_ROOT_UUID=DRYRUN-ROOT VH_ESP_UUID=DRYRUN-ESP
else
	VH_LUKS_UUID=$(cryptsetup luksUUID "$LUKS_PART")
	VH_ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
	VH_ESP_UUID=$(blkid -s UUID -o value "$ESP_PART")
fi
export VH_LUKS_UUID VH_ROOT_UUID VH_ESP_UUID
VH_CMDLINE=$(vh_cmdline)
# Values for the rootfs/*.in templates that are derived from vh.conf
for u in $VH_DNS_UPSTREAMS; do
	[[ $u =~ ^[0-9.]+@853#[A-Za-z0-9.-]+$ ]] || die "VH_DNS_UPSTREAMS: \"$u\" must have the form IP@853#name"
done
VH_DOT_IPS=$(for u in $VH_DNS_UPSTREAMS; do echo "${u%%@*}"; done | sort -u | paste -sd, - | sed 's/,/, /g')
VH_UNBOUND_FORWARDS=$(for u in $VH_DNS_UPSTREAMS; do printf '\tforward-addr: %s\n' "$u"; done)
VH_CHRONY_SERVERS=$(for s in $VH_NTS_SERVERS; do printf 'server %s iburst nts\n' "$s"; done)
VH_SHM_SIZE="25%"
if [ "$VH_IPV6" = no ]; then
	# IPv6 is disabled in the kernel: AAAA records are stripped from answers (treated as
	# "private"), so programs do not waste time on IPv6 attempts that cannot succeed
	VH_UNBOUND_AAAA=$'\t# IPv6 is disabled (VH_IPV6=no): AAAA records are not returned\n\tprivate-address: ::/0'
else
	VH_UNBOUND_AAAA=""
fi
export VH_CMDLINE VH_DOT_IPS VH_UNBOUND_FORWARDS VH_CHRONY_SERVERS VH_SHM_SIZE VH_UNBOUND_AAAA
ok "LUKS $VH_LUKS_UUID, root $VH_ROOT_UUID, ESP $VH_ESP_UUID"

# ---------------------------------------------------------------- bootstrap
say "xbps: repository keys from the verified live environment and the xbps.d configs"
run mkdir -p "$MNT/var/db/xbps/keys" "$MNT/etc/xbps.d"
run cp -a /var/db/xbps/keys/. "$MNT/var/db/xbps/keys/"
# xbps.d goes in BEFORE installing: ignorepkg and noextract already apply to the bootstrap.
for f in "$VH_ROOT"/rootfs/etc/xbps.d/*; do
	b=$(basename "$f")
	if [ "$DRY_RUN" = 1 ]; then echo "   + render /etc/xbps.d/${b%.in}"; continue; fi
	case $b in
		*.in) render "$f" "$MNT/etc/xbps.d/${b%.in}" ;;
		*) install -m 0644 "$f" "$MNT/etc/xbps.d/$b" ;;
	esac
done
if [ "$VH_FIRMWARE_TRIM" = yes ]; then
	if [ "$DRY_RUN" = 1 ]; then echo "   + /etc/xbps.d/40-vh-firmware.conf (needed firmware only)"
	else
		# the links the plan's firmware is reached through: the firmware packages' file lists
		vh_firmware_files "$REPO" "$NONFREE" > /tmp/vh-firmware-files.txt
		if [ -s /tmp/vh-firmware-files.txt ]; then
			ok "firmware: $(grep -c . /tmp/vh-firmware-files.txt) entries of the firmware packages, $(grep -c ' -> ' /tmp/vh-firmware-files.txt) of them links"
		elif vh_packages | grep -qE "$VH_FIRMWARE_PKGS"; then
			warn "the firmware packages' file lists did not come: firmware the plan names through links under another name may be cut (vh-kconf check names it at the first boot)"
		else
			ok "firmware: the plan names no firmware package (a virtual machine without devices that need one)"
		fi
		vh_firmware_noextract /tmp/vh-firmware-files.txt > "$MNT/etc/xbps.d/40-vh-firmware.conf"
	fi
fi

if [ -n "$PREBUILT" ]; then
	say "thor: the live image's build (docs/18)"
	run bash "$VH_ROOT/install/build-thor.sh" --prebuilt "$PREBUILT/thor" "$MNT"
else
	say "thor: building in the live environment's RAM (docs/18)"
	run bash "$VH_ROOT/install/build-thor.sh" "$MNT"
fi
THOR=/tmp/vh-thor/dest/usr/bin/thor
# During installation the thor policy runs in learn mode: kernel hooks, dracut modules,
# sysctl.d files and udev rules of the base system packages are recorded in
# /etc/thor/baseline instead of being neutralised. SUID/SGID, capabilities and the
# deny list already apply.
if [ "$DRY_RUN" = 1 ]; then echo "   + /etc/thor/policy.conf: mode=learn"
else printf '# thor (docs/18): enforce -- the policy applies; learn -- only while the system is being installed\nmode=learn\n' > "$MNT/etc/thor/policy.conf"; fi
thor_install() {
	# the programs take libxbps with the policy from their own tree (rpath $ORIGIN/../lib)
	run env XBPS_ARCH="$VH_ARCH" "$THOR" install -y -r "$MNT" -R "$REPO" -R "$NONFREE" "$@"
}

say "installing packages ($(vh_packages | wc -l) + dependencies), without the kernel: thor, in parallel"
# The kernel is installed last, after the configuration below: its hooks then build the
# UKI with the right dracut-uefi, sign it with the keys that already exist and register
# it with Limine.
mapfile -t PKGS < <(vh_packages | grep -vx "$VH_KERNEL")
thor_install "${PKGS[@]}"

# ---------------------------------------------------------------- desktop
if [ -n "$PREBUILT" ]; then
	say "RefursWM and RefursLine: the live image's build $(vh_desktop_variant)"
	run bash "$VH_ROOT/install/build-desktop.sh" --prebuilt "$PREBUILT/desktop/$(vh_desktop_variant)" "$MNT"
else
	say "RefursWM and RefursLine: building in the live environment's RAM"
	run bash "$VH_ROOT/install/build-desktop.sh" "$MNT"
fi

# ---------------------------------------------------------------- configuration files
say "configuration files (rootfs/)"
install_tree "$VH_ROOT/rootfs" "$MNT"
run install -d -m 0700 "$MNT/root/vh"
# the C tools (src/) were removed when the tools moved to Zig; zig/ is copied instead
run cp -a "$VH_ROOT/install" "$VH_ROOT/tools" "$VH_ROOT/rootfs" "$VH_ROOT/optional" \
	"$VH_ROOT/zig" "$VH_ROOT/thor" "$VH_ROOT/hwdb" "$VH_ROOT/adapt" "$VH_ROOT/vh.conf.example" "$MNT/root/vh/"
run install -d -m 0700 "$MNT/root/vh/kernel"
run cp -a "$VH_ROOT/kernel/pins" "$VH_ROOT/kernel/profiles" "$VH_ROOT/kernel/src" "$VH_ROOT/kernel/build.zig" \
	"$VH_ROOT/kernel/build.zig.zon" "$MNT/root/vh/kernel/"
# the plan of this machine stays with it: the installer's scripts (chroot.sh, 30-lock.sh) read
# plan.env, vh-kconf and vh-plan re-plan it after a hardware change (U2)
run install -m 0600 "$PLAN_DIR/plan.env" "$MNT/root/vh/plan.env"
run install -d -m 0755 "$MNT/etc/vh"
for f in hw.zon plan.zon plan-report.txt; do
	run install -m 0644 "$PLAN_DIR/$f" "$MNT/etc/vh/$f"
done
if [ -x "$PLAN_DIR/bin/vh-plan" ]; then
	run install -m 0755 "$PLAN_DIR/bin/vh-kconf" "$PLAN_DIR/bin/vh-plan" "$MNT/usr/local/sbin/"
fi
# Zig tools: the compiler lives only in the live environment's RAM; the system gets binaries
if [ -n "$PREBUILT" ]; then
	run bash "$VH_ROOT/install/build-tools.sh" --prebuilt "$PREBUILT/bin" "$MNT"
else
	run bash "$VH_ROOT/install/build-tools.sh" "$MNT"
fi
# the SELinux policy (docs/uni/selinux.md): built by secilc, which Void lacks; our live image
# brings it (live/prebuilt.sh), the installer only copies it. The machine kernel of the plan
# gets CONFIG_SECURITY_SELINUX from the feature the rule security.mac.selinux selects.
if [ "$VH_MAC" = selinux ]; then
	SELINUX_SRC=
	if [ -n "$PREBUILT" ] && [ -s "$PREBUILT/selinux/file_contexts" ]; then
		SELINUX_SRC=$PREBUILT/selinux
	elif [ -n "$VH_SELINUX_DIR" ]; then
		# a policy built elsewhere (sh selinux/build.sh DIR, on a USB stick or the VM rig's repository
		# copy); checked here and not in load_config, which chroot.sh runs where DIR does not exist
		[ -s "$VH_SELINUX_DIR/SHA256SUMS" ] || die "VH_SELINUX_DIR: $VH_SELINUX_DIR has no SHA256SUMS (sh selinux/build.sh DIR)"
		( cd "$VH_SELINUX_DIR" && sha256sum -c --quiet SHA256SUMS ) || die "$VH_SELINUX_DIR: a file does not match its SHA256SUMS"
		[ -s "$VH_SELINUX_DIR/file_contexts" ] || die "$VH_SELINUX_DIR: no file_contexts"
		SELINUX_SRC=$VH_SELINUX_DIR
	fi
	[ -n "$SELINUX_SRC" ] || die "VH_MAC=selinux needs the policy built: install from UniVoidDistro's live image (live/prebuilt.sh builds selinux/ with secilc), or build it with sh selinux/build.sh DIR and set VH_SELINUX_DIR=DIR"
	say "SELinux policy from $SELINUX_SRC ($(sed -n 's/^COMMIT=//p' "$SELINUX_SRC/BUILD"))"
	run install -d -m 0755 "$MNT/etc/vh/selinux"
	run install -m 0644 "$SELINUX_SRC"/policy.* "$SELINUX_SRC/file_contexts" "$SELINUX_SRC/BUILD" "$SELINUX_SRC/SHA256SUMS" "$MNT/etc/vh/selinux/"
fi
[ -f "$CFG" ] && run install -m 0600 "$CFG" "$MNT/root/vh/vh.conf"
if [ "$DRY_RUN" != 1 ]; then
	printf 'VH_LUKS_UUID=%s\nVH_ROOT_UUID=%s\nVH_ESP_UUID=%s\nVH_DISK=%s\n' \
		"$VH_LUKS_UUID" "$VH_ROOT_UUID" "$VH_ESP_UUID" "$VH_DISK" > "$MNT/root/vh/ids"
fi

# ---------------------------------------------------------------- chroot
say "configuring in the chroot"
chroot_mounts() {
	run mount -t proc proc "$MNT/proc"
	run mount -t sysfs sys "$MNT/sys"
	run mount -t efivarfs efivarfs "$MNT/sys/firmware/efi/efivars"
	run mount --rbind /dev "$MNT/dev"
	run mount --make-rslave "$MNT/dev"
	run mount -t tmpfs -o mode=0755,nosuid,nodev run "$MNT/run"
	if [ -e /sys/kernel/security/tpm0 ]; then
		run mount -t securityfs securityfs "$MNT/sys/kernel/security"
	fi
}
chroot_mounts
run env -i PATH=/usr/bin:/usr/sbin HOME=/root TERM="${TERM:-linux}" \
	VH_TEST_PASSWORD="${VH_TEST_PASSWORD:-}" VH_YES="${VH_YES:-0}" \
	chroot "$MNT" /bin/bash /root/vh/install/chroot.sh

# ---------------------------------------------------------------- kernel and bootloader
say "kernel $VH_KERNEL: dracut-uefi -> UKI -> signature -> limine.conf -> Limine"
thor_install "$VH_KERNEL"
if [ "$DRY_RUN" != 1 ]; then
	ls "$MNT"/boot/efi/EFI/void/linux-*.efi >/dev/null 2>&1 || die "no UKI was created (see the dracut output above)"
	[ -s "$MNT/boot/efi/EFI/BOOT/$VH_EFI_BOOT" ] && [ -s "$MNT/boot/efi/EFI/BOOT/limine.conf" ] \
		|| die "Limine is not installed on the ESP (vh-limine-update)"
	ok "$(ls "$MNT"/boot/efi/EFI/void/)"
fi

say "NVRAM boot entry"
# Old entries with the same name are removed so they do not pile up on reinstallation.
if [ "$DRY_RUN" != 1 ]; then
	chroot "$MNT" efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\*\? Void Linux (Limine).*/\1/p' \
		| while read -r n; do chroot "$MNT" efibootmgr -q -b "$n" -B; done
fi
run chroot "$MNT" efibootmgr -q -c -d "$VH_DISK" -p 1 -L "Void Linux (Limine)" -l "\\EFI\\BOOT\\$VH_EFI_BOOT"

# The package cache (~1.5 GB) is not needed on the target system.
run rm -rf "$MNT/var/cache/xbps"

# the labels of what came after the chroot's relabel: the kernel package (its modules), the UKI
# hook's files (the mounted ESP itself takes no label; /boot is relabelled at boot)
if [ "$VH_MAC" = selinux ] && [ "$DRY_RUN" != 1 ]; then
	say "SELinux: the labels of the kernel's files"
	chroot "$MNT" /usr/local/sbin/vh-selabel --one-fs / | tail -1
	selabel_diff=$(chroot "$MNT" /usr/local/sbin/vh-selabel --check --one-fs / 2>&1) \
		|| { printf '%s\n' "$selabel_diff" | tail -25; die "vh-selabel: a label differs after the kernel's installation"; }
fi

say "thor policy: enforce (baseline: $(grep -vc '^#' "$MNT/etc/thor/baseline" 2>/dev/null || echo 0) entries)"
if [ "$DRY_RUN" = 1 ]; then echo "   + /etc/thor/policy.conf: mode=enforce"
else printf '# thor (docs/18): enforce -- the policy applies; learn -- only while the system is being installed\nmode=enforce\n' > "$MNT/etc/thor/policy.conf"; fi

# ---------------------------------------------------------------- done
say "done"
cat <<EOF

Installation finished. Next:
  1. Back up the LUKS header to external media (docs/01):
       cryptsetup luksHeaderBackup $LUKS_PART --header-backup-file /path/on/usb/luks-header.img
  2. Unmount and reboot:
       umount -R $MNT && cryptsetup close cryptroot && reboot
  3. Remove the USB stick. Boot: Limine -> UKI -> LUKS passphrase -> login.
  4. Log in on tty2 as $VH_ADMIN and run stage 2:
       doas /root/vh/install/20-firstboot.sh     (details: docs/03)
EOF
