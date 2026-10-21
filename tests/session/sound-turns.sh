#!/bin/bash
# The sound card is one: the everyday user's PipeWire and the gaming session's take it in turn
# (tests/vm/steps/session.py runs this as root on the VM rig, whose QEMU has a sound card).
#   1. the user's PipeWire, as the desktop starts it (without the desktop), plays 6 s;
#   2. a session started meanwhile finds the card busy and waits; it takes the card once the
#      user's PipeWire has let it go (WirePlumber closes an idle card after 5 s), and plays 8 s;
#   3. 2 s into that, the user's PipeWire tries to play and finds the card busy.
# The user's PipeWire keeps its state in a home of its own in /tmp, so that the user's real home
# stays as it was (the step compares the whole system before and after).
#   bash tests/session/sound-turns.sh [USER]
set -u
u=${1:-user}
uid=$(id -u "$u")
rt=/run/user/$uid
home=/tmp/vh-turns-home
as() { setpriv --reuid="$u" --regid="$u" --init-groups env -i HOME="$home" XDG_RUNTIME_DIR="$rt" PATH=/usr/bin:/bin "$@"; }
install -d -m 0700 -o "$u" -g "$u" "$rt" "$home"
as sh -c 'cd && exec pipewire' > /tmp/vh-user-pw.log 2>&1 &
for _ in $(seq 1 50); do [ -S "$rt/pulse/native" ] && break; sleep 0.2; done
sleep 2
echo "USER_SINKS=$(as pactl list short sinks | cut -f2 | tr '\n' ' ')"
head -c 1152000 /dev/urandom | as pacat --raw --format=s16le --rate=48000 --channels=2 &
sleep 1
(
	for _ in $(seq 1 150); do pgrep -u game -x pacat >/dev/null && break; sleep 0.2; done
	sleep 2
	head -c 192000 /dev/urandom | timeout 8 setpriv --reuid="$u" --regid="$u" --init-groups env -i HOME="$home" \
		XDG_RUNTIME_DIR="$rt" PATH=/usr/bin:/bin pacat --raw --format=s16le --rate=48000 --channels=2
	echo "USER_AGAIN_RC=$?"
) > /tmp/vh-turns.out 2>&1 &
setpriv --reuid=game --regid=game --init-groups /usr/local/bin/vh-game-enter -c 'bash -s' <<'EOF'
sleep 2
echo "BUSY=$(pactl list short sinks | cut -f2 | tr '\n' ' ')"
for i in $(seq 1 100); do
	s=$(pactl list short sinks)
	[[ $s == *alsa_output* ]] && break
	sleep 0.2
done
echo "FREE_AFTER=$((i / 5))"
echo "FREE=$(pactl list short sinks | cut -f2 | tr '\n' ' ')"
head -c 1536000 /dev/urandom | pacat --raw --format=s16le --rate=48000 --channels=2 && echo PLAYED_AFTER
EOF
wait
cat /tmp/vh-turns.out
echo "USER_BUSY_LOG=$(grep -c -i 'busy' /tmp/vh-user-pw.log)"
grep -i 'busy' /tmp/vh-user-pw.log | head -3
pkill -u "$u" -x wireplumber
pkill -u "$u" -x pipewire
sleep 1
rm -rf "$rt" "$home" /tmp/vh-user-pw.log /tmp/vh-turns.out
