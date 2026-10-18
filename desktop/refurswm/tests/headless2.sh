#!/bin/sh
# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
# Second headless round: layer shell (swaybg, fuzzel), focus-follows-mouse (wlrctl virtual
# pointer), idle CPU cost, session lock incl. a crashed locker. Needs -Dtesting=true.
# usage: tests/headless2.sh BIN OUTDIR
set -u
BIN=$1; OUT=$2
mkdir -p "$OUT"
export XDG_RUNTIME_DIR=$(mktemp -d) WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
"$BIN" >"$OUT/wm.log" 2>&1 &
WM=$!
for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break; sleep 0.1; done
export WAYLAND_DISPLAY=wayland-0
shot() { sleep 0.8; grim "$OUT/$1.png"; }
cpu() { awk '{print $14+$15}' /proc/$WM/stat; }

swaybg -c '#802020' >/dev/null 2>&1 &
foot >/dev/null 2>&1 &
sleep 1; foot >/dev/null 2>&1 &
sleep 1.5; shot 1-bg-two
wlrctl pointer move -3000 -3000; wlrctl pointer move 300 300; shot 2-hover-left
wlrctl pointer move 600 0; shot 3-hover-right

fuzzel >/dev/null 2>&1 &
sleep 1; wtype abc; shot 4-fuzzel
wlrctl pointer move -600 0; shot 5-hover-while-launcher
wtype -k Escape; sleep 0.5; shot 6-launcher-closed

# idle cost: nothing changes on screen for 10 s
sleep 1
a=$(cpu); sleep 10; b=$(cpu)
echo "idle cpu ticks over 10s: $((b - a))" >"$OUT/perf.txt"
grep -E "VmRSS|VmHWM" /proc/$WM/status >>"$OUT/perf.txt"
# active cost: 200 pointer moves
a=$(cpu); for i in $(seq 100); do wlrctl pointer move 3 1; wlrctl pointer move -3 -1; done; b=$(cpu)
echo "cpu ticks for 200 pointer motions: $((b - a))" >>"$OUT/perf.txt"

swaylock -c 000000 >/dev/null 2>&1 &
LK=$!
sleep 1.5; shot 7-locked
kill -9 $LK; sleep 0.5; shot 8-locker-crashed
wtype -M logo -k Return -m logo; sleep 1; shot 9-locked-no-spawn
pgrep -c foot >"$OUT/foot-count.txt"
kill $WM; wait $WM
echo "exit=$?" >>"$OUT/wm.log"
