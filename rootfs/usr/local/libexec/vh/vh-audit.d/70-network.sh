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
if ls /sys/bus/acpi/drivers/tiny-power-button/ 2>/dev/null | grep -q ':'; then
	bad "tiny_power_button took the power button (Ctrl+Alt+Del bypasses vh-acpid): module_blacklist needed"
else
	ok "the power button is not owned by tiny_power_button"
fi
