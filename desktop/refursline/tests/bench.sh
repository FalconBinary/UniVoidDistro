#!/bin/sh
# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
# Замеры против netline в одинаковых условиях (headless RefursWM, контейнер refurs-dev3):
# процессы в покое и их PSS, с обоями и без. netline + zbg запускаются из сессии (без mango
# netline переподключается к IPC — его пробуждения тут не показательны, только память).
# usage: tests/bench.sh REFURSWM_BIN REFURSLINE_BIN NETLINE_DIR OUTDIR
set -u
WM=$1; BAR=$2; NL=$3; OUT=$4
pss() { for p in "$@"; do awk '/^Pss:/ {print $2}' "/proc/$p/smaps_rollup"; done | awk '{s+=$1} END {print s+0}'; }
detail() { for p in "$@"; do echo "  $p $(tr '\0' ' ' </proc/$p/cmdline): $(awk '/^(Rss|Pss|Pss_Anon|Pss_File|Private_Dirty):/ {printf "%s %s  ", $1, $2}' "/proc/$p/smaps_rollup")"; done; }
mkdir -p "$OUT" /tmp/home/Pictures/wallpapers /tmp/home/.cache/refursline /tmp/home/.cache/netline
# обои 1920×1080 PNG, одинаковые обоим
python3 - <<'PY'
import zlib, struct
w, h = 1920, 1080
rows = []
for y in range(h):
    r = bytearray(1 + 3 * w)
    for x in range(w):
        r[1 + 3 * x] = x * 255 // w
        r[2 + 3 * x] = y * 255 // h
        r[3 + 3 * x] = (x ^ y) & 255
    rows.append(bytes(r))
def ch(t, c): return struct.pack('>I', len(c)) + t + c + struct.pack('>I', zlib.crc32(t + c) & 0xffffffff)
open('/tmp/home/Pictures/wallpapers/w.png', 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(b''.join(rows), 1)) + ch(b'IEND', b''))
PY
printf w.png >/tmp/home/.cache/refursline/wallpaper
printf w.png >/tmp/home/.cache/netline/wallpaper
chown -R 1000:1000 /tmp/home "$OUT"
run() { setpriv --reuid=1000 --regid=1000 --clear-groups env HOME=/tmp/home "$@"; }

session() {
	XDG_RUNTIME_DIR=$(run mktemp -d); export XDG_RUNTIME_DIR WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
	WLR_HEADLESS_OUTPUT_WIDTH=1920 WLR_HEADLESS_OUTPUT_HEIGHT=1080 run "$WM" >"$OUT/wm-$1.log" 2>&1 &
	WMP=$!
	for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break; sleep 0.1; done
	export WAYLAND_DISPLAY=wayland-0
}

# --- RefursLine: бар из автозапуска RefursWM
install -m 755 "$BAR" /usr/local/bin/refursline
session refursline
sleep 3
P=$(pgrep -u 1000 -x refursline | tr '\n' ' ')
echo "refursline: процессов $(echo $P | wc -w), PSS $(pss $P) kB ($P)" | tee "$OUT/bench.txt"
detail $P | tee -a "$OUT/bench.txt"
for p in $P; do awk '/^[0-9a-f]+-/ {name=$6} /^Pss:/ && $2 > 8 {print "    " $2 " kB " name}' /proc/$p/smaps; done | tee -a "$OUT/bench.txt"
kill $WMP; wait $WMP 2>/dev/null; pkill -u 1000 -x refursline; sleep 0.5
rm -f /usr/local/bin/refursline

# --- netline + zbg из сессии
session netline
run "$NL/netline" >/dev/null 2>&1 &
run "$NL/zbg" >/dev/null 2>&1 &
sleep 3
P=$(pgrep -u 1000 -x 'netline|zbg' | tr '\n' ' ')
echo "netline+zbg: процессов $(echo $P | wc -w), PSS $(pss $P) kB ($P)" | tee -a "$OUT/bench.txt"
detail $P | tee -a "$OUT/bench.txt"
for p in $P; do awk '/^[0-9a-f]+-/ {name=$6} /^Pss:/ && $2 > 8 {print "    " $2 " kB " name}' /proc/$p/smaps; done | tee -a "$OUT/bench.txt"
kill $WMP; wait $WMP 2>/dev/null; pkill -u 1000 -x 'netline|zbg'
