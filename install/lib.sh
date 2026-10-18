# shellcheck shell=bash
# Shared installer functions. Sourced with ". lib.sh".

set -euo pipefail
umask 022

VH_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [ -t 1 ]; then
	C_B=$'\e[1m' C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_0=$'\e[0m'
else
	C_B="" C_R="" C_G="" C_Y="" C_0=""
fi

say()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# In --dry-run mode commands are printed instead of executed.
DRY_RUN=${DRY_RUN:-0}
run() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '   + %s\n' "$*"
	else
		"$@"
	fi
}

need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }

# Confirmation: the user must type the exact string.
confirm_exact() {
	local want=$1 prompt=$2 got
	[ "${VH_YES:-0}" = 1 ] && return 0
	printf '%s%s%s\nType "%s" to continue: ' "$C_Y" "$prompt" "$C_0" "$want"
	read -r got
	[ "$got" = "$want" ] || die "cancelled"
}

yesno() { # yesno NAME VALUE: the value must be yes or no
	case $2 in yes|no) ;; *) die "$1 must be yes or no, not \"$2\"" ;; esac
}

load_config() {
	local cfg=${1:-$VH_ROOT/vh.conf}
	# Defaults come from the example, then the user's file. set -a exports the
	# variables: render() reads them when substituting @VH_*@ in templates.
	set -a
	# shellcheck source=/dev/null
	. "$VH_ROOT/vh.conf.example"
	if [ -f "$cfg" ]; then
		# shellcheck source=/dev/null
		. "$cfg"
	else
		warn "no $cfg: using the defaults"
	fi
	set +a
	yesno VH_TRIM "$VH_TRIM"
	yesno VH_CAMERA "$VH_CAMERA"
	yesno VH_CARDREADER "$VH_CARDREADER"
	yesno VH_VIRT "$VH_VIRT"
	yesno VH_IPV6 "$VH_IPV6"
	yesno VH_HOME_NOEXEC "$VH_HOME_NOEXEC"
	yesno VH_FIRMWARE_TRIM "$VH_FIRMWARE_TRIM"
	case $VH_GPU in igpu|nouveau) ;; *) die "VH_GPU: igpu or nouveau" ;; esac
	case $VH_BLUETOOTH in off|optional|on) ;; *) die "VH_BLUETOOTH: off, optional or on" ;; esac
	case $VH_ETH in dhcp|static|off) ;; *) die "VH_ETH: dhcp, static or off" ;; esac
	case $VH_INITRD_COMPRESS in zstd|lz4) ;; *) die "VH_INITRD_COMPRESS: zstd or lz4" ;; esac
	case $VH_ZRAM_ALGO in zstd|lz4|lzo-rle) ;; *) die "VH_ZRAM_ALGO: zstd, lz4 or lzo-rle" ;; esac
	case $VH_MIRROR in https://*) ;; *) die "VH_MIRROR must start with https://" ;; esac
	if [ "$VH_ETH" = static ]; then
		[ -n "$VH_ETH_ADDR" ] && [ -n "$VH_ETH_GW" ] || die "VH_ETH=static requires VH_ETH_ADDR and VH_ETH_GW"
	fi
	local n
	for n in "$VH_ADMIN" "$VH_USER" "$VH_BROWSER_USER" "$VH_HOSTNAME"; do
		[[ $n =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "invalid name \"$n\""
	done
	[ "$VH_ADMIN" != "$VH_USER" ] || die "VH_ADMIN and VH_USER must differ"
	if [ -n "$VH_DEV_DIR" ]; then
		[[ $VH_DEV_DIR =~ ^[A-Za-z0-9._-]+$ ]] || die "VH_DEV_DIR must be a single directory name, without \"/\""
	fi
}

# Partition names: nvme0n1 -> nvme0n1p1, sda -> sda1.
part() {
	case $1 in
		*[0-9]) printf '%sp%s' "$1" "$2" ;;
		*) printf '%s%s' "$1" "$2" ;;
	esac
}

# render SOURCE DEST [MODE]: substitutes @VH_*@ and @VAR@ from the environment.
# An unknown placeholder is an error, so that no "@X@" is left in a config file.
render() {
	local src=$1 dst=$2 mode=${3:-0644}
	mkdir -p "$(dirname "$dst")"
	awk -v src="$src" '
	{
		out = ""; s = $0
		while (match(s, /@[A-Z][A-Z0-9_]*@/)) {
			name = substr(s, RSTART + 1, RLENGTH - 2)
			if (name in ENVIRON) val = ENVIRON[name]
			else { missing[name] = 1; val = substr(s, RSTART, RLENGTH) }
			out = out substr(s, 1, RSTART - 1) val
			s = substr(s, RSTART + RLENGTH)
		}
		print out s
	}
	END {
		n = 0
		for (m in missing) list = list (n++ ? ", " : "") m
		if (n) { print "render " src ": undefined " list > "/dev/stderr"; exit 1 }
	}' "$src" > "$dst.vhtmp" || { rm -f "$dst.vhtmp"; return 1; }
	chmod "$mode" "$dst.vhtmp"
	mv -f "$dst.vhtmp" "$dst"
}

# Copies the rootfs/ tree into ROOT: *.in files go through render(), the rest are
# copied as they are. Modes: executable -> 0755, others -> 0644, doas.conf -> 0400.
# *.cin files are rendered by chroot.sh: they need values that exist only inside the
# system (GIDs of the groups it creates).
install_tree() {
	local tree=$1 root=$2 f rel dst mode
	while IFS= read -r -d '' f; do
		rel=${f#"$tree"/}
		case $rel in *.cin) continue ;; esac
		dst=$root/${rel%.in}
		if [ -x "$f" ]; then mode=0755; else mode=0644; fi
		case $rel in
			etc/doas.conf*) mode=0400 ;;
			etc/sudoers*) mode=0440 ;;
		esac
		if [ "$DRY_RUN" = 1 ]; then
			printf '   + install %s (%s)\n' "/${rel%.in}" "$mode"
			continue
		fi
		mkdir -p "$(dirname "$dst")"
		case $rel in
			*.in) render "$f" "$dst" "$mode" ;;
			*) install -m "$mode" "$f" "$dst" ;;
		esac
	done < <(find "$tree" -type f -print0 | sort -z)
}

export -f render 2>/dev/null || true

# Modules the kernel refuses to load (module_blacklist= on the cmdline and
# "install ... /bin/false" in modprobe.d). Rationale: docs/03, docs/05.
vh_module_blacklist() {
	local m=(
		# rare network protocols, reachable without privileges through socket()
		sctp sctp_diag rds rds_tcp rds_rdma tipc can atm ax25 netrom rose x25
		appletalk ieee802154 nfc
		# DMA-capable ports and exotic hardware
		firewire_core firewire_ohci firewire_sbp2 thunderbolt usbip_host vhci_hcd
		# file systems that are never mounted here
		cramfs hfs hfsplus udf cifs nfs nfsv4 ksmbd 9p jffs2 freevxfs
		# unprivileged mounts inside a user namespace (the CVE-2023-0386 class): in the
		# Void kernel these are modules, so loading is denied (no flatpak/AppImage/podman here)
		fuse overlay
		# miscellaneous
		binfmt_misc uhid vivid pcspkr
		# ACPI power button: tiny_power_button and button match the same device (PNP0C0C)
		# and the first one to autoload wins. tiny_power_button provides no input device
		# and instead sends init a "Ctrl+Alt+Del": vh-acpid never sees the button and its
		# action bypasses /etc/vh/acpi.conf (found on the test bench, kernel 6.18.57)
		tiny_power_button
		# Intel ME interface (AMT is off; the fTPM works through tpm_crb)
		mei mei_me mei_hdcp mei_pxp mei_wdt
	)
	[ "$VH_BLUETOOTH" = off ] && m+=(bluetooth btusb btintel btrtl btbcm btmtk)
	[ "$VH_CAMERA" = no ] && m+=(uvcvideo)
	[ "$VH_CARDREADER" = no ] && m+=(rtsx_pci rtsx_pci_sdmmc)
	[ "$VH_VIRT" = no ] && m+=(kvm kvm_intel)
	[ "$VH_GPU" = igpu ] && m+=(nouveau)
	printf '%s\n' "${m[@]}"
}

# Firmware: only the files this laptop needs are extracted (VH_FIRMWARE_TRIM=yes).
# linux-firmware-network is 440 MB of firmware for every network chip (Qualcomm, Mediatek,
# Broadcom...); here only iwlwifi (AX201), Intel BT, rtl_nic (RTL8111), i915 and the
# microcode are needed. noextract also applies to updates; "!" re-includes a match
# (man xbps.d). docs/02.
vh_firmware_noextract() {
	local keep=(
		"intel-ucode/*"          # CPU microcode (dracut early_microcode)
		"regulatory.db*"         # Wi-Fi regulatory database (wireless-regdb)
		"i915/kbl_*" "i915/cml_*"   # Comet Lake: DMC (and GuC/HuC if enabled)
		"iwlwifi-Qu*"            # AX201 CNVi: Qu/QuZ-*-hr-*
		"intel/ibt-*"            # AX201 Bluetooth (8087:0026)
		"rtl_nic/*"              # RTL8111/8168 (r8169)
	)
	[ "$VH_GPU" = nouveau ] && keep+=("nvidia/tu11*")   # TU117: GSP, PMU and so on
	local k
	echo "# void-hardperf-light: firmware for this hardware only (VH_FIRMWARE_TRIM=yes, docs/02)."
	echo "# To get everything back: delete this file and run xbps-install -f linux-firmware-network linux-firmware-intel"
	echo "noextract=/usr/lib/firmware/*"
	# shellcheck disable=SC2206 # intentional word splitting
	for k in "${keep[@]}" ${VH_FIRMWARE_KEEP:-}; do
		echo "noextract=!/usr/lib/firmware/$k"
	done
}

# Kernel command line embedded in the UKI. Under Secure Boot systemd-stub ignores
# anything passed from outside, so changing it means rebuilding the UKI.
# Every parameter is explained in docs/03-boot.md.
vh_cmdline() {
	local bl
	bl=$(vh_module_blacklist | paste -sd, -)
	local c=(
		"rd.luks.uuid=$VH_LUKS_UUID" "root=UUID=$VH_ROOT_UUID" rootfstype=xfs
		rootflags=noatime,logbsize=256k ro
		rd.lvm=0 rd.md=0 rd.dm=0 rd.shell=0 rd.emergency=poweroff
		quiet loglevel=3 net.ifnames=0
		panic=10
		lockdown=confidentiality module.sig_enforce=1
		lsm=landlock,lockdown,yama,apparmor
		intel_iommu=on iommu.strict=1 iommu.passthrough=0 efi=disable_early_pci_dma
		init_on_alloc=1 init_on_free=1 slab_nomerge page_alloc.shuffle=1
		debugfs=off ia32_emulation=0
		bdev_allow_write_mounted=0 efi_pstore.pstore_disable=1 proc_mem.force_override=never
		"cfg80211.ieee80211_regdom=$VH_REGDOM"
		preempt=full
		"module_blacklist=$bl"
	)
	[ "$VH_IPV6" = no ] && c+=(ipv6.disable=1)
	# shellcheck disable=SC2206 # intentional word splitting
	[ -n "${VH_EXTRA_CMDLINE:-}" ] && c+=($VH_EXTRA_CMDLINE)
	printf '%s' "${c[*]}"
}
