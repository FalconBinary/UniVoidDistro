# shellcheck shell=sh
# vh-audit: runit services (docs/05). Sourced by vh-audit.
sec "Services"
# every machine's; what the hardware needs (iwd, vh-acpid ...) is checked against the plan (area plan)
for sv in dbus unbound chronyd seatd socklog-unix nanoklogd vh-check; do
	sv status "$sv" 2>/dev/null | grep -q '^run:' && ok "service $sv is running" || bad "service $sv is not running"
done
for sv in sshd acpid dhcpcd wpa_supplicant cronie snooze-daily; do
	[ -e "/var/service/$sv" ] && bad "unwanted service enabled: $sv"
done
running=$(ls /var/service | wc -l)
ok "services enabled: $running ($(ls /var/service | paste -sd' ' -))"
if [ -d /etc/vh/optional ] && [ -n "$(ls /etc/vh/optional 2>/dev/null)" ]; then
	ok "paranoid modules: $(ls /etc/vh/optional | paste -sd' ' -)"
fi
