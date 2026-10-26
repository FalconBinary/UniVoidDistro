#!/bin/sh
# vh-init as PID 1 in a throwaway privileged Void container of the native architecture.
#   sh tests/init/init_test.sh
# The container's entry point is vh-init itself (--test-pid1 --no-stage1: a container has no
# stage 1 to run; --dir tests/init/svc: the test services). It starts the manager, the manager
# starts the services and the driver (init_driver.sh, a oneshot), the driver checks them and
# asks for the poweroff: PID 1 stops the services in order, runs stage 3 and calls reboot(2),
# which ends the container (its init is killed: docker reports 129). What the services wrote
# into /tmp is read from the stopped container afterwards (the stop order).
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
img=$(sh "$repo/tests/docker/build.sh")
case $(uname -m) in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
out=$repo/build/init-test
rm -rf "$out"
mkdir -p "$out"
echo "== building vh-init, vh-ctl and the unit tests ($arch-linux)"
(cd "$repo/init" && zig build install tests -Dtarget="$arch-linux" --prefix "$out")
cp -r "$repo/tests/init/svc" "$out/svc"
cp "$repo/tests/init/init_driver.sh" "$out/"
name=vh-init-test-$$
fails=0
echo "== unit tests"
docker run --rm -v "$out:/t:ro" "$img" sh -c '/t/test/vh-init 2>&1 | tail -1' | grep -q 'passed; 0 skipped; 0 failed\|All .* tests passed' && echo "ok unit tests" || { echo "FAIL unit tests"; fails=1; docker run --rm -v "$out:/t:ro" "$img" /t/test/vh-init 2>&1 | grep -v OK | tail -20; }
echo "== the sv shim without a manager: runit's sv under the name sv (not the LSB script sv.runit)"
# runit's sv with argv[0] other than "sv" is an LSB init script of a service of that name; the
# shim passes "sv" (the rig's first vh-init run, kvm-smoke 40323258202, saw one "fail: sv.runit" line)
shim=$(docker run --rm -v "$out:/t:ro" "$img" sh -c 'cp /usr/bin/sv /usr/bin/sv.runit && ln -sf /t/bin/vh-ctl /usr/bin/sv && sv status /etc/sv/agetty-tty1 2>&1; echo rc=$?')
case $shim in *"agetty-tty1"*) echo "ok the shim ran runit's sv for agetty-tty1 ($(printf '%s' "$shim" | head -1))" ;; *) echo "FAIL the shim: $shim"; fails=1 ;; esac
echo "== vh-init as PID 1 of the container (log: $out/console.log)"
docker run -d --name "$name" --privileged -v "$out:/t:ro" "$img" /t/bin/vh-init --test-pid1 --no-stage1 --dir /t/svc -v >/dev/null
# the whole run takes about 20 s; a hang (no poweroff) is cut after 180 s
i=0
while [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = true ] && [ $i -lt 180 ]; do sleep 1; i=$((i + 1)); done
if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = true ]; then echo "FAIL the container did not end in 180 s: killed"; docker kill "$name" >/dev/null; fails=1; fi
rc=$(docker inspect -f '{{.State.ExitCode}}' "$name")
docker logs "$name" > "$out/console.log" 2>&1
echo "   container exit code $rc after $i s (130 = the init was killed by SIGINT: reboot(2) with POWER_OFF in a pid namespace)"
grep -q 'VH_DRIVER_DONE' "$out/console.log" && echo "ok the driver ran to its end" || { echo "FAIL the driver did not finish"; fails=1; }
grep '^FAIL\|^ok\|^SKIP\|^==' "$out/console.log" | sed 's/^/   /'
n=$(grep -c '^FAIL' "$out/console.log" || true)
[ "$n" = 0 ] && echo "ok no FAIL line from the driver" || { echo "FAIL $n driver checks failed"; fails=1; }
grep -q 'vh-init: poweroff requested' "$out/console.log" && echo "ok PID 1 took the poweroff request" || { echo "FAIL no poweroff request in the log"; fails=1; }
grep -q 'vh-init: every service is down\|manager exited with 0 during the shutdown' "$out/console.log" && echo "ok the manager stopped every service" || { echo "FAIL the services were not all stopped"; fails=1; }
grep -q 'did not stop the services in 60 s' "$out/console.log" && { echo "FAIL the shutdown hit the 60 s timeout"; fails=1; } || echo "ok the shutdown finished before its timeout"
[ "$i" -lt 60 ] && echo "ok the whole run took $i s" || { echo "FAIL the run took $i s (a hang somewhere)"; fails=1; }
grep -q 'stage 3 done in' "$out/console.log" && echo "ok stage 3 ran" || { echo "FAIL no stage 3"; fails=1; }
if [ "$rc" = 130 ]; then echo "ok the container ended by reboot(2) with POWER_OFF ($rc)"; else echo "FAIL the container did not end by reboot(2): $rc"; fails=1; fi
# the stop order: b (needs a) must have been stopped before a
sa=$(docker cp "$name:/tmp/stop-a" - 2>/dev/null | tar -xO 2>/dev/null || true)
sb=$(docker cp "$name:/tmp/stop-b" - 2>/dev/null | tar -xO 2>/dev/null || true)
if [ -n "$sa" ] && [ -n "$sb" ]; then
	[ "$sb" -lt "$sa" ] && echo "ok shutdown stopped b ($sb) before a ($sa): the reverse of the dependency" || { echo "FAIL shutdown stopped a ($sa) before b ($sb)"; fails=1; }
else echo "FAIL no stop stamps (a: '$sa', b: '$sb')"; fails=1; fi
docker rm "$name" >/dev/null 2>&1 || true
[ "$fails" = 0 ] && echo "== vh-init container test: PASS" || { echo "== vh-init container test: FAIL"; exit 1; }
