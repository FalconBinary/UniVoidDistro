#!/bin/bash
# Stage 0: hardware probe. Runs in the live environment as root and writes nothing to disk.
# Gathers everything that must be known before installing (module 0 of the guide) and
# prints recommendations for vh.conf. The report states facts any machine has, named by
# what they are; what a vendor or a model means (fan control, firmware menus, quirks) is in
# hwdb/ and shows as the notes of the plan (--plan, docs/uni/principles.md, rule 1).
#
#   ./install/00-probe.sh                 -- only what the live image already has
#   ./install/00-probe.sh --install-tools -- first install pciutils, usbutils, tpm2-tools,
#                                           nvme-cli, iw, efibootmgr into the live environment (RAM)
#   ./install/00-probe.sh --plan          -- then the machine's plan too (install/plan.sh: what
#                                           hwdb/ decides for it, and the security gate)
#
# Report: /tmp/vh-probe-<date>.txt -- handy to attach to a question or to keep.

. "$(dirname "$0")/lib.sh"
set +e +o pipefail   # the probe must not stop at the first missing utility
need_root

WANT_PLAN=0
for a in "$@"; do [ "$a" = --plan ] && WANT_PLAN=1; done
if [ "${1:-}" = "--install-tools" ]; then
	say "installing utilities into the live environment (RAM only)"
	xbps-install -Syu xbps >/dev/null 2>&1
	xbps-install -Sy pciutils usbutils tpm2-tools nvme-cli iw efibootmgr dmidecode \
		|| warn "not every utility was installed (no network?)"
fi

OUT=/tmp/vh-probe-$(date +%Y%m%d-%H%M%S).txt
exec > >(tee "$OUT") 2>&1
have() { command -v "$1" >/dev/null 2>&1; }
sec() { printf '\n%s######## %s%s\n' "$C_B" "$*" "$C_0"; }
rd() { [ -r "$1" ] && tr -d '\0' < "$1" 2>/dev/null; }
REC=()   # recommendations
rec() { REC+=("$*"); }

sec "System"
for f in sys_vendor product_name product_version board_name bios_vendor bios_version bios_date; do
	printf '%-16s %s\n' "$f:" "$(rd /sys/class/dmi/id/$f)"
done
echo "live kernel:     $(uname -r)"
echo "RAM:             $(awk '/MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)"

sec "Memory"
if have dmidecode; then
	dmidecode -t memory 2>/dev/null | awk -F: '/^\tSize:/ {sz=$2} /^\tLocator:/ {loc=$2} /^\tConfigured Memory Speed:/ {printf "  %-12s %-12s %s\n", loc, sz, $2}'
	n=$(dmidecode -t memory 2>/dev/null | grep -cE '^\s+Size: [0-9]+ (GB|MB)')
	echo "modules installed: $n"
	[ "$n" = 1 ] && rec "One memory module is installed: the memory runs in single-channel mode. A second identical module doubles the bandwidth that integrated graphics and zram use (docs/15)."
else
	echo "no dmidecode (run with --install-tools)"
fi

sec "CPU"
grep -m1 'model name' /proc/cpuinfo
echo "cores/threads:   $(grep -c ^processor /proc/cpuinfo)"
echo "microcode:       $(grep -m1 microcode /proc/cpuinfo | awk '{print $3}')"
flags=$(grep -m1 '^flags' /proc/cpuinfo)
# the flags of both x86 vendors where they differ: virtualization vmx/svm, memory encryption tme/sme
for fl in vmx svm smx tme sme sgx ibt user_shstk rdrand rdseed aes avx2 avx512f; do
	if [[ " $flags " == *" $fl "* ]]; then echo "  flag $fl: yes"; else echo "  flag $fl: no"; fi
done
[[ " $flags " == *" tme "* || " $flags " == *" sme "* ]] || rec "No memory encryption in the CPU (the flags tme, sme): plaintext in DRAM is not encrypted in hardware; cold-boot protection is software only (docs/05)."
[[ " $flags " == *" vmx "* || " $flags " == *" svm "* ]] && rec "Hardware virtualization (vmx or svm) is enabled in the firmware. If KVM is not needed, disable it there (docs/00), VH_VIRT=no."
echo "vulnerabilities and mitigations:"
for f in /sys/devices/system/cpu/vulnerabilities/*; do
	printf '  %-28s %s\n' "$(basename "$f")" "$(cat "$f")"
done

sec "Firmware (UEFI)"
if [ -d /sys/firmware/efi ]; then
	echo "mode: UEFI, $(rd /sys/firmware/efi/fw_platform_size)-bit"
	efv() { # efv NAME -- value of a one-byte EFI variable
		local f; f=$(ls /sys/firmware/efi/efivars/"$1"-* 2>/dev/null | head -1)
		[ -n "$f" ] && od -An -t u1 -j4 -N1 "$f" | tr -d ' ' || echo "none"
	}
	echo "SecureBoot:      $(efv SecureBoot)"
	echo "SetupMode:       $(efv SetupMode)"
	echo "MOR (MemoryOverwriteRequestControl): $(efv MemoryOverwriteRequestControl)"
	ls /sys/firmware/efi/efivars/ | grep -q MemoryOverwriteRequestControl \
		&& rec "MOR is supported by the firmware: a reboot through the firmware wipes RAM (docs/03)." \
		|| rec "MOR not found: the firmware will not wipe RAM; residual risk (docs/03)."
	[ "$(efv SetupMode)" = 1 ] && rec "Secure Boot is already in Setup Mode: the keys can be enrolled right away (docs/03)."
	have efibootmgr && { echo "boot entries:"; efibootmgr -v 2>/dev/null | sed 's/^/  /'; }
else
	echo "mode: BIOS/CSM -- NOT SUPPORTED. Enable UEFI and disable CSM."
	rec "Boot in UEFI mode (CSM off): the installer works with UEFI only."
fi

sec "TPM"
if [ -e /sys/class/tpm/tpm0 ]; then
	echo "TPM version: $(rd /sys/class/tpm/tpm0/tpm_version_major)"
	echo "driver:      $(basename "$(readlink -f /sys/class/tpm/tpm0/device/driver 2>/dev/null)")"
	ls -l /dev/tpm0 /dev/tpmrm0 2>/dev/null
	if have tpm2_getcap; then
		# the manufacturer: a firmware TPM (inside the CPU's management engine) is named in the plan's notes
		tpm2_getcap properties-fixed 2>/dev/null | grep -A2 -E 'TPM2_PT_MANUFACTURER|TPM2_PT_FIRMWARE_VERSION_1' | sed 's/^/  /'
		echo "  lockoutAuthSet: $(tpm2_getcap properties-variable 2>/dev/null | grep -i lockoutAuthSet | awk '{print $2}')"
	fi
	EVLOG=/sys/kernel/security/tpm0/binary_bios_measurements
	if have tpm2_eventlog && [ -r "$EVLOG" ]; then
		n=$(tpm2_eventlog "$EVLOG" 2>/dev/null | grep -c 'EV_EFI_BOOT_SERVICES_DRIVER')
		echo "Option ROMs in the measurement log (EV_EFI_BOOT_SERVICES_DRIVER): $n"
		if [ "$n" -gt 0 ]; then
			rec "Option ROMs present ($n): enroll the SB keys with --tpm-eventlog, NOT with --microsoft, otherwise the display or disk may fail to initialise (docs/03)."
		else
			rec "No Option ROMs found: sbctl enroll-keys without the Microsoft certificates (docs/03)."
		fi
	else
		echo "measurement log: no tpm2_eventlog (run with --install-tools)"
	fi
else
	echo "No TPM found. Enable the firmware TPM (fTPM) or the TPM module in the firmware setup."
	rec "No TPM found: enable the firmware TPM or the TPM module in the firmware setup (needed for tpm2-totp and VH_SECURITY=strict)."
fi

sec "PCI devices"
if have lspci; then
	lspci -nnk | sed 's/^/  /'
	if lspci -vvv 2>/dev/null | grep -q 'Address Translation Service'; then
		echo "ATS: devices with ATS present:"
		lspci -vvv 2>/dev/null | awk '/^[0-9a-f]/{dev=$0} /Address Translation Service/{print "  " dev}'
		rec "Devices with ATS present: do not add pci=noats without checking (docs/03)."
	else
		echo "ATS: no device uses it"
		rec "ATS is not used: pci=noats can be added to the cmdline (docs/03, optional)."
	fi
else
	echo "no lspci (run with --install-tools)"
fi
# the display controllers: the one that brought the console up (boot_vga), and a dGPU
for d in /sys/bus/pci/devices/*; do
	case $(cat "$d/class") in 0x03*) ;; *) continue ;; esac
	bv=$(cat "$d/boot_vga" 2>/dev/null)
	drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)
	printf 'display controller %s: %s, driver %s\n' "${d##*/}" "$([ "$bv" = 1 ] && echo "brought the console up" || echo "did not bring the console up (a dGPU if another one did)")" "${drv:-none}"
done

sec "Display outputs (DRM)"
for c in /sys/class/drm/card*-*; do
	[ -e "$c/status" ] || continue
	card=${c##*/}; card=${card%%-*}
	dev=$(readlink -f "/sys/class/drm/$card/device")
	drv=$(basename "$(readlink -f "$dev/driver" 2>/dev/null)")
	printf '  %-24s %-10s driver=%s\n' "${c##*/}" "$(cat "$c/status")" "$drv"
	# a port of the GPU that did not bring the console up: dark while that GPU sleeps
	case $(cat "$dev/class" 2>/dev/null):$(cat "$dev/boot_vga" 2>/dev/null):${c##*/} in
		0x03*:1:*|*:*eDP*|*:*LVDS*|*:*DSI*) ;;
		0x03*) rec "Port ${c##*/} is wired to ${dev##*/}, the GPU that did not bring the console up: where the plan lets that dGPU sleep (VH_GPU auto or igpu on a laptop) the port stays dark; the plan's notes say what wakes it (docs/04)." ;;
	esac
done
for d in /sys/bus/pci/devices/*; do
	case $(cat "$d/class") in 0x03*) ;; *) continue ;; esac
	[ -e "$d/driver" ] || echo "  (${d##*/} has no driver: its ports are not listed; load its driver and run the probe again to see them)"
done

sec "USB"
if have lsusb; then
	lsusb | sed 's/^/  /'
	echo "tree:"
	lsusb -t | sed 's/^/  /'
fi
# Bluetooth controllers: USB interfaces of class e0, and whether the kernel calls the device built in
for i in /sys/bus/usb/devices/*:*; do
	[ "$(cat "$i/bInterfaceClass" 2>/dev/null)" = e0 ] || continue
	u=${i%:*}
	echo "  Bluetooth controller ${u##*/}: $(cat "$u/idVendor"):$(cat "$u/idProduct") ($(cat "$u/removable" 2>/dev/null || echo unknown))"
done 2>/dev/null | sort -u
echo "port connection type (connect_type):"
for p in /sys/bus/usb/devices/*/port/connect_type /sys/bus/usb/devices/*/*/connect_type; do
	[ -r "$p" ] && printf '  %-55s %s\n' "$p" "$(cat "$p")"
done 2>/dev/null | sort -u
rec "External ports must not be \"hardwired\" (otherwise usbcore.authorized_default=2 trusts them): compare the list above with the physical connectors (docs/05)."

sec "Input devices"
awk 'BEGIN{RS=""} /Name=/ {print}' /proc/bus/input/devices | grep -E '^(N|P|S|H):' | sed 's/^/  /'
if grep -A3 -i 'keyboard' /proc/bus/input/devices | grep -q 'isa0060'; then
	echo "internal keyboard: i8042 (PS/2)"
elif grep -B1 -A3 -i 'keyboard' /proc/bus/input/devices | grep -q 'usb-'; then
	echo "internal keyboard: possibly internal USB (the kernel's word for each USB device: fixed = built in)"
	for u in /sys/bus/usb/devices/[0-9]*-*; do
		case ${u##*/} in *:*) continue ;; esac
		[ -r "$u/removable" ] && printf '  %-10s %s %s\n' "${u##*/}" "$(cat "$u/removable")" "$(cat "$u/product" 2>/dev/null)"
	done
	rec "The keyboard may be on internal USB: the plan names its place for vh-acpid when the kernel calls it fixed; with USB authorisation (optional/usb-auth) name its port explicitly (docs/05)."
fi

sec "Network"
for n in /sys/class/net/*; do
	[ "${n##*/}" = lo ] && continue
	printf '  %-10s driver=%-10s mac=%s\n' "${n##*/}" \
		"$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)")" "$(cat "$n/address")"
done
have iw && { echo "regulatory domain:"; iw reg get 2>/dev/null | sed 's/^/  /' | head -20; }
have rfkill && rfkill list 2>/dev/null | sed 's/^/  /'
# the firmware messages and the power-saving parameters of the network drivers bound here
for n in /sys/class/net/*; do
	drv=$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null)
	[ -n "$drv" ] && [ "$drv" != . ] || continue
	dmesg 2>/dev/null | grep -i "^.*$drv.*firmware" | tail -2 | sed "s/^/  firmware ($drv): /"
	have modinfo && modinfo -p "$drv" 2>/dev/null | grep -iE 'power|uapsd' | sed "s/^/  $drv parameter: /"
done

sec "Hardware watchdog"
# the plan names the board's watchdog (VH_PLAN_WATCHDOG, optional/deadman); a firmware that
# disabled it leaves its driver without a device, so nothing is listed here
n=0
for w in /sys/class/watchdog/watchdog*; do
	[ -e "$w" ] || continue
	n=$((n + 1))
	echo "  ${w##*/}: $(cat "$w/identity" 2>/dev/null), driver $(basename "$(readlink -f "$w/device/driver" 2>/dev/null)" 2>/dev/null)"
done
[ "$n" = 0 ] && rec "No watchdog device: either the board has no hardware watchdog the kernel knows, or the firmware disabled it; optional/deadman then uses softdog, the weaker one (docs/uni/runtime.md)."

sec "Storage"
lsblk -d -o NAME,SIZE,MODEL,TRAN,ROTA,PHY-SEC,LOG-SEC 2>/dev/null | sed 's/^/  /'
for d in /dev/nvme?n1; do
	[ -b "$d" ] || continue
	echo "$d: scheduler $(cat /sys/block/${d##*/}/queue/scheduler)"
	if have nvme; then
		nvme id-ns -H "$d" 2>/dev/null | grep -E 'LBA Format' | sed 's/^/  /'
		nvme id-ctrl -H "${d%n1}" 2>/dev/null | grep -iE 'Crypto Erase|Sanitize|Format NVM' | head -8 | sed 's/^/  /'
		nvme id-ns -H "$d" 2>/dev/null | grep -E 'LBA Format' | grep -q 'Data Size: 4096' \
			&& rec "$d supports 4096-byte LBAs: reformatting (nvme format --lbaf=N, erases everything) removes the 512-byte emulation (docs/01, optional)."
	fi
done

sec "Audio, backlight, battery"
for c in /proc/asound/card*/codec#*; do
	[ -r "$c" ] && { echo "  $c:"; head -3 "$c" | sed 's/^/    /'; }
done
ls /sys/class/backlight/ 2>/dev/null | sed 's/^/  backlight: /'
ls /sys/class/power_supply/ 2>/dev/null | sed 's/^/  power: /'
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_driver 2>/dev/null | sed 's/^/  cpufreq: /'
cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_available_preferences 2>/dev/null | sed 's/^/  EPP: /'

sec "Recommendations"
for r in "${REC[@]}"; do printf ' * %s\n' "$r"; done
echo
echo "Report saved: $OUT"
if [ "$WANT_PLAN" = 1 ]; then
	sec "The plan of this machine (hwdb/): its notes and the security gate"
	bash "$VH_ROOT/install/plan.sh"
	echo "plan.env, plan-report.txt and the probe's snapshot: /tmp/vh"
elif [ -r /tmp/vh/plan-report.txt ]; then
	sec "The notes of the plan made earlier (/tmp/vh/plan-report.txt)"
	sed -n '/^notes/,/^$/p' /tmp/vh/plan-report.txt
else
	echo "What hwdb/ knows about this machine's vendor and model (fan and power control, the firmware's Secure Boot menus, quirks) is in the plan's notes: run with --plan."
fi
echo "Copy it to a USB stick or over the network before rebooting: /tmp lives in RAM."
