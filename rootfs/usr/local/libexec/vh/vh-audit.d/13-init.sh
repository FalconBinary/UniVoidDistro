# shellcheck shell=sh
# vh-audit: PID 1 (init/README.md, v0.2 vh-init). Sourced by vh-audit. The area says which init
# runs and, under vh-init, that every enabled service is up and PID 1 is the small process it
# should be; under runit it only reports.
sec "PID 1 (vh-init)"
exe=$(readlink /proc/1/exe 2>/dev/null)
case $exe in
*vh-init*)
	ok "PID 1 is vh-init ($exe)"
	[ -S /run/vh/init.sock ] && ok "the manager's control socket exists" || bad "no /run/vh/init.sock: the manager is not running"
	mp=$(grep -l -- '--manager' /proc/[0-9]*/cmdline 2>/dev/null | head -1 | cut -d/ -f3)
	[ -n "$mp" ] && ok "the manager runs as pid $mp" || bad "no manager process"
	if [ -x /usr/local/sbin/vh-ctl ]; then
		st=$(/usr/local/sbin/vh-ctl status 2>/dev/null)
		notup=$(printf '%s\n' "$st" | awk '$2 != "up" && $2 != "done" && $2 != "delayed" {print $1 "(" $2 ")"}' | paste -sd' ' -)
		[ -z "$notup" ] && ok "every service is up or done ($(printf '%s\n' "$st" | wc -l) services)" || bad "services not up: $notup"
	else bad "no /usr/local/sbin/vh-ctl"; fi
	rss=$(awk '/VmRSS/ {print $2}' /proc/1/status 2>/dev/null)
	[ -n "$rss" ] && [ "$rss" -lt 4096 ] && ok "PID 1 uses $rss kB of RSS" || unk "PID 1 RSS: ${rss:-?} kB"
	pgrep -x runsv >/dev/null 2>&1 && bad "runsv processes exist under vh-init" || ok "no runsv or runsvdir processes"
	dmesg 2>/dev/null | grep -aq 'vh-init: stage 1 done' && ok "kmsg: vh-init ran stage 1" || unk "no vh-init stage 1 marker in dmesg (the log may have wrapped)"
	[ -d /var/log/vh ] && [ "$(stat -c %a /var/log/vh)" = 700 ] && ok "/var/log/vh is root's (0700)" || bad "/var/log/vh is missing or not 0700"
	;;
*runit*)
	unk "PID 1 is runit ($exe); vh-init is not installed as init= (doas vh-init --install)"
	;;
*)
	bad "PID 1 is $exe: neither runit nor vh-init"
	;;
esac
