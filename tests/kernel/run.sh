#!/bin/sh
# Unit tests of vh-kconf (kernel/) in a throwaway container: Zig cross-builds the test binary
# for Linux of the host's architecture (as tests/zig/run.sh does), the container only runs it
# (a static PIE: any Linux image does; alpine is used). The files the tests read
# (tests/kernel/fixtures, kernel/pins, kernel/profiles, kernel/hw, hwdb, the golden plans of tests/adapt) and the
# binaries are streamed in with tar instead of a bind mount: Docker Desktop on macOS refuses files that carry the
# com.apple.provenance attribute ("Resource deadlock would occur"), and files written from
# the Claude app carry it.
#   sh tests/kernel/run.sh
set -eu
# macOS tar: no AppleDouble ("._name") files for the extended attributes
export COPYFILE_DISABLE=1
repo=$(cd "$(dirname "$0")/../.." && pwd)
case $(uname -m) in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
out=$repo/build/kt
rm -rf "$out"
echo "== building vh-kconf and its tests, and vh-plan for the fresh plan of check ($arch-linux)"
(cd "$repo/kernel" && zig build install tests -Dtarget="$arch-linux" -Dcpu=baseline --prefix "$out")
(cd "$repo/adapt" && zig build install -Dtarget="$arch-linux" -Dcpu=baseline --prefix "$out")
echo "== running in a container"
tar -C "$repo" -cf - kernel/pins kernel/profiles kernel/hw hwdb vh.conf.example tests/kernel/fixtures tests/adapt/golden build/kt | docker run --rm -i alpine:3.20 sh -c '
	set -e
	mkdir -p /src && cd /src && tar -xf -
	for t in /src/build/kt/test/*; do printf "%s: " "$(basename "$t")"; "$t" 2>&1 | tail -1; done
	echo "== the fixture through the installed binary"
	/src/build/kt/bin/vh-kconf probe --from /src/tests/kernel/fixtures/gf63 > /tmp/gf63.zon
	echo "devices: $(grep -c "modalias" /tmp/gf63.zon)"
	/src/build/kt/bin/vh-kconf resolve --hw /tmp/gf63.zon --plan /src/tests/adapt/golden/gf63/strict/plan.zon --repo /src --out /tmp/r
	head -4 /tmp/r/resolve-report.txt
	wc -l /tmp/r/lsmod /tmp/r/fragment.config /tmp/r/.config
	echo "== vh-kconf check: the GF63 against its own probe, then the AMD desktop against the GF63s"
	c() { rc=0; /src/build/kt/bin/vh-kconf check --kmsg /dev/null --root /tmp/croot --repo /src "$@" > /tmp/check.out 2>&1 || rc=$?; echo "exit $rc: $(cat /tmp/croot/run/vh/check.done)"; }
	c --from /src/tests/kernel/fixtures/gf63 --hw /src/kernel/hw/gf63.zon --vh-plan none
	[ "$rc" = 0 ] && grep -qx "VH_CHECK machine=same devices=0 firmware=0 lost=0" /tmp/croot/run/vh/check.done && [ ! -e /tmp/croot/run/vh/check ]
	c --from /src/tests/kernel/fixtures/amd-desktop --hw /src/kernel/hw/gf63.zon --vh-plan /src/build/kt/bin/vh-plan
	[ "$rc" = 1 ] && grep -q "machine=different" /tmp/croot/run/vh/check.done
	grep "^  CPU\|^  board\|^A fresh plan" /tmp/croot/run/vh/check
	grep -q "^machine: amd-desktop" /tmp/croot/run/vh/plan/plan-report.txt && grep -q "amd-desktop" /tmp/croot/run/vh/plan/hw.zon
	echo "the fresh plan: $(head -2 /tmp/croot/run/vh/plan/plan-report.txt | tail -1)"
'
