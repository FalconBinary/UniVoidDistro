# shellcheck shell=bash
# The gaming session's sound, from inside (tests/vm/steps/session.py feeds this file to
# `vh-game-enter -c 'bash -s'` on the VM rig, whose QEMU has a sound card): the session's own
# PipeWire has the card's sink and no microphone, and sound goes out through its pulse server
# (Proton, Wine, Steam) and through PipeWire's own protocol (SDL). The root has bash, coreutils
# and PipeWire's tools, no grep or sed.
for _ in $(seq 1 50); do
	s=$(pactl list short sinks 2>/dev/null)
	[[ $s == *alsa_output* ]] && break
	sleep 0.2
done
echo "SINKS=$(pactl list short sinks | cut -f2 | tr '\n' ' ')"
echo "SOURCES=$(pactl list short sources | cut -f2 | tr '\n' ' ')"
# WirePlumber starts a new sink at 0.4 of its volume (about 6 % of the amplitude): full volume,
# so that what comes out is unmistakable (the state stays in the home, which remove takes away)
pactl set-sink-volume @DEFAULT_SINK@ 100%
echo "VOLUME=$(pactl get-sink-volume @DEFAULT_SINK@ | head -1)"
# 5 s of noise at full scale each way: QEMU's WAV file on the host shows whether it came out
head -c 960000 /dev/urandom | pacat --raw --format=s16le --rate=48000 --channels=2 && echo PULSE_PLAYED
head -c 960000 /dev/urandom | pw-cat --playback --raw --format s16 --rate 48000 --channels 2 - && echo NATIVE_PLAYED
echo "LOG=$(head -c 600 "$XDG_RUNTIME_DIR/vh-sound.log" | tr '\n' ' ')"
