#!/bin/sh
# vh-stage1 (init/) tests in a throwaway privileged Void container of the native architecture.
#   sh tests/init/run.sh
#  1. the unit tests of init/ (zig build tests, run in the container);
#  2. tests/init/stage1_test.sh: every stage-1 step that is possible in a container, checked
#     against the stock tools as oracles (sysctl --system, mount -a, halt -B + utmpdump,
#     seedrng, nft) and under a fake root (--root) for what touches the kernel of the host;
#  3. tests/init/init_test.sh: vh-init as PID 1 of a container with the test services of
#     tests/init/svc, driven by tests/init/init_driver.sh through vh-ctl and the sv shim.
# Zig builds on the host (cross-compilation); the container only runs the result, as in
# tests/zig/run.sh. The VM step (tests/vm/steps/init.py) covers the real boot.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
img=$(sh "$repo/tests/docker/build.sh")
case $(uname -m) in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
out=$repo/build/init-test       # inside the repository: macOS docker does not see temporary directories
rm -rf "$out"
mkdir -p "$out"
echo "== building vh-stage1 and its unit tests ($arch-linux)"
(cd "$repo/init" && zig build install tests -Dtarget="$arch-linux" --prefix "$out")
# the scripts go in with the binaries: the container needs nothing else from the repository
cp "$repo/tests/init/stage1_test.sh" "$out/"
# vh-power, the script the udev rule runs, against the native power step of stage 1, and
# vh-backlight on a fake sysfs
cp "$repo/rootfs/usr/local/sbin/vh-power" "$repo/rootfs/usr/local/bin/vh-backlight" "$out/"
docker run --rm --privileged -v "$out:/t:ro" "$img" sh /t/stage1_test.sh /t
# v0.2: vh-init as PID 1 of a container, the manager, vh-ctl and the sv shim (tests/init/init_test.sh)
sh "$repo/tests/init/init_test.sh"
