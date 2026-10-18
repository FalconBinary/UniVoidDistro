#!/bin/sh
# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
# Cost of RefursWM, headless (pixman, no GPU): binary and libraries, start time, memory of all its own
# processes, idle CPU, the price of pointer motion (CPU and syscalls, with an idle daemon running as
# on a desktop) and the configures a client gets when its focused window is activated again.
# usage: tests/bench.sh BIN EVIL OUTDIR      (BIN built with -Dtesting=true; strace needs CAP_SYS_PTRACE)
set -u
BIN=$1; EVIL=$2; OUT=$3
mkdir -p "$OUT"
R=$OUT/bench.txt
: >"$R"
XDG_RUNTIME_DIR=$(mktemp -d)
export XDG_RUNTIME_DIR WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
note() { echo "$*" | tee -a "$R"; }
cpu() { awk '{print $14 + $15}' "/proc/$1/stat"; }

readelf -d "$BIN" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' >"$OUT/needed.txt"
note "binary: $(stat -c %s "$BIN") bytes, NEEDED: $(wc -l <"$OUT/needed.txt")"

t0=$(date +%s%N)
"$BIN" >"$OUT/wm.log" 2>&1 &
WM=$!
until [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; do sleep 0.001; done
t1=$(date +%s%N)
note "socket ready: $(((t1 - t0) / 1000000)) ms"
export WAYLAND_DISPLAY=wayland-0
sleep 1

procs="$WM $(pgrep -P "$WM" -x refurs-launcher)"
pss=0
for p in $procs; do pss=$((pss + $(awk '/^Pss:/ {print $2}' "/proc/$p/smaps_rollup"))); done
grep -o '/[^ ]*\.so[^ ]*' "/proc/$WM/maps" | sort -u >"$OUT/maps.txt"
note "memory: PSS $pss kB (processes: $(echo $procs | wc -w)), compositor RSS $(awk '/^VmRSS/ {print $2}' "/proc/$WM/status") kB, mapped .so: $(wc -l <"$OUT/maps.txt")"

a=$(cpu "$WM"); sleep 10; b=$(cpu "$WM")
note "idle: $((b - a)) CPU ticks in 10 s"

# an idle daemon with two timeouts, as on a real desktop; the motion runs over a window of its own
swayidle -w timeout 300 true timeout 600 true >/dev/null 2>&1 &
sleep 0.5
a=$(cpu "$WM"); "$EVIL" motion 2000 >/dev/null; b=$(cpu "$WM")
note "2000 pointer motions: $((b - a)) CPU ticks"
if command -v strace >/dev/null; then
	strace -f -c -o "$OUT/strace.txt" -p "$WM" 2>/dev/null &
	ST=$!
	sleep 0.5
	"$EVIL" motion 2000 >/dev/null
	sleep 0.2
	kill -INT $ST; wait $ST
	note "syscalls for 2000 motions: $(awk '$NF == "total" {print $4}' "$OUT/strace.txt"), of them timerfd_settime: $(awk '$NF == "timerfd_settime" {print $4}' "$OUT/strace.txt")"
fi
# headless has no keyboard: hold a virtual one so the window gets keyboard focus
"$EVIL" keyboard 30 >/dev/null 2>&1 &
sleep 0.3
note "$("$EVIL" selfactivate 20)"
pkill -x evil

pkill -x swayidle
kill "$WM"; wait "$WM"
echo "exit=$?" >>"$OUT/wm.log"
