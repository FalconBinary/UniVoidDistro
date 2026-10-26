#!/bin/bash
# vh-init container test, the part inside the container: started by vh-init (PID 1 of the
# container's namespace, --test-pid1 --no-stage1 --dir /t/svc) as the oneshot zz-driver after
# the test services of tests/init/svc. Checks them through vh-ctl and the sv shim, then asks
# PID 1 for the poweroff; the host (init_test.sh) reads the rest from the stopped container.
set -u
C=/t/bin/vh-ctl
mkdir -p /tmp/bin && ln -sf /t/bin/vh-ctl /tmp/bin/sv
SV=/tmp/bin/sv
fails=0
ok()   { echo "ok $*"; }
bad()  { echo "FAIL $*"; fails=$((fails + 1)); }
skip() { echo "SKIP $*"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1 = '$2' (expected '$3')"; fi; }
has()  { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else bad "$1: no '$3' in: $(printf '%s' "$2" | tail -c 400 | tr '\n' '|')"; fi; }
state() { $C status "$1" 2>/dev/null | awk '{print $2}'; }
pidof_svc() { $C status "$1" 2>/dev/null | awk '{print $4}'; }
# vh-ctl status prints "NAME STATE pid N Ns": state is $2, the pid $4
waitstate() { # NAME STATE [SECONDS]
	local i=0 n=${3:-5}
	while [ $i -lt $((n * 10)) ]; do [ "$(state "$1")" = "$2" ] && return 0; sleep 0.1; i=$((i + 1)); done
	return 1
}

echo "== the manager"
has "ping" "$($C ping)" 'vh-init manager'
sleep 1.5   # the readiness of every test service, and the crash service's restarts
st=$($C status)
echo "$st" | sed 's/^/   /'
chk "a is up (ready through fd 3)" "$(state a)" up
chk "b is up (needs a)" "$(state b)" up
chk "c-oneshot is done" "$(state c-oneshot)" done
chk "sockready is up (ready by the socket path)" "$(state sockready)" up
chk "user is up" "$(state user)" up

echo "== ordering"
ra=$(cat /tmp/ready-a) sb=$(cat /tmp/start-b) cd_=$(cat /tmp/c-done)
[ "$ra" -lt "$sb" ] && ok "a was ready ($ra) before b started ($sb)" || bad "b started ($sb) before a was ready ($ra)"
[ "$cd_" -lt "$sb" ] && ok "c-oneshot finished before b started" || bad "b started before c-oneshot finished"
sleep 1.2
if [ -e /tmp/delayed-done ]; then
	dd=$(( ($(cat /tmp/delayed-done) - cd_) / 1000000 ))
	[ "$dd" -ge 950 ] && ok "delayed (delay = 1s, after c) ran ${dd} ms after the oneshot c" || bad "delayed ran ${dd} ms after c: too early"
else bad "delayed did not run after 2.7 s"; fi
chk "delayed is done" "$(state delayed)" done

echo "== restarts and backoff"
runs=$(wc -l < /tmp/crash-runs)
[ "$runs" -ge 3 ] && ok "crash ran $runs times in 2.7 s" || bad "crash ran only $runs times"
mapfile -t ts < /tmp/crash-runs
d1=$(( (ts[1] - ts[0]) / 1000000 )) d2=$(( (ts[2] - ts[1]) / 1000000 ))
[ "$d1" -ge 180 ] && ok "first restart after ${d1} ms (delay 200 ms)" || bad "first restart after ${d1} ms"
[ "$d2" -ge 380 ] && ok "second restart after ${d2} ms (backoff doubled)" || bad "second restart after ${d2} ms (no backoff)"
r=$($C status crash | grep -o 'restarts [0-9]*' | awk '{print $2}')
[ "${r:-0}" -ge 2 ] && ok "status counts $r restarts" || bad "status counts ${r:-0} restarts"

echo "== the process: user, groups, capabilities, no_new_privs, seccomp, nice, cgroup, env"
chk "user = nobody runs as uid 99" "$(cat /tmp/user-id)" "$(id -u nobody)"
has "nobody's groups include its primary group" "$(cat /tmp/user-groups)" "$(id -g nobody)"
caps=$(cat /tmp/caps)
has "caps = net_bind_service: CapEff bit 10 only" "$caps" 'CapEff:[[:space:]]*0000000000000400'
has "caps: the bounding set is the same" "$caps" 'CapBnd:[[:space:]]*0000000000000400'
has "caps: ambient keeps it across exec" "$caps" 'CapAmb:[[:space:]]*0000000000000400'
has "no_new_privs is on" "$caps" 'NoNewPrivs:[[:space:]]*1'
has "the ABI seccomp filter is on (mode 2)" "$caps" 'Seccomp:[[:space:]]*2'
has "caps = none as root: no capability at all" "$(cat /tmp/rootcaps)" 'CapEff:[[:space:]]*0000000000000000'
chk "nice = 10" "$(cat /tmp/nice)" 10
if command -v chrt >/dev/null; then has "sched = batch" "$(chrt -p "$(pidof_svc nice)" 2>&1)" 'SCHED_BATCH'; else skip "chrt not in the image: sched not checked"; fi
if grep -q '/vh/cgtest$' /tmp/cgroup; then ok "the service runs in its cgroup /vh/cgtest"; else skip "no cgroup for the service here: $(cat /tmp/cgroup)"; fi
chk "env = FOO=bar" "$(cat /tmp/env-foo)" bar
chk "dir = /tmp" "$(cat /tmp/env-pwd)" /tmp
chk "umask = 077" "$(cat /tmp/env-umask)" 0077

echo "== logs"
log=/var/log/vh/logtest/current
[ -r "$log" ] && ok "the log file exists" || bad "no $log"
has "a stamped line" "$(cat "$log")" '^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9:]*\.[0-9]\{3\}Z hello-log$'
chk "two lines" "$(wc -l < "$log")" 2
chk "the log directory is root's" "$(stat -c %a /var/log/vh)" 700

echo "== vh-ctl"
pa=$(pidof_svc sockready)
out=$($C stop sockready); echo "   $out"
chk "stop: down" "$(state sockready)" down
out=$($C start sockready); echo "   $out"
chk "start: up again" "$(state sockready)" up
pb=$(pidof_svc sockready)
[ "$pa" != "$pb" ] && ok "a new pid after stop/start ($pa -> $pb)" || bad "the same pid after stop/start"
pa=$(pidof_svc a)
out=$($C restart a); echo "   $out"
pb=$(pidof_svc a)
chk "restart: up" "$(state a)" up
[ "$pa" != "$pb" ] && ok "restart gave a new pid ($pa -> $pb)" || bad "restart kept the pid"
chk "b stays up while a restarts (runit semantics)" "$(state b)" up
pl=$(pidof_svc logtest)
$C signal logtest HUP >/dev/null
sleep 2.5   # a quick exit waits restart_delay (1 s) before the restart
[ "$(pidof_svc logtest)" != "$pl" ] && [ "$(state logtest)" = up ] && ok "signal HUP: the service died and was restarted" || bad "signal HUP: $(state logtest), pid $(pidof_svc logtest) (was $pl)"
has "list" "$($C list)" '^zz-driver$'
has "tree shows needs" "$($C tree)" 'b (up, .*) needs a after c-oneshot a'
has "why b" "$($C why b)" '^b (up'
has "blame has a line per started service" "$($C blame)" ' ms a (started at'
$C status nosuch >/dev/null 2>&1 && bad "status of an unknown service succeeded" || ok "status of an unknown service fails"
$C bogus 2>/dev/null && bad "an unknown command is accepted" || ok "an unknown command is refused"

echo "== the sv shim"
has "sv status a: runit's line" "$($SV status a)" '^run: a: (pid [0-9]*) [0-9]*s$'
$SV check a >/dev/null && ok "sv check a exits 0" || bad "sv check a failed"
$SV down a >/dev/null; sleep 0.5
has "sv down a" "$($SV status a)" '^down: a: [0-9]*s, normally up$'
out=$($SV -w 5 start a); rc=$?
chk "sv -w 5 start a exits 0" "$rc" 0
has "sv start prints run:" "$out" '^run: a:'
$SV status nosuch >/dev/null 2>&1 && bad "sv status of an unknown service exits 0" || ok "sv status of an unknown service exits 1"
has "sv status prints fail: for an unknown service" "$($SV status nosuch 2>&1)" '^fail: nosuch:'

echo "== a runit service directory, taken in by reload"
d=/etc/sv/rsvc
mkdir -p $d/log
cat > $d/run <<'R'
#!/bin/sh
exec 2>&1
echo "rsvc starting"
sleep 0.3
: > /tmp/rsvc-ready
exec sleep 1000
R
cat > $d/check <<'R'
#!/bin/sh
test -e /tmp/rsvc-ready
R
cat > $d/finish <<'R'
#!/bin/sh
echo "$1 $2" > /tmp/rsvc-finish
R
cat > $d/log/run <<'R'
#!/bin/sh
exec cat >> /tmp/rsvc-log
R
chmod +x $d/run $d/check $d/finish $d/log/run
# Void's /var/service is a link into /run/runit, which no container has
if [ -L /var/service ] && [ ! -e /var/service ]; then rm -f /var/service; fi
mkdir -p /var/service && ln -sfn $d /var/service/rsvc
has "reload" "$($C reload)" 'services'
waitstate rsvc up 5 && ok "rsvc is up after its check script passed" || bad "rsvc: $(state rsvc) after 5 s"
[ -e /tmp/rsvc-ready ] && ok "rsvc was not up before its check: /tmp/rsvc-ready exists" || bad "rsvc up without the check"
sleep 0.3
has "the runit logger got the service's output" "$(cat /tmp/rsvc-log 2>/dev/null)" 'rsvc starting'
has "sv status shows the logger" "$($SV status rsvc)" '^run: rsvc: (pid [0-9]*) [0-9]*s; run: log: (pid [0-9]*)'
$SV down rsvc >/dev/null; sleep 0.8
has "finish ran with the exit code and the status" "$(cat /tmp/rsvc-finish 2>/dev/null)" '^[0-9]* [0-9]*$'
chk "rsvc is down" "$(state rsvc)" down

echo "== enable and disable"
mkdir -p /etc/vh/services
printf 'exec = /bin/sh -c "exec sleep 1000"\n' > /etc/vh/services/en.svc
has "enable" "$($C enable en)" 'enabled en'
waitstate en up 5 && ok "en is up after enable" || bad "en: $(state en)"
has "disable" "$($C disable en)" 'disabled en'
sleep 1
[ "$(state en)" != up ] && ok "en is not up after disable ($(state en))" || bad "en is still up after disable"

echo "== the manager crashes: PID 1 starts it again, the services are picked up from their cgroups"
manager_pid() { for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = vh-manager ] && { echo "${p#/proc/}"; return; }; done; }
mpid=$(manager_pid)
pa=$(pidof_svc a)
if [ -n "$mpid" ]; then
	kill -9 "$mpid"
	sleep 3.5
	has "the manager is back" "$($C ping 2>&1)" 'vh-init manager'
	mpid2=$(manager_pid)
	[ -n "$mpid2" ] && [ "$mpid2" != "$mpid" ] && ok "a new manager, pid $mpid2 (was $mpid)" || bad "manager pid: '$mpid2' (was $mpid)"
	if grep -q '/vh/cgtest$' /tmp/cgroup; then
		chk "a kept its process (adopted from the cgroup)" "$(pidof_svc a)" "$pa"
		chk "a is up" "$(state a)" up
	else skip "no cgroups: adoption not checked"; fi
else bad "no manager process found"; fi

echo "VH_DRIVER fails=$fails"
echo "VH_DRIVER_DONE"
$C poweroff >/dev/null
exit 0
