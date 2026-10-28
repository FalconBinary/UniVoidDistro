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

say()  { printf '%s==>%s %s%s\n' "$C_B" "$C_0" "$*" "$(say_mem)"; }
ok()   { printf '%s  ok%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s  !!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# With VH_SAY_MEM=1 (10-install.sh: the live environment builds everything in its RAM) every
# heading also shows the RAM: MemAvailable now, what tmpfs holds (Shmem), and the lowest
# MemAvailable mem_sampler saw since the previous heading, which is where a build peaks
VH_MEM_LOW=/tmp/vh-mem.low
say_mem() {
	[ "${VH_SAY_MEM:-0}" = 1 ] && [ -r /proc/meminfo ] || return 0
	local low=
	if [ -s "$VH_MEM_LOW" ]; then low=$(cat "$VH_MEM_LOW"); : > "$VH_MEM_LOW"; fi
	awk -v low="$low" '/^MemAvailable:/ { a = $2 } /^Shmem:/ { s = $2 }
		END {
			if (a == "") exit
			printf "   [RAM: %d MiB available, %d MiB in tmpfs", a / 1024, s / 1024
			if (low != "") printf "; lowest since the previous step %d MiB", low / 1024
			printf "]"
		}' /proc/meminfo
}
# every 2 s, the lowest MemAvailable into $VH_MEM_LOW (say_mem empties it at each heading)
mem_sampler() {
	local a l
	while sleep 2; do
		a=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo) || continue
		l=$(cat "$VH_MEM_LOW" 2>/dev/null) || l=
		if [ -z "$l" ] || [ "$a" -lt "$l" ]; then echo "$a" > "$VH_MEM_LOW" || true; fi
	done
}

# Building the installer's programs in the live system's RAM (Void's own image, or ours of
# another commit) peaks at 2.1 GiB, the RefursWM build with Zig and the earlier builds in tmpfs
# (the VM rig): 3 GiB, which the gate's memory floor no longer asks for since our live image
# brings them built (hwdb/security.zon, memory-floor; docs/uni/live-image.md). MemTotal, as the
# probe reads it; VH_MEMINFO is for tests.
VH_BUILD_RAM_MIB=2750
need_build_ram() {
	local total
	total=$(awk '/^MemTotal:/ { print int($2 / 1024) }' "${VH_MEMINFO:-/proc/meminfo}" 2>/dev/null) || total=
	[ -n "$total" ] || return 0
	[ "$total" -ge "$VH_BUILD_RAM_MIB" ] || die "the kernel sees $total MiB of memory: building the installer's programs in RAM needs 3 GiB. UniVoidDistro's live image of this commit brings them built and installs in 1.5 GiB (docs/uni/live-image.md)"
}

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

# The architecture of the machine being installed, as the boot files name it (UEFI 3.5.1.1,
# the removable-media loader): x64 on x86_64, aa64 on aarch64 (U5). The EFI stub of the UKI is
# linuxARCH.efi.stub, Limine's loader on the ESP is EFI/BOOT/BOOTARCH.EFI, and xbps's
# architecture is uname's. The serial console the VM rig logs in on is ttyS0 on x86 and the
# PL011 ttyAMA0 on ARM.
vh_arch() {
	local m
	m=$(uname -m)
	case $m in x86_64|aarch64) echo "$m" ;; *) die "no installation path for $m: x86_64 or aarch64 (docs/uni/ROADMAP.md, U5)" ;; esac
}
vh_efi_arch() { case $(vh_arch) in x86_64) echo x64 ;; aarch64) echo aa64 ;; esac; }
# Void's repository of the architecture below MIRROR/current: x86_64 at the root, aarch64 in
# /aarch64 (thor/package.sh writes the same into the installed xbps)
vh_repo_sub() { case $(vh_arch) in x86_64) echo "" ;; aarch64) echo /aarch64 ;; esac; }
vh_efi_boot() { echo "BOOT$(vh_efi_arch | tr '[:lower:]' '[:upper:]').EFI"; }
vh_serial_tty() { case $(vh_arch) in x86_64) echo ttyS0 ;; aarch64) echo ttyAMA0 ;; esac; }

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
	# the EFI stub's name in the dracut template (rootfs/etc/dracut.conf.d/10-vh.conf.in) and the
	# repository's path in the xbps.d templates (rootfs/etc/xbps.d/*.in)
	VH_EFI_ARCH=$(vh_efi_arch)
	VH_REPO_SUB=$(vh_repo_sub)
	export VH_EFI_ARCH VH_REPO_SUB
	yesno VH_TRIM "$VH_TRIM"
	yesno VH_CAMERA "$VH_CAMERA"
	yesno VH_CARDREADER "$VH_CARDREADER"
	yesno VH_VIRT "$VH_VIRT"
	yesno VH_IPV6 "$VH_IPV6"
	yesno VH_HOME_NOEXEC "$VH_HOME_NOEXEC"
	yesno VH_FIRMWARE_TRIM "$VH_FIRMWARE_TRIM"
	case $VH_SECURITY in strict|tiered) ;; *) die "VH_SECURITY: strict or tiered" ;; esac
	case $VH_MAC in apparmor|selinux) ;; *) die "VH_MAC: apparmor or selinux" ;; esac
	case $VH_SELINUX_MODE in permissive|enforcing) ;; *) die "VH_SELINUX_MODE: permissive or enforcing" ;; esac
	case $VH_GPU in auto|igpu|nouveau) ;; *) die "VH_GPU: auto, igpu or nouveau" ;; esac
	case $VH_BLUETOOTH in off|optional|on) ;; *) die "VH_BLUETOOTH: off, optional or on" ;; esac
	case $VH_ETH in auto|dhcp|static|off) ;; *) die "VH_ETH: auto, dhcp, static or off" ;; esac
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

# The plan of this machine (vh-plan, install/plan.sh): the VH_PLAN_* values. plan.env is
# checked before it is sourced: every line is a comment, empty, or VH_PLAN_NAME='value' with
# nothing a shell would expand inside the quotes (vh-plan writes only such lines; a file that
# says anything else was not written by it).
load_plan() {
	local f=${1:-/tmp/vh/plan.env}
	[ -r "$f" ] || die "no plan $f: run install/plan.sh first (it probes the machine and plans it)"
	if grep -v -E "^(#.*)?$" "$f" | grep -q -v -E "^VH_PLAN_[A-Z0-9_]+='[A-Za-z0-9_.,:=/*+@ -]*'$"; then
		die "$f has lines vh-plan does not write; refusing to source it"
	fi
	set -a
	# shellcheck source=/dev/null
	. "$f"
	set +a
	[ -n "${VH_PLAN_TIER:-}" ] || die "$f: no VH_PLAN_TIER"
}

# The security gate (docs/uni/principles.md): refused stops; reduced stops in strict mode and
# asks for a typed confirmation of every residual risk in tiered mode. The report lists them.
# The commit of this repository: git's, or .vh-commit where the copy has no .git (the copy on
# our live image, the rig's copy in its VM)
vh_commit() {
	git -C "$VH_ROOT" rev-parse HEAD 2>/dev/null || cat "$VH_ROOT/.vh-commit" 2>/dev/null || true
}

# The programs our live image brings already built (live/prebuilt.sh, docs/uni/live-image.md):
# prints their directory when this is our image, made from this very commit, and every file
# matches the image's SHA256SUMS. Returns 1 when it is not (Void's own image, another commit:
# the installer builds as before), 2 when a file does not match: the caller stops then, since
# the image is not what was built.
VH_PREBUILT=${VH_PREBUILT:-/usr/local/lib/vh/prebuilt}
vh_prebuilt() {
	local built here
	[ -r /etc/vh-live ] && [ -r "$VH_PREBUILT/SHA256SUMS" ] || return 1
	built=$(sed -n 's/^COMMIT=//p' /etc/vh-live)
	here=$(vh_commit)
	if [ -z "$built" ] || [ "$built" != "$here" ]; then
		warn "the live image was built from ${built:-an unknown commit}, this repository is ${here:-of an unknown commit}: building here instead of using the image's programs"
		return 1
	fi
	if ! ( cd "$VH_PREBUILT" && sha256sum -c --quiet SHA256SUMS ) >&2; then
		warn "$VH_PREBUILT: a file does not match SHA256SUMS"
		return 2
	fi
	echo "$VH_PREBUILT"
}

# Which of the live image's builds of RefursWM and RefursLine fits this machine: the plan's
# x86-64 level (v3 when its CPU has it, v1 otherwise) and VH_BLUETOOTH (optional compiles the
# bar's Bluetooth menu in); on aarch64 the one build for every ARMv8 core (live/prebuilt.sh)
vh_desktop_variant() {
	local lvl=v1 bt=plain
	[ "${VH_BLUETOOTH:-}" = optional ] && bt=btmenu
	case ${VH_PLAN_ARCH:-$(uname -m)} in aarch64) echo "aarch64-$bt"; return ;; esac
	case " ${VH_PLAN_TAGS:-} " in *" x86-64-v3 "*) lvl=v3 ;; esac
	echo "x86-64-$lvl-$bt"
}

security_gate() {
	local report=${1:-/tmp/vh/plan-report.txt}
	case $VH_PLAN_TIER in
		full) ok "security: every protection of this architecture is available" ;;
		refused)
			sed -n '/^Requirements not met/,/^$/p' "$report" >&2
			die "this machine is below the floor of the security gate (see above)" ;;
		reduced)
			sed -n '/^Requirements not met/,/^$/p' "$report"
			[ "$VH_SECURITY" = tiered ] || die "VH_SECURITY=strict refuses a machine that misses a requirement (above: what is missing and the firmware setting that fixes it); VH_SECURITY=tiered installs it with the risks confirmed"
			confirm_exact "accept $VH_PLAN_ACKNOWLEDGE" "Install with these residual risks? Missing: $VH_PLAN_ACKNOWLEDGE." ;;
		*) die "VH_PLAN_TIER: $VH_PLAN_TIER" ;;
	esac
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
		# a link goes in as a link: runit's state of each service in /run, as Void's packages
		# ship it (/etc/sv/NAME/supervise -> /run/runit/supervise.NAME), in place of a supervise
		# directory a runsv made on disk before the link was there
		if [ -L "$f" ]; then
			if [ "$DRY_RUN" = 1 ]; then
				printf '   + link %s -> %s\n' "/$rel" "$(readlink "$f")"
				continue
			fi
			mkdir -p "$(dirname "$dst")"
			[ -L "$dst" ] || rm -rf "$dst"
			ln -sfn "$(readlink "$f")" "$dst"
			continue
		fi
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
	done < <(find "$tree" \( -type f -o -type l \) -print0 | sort -z)
}

export -f render 2>/dev/null || true

# Modules the kernel refuses to load (module_blacklist= on the cmdline and
# "install ... /bin/false" in modprobe.d). Rationale: docs/03, docs/05. The policy below is
# the same on every machine; what depends on the hardware or on vh.conf (the ME interface of
# an Intel CPU, nouveau beside a sleeping dGPU, Bluetooth off, the camera, the card reader,
# KVM) comes from the plan (VH_PLAN_DENY, hwdb/).
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
		# (tiny_power_button: the plan decides, hwdb/platform.zon acpi.power-button.*)
	)
	# shellcheck disable=SC2206 # the plan's list, one word per module
	m+=(${VH_PLAN_DENY:-})
	printf '%s\n' "${m[@]}"
}

# Firmware: only the files this machine's drivers need are extracted (VH_FIRMWARE_TRIM=yes).
# The linux-firmware packages hold hundreds of MB for every chip; the plan lists what the
# modules of this machine's devices name (kernel/pins/modules.firmware), narrowed to the device
# where a rule of hwdb/ knows it, plus the microcode and regulatory.db (VH_PLAN_FIRMWARE).
# noextract also applies to updates; "!" re-includes a match, and xbps matches with fnmatch
# without FNM_PATHNAME, so "*" crosses "/" (man xbps.d; lib/util.c). docs/02.
#
# The names the drivers ask for are often links. linux-firmware keeps them as links into vendor
# directories (iwlwifi-*.ucode -> intel/iwlwifi/, since 2025), some under another name
# (amdgpu/vcn_4_0_4.bin -> vcn_4_0_0.bin; intel/ish/ -> the maker's ish/), some of them whole
# directories (nvidia/ad104 -> ad102), some through chains. A kept link whose target the trim
# cuts leaves the driver without its firmware: the first real machine's Wi-Fi on linux-firmware
# 20260810. So every pattern is kept in any directory too, which follows the files that moved
# and keeps working when an update brings new versions of them; and FILES, the firmware
# packages' file lists (vh_firmware_files), gives the targets under other names, kept by name.
vh_firmware_noextract() { # [FILES]
	local k
	echo "# UniVoidDistro: firmware for this machine's hardware only (VH_FIRMWARE_TRIM=yes, docs/02, the plan)."
	echo "# To get everything back: delete this file and run xbps-install -f linux-firmware-network linux-firmware-intel linux-firmware-amd"
	echo "noextract=/usr/lib/firmware/*"
	# shellcheck disable=SC2206 # intentional word splitting
	for k in ${VH_PLAN_FIRMWARE:-} ${VH_FIRMWARE_KEEP:-}; do
		echo "noextract=!/usr/lib/firmware/$k"
		echo "noextract=!/usr/lib/firmware/*/$k"
	done
	if [ -n "${1:-}" ]; then
		echo "# the targets of the links above under other names (the packages' file lists at installation)"
		# shellcheck disable=SC2086 # the plan's list, one word per pattern
		vh_firmware_link_keep "$1" ${VH_PLAN_FIRMWARE:-} ${VH_FIRMWARE_KEEP:-} | sed 's|^|noextract=!/usr/lib/firmware/|'
	fi
}

# The packages that ship firmware, by name
VH_FIRMWARE_PKGS='^(linux-firmware.*|.*-firmware|.*-ucode|wireless-regdb)$'

# The file lists of the firmware packages this system gets from the repositories REPO...: those
# of vh_packages, and the dependencies that ship firmware too (linux-firmware-network brings
# -broadcom). "PATH" or "PATH -> TARGET" per line under /usr/lib/firmware; xbps-query -R -f reads
# a package's file list, not the package, from the index the sync fetched (the live system's
# own repository list may be another mirror, and has no nonfree).
vh_firmware_files() { # REPO...
	local r=() p todo next seen=" "
	for p in "$@"; do r+=("--repository=$p"); done
	xbps-install -S -i "${r[@]}" >/dev/null 2>&1 || true
	todo=$(vh_packages | grep -E "$VH_FIRMWARE_PKGS" || true)
	while [ -n "$todo" ]; do
		next=""
		for p in $todo; do
			case $seen in *" $p "*) continue ;; esac
			seen="$seen$p "
			xbps-query -i "${r[@]}" -R -f "$p" 2>/dev/null | grep '^/usr/lib/firmware/' || true
			next="$next $(xbps-query -i "${r[@]}" -R -x "$p" 2>/dev/null | sed 's/[<>=].*//' | grep -E "$VH_FIRMWARE_PKGS" || true)"
		done
		todo=$next
	done
}

# An absolute path without its "." and ".." parts
vh_normpath() {
	local -a parts out=()
	local seg
	IFS=/ read -ra parts <<< "$1"
	for seg in "${parts[@]}"; do
		case $seg in
			''|.) ;;
			..) [ "${#out[@]}" = 0 ] || out=("${out[@]:0:${#out[@]}-1}") ;;
			*) out+=("$seg") ;;
		esac
	done
	printf '/%s' "${out[@]}"
	echo
}

# What the links that PATTERN... keep lead to, relative to /usr/lib/firmware, beyond what the
# patterns keep themselves (FILES: vh_firmware_files). A pattern below a directory link is also
# a pattern below its target, and the link is kept (nvidia/ad104/gsp/* keeps nvidia/ad104 and
# nvidia/ad102/gsp/*); the target of a kept file link is kept by name, through chains.
vh_firmware_link_keep() { # FILES PATTERN...
	local files=$1 fw=/usr/lib/firmware line path target p q e covered changed
	shift
	local -A link=() isdir=() kept=() emit=()
	local -a pats=() all=()
	while IFS= read -r line; do
		case $line in
			"$fw"/*" -> "*)
				path=${line%% -> *} target=${line#* -> }
				case $target in /*) ;; *) target=$(vh_normpath "${path%/*}/$target") ;; esac
				link[$path]=$target
				all+=("$path") ;;
			"$fw"/*)
				all+=("$line")
				p=${line%/*}
				while [ "$p" != "$fw" ] && [ -z "${isdir[$p]:-}" ]; do isdir[$p]=1; p=${p%/*}; done ;;
		esac
	done < "$files"
	for p in "$@"; do pats+=("$fw/$p" "$fw/*/$p"); done
	# directory links (and chains of them): the patterns below one, read below its target too
	changed=1
	while [ "$changed" = 1 ]; do
		changed=0
		for path in "${!link[@]}"; do
			for p in "${pats[@]}"; do
				[[ $p == "$path"/* ]] || continue
				q=${link[$path]}${p#"$path"}
				[ -z "${emit[${q#"$fw"/}]:-}" ] || continue
				pats+=("$q")
				# the link itself, and the pattern through it; not the whole target directory
				emit[${q#"$fw"/}]=1 emit[${path#"$fw"/}]=1 kept[$path]=1 kept[${link[$path]}]=1
				changed=1
			done
		done
	done
	# the entries the patterns keep
	for path in "${all[@]}"; do
		for p in "${pats[@]}"; do
			# shellcheck disable=SC2053 # the pattern is a glob on purpose, as xbps matches it
			if [[ $path == $p ]]; then kept[$path]=1; break; fi
		done
	done
	# file links: their targets, through chains
	changed=1
	while [ "$changed" = 1 ]; do
		changed=0
		for path in "${!kept[@]}"; do
			target=${link[$path]:-}
			[ -n "$target" ] && [ -z "${kept[$target]:-}" ] || continue
			kept[$target]=1
			changed=1
			if [ -n "${isdir[$target]:-}" ]; then emit[${target#"$fw"/}/*]=1; else emit[${target#"$fw"/}]=1; fi
		done
	done
	# what the patterns keep already needs no line of its own
	for e in "${!emit[@]}"; do
		covered=0
		for p in "$@"; do
			# shellcheck disable=SC2053 # the pattern is a glob on purpose, as xbps matches it
			if [[ $e == $p || $e == */$p ]]; then covered=1; break; fi
		done
		[ "$covered" = 1 ] || printf '%s\n' "$e"
	done | LC_ALL=C sort
}

# Kernel command line embedded in the UKI. Under Secure Boot systemd-stub ignores
# anything passed from outside, so changing it means rebuilding the UKI.
# Every parameter is explained in docs/03-boot.md; the hardware's in hwdb/.
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
		# the mandatory access control: with VH_MAC=selinux the machine kernel runs SELinux (the
		# first exclusive LSM it has) and the stock kernel, which has none, AppArmor (docs/uni/selinux.md)
		"lsm=landlock,lockdown,yama,$( [ "$VH_MAC" = selinux ] && printf 'selinux,' )apparmor"
		iommu.strict=1 iommu.passthrough=0
		init_on_alloc=1 init_on_free=1 slab_nomerge page_alloc.shuffle=1
		debugfs=off
		bdev_allow_write_mounted=0 efi_pstore.pstore_disable=1 proc_mem.force_override=never
		"cfg80211.ieee80211_regdom=$VH_REGDOM"
		preempt=full
		"module_blacklist=$bl"
	)
	# what the hardware asks for: intel_iommu=on with a DMAR table, efi=disable_early_pci_dma
	# and ia32_emulation=0 on x86_64 (VH_PLAN_CMDLINE, hwdb/)
	# shellcheck disable=SC2206 # the plan's list, one word per parameter
	c+=(${VH_PLAN_CMDLINE:-})
	[ "$VH_IPV6" = no ] && c+=(ipv6.disable=1)
	# shellcheck disable=SC2206 # intentional word splitting
	[ -n "${VH_EXTRA_CMDLINE:-}" ] && c+=($VH_EXTRA_CMDLINE)
	printf '%s' "${c[*]}"
}
