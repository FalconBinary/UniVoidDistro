# shellcheck shell=sh
# vh-audit: runit services (docs/05). Sourced by vh-audit.
sec "Services"
# every machine's; what the hardware needs (iwd, vh-acpid ...) is checked against the plan (area
# plan). svc_up (vh-audit): under vh-init a oneshot that ran is done, a timer delayed
for sv in dbus unbound chronyd seatd socklog-unix nanoklogd vh-check vh-boot-assess; do
	svc_up "$sv" && ok "service $sv is running" || bad "service $sv is not running"
done
for sv in sshd acpid dhcpcd wpa_supplicant cronie snooze-daily; do
	[ -e "/var/service/$sv" ] && bad "unwanted service enabled: $sv"
done
# runit's state of each service in /run (tmpfs), as Void's packages keep it: an installation
# from before 2026-10-21 kept ours on disk (docs/uni/runtime.md)
ondisk=$(find /etc/sv -mindepth 2 -maxdepth 3 -name supervise -type d 2>/dev/null | paste -sd' ' -)
[ -z "$ondisk" ] && ok "runit keeps the state of every service in /run" \
	|| bad "runit's state of a service on disk: $ondisk (doas vh-update moves it to /run)"
running=$(ls /var/service | wc -l)
ok "services enabled: $running ($(ls /var/service | paste -sd' ' -))"
if [ -d /etc/vh/optional ] && [ -n "$(ls /etc/vh/optional 2>/dev/null)" ]; then
	ok "paranoid modules: $(ls /etc/vh/optional | paste -sd' ' -)"
fi
