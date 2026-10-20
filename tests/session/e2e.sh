#!/bin/bash
# The gaming session end to end, as root in a throwaway privileged Void container whose own root
# plays the installed system (tests/session/run.sh starts it):
#   1. the system as the installer leaves it, as far as vh-game reads it: the groups _seatd and
#      render, access.conf, /etc/shells, fstab, the getty of tty3, the programs;
#   2. a snapshot: every file under / (type, mode, owner, size, link target, sha256);
#   3. vh-game install, with a stand-in for thor (xbps-install with thor's arguments; the
#      packages cut to base-files, bash and coreutils unless VH_TEST_FULL=1) and a plan.env;
#   4. the session as game, without privileges: vh-game-enter --check and -c;
#   5. vh-game remove, and the snapshot again: the same, byte for byte.
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
# /var/lib/vh as vh-limine-update makes it, for root alone: vh-root lets game pass through it
# while the root exists, and gives it its mode back with the removal
mkdir -p /var/lib/vh && chmod 0700 /var/lib/vh
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
printf "# vh-plan\nVH_PLAN_GAME_PACKAGES='mesa-vulkan-lavapipe'\n" > /tmp/plan.env

snap() { # the whole system but the pseudo-file systems, the logs and this test's own files
	find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp -o -path /src \
		-o -path /var/log -o -path /var/cache -o -path /root/.cache \) -prune -o -printf '%p\t%y\t%m\t%U\t%G\t%s\t%l\n' | LC_ALL=C sort > "$1"
	find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp -o -path /src \
		-o -path /var/log -o -path /var/cache -o -path /root/.cache \) -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >> "$1"
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
[ "$(stat -c %a /var/lib/vh)" = 701 ] && ok "/var/lib/vh: the search bit for others while a root exists" || bad "/var/lib/vh" "$(stat -c %a /var/lib/vh)"
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
	# a file the session writes in its home stays; one in its /tmp does not
	setpriv --reuid=game --regid=game --init-groups /usr/local/bin/vh-game-enter -c 'echo save > ~/save; echo t > /tmp/t' >/dev/null 2>&1
	[ "$(cat /home/game/save 2>/dev/null)" = save ] && [ ! -e /tmp/t ] && ok "the home is the user's, /tmp the session's" || bad "home and /tmp"
	# nothing of the session outlives it
	sleep 1
	[ -z "$(pgrep -u game)" ] && ok "no process of game after the session" || bad "processes left" "$(pgrep -a -u game)"
fi

echo "== vh-game remove"
(umask 077; vh-game remove --yes) > /tmp/remove.out 2>&1 && ok "remove" || bad "remove" "$(tail -5 /tmp/remove.out | tr '\n' '|')"
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
vh-game remove --yes > /tmp/remove2.out 2>&1 && ok "a second removal changes nothing" || bad "second removal" "$(cat /tmp/remove2.out)"
snap /tmp/after2
cmp -s /tmp/before /tmp/after2 && ok "still the same" || bad "the second removal changed the system"

[ "$fails" = 0 ] && echo "e2e: all checks passed" || echo "e2e: $fails check(s) failed"
exit $((fails > 0))
