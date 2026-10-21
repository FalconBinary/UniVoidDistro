# shellcheck shell=sh
# vh-audit: the gaming session (vh-game, docs/uni/game.md), when it is installed. Sourced by vh-audit.
# Without it there is nothing of it: no user game, no root, no login on tty3.
groot=/var/lib/vh/roots/game
if ! getent passwd game >/dev/null 2>&1 && [ ! -d "$groot" ]; then
	return 0
fi
sec "Gaming session"
gl=$(getent passwd game)
case $gl in
	*":/home/game:/usr/local/bin/vh-game-enter") ok "game: home /home/game, login shell vh-game-enter" ;;
	*) bad "game: $gl (expected the home /home/game and the shell /usr/local/bin/vh-game-enter)" ;;
esac
for g in wheel input video audio kvm netdev; do
	id -nG game 2>/dev/null | tr ' ' '\n' | grep -qx "$g" && bad "game is in group $g"
done
ok "game's groups: $(id -nG game 2>/dev/null)"
case $(getent shadow game | cut -d: -f2) in
	'$y$'*) ok "game: yescrypt password" ;;
	*) bad "game: the password is not yescrypt" ;;
esac
[ "$(grep -c '^+ : game : ' /etc/security/access.conf)" = 1 ] && grep -qx '+ : game : tty3' /etc/security/access.conf \
	&& ok "pam_access: game on tty3 only" || bad "pam_access: game is not on tty3 alone ($(grep ' game ' /etc/security/access.conf | paste -sd' ' -))"
[ -L /etc/runit/runsvdir/default/agetty-tty3 ] && unk "tty3 has a getty at every boot (a link in runsvdir); vh-game tty on starts it until the next boot only"
if [ -d "$groot" ]; then
	chk "$groot" "$(stat -c '%a %U %G' "$groot")" "750 root game"
	chk "the gaming root's thor policy" "$(sed -n 's/^mode=//p' "$groot/etc/thor/policy.conf" 2>/dev/null)" enforce
	suid=$(find "$groot" -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | head -5 | paste -sd' ' -)
	[ -z "$suid" ] && ok "no SUID/SGID file in the gaming root" || bad "SUID/SGID in the gaming root: $suid"
	caps=$(getcap -r "$groot" 2>/dev/null | head -5 | paste -sd' ' -)
	[ -z "$caps" ] && ok "no file capability in the gaming root" || bad "file capabilities in the gaming root: $caps"
else
	bad "the user game exists but not its root $groot (doas vh-game remove, then install)"
fi
# game passes /var/lib/vh by its own ACL entry; the system's state there is nobody else's
getfacl -p /var/lib/vh 2>/dev/null | grep -qx 'user:game:--x' && ok "/var/lib/vh: game passes by its ACL" \
	|| bad "/var/lib/vh: no ACL entry for game (vh-game-enter cannot reach the root)"
[ "$(( 0$(stat -c %a /var/lib/vh) & 1 ))" = 1 ] && unk "/var/lib/vh: every user may pass (mode $(stat -c %a /var/lib/vh)); game needs only its ACL entry" \
	|| ok "/var/lib/vh: no other user passes"
for m in /var/lib/vh/roots /home/game; do
	case ",$(findmnt -no OPTIONS "$m" 2>/dev/null)," in
		*,nosuid,*) case ",$(findmnt -no OPTIONS "$m")," in *,nodev,*) ok "$m: nosuid, nodev" ;; *) bad "$m: no nodev" ;; esac ;;
		*) bad "$m: not a mount with nosuid ($(findmnt -no OPTIONS "$m" 2>/dev/null))" ;;
	esac
	# games run from the home and the root: a bind mount keeps noexec of /home unless fstab says exec
	case ",$(findmnt -no OPTIONS "$m" 2>/dev/null)," in
		*,noexec,*) bad "$m: noexec, no game runs from it (its fstab line needs exec: doas vh-game remove, then install)" ;;
	esac
done
# the session's devices: game opens the render nodes and seatd's socket, never input
for d in /dev/input/event*; do
	[ -e "$d" ] || continue
	[ "$(stat -c %G "$d")" = game ] && bad "$d belongs to group game"
done
ok "no input device of group game"
# sound: the session's own PipeWire plays through the cards' playback and control nodes, which
# game gets by an ACL entry each (vh-game's udev rule); never a capture node (the microphone),
# hwdep, the sequencer or the timer
[ -f /etc/udev/rules.d/99-vh-game.rules ] && ok "the session's sound: the udev rule of game's playback nodes" \
	|| bad "no /etc/udev/rules.d/99-vh-game.rules: the gaming session has no sound (doas vh-game remove, then install)"
other=""
for d in /dev/snd/*; do
	[ -c "$d" ] || continue
	getfacl -p "$d" 2>/dev/null | grep -q '^user:game:' || continue
	case ${d##*/} in
		controlC[0-9]*|pcmC[0-9]*D[0-9]*p) ;;
		*) other="$other ${d##*/}" ;;
	esac
done
[ -z "$other" ] && ok "game reaches no capture, hwdep, sequencer or timer node" || bad "game has an ACL entry on:$other"
# the gaming boot (vh-game boot on, G3): ia32 for the gaming session alone. Its stage 1 binds
# vh-game's marker over /etc/runit/2; its stage 2 starts tty3's login outside the x86_64
# filter and puts everything else under it (sbctl verify above covers the twin UKI's signature)
if [ -e /etc/vh/game-boot ]; then
	[ -f /etc/runit/core-services/98-vh-game.sh ] && ok "the gaming boot is on: the last entry of Limine's menu (doas vh-game play)" \
		|| bad "the gaming boot: /etc/vh/game-boot without its stage-1 script (doas vh-game boot on)"
	case " $(cat /proc/cmdline) " in
		*" ia32_emulation=1 "*)
			mountpoint -q /etc/runit/2 && bad "the gaming boot: /etc/runit/2 is still bound over (vh-game stage2 did not run)"
			p=$(pgrep -x runsvdir | head -1)
			chk "the gaming boot: runsvdir's seccomp mode (the x86_64 filter)" "$(sed -n 's/^Seccomp:[[:space:]]*//p' "/proc/$p/status" 2>/dev/null)" 2
			chk "the gaming boot: this shell's seccomp mode (the x86_64 filter)" "$(sed -n 's/^Seccomp:[[:space:]]*//p' /proc/self/status)" 2
			;;
		*) ok "this boot is an everyday one: ia32 off" ;;
	esac
elif [ -e /etc/runit/core-services/98-vh-game.sh ]; then
	bad "the stage-1 script of the gaming boot is there without its marker (doas vh-game boot off)"
fi
unset groot gl suid caps m d g other p
