#!/bin/sh
# Copyright (c) 2026 Denys (FalconBinary)
# SPDX-License-Identifier: GPL-3.0-or-later
# Проверка вживую без GPU: RefursWM (сборка -Dtesting=true) запускает бар из автозапуска с grant,
# дальше хоткеи (wtype), клики (wlrctl) и снимки (grim). Запускается в контейнере refurs-dev3 от
# root: ставит бинарник по пути из grant, сессию ведёт от uid 1000 (бар от root не запускается),
# а сам читает то, что бар (DUMPABLE=0) показывает только root: память, дескрипторы, окружение.
# usage: tests/headless.sh REFURSWM_BIN REFURSLINE_BIN OUTDIR
set -u
WM=$1; BAR=$2; OUT=$3

if [ "$(id -u)" = 0 ]; then
	install -m 755 "$BAR" /usr/local/bin/refursline
	mkdir -p "$OUT" /tmp/home/Pictures/wallpapers && chown -R 1000:1000 /tmp/home "$OUT"
	rm -f "$OUT"/req-* "$OUT"/res-*
	setpriv --reuid=1000 --regid=1000 --clear-groups env HOME=/tmp/home USER=test REFURSLINE_TRACE="${REFURSLINE_TRACE:-}" sh "$0" "$@" &
	SESSION=$!
	# замеры по запросу сессии: файл req-ИМЯ с pid → res-ИМЯ
	while kill -0 "$SESSION" 2>/dev/null; do
		for r in "$OUT"/req-*; do
			[ -e "$r" ] || continue
			name=${r##*/req-}; pid=$(cat "$r")
			# простой: 8 с strace; пробуждение только от таймера часов (второй fd в ppoll) не
			# считается — в VM часы системы шагают, и таймер с CANCEL_ON_SET перевзводится
			if [ "$name" = idle ]; then
				timeout 8 strace -p "$pid" -e trace=ppoll -e signal=none 2>&1 | awk '
					/ppoll\(/ && /= [0-9]+ \(/ {
						split($0, a, "{fd="); split(a[3], b, ","); clock = b[1]
						r = $0; sub(/.*= [0-9]+ \(\[/, "", r)
						n = split(r, ev, "{fd="); other = 0
						for (i = 2; i <= n; i++) { split(ev[i], f, ","); if (f[1] != clock) other = 1 }
						if (other) o++; else c++
					}
					END { printf "other=%d clock=%d\n", o, c }' >"$OUT/res-$name"
				rm -f "$r"; continue
			fi
			{
				awk '/^(Rss|Pss|Pss_Anon|Pss_File):/ {printf "%s %s kB  ", $1, $2}' "/proc/$pid/smaps_rollup"; echo
				echo "fds: $(ls /proc/"$pid"/fd | wc -l)"
				ls -l /proc/"$pid"/fd | awk 'NR > 1 {print $NF}' | tr '\n' ' '; echo
				tr '\0' '\n' <"/proc/$pid/environ" | grep -c '^WAYLAND_SOCKET=' | sed 's/^/WAYLAND_SOCKET: /'
				grep -E '^(Seccomp|NoNewPrivs):' "/proc/$pid/status" | tr '\n' ' '; echo
			} >"$OUT/res-$name" 2>&1
			rm -f "$r"
		done
		sleep 0.1
	done
	wait "$SESSION"
	exit $?
fi

export XDG_RUNTIME_DIR=$(mktemp -d) WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
fails=0
R=$OUT/result.txt
: >"$R"
ok() { echo "PASS $1" | tee -a "$R"; }
bad() { echo "FAIL $1${2:+: $2}" | tee -a "$R"; fails=$((fails + 1)); }
measure() { echo "$2" >"$OUT/req-$1"; while [ -e "$OUT/req-$1" ]; do sleep 0.05; done; cat "$OUT/res-$1"; }
st() { awk -v k="$2:" '$1 == k {print $2}' "/proc/$1/status"; }
key() { wtype -M logo "$@" -m logo; sleep 0.5; }
shot() { sleep 0.6; grim "$OUT/$1.png"; }
# указатель в точку (x, y): в угол, потом относительно
pointer() { wlrctl pointer move -5000 -5000; wlrctl pointer move "$1" "$2"; sleep 0.2; }

"$WM" >"$OUT/wm.log" 2>&1 &
WMP=$!
for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break; sleep 0.1; done
export WAYLAND_DISPLAY=wayland-0
sleep 1.5
BARP=$(pgrep -x -u 1000 refursline | head -n 1)
[ -n "$BARP" ] && ok "бар запущен RefursWM из автозапуска (pid $BARP)" || bad "бар" "не запущен: $(cat "$OUT/wm.log")"
BRK=$(pgrep -P "$BARP" -x refursline)
shot 01-start

NPROC=$(pgrep -x -u 1000 refursline | wc -l)
[ "$NPROC" = 2 ] && ok "в покое 2 процесса: бар и broker" || bad "процессы" "$NPROC"
measure bar "$BARP" >"$OUT/bar.txt"
grep -Eq "Seccomp:[[:space:]]+2" "$OUT/bar.txt" && grep -Eq "NoNewPrivs:[[:space:]]+1" "$OUT/bar.txt" && ok "бар: no_new_privs + seccomp" || bad "бар" "$(tail -n 1 "$OUT/bar.txt")"
ok "бар: $(head -n 2 "$OUT/bar.txt" | tr '\n' ' ')"
measure broker "$BRK" >"$OUT/broker.txt"
n=$(sed -n 's/^fds: //p' "$OUT/broker.txt")
[ "$n" -le 5 ] && ok "broker: $n дескрипторов ($(sed -n 3p "$OUT/broker.txt"))" || bad broker "$(cat "$OUT/broker.txt")"
grep -q "socket:" "$OUT/bar.txt" || bad "бар" "нет сокетов?"

foot >/dev/null 2>&1 &
sleep 1.5; shot 02-foot
key -k 2; shot 03-ws2
key -k 1; shot 04-ws1
key -k Tab; shot 05-scroll-mode
key -k Tab
key -M shift -k t -m shift; shot 06-light
key -M shift -k t -m shift; shot 07-dark

# простой: ни одного пробуждения за 8 с (strace от root; часы — раз в минуту и при шаге
# системных часов — не в счёт). Окно не задевает смену минуты.
sleep 3
sec=$(date +%S); sec=${sec#0}
[ "$sec" -gt 48 ] && sleep $((63 - sec))
w=$(measure idle "$BARP")
case $w in other=0*) ok "простой: 0 пробуждений за 8 с ($w)" ;; *) bad "простой" "$w" ;; esac

# меню по хоткеям RefursWM: событие refurs-shell → broker → refursline <меню>
key -k d; sleep 1; shot 08-run
MENU=$(pgrep -o -f "refursline run")  # старший: у лаунчера есть свой процесс запуска
[ -n "$MENU" ] && ok "Super+D: лаунчер" || bad "лаунчер" "не открылся"
measure menu "$MENU" >"$OUT/menu.txt"
grep -q "WAYLAND_SOCKET: 0" "$OUT/menu.txt" && ok "меню: привилегированного сокета нет в окружении" || bad "меню" "$(cat "$OUT/menu.txt")"
grep -Eq "Seccomp:[[:space:]]+2" "$OUT/menu.txt" && ok "меню: seccomp" || bad "меню" "$(tail -n 1 "$OUT/menu.txt")"
key -k d; sleep 0.8
pgrep -f "refursline run" >/dev/null && bad "лаунчер" "второй Super+D не закрыл" || ok "второй Super+D закрывает лаунчер"
key -k c; sleep 1; shot 09-calendar
pgrep -f "refursline cal" >/dev/null && ok "Super+C: календарь" || bad календарь "не открылся"
pkill -f "refursline cal"
key -k Escape; sleep 1; shot 10-power
pgrep -f "refursline power" >/dev/null && ok "Super+Escape: питание" || bad питание "не открылось"
pkill -f "refursline power"
key -k n; sleep 1.2; shot 11a-wifi
pgrep -f "refursline wifi" >/dev/null && ok "Super+N: Wi‑Fi (без iwd — сообщение, не падение)" || bad wifi "меню упало: $(tail -n 2 "$OUT/wm.log" | tr '\n' ' ')"
pkill -f "refursline wifi"
key -k b; sleep 1.2; shot 11b-bt
pgrep -f "refursline bt" >/dev/null && ok "Super+B: Bluetooth (без bluetoothd — сообщение, не падение)" || bad bt "меню упало: $(tail -n 2 "$OUT/wm.log" | tr '\n' ' ')"
pkill -f "refursline bt"
key -k p; sleep 1; shot 11-wall-menu
pgrep -f "refursline wall" >/dev/null && ok "Super+P: обои" || bad обои "меню не открылось"
pkill -f "refursline wall"

# клики по бару (панель с отступом 10 px): стол 2, назад на 1, ПКМ по значку обоев → случайные обои
cp "$OUT/06-light.png" /tmp/home/Pictures/wallpapers/light.png
pointer 101 22; wlrctl pointer click left; sleep 0.5; shot 12-click-ws2
pointer 78 22; wlrctl pointer click left; sleep 0.3
key -k q; sleep 0.6
pointer 1222 22; wlrctl pointer click right; sleep 2; shot 13-wallpaper
[ "$(cat /tmp/home/.cache/refursline/wallpaper)" = light.png ] && ok "ПКМ по обоям: выбраны случайные (light.png)" || bad обои "файл состояния: $(cat /tmp/home/.cache/refursline/wallpaper)"
measure bar-wall "$BARP" >"$OUT/bar-wall.txt"
ok "бар с обоями: $(head -n 1 "$OUT/bar-wall.txt")"

# бар не из RefursWM (без WAYLAND_SOCKET) не запускается
XDG_RUNTIME_DIR=$(mktemp -d) /usr/local/bin/refursline >"$OUT/bar-shell.txt" 2>&1
grep -q "WAYLAND_SOCKET" "$OUT/bar-shell.txt" && ok "бар из шелла: отказ" || bad "бар из шелла" "$(cat "$OUT/bar-shell.txt")"
# второй экземпляр выходит сам
/usr/local/bin/refursline >"$OUT/bar-second.txt" 2>&1
grep -q "уже запущен" "$OUT/bar-second.txt" && ok "второй экземпляр выходит" || bad "второй экземпляр" "$(cat "$OUT/bar-second.txt")"

pkill -x foot
kill $WMP; wait $WMP
grep "refursline" "$OUT/wm.log" >>"$R"
echo "failures: $fails" | tee -a "$R"
exit "$fails"
