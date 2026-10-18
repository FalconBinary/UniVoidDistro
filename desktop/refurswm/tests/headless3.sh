#!/bin/sh
# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
# Third headless round: floating, move to workspace, toggle split, scroll columns, Super+drag swap.
# usage: tests/headless3.sh BIN OUTDIR
set -u
BIN=$1; OUT=$2
mkdir -p "$OUT"
export XDG_RUNTIME_DIR=$(mktemp -d) WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
"$BIN" >"$OUT/wm.log" 2>&1 &
WM=$!
for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break; sleep 0.1; done
export WAYLAND_DISPLAY=wayland-0
key() { wtype -M logo "$@" -m logo; sleep 0.6; }
shot() { sleep 0.8; grim "$OUT/$1.png"; }
for n in 1 2 3; do foot -T "win$n" >/dev/null 2>&1 & sleep 1.2; done
key -k space;                     shot 1-float
key -M shift -k Left -m shift; key -M shift -k Left -m shift; shot 2-float-moved
key -k space;                     shot 3-tiled-again
key -k s;                         shot 4-split-toggled
key -M shift -k 2 -m shift;       shot 5-moved-to-ws2
key -k 2;                         shot 6-on-ws2
key -k 1
key -k Tab
key -k bracketleft;               shot 7-scroll-merged
key -k backslash;                 shot 8-scroll-expelled
key -k r;                         shot 9-scroll-width
key -k Tab
# Super + left drag from window 1 onto window 2 swaps them
wlrctl pointer move -3000 -3000; wlrctl pointer move 200 300
wtype -P Super_L; sleep 0.2
wlrctl pointer click left >/dev/null 2>&1
shot 10-before-drag
wtype -p Super_L
kill $WM; wait $WM
echo "exit=$?" >>"$OUT/wm.log"
