#!/bin/sh
# Build vh-stage1 for the VM rig (x86_64, static PIE) into build/init/bin. The VM step
# tests/vm/steps/init.py installs it from there (python3 tests/vm/check.py stage1 --repo)
# and bench/init/stage1_boot.py measures it; both also need build/ from tests/zig/build.sh.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
rm -rf "$repo/build/init"
(cd "$repo/init" && zig build -Dtarget=x86_64-linux -Dcpu=baseline --prefix "$repo/build/init")
ls -l "$repo/build/init/bin/vh-stage1"
