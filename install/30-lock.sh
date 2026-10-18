#!/bin/bash
# Stage 3: forbid loading kernel modules after boot (kernel.modules_disabled=1).
#   doas /root/vh/install/30-lock.sh
#
# Before running it, use every piece of hardware you will need DURING THIS BOOT:
# Wi-Fi (your own network and, if it happens, a foreign one with DHCP), Ethernet, a USB
# stick (vfat/exfat), headphones, Bluetooth (if VH_BLUETOOTH is not off), a FIDO2 key,
# an external monitor. The script takes the list of loaded modules (lsmod): they will be
# preloaded at the end of stage 1, after which module loading is blocked until reboot.
# Details: docs/05-system.md, section "Kernel modules".

. "$(dirname "$0")/lib.sh"
need_root
load_config /root/vh/vh.conf

LIST=/etc/vh/modules.preload
mapfile -t blocked < <(vh_module_blacklist)
# Needed later even if not loaded now: the ESP (vfat, nls), USB sticks, USB HID.
extra=(vfat fat nls_cp437 nls_iso8859_1 nls_utf8 exfat usb_storage uas usbhid hid_generic tcp_bbr sch_fq)
{
	echo "# void-hardperf-light: modules preloaded before kernel.modules_disabled=1 ($(date -u +%F), kernel $(uname -r))"
	echo "# fuse and overlay are never included: after the lock not even a userns can load them."
	{
		awk 'NR > 1 {print $1}' /proc/modules
		printf '%s\n' "${extra[@]}"
	} | sort -u | while read -r m; do
		case $m in fuse|overlay) continue ;; esac
		printf '%s\n' "${blocked[@]}" | grep -qx "$m" && continue
		modinfo -n "$m" >/dev/null 2>&1 || continue   # built-in or absent
		echo "$m"
	done
} > "$LIST.new"

echo "Modules to preload ($(grep -vc '^#' "$LIST.new")):"
grep -v '^#' "$LIST.new" | paste -sd' ' - | fold -s -w 100 | sed 's/^/  /'
cat <<EOF

After a reboot no module outside this list will load, not even for root.
New hardware of another kind (for example a USB network card) will work only after
running this script again and rebooting. To disable the lock:
  doas rm /etc/vh/modlock.enabled   (takes effect from the next boot)
EOF
confirm_exact lock "Enable the module lock from the next boot?"
mv "$LIST.new" "$LIST"
chmod 0644 "$LIST"
: > /etc/vh/modlock.enabled
ok "enabled. Reboot and check: cat /proc/sys/kernel/modules_disabled -> 1"
