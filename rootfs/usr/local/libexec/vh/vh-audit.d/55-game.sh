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
for m in /var/lib/vh/roots /home/game; do
	case ",$(findmnt -no OPTIONS "$m" 2>/dev/null)," in
		*,nosuid,*) case ",$(findmnt -no OPTIONS "$m")," in *,nodev,*) ok "$m: nosuid, nodev" ;; *) bad "$m: no nodev" ;; esac ;;
		*) bad "$m: not a mount with nosuid ($(findmnt -no OPTIONS "$m" 2>/dev/null))" ;;
	esac
done
# the session's devices: game opens the render nodes and seatd's socket, never input or sound
for d in /dev/input/event*; do
	[ -e "$d" ] || continue
	[ "$(stat -c %G "$d")" = game ] && bad "$d belongs to group game"
done
ok "no input device of group game"
unset groot gl suid caps m d g
