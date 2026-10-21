#!/bin/bash
# The gaming session end to end, as root in a throwaway privileged Void container whose own root
# plays the installed system (tests/session/run.sh starts it):
#   1. the system as the installer leaves it, as far as vh-game reads it: the groups _seatd and
#      render, access.conf, /etc/shells, fstab, the getty of tty3, the programs, udev's rules
#      directory, and a sound card's nodes as udev makes them (a container has no card);
#   2. a snapshot: every file under / (type, mode, owner, size, link target, sha256);
#   3. vh-game install, with a stand-in for thor (xbps-install with thor's arguments; the
#      packages cut to base-files, bash and coreutils unless VH_TEST_FULL=1) and a plan.env;
#   4. the session as game, without privileges: vh-game-enter --check and -c;
#   5. vh-game boot on and off (G3) with a stand-in for vh-limine-update (a container has no
#      ESP): the marker, the stage-1 script, stage 1 in a boot that is not the gaming one;
#   6. vh-game remove (the gaming boot on: remove turns it off), and the snapshot again: the
#      same, byte for byte.
#   bash tests/session/e2e.sh /src
set -u
src=${1:?"the repository copy"}
fails=0
ok() { echo "ok $1"; }
bad() { echo "FAIL $1${2:+: $2}"; fails=$((fails + 1)); }

case $(xbps-uhelper arch) in x86_64) repo=https://repo-default.voidlinux.org/current ;; *) repo=https://repo-default.voidlinux.org/current/aarch64 ;; esac

echo "== the system before the gaming session"
for g in _seatd render; do getent group "$g" >/dev/null || groupadd -r "$g"; done
id user >/dev/null 2>&1 || useradd -m -G _seatd,render user
install -d -m 0755 /etc/security /etc/xbps.d /usr/local/bin /usr/local/sbin
sed -e 's/@VH_USER@/user/' -e 's/@VH_ADMIN@/admin/' "$src/rootfs/etc/security/access.conf.in" > /etc/security/access.conf
[ -e /etc/fstab ] || : > /etc/fstab
[ -e /etc/shells ] || printf '/bin/sh\n/bin/bash\n' > /etc/shells
printf 'repository=%s\n' "$repo" > /etc/xbps.d/00-repository-main.conf
install -m 0755 "$src/build/st/bin/vh-game-enter" /usr/local/bin/
install -m 0755 "$src/build/st/bin/vh-game" "$src/build/st/bin/vh-root" /usr/local/sbin/
[ -d /etc/sv/agetty-tty3 ] || mkdir -p /etc/sv/agetty-tty3
mkdir -p /etc/udev/rules.d
# runit-void's stage 2 and core-services, and the system's /etc/vh, which the gaming boot needs
# (the image may lack runit)
install -d -m 0755 /etc/vh
[ -d /etc/runit/core-services ] || mkdir -p /etc/runit/core-services
[ -e /etc/runit/2 ] || { printf '#!/bin/sh\nexec runsvdir -P /run/runit/runsvdir/current\n' > /etc/runit/2; chmod 0755 /etc/runit/2; }
# a sound card's nodes as udev makes them, root:audio 0660: its control node, a playback and a
# capture PCM, its codec's hwdep, the timer and the sequencer
getent group audio >/dev/null || groupadd -r audio
mkdir -p /dev/snd
for n in controlC0:0 pcmC0D0p:16 pcmC0D0c:24 hwC0D0:4 timer:33 seq:1; do
	# a container may have the host's timer and sequencer already, and no card
	[ -e "/dev/snd/${n%:*}" ] && continue
	mknod "/dev/snd/${n%:*}" c 116 "${n#*:}"
	chown root:audio "/dev/snd/${n%:*}"
	chmod 0660 "/dev/snd/${n%:*}"
done
# /var/lib/vh as vh-limine-update makes it, for root alone: vh-root lets game, and nobody else,
# pass through it while the root exists (an ACL), and takes that away with the removal
mkdir -p /var/lib/vh && chmod 0700 /var/lib/vh
# getfacl for the snapshots (the system has acl-progs; this image does not)
command -v getfacl >/dev/null || xbps-install -Sy acl-progs >/dev/null 2>&1 || xbps-install -Sy acl-progs
mkdir -p /tmp/stub
cat > /tmp/stub/thor <<'EOF'
#!/bin/sh
# thor's arguments (install|update -y -r ROOT [PKG...]) for xbps-install; the root's own
# xbps.d (its repository, its noextract) applies
cmd=$1; shift
[ "$1" = -y ] && shift
[ "$1" = -r ] || exit 2
root=$2; shift 2
[ "$cmd" = update ] && exec xbps-install -Syu -r "$root"
[ "${VH_TEST_FULL:-0}" = 1 ] || set -- base-files bash coreutils
exec xbps-install -Sy -r "$root" "$@"
EOF
chmod 0755 /tmp/stub/thor
# vh-limine-update's stand-in: what it was run with, and whether the gaming boot was on
cat > /tmp/stub/limine-update <<'EOF'
#!/bin/sh
[ -e /etc/vh/game-boot ] && on=on || on=off
echo "limine-update $* game=$on" >> /tmp/limine.calls
EOF
chmod 0755 /tmp/stub/limine-update
printf "# vh-plan\nVH_PLAN_GAME_PACKAGES='mesa-vulkan-lavapipe'\n" > /tmp/plan.env

snap() { # the whole system but the pseudo-file systems, the logs and this test's own files:
	# every path's type, mode, owner, size, link target, every file's sha256, every extended ACL
	set -- "$1" \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp -o -path /src \
		-o -path /var/log -o -path /var/cache -o -path /root/.cache \) -prune
	out=$1; shift
	find / -xdev "$@" -o -printf '%p\t%y\t%m\t%U\t%G\t%s\t%l\n' | LC_ALL=C sort > "$out"
	find / -xdev "$@" -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >> "$out"
	find / -xdev "$@" -o -print0 | LC_ALL=C sort -z | xargs -0 getfacl -s -p 2>/dev/null >> "$out"
}
snap /tmp/before
echo "files: $(grep -c . /tmp/before)"
cp /etc/passwd /etc/group /etc/shadow /tmp/
nft_before=$(nft list ruleset 2>/dev/null || true)

echo "== vh-game install"
hash='$y$j9T$7SZe8DiL3oMiMOkl7I0Na/$Fdu9oQ8ER1wM2ixgnXzlvaK0Ap/CIoUEB1n/6OWfl25'
if (umask 077; vh-game install --any-arch --password-hash "$hash" --plan-env /tmp/plan.env --thor /tmp/stub/thor) > /tmp/install.out 2>&1; then
	ok "install"
else
	bad "install" "$(tail -5 /tmp/install.out | tr '\n' '|')"
fi
grep -E '^VH_GAME|vh-game:|vh-root:' /tmp/install.out
uid=$(id -u game 2>/dev/null || echo none)
[ "$uid" != none ] && [ "$uid" -ge 1000 ] && ok "the user game ($uid)" || bad "the user game" "$uid"
[ "$(getent passwd game | cut -d: -f6,7)" = "/home/game:/usr/local/bin/vh-game-enter" ] && ok "its home and its login shell" || bad "home and shell" "$(getent passwd game)"
for g in _seatd render; do id -nG game | tr ' ' '\n' | grep -qx "$g" && ok "game in $g" || bad "game in $g" "$(id -nG game)"; done
for g in wheel input video audio kvm; do id -nG game | tr ' ' '\n' | grep -qx "$g" && bad "game is in $g"; done
grep -q '^game:\$y\$' /etc/shadow && ok "a yescrypt password" || bad "shadow"
grep -qx '+ : game : tty3' /etc/security/access.conf && ok "pam_access: game on tty3" || bad "access.conf"
[ "$(grep -n 'game : tty3' /etc/security/access.conf | cut -d: -f1)" -lt "$(grep -n '^- : ALL : ALL' /etc/security/access.conf | cut -d: -f1)" ] \
	&& ok "before the line that denies everyone" || bad "access.conf order"
grep -qx /usr/local/bin/vh-game-enter /etc/shells && ok "/etc/shells" || bad "/etc/shells"
for m in /home/game /var/lib/vh/roots; do
	o=$(findmnt -no OPTIONS "$m" 2>/dev/null)
	case ",$o," in *,nosuid,*nodev,*) case ",$o," in *,noexec,*) bad "$m: exec" "$o" ;; *) ok "$m: a mount of its own, nosuid, nodev, exec" ;; esac ;; *) bad "$m mount" "$o" ;; esac
	grep -q "^$m	$m	none	bind,nosuid,nodev	0 0$" /etc/fstab && ok "$m in fstab" || bad "$m in fstab"
done
root=/var/lib/vh/roots/game
[ "$(stat -c '%a %U %G' "$root")" = "750 root game" ] && ok "the root: 0750 root:game" || bad "the root's mode" "$(stat -c '%a %U %G' "$root")"
[ "$(stat -c '%a %U' /home/game)" = "700 game" ] && ok "the home: 0700 game" || bad "the home's mode" "$(stat -c '%a %U' /home/game)"
grep -qx 'mode=enforce' "$root/etc/thor/policy.conf" && grep -qx xorg-server-xwayland "$root/etc/thor/allow.conf" \
	&& ok "the root's thor policy: enforce, Xwayland allowed there" || bad "the root's thor policy"
grep -q "^game:x:$uid:$uid:" "$root/etc/passwd" && ok "game in the root's passwd" || bad "the root's passwd"
[ -d "$root/home/game" ] && ok "the home's place in the root" || bad "no $root/home/game"
# game reaches its root (and only through the search bit of /var/lib/vh)
setpriv --reuid=game --regid=game --init-groups sh -c "test -r $root/etc/passwd && test -x $root/usr/bin" \
	&& ok "game reads its root, though doas's umask is 077" || bad "game cannot read $root" "$(stat -c '%a %n' /var/lib/vh /var/lib/vh/roots "$root" "$root/etc" 2>&1 | tr '\n' '|')"
acl=$(getfacl -p /var/lib/vh 2>/dev/null)
case $acl in *"user:game:--x"*"other::---"*) ok "/var/lib/vh: game passes by its ACL, others do not" ;; *) bad "/var/lib/vh's ACL" "$(echo "$acl" | tr '\n' '|')" ;; esac
setpriv --reuid=user --regid=user --init-groups sh -c "test -x /var/lib/vh/roots" 2>/dev/null \
	&& bad "another user passes /var/lib/vh" || ok "another user does not pass /var/lib/vh"
missing=""
for d in proc sys dev run tmp var/tmp home/game bin/bash; do [ -e "$root/$d" ] || missing="$missing $d"; done
[ -z "$missing" ] && ok "the mount points vh-game-enter needs are in the root" || bad "missing in the root:$missing"
[ -z "$(ls -A "$root/var/cache/xbps" 2>/dev/null)" ] && ok "no package cache left in the root" || bad "the root's package cache"
if grep -q 'noextract=/usr/share/doc/\*' "$root/etc/xbps.d/30-vh-noextract.conf" && [ -z "$(ls -A "$root/usr/share/doc" 2>/dev/null)" ]; then
	ok "documentation not extracted"
else
	bad "noextract"
fi
vh-root list | tee /tmp/list.out
grep -q '^game	profile game' /tmp/list.out && ok "vh-root list" || bad "vh-root list"
vh-game status | tail -1 | grep -q 'installed=yes' && ok "vh-game status" || bad "vh-game status"

# the sound: the session's own server in the root, the cards' playback and control nodes for game
for f in pipewire.conf.d/10-wireplumber.conf pipewire.conf.d/20-pipewire-pulse.conf; do
	[ -L "$root/etc/pipewire/$f" ] || bad "no link $root/etc/pipewire/$f"
done
for f in pipewire/pipewire.conf.d/60-vh-game.conf pipewire/pipewire-pulse.conf.d/60-vh-game.conf wireplumber/wireplumber.conf.d/60-vh-game.conf; do
	[ -f "$root/etc/$f" ] || bad "no $root/etc/$f"
done
grep -q 'support.dbus = disabled' "$root/etc/wireplumber/wireplumber.conf.d/60-vh-game.conf" && grep -q 'module.rt = false' "$root/etc/pipewire/pipewire.conf.d/60-vh-game.conf" \
	&& ok "the root's sound server: PipeWire, its pulse server, WirePlumber for the cards alone, no realtime" || bad "the root's sound configuration"
if [ "${VH_TEST_FULL:-0}" = 1 ]; then
	[ -x "$root/usr/bin/pipewire" ] && [ -x "$root/usr/bin/wireplumber" ] && ok "pipewire and wireplumber in the root" || bad "pipewire and wireplumber in the root"
fi
grep -qF 'SUBSYSTEM=="sound", KERNEL=="controlC[0-9]*|pcmC[0-9]*D[0-9]*p", ACTION!="remove", RUN+="/usr/bin/setfacl -m u:game:rw $devnode"' /etc/udev/rules.d/99-vh-game.rules \
	&& ok "the udev rule: game's ACL entry on the playback and control nodes" || bad "the udev rule" "$(cat /etc/udev/rules.d/99-vh-game.rules 2>&1 | tail -1)"
acl_ok=1
for n in controlC0 pcmC0D0p; do getfacl -p "/dev/snd/$n" 2>/dev/null | grep -qx 'user:game:rw-' || acl_ok=0; done
for n in pcmC0D0c hwC0D0 timer seq; do getfacl -p "/dev/snd/$n" 2>/dev/null | grep -q '^user:game:' && acl_ok=0; done
[ "$acl_ok" = 1 ] && ok "game's ACL entry on the control and playback nodes now, none on capture, hwdep, timer, sequencer" \
	|| bad "the sound nodes' ACLs" "$(getfacl -s -p /dev/snd/* 2>&1 | tr '\n' '|')"
setpriv --reuid=game --regid=game --init-groups sh -c 'test -r /dev/snd/pcmC0D0p -a -w /dev/snd/pcmC0D0p -a ! -r /dev/snd/pcmC0D0c' \
	&& ok "game opens the playback node, not the capture node" || bad "game's access to the sound nodes"
grep -q '^VH_GAME installed .* sound=2$' /tmp/install.out && vh-game status | tail -1 | grep -q ' sound=2$' \
	&& ok "vh-game install and status: 2 sound nodes for game" || bad "sound in install's and status' lines" "$(grep '^VH_GAME' /tmp/install.out; vh-game status | tail -1)"
vh-game install --any-arch --password-hash "$hash" --plan-env /tmp/plan.env --thor /tmp/stub/thor > /tmp/again.out 2>&1 \
	&& bad "a second install is refused" || { grep -q 'exists already' /tmp/again.out && ok "a second install is refused" || bad "second install" "$(cat /tmp/again.out)"; }

echo "== the session (game, no privileges)"
userns_restricted=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)
if [ "$userns_restricted" = 1 ]; then
	echo "note: kernel.apparmor_restrict_unprivileged_userns=1 here: the unprivileged session is not tested (the VM rig and the workflow do)"
else
	setpriv --reuid=game --regid=game --init-groups /usr/local/bin/vh-game-enter --check > /tmp/check.out 2>&1
	cat /tmp/check.out
	# a container has no seatd and no GPU: their lines aside, every check must pass
	grep -q '^VH_GAME_ENTER ' /tmp/check.out && ! grep '^FAIL' /tmp/check.out | grep -v seatd | grep -q . \
		&& ok "vh-game-enter --check" || bad "vh-game-enter --check" "$(grep '^FAIL' /tmp/check.out | tr '\n' '|')"
	out=$(setpriv --reuid=game --regid=game --init-groups /usr/local/bin/vh-game-enter -c 'echo "$(id -un) $(hostname 2>/dev/null || cat /proc/sys/kernel/hostname) $$ $HOME"; ls /home' 2>&1)
	[ "$out" = "game game 2 /home/game
game" ] && ok "vh-game-enter -c: game, host game, PID 2, only its home" || bad "vh-game-enter -c" "$out"
	# the session's /dev/snd: the playback and control nodes as they are (116:n), every other
	# node /dev/null (1:3)
	out=$(setpriv --reuid=game --regid=game --init-groups /usr/local/bin/vh-game-enter -c 'cd /dev/snd && stat -c "%n %t:%T" * | sort | tr "\n" " "' 2>&1)
	[ "$out" = "controlC0 74:0 hwC0D0 1:3 pcmC0D0c 1:3 pcmC0D0p 74:10 seq 1:3 timer 1:3 " ] \
		&& ok "the session's sound nodes: control and playback, the microphone, hwdep, timer and sequencer /dev/null" || bad "the session's /dev/snd" "$out"
	if [ "${VH_TEST_FULL:-0}" = 1 ]; then
		# the session's own sound server: up (its pulse socket) before the program runs
		out=$(setpriv --reuid=game --regid=game --init-groups /usr/local/bin/vh-game-enter -c 'test -S "$XDG_RUNTIME_DIR/pulse/native" && echo "PULSE_UP $$"' 2>&1)
		[ "$out" = "PULSE_UP 2" ] && ok "the session's sound server: its pulse socket there before the program, which is PID 2" \
			|| bad "the session's sound server" "$(echo "$out" | tr '\n' '|')"
	fi
	# a file the session writes in its home stays; one in its /tmp does not
	setpriv --reuid=game --regid=game --init-groups /usr/local/bin/vh-game-enter -c 'echo save > ~/save; echo t > /tmp/t' >/dev/null 2>&1
	[ "$(cat /home/game/save 2>/dev/null)" = save ] && [ ! -e /tmp/t ] && ok "the home is the user's, /tmp the session's" || bad "home and /tmp"
	# nothing of the session outlives it
	sleep 1
	[ -z "$(pgrep -u game)" ] && ok "no process of game after the session" || bad "processes left" "$(pgrep -a -u game)"
fi

echo "== the gaming boot (G3)"
lu="--limine-update /tmp/stub/limine-update"
: > /tmp/limine.calls
# shellcheck disable=SC2086
(umask 077; vh-game boot on --any-arch $lu) > /tmp/boot.out 2>&1 && grep -qx 'VH_GAME boot on' /tmp/boot.out \
	&& ok "vh-game boot on" || bad "boot on" "$(tail -5 /tmp/boot.out | tr '\n' '|')"
[ "$(head -1 /etc/vh/game-boot 2>/dev/null)" = '#!/usr/local/sbin/vh-game stage2' ] && [ "$(stat -c %a /etc/vh/game-boot)" = 755 ] \
	&& ok "the marker: the stage 2 of the gaming boot, 0755" || bad "the marker" "$(ls -l /etc/vh/game-boot 2>&1; head -1 /etc/vh/game-boot 2>&1)"
grep -q '/usr/local/sbin/vh-game stage1' /etc/runit/core-services/98-vh-game.sh 2>/dev/null && [ "$(stat -c %a /etc/runit/core-services/98-vh-game.sh)" = 644 ] \
	&& ok "the stage-1 script, 0644" || bad "the stage-1 script" "$(ls -l /etc/runit/core-services 2>&1 | tr '\n' '|')"
[ "$(cat /tmp/limine.calls)" = "limine-update  game=on" ] && ok "vh-limine-update ran with the gaming boot on" || bad "vh-limine-update's run" "$(cat /tmp/limine.calls)"
vh-game status | tail -1 | grep -q ' boot=on this=everyday ' && ok "vh-game status: the gaming boot on, this boot an everyday one" || bad "status" "$(vh-game status | tail -1)"
# this container's kernel command line is no gaming boot's: stage 1 does nothing, stage 2 by hand is refused
vh-game stage1 > /tmp/stage1.out 2>&1 && [ ! -s /tmp/stage1.out ] && ! mountpoint -q /etc/runit/2 \
	&& ok "vh-game stage1 outside the gaming boot: nothing" || bad "stage1" "$(cat /tmp/stage1.out)"
vh-game stage2 > /tmp/stage2.out 2>&1 && bad "vh-game stage2 by hand runs" || { grep -q 'which runit runs' /tmp/stage2.out && ok "vh-game stage2 by hand is refused" || bad "stage2" "$(cat /tmp/stage2.out)"; }
# shellcheck disable=SC2086
vh-game boot off $lu > /tmp/off.out 2>&1 && [ ! -e /etc/vh/game-boot ] && [ ! -e /etc/runit/core-services/98-vh-game.sh ] \
	&& [ "$(tail -1 /tmp/limine.calls)" = "limine-update  game=off" ] && ok "vh-game boot off: the marker and the script gone, vh-limine-update ran" \
	|| bad "boot off" "$(tail -3 /tmp/off.out | tr '\n' '|') $(tail -1 /tmp/limine.calls)"
# shellcheck disable=SC2086
vh-game boot on --any-arch $lu > /dev/null 2>&1 || bad "boot on again"

echo "== vh-game remove"
# shellcheck disable=SC2086
(umask 077; vh-game remove --yes $lu) > /tmp/remove.out 2>&1 && ok "remove" || bad "remove" "$(tail -5 /tmp/remove.out | tr '\n' '|')"
grep -q '^VH_GAME boot off' /tmp/remove.out && [ ! -e /etc/vh/game-boot ] && ok "remove turns the gaming boot off" || bad "remove and the gaming boot" "$(grep VH_GAME /tmp/remove.out | tr '\n' '|')"
grep -E '^VH_GAME|vh-game:|vh-root:' /tmp/remove.out
snap /tmp/after
if cmp -s /tmp/before /tmp/after; then
	ok "the system after the removal is the system before the install, byte for byte ($(grep -c . /tmp/after) entries)"
else
	bad "the system differs after the removal" "$(diff /tmp/before /tmp/after | head -20 | tr '\n' '|')"
fi
cmp -s /tmp/passwd /etc/passwd && cmp -s /tmp/group /etc/group && cmp -s /tmp/shadow /etc/shadow && ok "passwd, group, shadow" || bad "passwd, group, shadow"
[ "$(nft list ruleset 2>/dev/null || true)" = "$nft_before" ] && ok "the nft ruleset" || bad "the nft ruleset"
findmnt /home/game >/dev/null || findmnt /var/lib/vh/roots >/dev/null && bad "a mount is left" || ok "no mount left"
# /dev is not in the snapshot: the sound nodes are checked here, back to their mode alone
[ -z "$(getfacl -s -p /dev/snd/* 2>/dev/null)" ] && [ "$(stat -c %a /dev/snd/* | sort -u)" = 660 ] \
	&& ok "the sound nodes: no ACL left, 0660 as udev made them" || bad "the sound nodes after the removal" "$(getfacl -s -p /dev/snd/* 2>&1 | tr '\n' '|')"
vh-game remove --yes > /tmp/remove2.out 2>&1 && ok "a second removal changes nothing" || bad "second removal" "$(cat /tmp/remove2.out)"
# shellcheck disable=SC2086
vh-game boot on --any-arch $lu > /tmp/boot2.out 2>&1 && bad "boot on without the session" || { grep -q 'not installed' /tmp/boot2.out && [ ! -e /etc/vh/game-boot ] && ok "boot on without the session is refused" || bad "boot on without the session" "$(cat /tmp/boot2.out)"; }
snap /tmp/after2
cmp -s /tmp/before /tmp/after2 && ok "still the same" || bad "the second removal changed the system"

[ "$fails" = 0 ] && echo "e2e: all checks passed" || echo "e2e: $fails check(s) failed"
exit $((fails > 0))
