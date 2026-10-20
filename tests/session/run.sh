#!/bin/sh
# Track G (session/): the unit tests, then the gaming session end to end in a throwaway,
# privileged Void container whose own root plays the system (tests/session/e2e.sh): vh-game
# install, the session vh-game-enter makes (as the game user, without privileges), vh-game
# remove, and the whole file system compared before the install and after the removal.
#   sh tests/session/run.sh            # the root gets base-files, bash, coreutils only
#   VH_TEST_FULL=1 sh tests/session/run.sh   # every package of the profile and the plan
# Zig cross-builds for Linux of the host's architecture; the inputs are streamed in with tar
# (tests/kernel/run.sh says why). The session needs unprivileged user namespaces: a kernel that
# restricts them (Ubuntu's AppArmor, kernel.apparmor_restrict_unprivileged_userns=1, as in
# colima's VM) skips that part with a note; the workflow lifts the restriction on its runner.
set -eu
export COPYFILE_DISABLE=1
repo=$(cd "$(dirname "$0")/../.." && pwd)
case $(uname -m) in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
out=$repo/build/st
rm -rf "$out"
echo "== building vh-root, vh-game, vh-game-enter and their tests ($arch-linux)"
(cd "$repo/session" && zig build install tests -Dtarget="$arch-linux" -Dcpu=baseline --prefix "$out")
echo "== unit tests (a user, not root)"
tar -C "$repo" -cf - build/st/test | docker run --rm -i alpine:3.20 sh -c '
	set -e
	mkdir -p /src && cd /src && tar -xf -
	adduser -D -u 1000 tester >/dev/null 2>&1
	su tester -c "/src/build/st/test/vh-session" > /tmp/unit.out 2>&1 || { cat /tmp/unit.out; exit 1; }
	tail -1 /tmp/unit.out'
echo "== the session end to end (a privileged Void container)"
img=$(sh "$repo/tests/docker/build.sh")
tar -C "$repo" -cf - build/st/bin tests/session/e2e.sh rootfs/etc/security/access.conf.in |
	docker run --rm -i --privileged -e VH_TEST_FULL="${VH_TEST_FULL:-0}" "$img" bash -c '
	mkdir -p /src && cd /src && tar -xf - 2>/dev/null && bash tests/session/e2e.sh /src'
