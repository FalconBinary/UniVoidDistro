#!/bin/sh
# Unit tests of vh-kconf (kernel/) in a throwaway container: Zig cross-builds the test binary
# for Linux of the host's architecture (as tests/zig/run.sh does), the container only runs it
# (a static PIE: any Linux image does; alpine is used). The files the tests read
# (tests/kernel/fixtures, kernel/pins, kernel/profiles, the golden plans of tests/adapt) and the
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
echo "== building vh-kconf and its tests ($arch-linux)"
(cd "$repo/kernel" && zig build install tests -Dtarget="$arch-linux" -Dcpu=baseline --prefix "$out")
echo "== running in a container"
tar -C "$repo" -cf - kernel/pins kernel/profiles tests/kernel/fixtures tests/adapt/golden build/kt | docker run --rm -i alpine:3.20 sh -c '
	set -e
	mkdir -p /src && cd /src && tar -xf -
	for t in /src/build/kt/test/*; do printf "%s: " "$(basename "$t")"; "$t" 2>&1 | tail -1; done
	echo "== the fixture through the installed binary"
	/src/build/kt/bin/vh-kconf probe --from /src/tests/kernel/fixtures/gf63 > /tmp/gf63.zon
	echo "devices: $(grep -c "modalias" /tmp/gf63.zon)"
	/src/build/kt/bin/vh-kconf resolve --hw /tmp/gf63.zon --plan /src/tests/adapt/golden/gf63/strict/plan.zon --repo /src --out /tmp/r
	head -4 /tmp/r/resolve-report.txt
	wc -l /tmp/r/lsmod /tmp/r/fragment.config /tmp/r/.config
'
