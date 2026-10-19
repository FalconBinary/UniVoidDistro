#!/bin/bash
# Stage 0: hardware probe. Runs in the live environment as root and writes nothing to disk.
# Gathers everything that must be known before installing (module 0 of the guide) and
# prints recommendations for vh.conf.
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
	[ "$n" = 1 ] && rec "One memory module is installed: the integrated graphics run in single-channel mode. A second identical module is the biggest graphics and zram speedup available on this laptop (docs/15)."
else
	echo "no dmidecode (run with --install-tools)"
fi

sec "CPU"
grep -m1 'model name' /proc/cpuinfo
echo "cores/threads:   $(grep -c ^processor /proc/cpuinfo)"
echo "microcode:       $(grep -m1 microcode /proc/cpuinfo | awk '{print $3}')"
flags=$(grep -m1 '^flags' /proc/cpuinfo)
for fl in vmx smx tme ibt user_shstk sgx rdrand rdseed aes avx2 avx512f; do
	if [[ " $flags " == *" $fl "* ]]; then echo "  flag $fl: yes"; else echo "  flag $fl: no"; fi
done
[[ " $flags " == *" tme "* ]] || rec "No TME: plaintext in DRAM is not encrypted in hardware; cold-boot protection is software only (docs/05)."
[[ " $flags " == *" vmx "* ]] && rec "VT-x is enabled in the BIOS. If KVM is not needed, disable it (docs/00), VH_VIRT=no."
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
		tpm2_getcap properties-fixed 2>/dev/null | grep -A2 -E 'TPM2_PT_MANUFACTURER|TPM2_PT_FIRMWARE_VERSION_1' | sed 's/^/  /'
		tpm2_getcap properties-fixed 2>/dev/null | grep -A1 TPM2_PT_MANUFACTURER | grep -q '"INTC"' \
			&& rec "The TPM is an Intel PTT fTPM (inside the ME): trusting tpm2-totp means trusting the ME (docs/03)."
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
	echo "No TPM found. Enable Intel PTT / fTPM in the BIOS."
	rec "No TPM found: enable PTT in the BIOS (needed for tpm2-totp)."
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
	lspci -nn | grep -qi '10de:' && echo "NVIDIA dGPU: $(lspci -nn | grep -i '10de:' | head -1)"
else
	echo "no lspci (run with --install-tools)"
fi

sec "Display outputs (DRM)"
for c in /sys/class/drm/card*-*; do
	[ -e "$c/status" ] || continue
	card=${c##*/}; card=${card%%-*}
	drv=$(basename "$(readlink -f /sys/class/drm/$card/device/driver 2>/dev/null)")
	printf '  %-24s %-10s driver=%s\n' "${c##*/}" "$(cat "$c/status")" "$drv"
	case ${c##*/}:$drv in
		*HDMI*:nouveau|*DP*:nouveau|*HDMI*:nvidia*|*DP*:nvidia*)
			rec "Port ${c##*/} is wired to the NVIDIA GPU: it will not work with VH_GPU=igpu. If you need an external monitor, set VH_GPU=nouveau (docs/04)." ;;
	esac
done
lsmod | grep -q '^nouveau' || echo "  (nouveau is not loaded: dGPU ports may be invisible; modprobe nouveau and run the probe again)"

sec "USB"
if have lsusb; then
	lsusb | sed 's/^/  /'
	echo "tree:"
	lsusb -t | sed 's/^/  /'
	lsusb | grep -qi '8087:0026' && echo "  AX201 Bluetooth: 8087:0026 (internal USB device)"
fi
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
	echo "internal keyboard: possibly internal USB"
	rec "The keyboard may be on internal USB: with USB authorisation (optional/usb-auth) name its port explicitly (docs/05)."
fi

sec "Network"
for n in /sys/class/net/*; do
	[ "${n##*/}" = lo ] && continue
	printf '  %-10s driver=%-10s mac=%s\n' "${n##*/}" \
		"$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)")" "$(cat "$n/address")"
done
have iw && { echo "regulatory domain:"; iw reg get 2>/dev/null | sed 's/^/  /' | head -20; }
have rfkill && rfkill list 2>/dev/null | sed 's/^/  /'
dmesg 2>/dev/null | grep -iE 'iwlwifi.*loaded firmware|iwlwifi.*firmware: direct-loading|rtl_nic|r8169.*firmware' | head -4 | sed 's/^/  firmware: /'
grep -q 'iwlwifi' /proc/modules && have modinfo && {
	echo "iwlwifi/iwlmvm parameters:"
	modinfo -p iwlwifi 2>/dev/null | grep -E 'power_save|uapsd|bt_coex' | sed 's/^/  /'
	modinfo -p iwlmvm 2>/dev/null | grep -E 'power_scheme' | sed 's/^/  /'
}

sec "MSI: msi-ec driver (fan, power modes)"
if [ "$(rd /sys/class/dmi/id/sys_vendor)" = "Micro-Star International Co., Ltd." ]; then
	modprobe msi-ec 2>/dev/null
	if [ -d /sys/devices/platform/msi-ec ]; then
		echo "msi-ec supports this EC firmware: $(ls /sys/devices/platform/msi-ec | paste -sd' ' -)"
	else
		dmesg 2>/dev/null | grep -i 'msi_ec\|msi-ec' | tail -3 | sed 's/^/  /'
		echo "msi-ec does not support this EC firmware: fan modes are available only in Windows (docs/15)"
	fi
else
	echo "not MSI: skipped"
fi

sec "Hardware watchdog (iTCO)"
dmesg 2>/dev/null | grep -i tco | sed 's/^/  /'
ls /sys/class/watchdog/ 2>/dev/null | sed 's/^/  /'
lsmod | grep -E 'iTCO|lpc_ich|i2c_i801' | sed 's/^/  /'
dmesg 2>/dev/null | grep -qi 'unable to reset NO_REBOOT' && rec "The firmware locked NO_REBOOT on the iTCO: the hardware watchdog is unavailable (docs/05)."

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
	sec "The plan of this machine (hwdb/)"
	bash "$VH_ROOT/install/plan.sh"
	echo "plan.env, plan-report.txt and the probe's snapshot: /tmp/vh"
fi
echo "Copy it to a USB stick or over the network before rebooting: /tmp lives in RAM."
