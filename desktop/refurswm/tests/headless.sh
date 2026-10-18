#!/bin/sh
# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
# Headless smoke test (pixman renderer, no GPU): start RefursWM, open terminals, press keys
# through wtype, take screenshots with grim. Needs a build with -Dtesting=true.
# usage: tests/headless.sh BIN OUTDIR
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

foot -o font=monospace:size=9 >/dev/null 2>&1 &
sleep 1.2; shot 1-one
foot >/dev/null 2>&1 &
sleep 1.2; shot 2-two
foot >/dev/null 2>&1 &
sleep 1.2; shot 3-three
key -k Tab;               shot 4-scroll
key -k Left;              shot 5-scroll-left
key -k Tab;               shot 6-dwindle-again
key -M ctrl -k Right -m ctrl; shot 7-resize
key -k f;                 shot 8-fullscreen
key -k f
key -M shift -k t -m shift; shot 9-light
key -k 2;                 shot 10-ws2-empty
key -k 1;                 shot 11-ws1-back
key -k q; sleep 0.5; key -k q; sleep 0.5; key -k q; shot 12-closed
wayland-info >"$OUT/wayland-info.txt" 2>&1
kill $WM; wait $WM
echo "exit=$?" >>"$OUT/wm.log"
