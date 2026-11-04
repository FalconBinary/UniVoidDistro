# shellcheck shell=sh
# vh-audit: firewall, listening ports, DNS, time (docs/06, docs/07). Sourced by vh-audit.
sec "Network"
nft list table inet vh >/dev/null 2>&1 && ok "nftables: table vh" || bad "nftables: no vh table"
# the DHCP client (dhcpcd, iwd) holds a socket on port 68: server replies, not a service
listen=$(ss -Htulpn 2>/dev/null | awk '{print $1" "$5}' | grep -v '^udp .*:68$' | sort -u | paste -sd';' -)
case $listen in
	"tcp 127.0.0.1:53;udp 127.0.0.1:53"|"udp 127.0.0.1:53;tcp 127.0.0.1:53") ok "only unbound listens, on 127.0.0.1:53" ;;
	*) bad "open ports: $listen" ;;
esac
grep -q '^nameserver 127.0.0.1$' /etc/resolv.conf && ok "resolv.conf -> 127.0.0.1" || bad "resolv.conf was changed"
for i in all default eth0 wlan0; do
	[ -d "/proc/sys/net/ipv4/conf/$i" ] || continue
	for k in accept_redirects secure_redirects send_redirects; do
		chk "$i.$k" "$(cat /proc/sys/net/ipv4/conf/$i/$k)" 0
	done
done
if [ -d /sys/class/net/wlan0 ]; then
	chk "Wi-Fi power_save" "$(iw dev wlan0 get power_save 2>/dev/null | awk '{print $3}')" off
fi
getent hosts voidlinux.org >/dev/null && ok "DNS (unbound, DoT) answers" || unk "DNS does not answer (no network?)"
chronyc -n authdata 2>/dev/null | awk 'NR>2 && $2=="NTS" {n++} END {exit !(n>0)}' \
	&& ok "chrony: NTS sources" || unk "chrony: no NTS sources (no network?)"

sec "Power button and lid"
# the device under the driver: a platform driver since kernel 6.18.60, an ACPI driver before it
tiny_button=no
for tiny_dev in /sys/bus/platform/drivers/acpi-tiny-power-button/*:* /sys/bus/acpi/drivers/tiny-power-button/*:*; do
	[ -e "$tiny_dev" ] && tiny_button=yes
done
if [ "$tiny_button" = yes ]; then
	# the fixed button alone (hwdb rule acpi.power-button.fixed): tiny_power_button is its only
	# driver on 6.18, set to signal SIGINT, and /etc/runit/ctrlaltdel, through vh-ctrlaltdel of the
	# package vh-base, hands that to vh-acpid
	if ! grep -qwF 'tiny_power_button.power_signal=2' /proc/cmdline || ! grep -q 'sv 1 vh-acpid' /usr/local/libexec/vh/vh-ctrlaltdel 2>/dev/null \
		|| ! grep -q '/usr/local/libexec/vh/vh-ctrlaltdel' /etc/runit/ctrlaltdel 2>/dev/null; then
		bad "tiny_power_button took the power button (Ctrl+Alt+Del bypasses vh-acpid): module_blacklist needed, or doas vh-update (the migration 0001-ctrlaltdel)"
	elif ! grep -q 'acpi-tiny-power-button' /usr/local/libexec/vh/vh-ctrlaltdel; then
		bad "vh-ctrlaltdel does not know kernel 6.18.60's driver path: the power button reboots; doas vh-update"
	else
		ok "the fixed power button: tiny_power_button signals init (SIGINT), /etc/runit/ctrlaltdel hands it to vh-acpid"
	fi
else
	ok "the power button is not owned by tiny_power_button"
fi
