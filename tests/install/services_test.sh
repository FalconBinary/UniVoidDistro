#!/bin/bash
# runit's state of each service in /run, as Void's packages ship it: every service directory of
# rootfs/ and optional/ has supervise -> /run/runit/supervise.NAME (and log/supervise ->
# /run/runit/supervise.NAME-log); install/lib.sh install_tree puts the links in as links, in place
# of a supervise/ directory a runsv made on disk; rootfs/usr/local/libexec/vh/vh-sv-runstate turns
# an older installation's on-disk state into the links, an enabled service out of /var/service
# and back, leaves a directory alone while a runsv works in it, and says nothing when there is
# nothing to do; runit's runsv makes the link's target in /run/runit, and under runit's runsvdir
# an enabled service with a log restarts once and runs again with its state there.
#   bash tests/install/services_test.sh /src   (root, in the vh-dev image: tests/install/run.sh)
set -u
src=${1:?"the repository"}
fails=0
ok() { echo "ok $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fails=$((fails + 1)); }

echo "== every service directory of rootfs/ and optional/ has its links"
n_sv=0
for d in "$src"/rootfs/etc/sv/* "$src"/optional/*/sv/*; do
	[ -e "$d/run" ] || [ -e "$d/run.in" ] || continue
	n=${d##*/}
	n_sv=$((n_sv + 1))
	l=$(readlink "$d/supervise" 2>/dev/null || true)
	[ "$l" = "/run/runit/supervise.$n" ] && ok "$n: supervise -> $l" || bad "$n: supervise" "${l:-not a link}"
	if [ -e "$d/log/run" ]; then
		l=$(readlink "$d/log/supervise" 2>/dev/null || true)
		[ "$l" = "/run/runit/supervise.$n-log" ] && ok "$n/log: supervise -> $l" || bad "$n/log: supervise" "${l:-not a link}"
	fi
done
[ "$n_sv" -gt 0 ] && ok "$n_sv service directories" || bad "no service directory found"

echo "== install_tree: the links as links, in place of a supervise/ on disk"
tree=$(mktemp -d) root=$(mktemp -d)
mkdir -p "$tree/etc/sv" && cp -a "$src/rootfs/etc/sv/vh-acpid" "$tree/etc/sv/"
# what a runsv left on disk before the link existed
mkdir -p "$root/etc/sv/vh-acpid/supervise" "$root/etc/sv/vh-acpid/log/supervise"
echo stale > "$root/etc/sv/vh-acpid/supervise/stat"
out=$( . "$src/install/lib.sh"; DRY_RUN=1 install_tree "$tree" "$root" )
case $out in *"+ link /etc/sv/vh-acpid/supervise -> /run/runit/supervise.vh-acpid"*) ok "dry run: the link named" ;; *) bad "dry run" "$out" ;; esac
( . "$src/install/lib.sh"; DRY_RUN=0 install_tree "$tree" "$root" ) || bad "install_tree failed"
[ "$(readlink "$root/etc/sv/vh-acpid/supervise")" = /run/runit/supervise.vh-acpid ] \
	&& [ "$(readlink "$root/etc/sv/vh-acpid/log/supervise")" = /run/runit/supervise.vh-acpid-log ] \
	&& ok "the on-disk supervise/ and log/supervise/ replaced by the links" \
	|| bad "install_tree left" "$(ls -la "$root/etc/sv/vh-acpid" "$root/etc/sv/vh-acpid/log" 2>&1 | tr '\n' ' ')"
[ -f "$root/etc/sv/vh-acpid/run" ] && [ -x "$root/etc/sv/vh-acpid/run" ] && [ ! -L "$root/etc/sv/vh-acpid/run" ] \
	&& ok "the run script stays a file, executable" || bad "the run script"
( . "$src/install/lib.sh"; DRY_RUN=0 install_tree "$tree" "$root" ) && [ "$(readlink "$root/etc/sv/vh-acpid/supervise")" = /run/runit/supervise.vh-acpid ] \
	&& ok "a second install_tree keeps the link" || bad "a second install_tree"
rm -rf "$tree" "$root"

echo "== vh-sv-runstate: an older installation's state on disk becomes the link"
runstate=$src/rootfs/usr/local/libexec/vh/vh-sv-runstate
mkdir -p /etc/sv/vh-t1/supervise /etc/sv/vh-t2/supervise /etc/sv/vh-t2/log/supervise
# /var/service is Void's link to /etc/runit/runsvdir/default, whose directory a container may lack
mkdir -p "$(readlink -m /var/service)"
for f in /etc/sv/vh-t1/run /etc/sv/vh-t2/run /etc/sv/vh-t2/log/run; do printf '#!/bin/sh\nexec sleep 1000\n' > "$f"; chmod 0755 "$f"; done
echo stale > /etc/sv/vh-t2/supervise/stat
ln -sfn /etc/sv/vh-t2 /var/service/vh-t2
# vh-t3: its state on disk under a runsv started by hand, outside /var/service
mkdir -p /etc/sv/vh-t3/supervise /run/runit
printf '#!/bin/sh\nexec sleep 1000\n' > /etc/sv/vh-t3/run; chmod 0755 /etc/sv/vh-t3/run
runsv /etc/sv/vh-t3 & rsv=$!
i=0; while [ ! -p /etc/sv/vh-t3/supervise/ok ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
out=$(sh "$runstate" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "it ran" || bad "it failed ($rc)" "$out"
[ "$(readlink /etc/sv/vh-t1/supervise)" = /run/runit/supervise.vh-t1 ] && ok "a disabled service: the link" || bad "vh-t1" "$(ls -la /etc/sv/vh-t1)"
[ "$(readlink /etc/sv/vh-t2/supervise)" = /run/runit/supervise.vh-t2 ] && [ "$(readlink /etc/sv/vh-t2/log/supervise)" = /run/runit/supervise.vh-t2-log ] \
	&& ok "an enabled service with a log: both links" || bad "vh-t2" "$(ls -la /etc/sv/vh-t2 /etc/sv/vh-t2/log | tr '\n' ' ')"
[ "$(readlink /var/service/vh-t2)" = /etc/sv/vh-t2 ] && ok "the enabled service is back in /var/service" || bad "/var/service/vh-t2"
case $out in *"vh-t1: supervise -> /run/runit"*) ok "it says what it did" ;; *) bad "its output" "$out" ;; esac
[ -d /etc/sv/vh-t3/supervise ] && [ ! -L /etc/sv/vh-t3/supervise ] && case $out in *"vh-t3: a runsv is at work"*) true ;; *) false ;; esac \
	&& ok "a runsv at work in the directory: left as it is, and said" || bad "vh-t3 under its runsv" "$out"
# once that runsv is gone, the next run gives vh-t3 the link, and runit's runsv makes its target
sv exit /etc/sv/vh-t3 >/dev/null; wait "$rsv"
out=$(sh "$runstate" 2>&1)
[ "$(readlink /etc/sv/vh-t3/supervise)" = /run/runit/supervise.vh-t3 ] && case $out in *vh-t1*|*vh-t2*) false ;; *) true ;; esac \
	&& ok "its runsv gone: the link, and only that" || bad "the second run" "$out"
runsv /etc/sv/vh-t3 & rsv=$!
i=0; while [ ! -p /run/runit/supervise.vh-t3/ok ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -p /run/runit/supervise.vh-t3/ok ] && [ "$(sv status /etc/sv/vh-t3 | cut -c1-4)" = run: ] \
	&& ok "runsv keeps the state in /run/runit/supervise.vh-t3, sv reaches it" || bad "runsv through the link" "$(ls -la /run/runit 2>&1 | tr '\n' ' ')"
sv exit /etc/sv/vh-t3 >/dev/null; wait "$rsv"
out=$(sh "$runstate" 2>&1)
[ -z "$out" ] && ok "a third run has nothing to do, and says nothing" || bad "a third run is not silent" "$out"
rm -rf /etc/sv/vh-t1 /etc/sv/vh-t2 /etc/sv/vh-t3 /var/service/vh-t2 /run/runit/supervise.vh-t3

echo "== vh-sv-runstate under runsvdir: an enabled service with a log stops, gets the links, runs again"
mkdir -p /etc/sv/vh-t4/supervise /etc/sv/vh-t4/log/supervise
printf '#!/bin/sh\nexec sleep 1000\n' > /etc/sv/vh-t4/run
printf '#!/bin/sh\nexec cat >/dev/null\n' > /etc/sv/vh-t4/log/run
chmod 0755 /etc/sv/vh-t4/run /etc/sv/vh-t4/log/run
ln -s /etc/sv/vh-t4 /var/service/vh-t4
runsvdir /var/service & rsd=$!
# the service and its log running, as sv reports them; its pid
t4_up() { i=0; until sv status /etc/sv/vh-t4 2>/dev/null | grep -q '^run: .*; run: log:'; do [ "$i" -lt 200 ] || return 1; sleep 0.1; i=$((i + 1)); done; }
t4_pid() { sv status /etc/sv/vh-t4 | sed -n 's/^run: [^(]*(pid \([0-9]*\)).*/\1/p'; }
if t4_up; then
	pid0=$(t4_pid) t0=$(date +%s)
	out=$(sh "$runstate" 2>&1)
	t4_up; t1=$(date +%s) pid1=$(t4_pid)
	case $out in *"vh-t4: supervise log/supervise -> /run/runit"*) ok "it says what it did" ;; *) bad "its output" "$out" ;; esac
	[ "$(readlink /etc/sv/vh-t4/supervise)" = /run/runit/supervise.vh-t4 ] && [ "$(readlink /etc/sv/vh-t4/log/supervise)" = /run/runit/supervise.vh-t4-log ] \
		&& [ "$(readlink /var/service/vh-t4)" = /etc/sv/vh-t4 ] && ok "both links, and the service back in /var/service" || bad "vh-t4" "$(ls -la /etc/sv/vh-t4 /var/service | tr '\n' ' ')"
	[ -p /run/runit/supervise.vh-t4/ok ] && [ -p /run/runit/supervise.vh-t4-log/ok ] \
		&& ok "runsvdir's new runsv keeps the state of both in /run/runit" || bad "/run/runit" "$(ls -la /run/runit | tr '\n' ' ')"
	[ -n "$pid1" ] && [ "$pid1" != "$pid0" ] && [ $((t1 - t0)) -le 15 ] \
		&& ok "the service restarted once: running again $((t1 - t0)) s after the tool started" || bad "the restart" "pid $pid0 -> ${pid1:-none}, $((t1 - t0)) s"
	out=$(sh "$runstate" 2>&1); p=$(t4_pid)
	[ -z "$out" ] && [ "$p" = "$pid1" ] && ok "a second run says nothing and leaves the service running" || bad "a second run" "$out (pid $pid1 -> $p)"
else
	bad "runsvdir did not start vh-t4" "$(sv status /etc/sv/vh-t4 2>&1)"
fi
rm -f /var/service/vh-t4
i=0; while pgrep -f '^runsv vh-t4$' >/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill "$rsd"; wait "$rsd" 2>/dev/null
rm -rf /etc/sv/vh-t4 /run/runit/supervise.vh-t4 /run/runit/supervise.vh-t4-log

echo
[ "$fails" = 0 ] && echo "services_test: all checks passed" || echo "services_test: $fails FAILED"
exit $(( fails > 0 ))
