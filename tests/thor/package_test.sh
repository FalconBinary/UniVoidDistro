#!/bin/sh
# The thor package replaces xbps and libxbps on a real Void system (docs/18).
#   sh tests/thor/package_test.sh THOR_DESTDIR
# Only in a throwaway Void container: installs thor in place of the stock xbps.
set -eu
d=${1:?"DESTDIR of the thor build"}
repo_src=$(cd "$(dirname "$0")/../.." && pwd)
w=$(mktemp -d)
fail=0
okk() { echo "ok $*"; }
bad() { echo "FAIL $*"; fail=1; }
check() { if eval "$2"; then okk "$1"; else bad "$1"; fi; }
arch=$(xbps-uhelper arch)

# without the ACLs and xattrs of the source directory (a host volume in docker)
cp -R "$d" "$w/dest"
check "rpath: xbps-install takes libxbps from its own tree" \
	'env -u LD_LIBRARY_PATH ldd "$w/dest/usr/bin/xbps-install" | grep -q "$w/dest/usr/bin/../lib/libxbps.so.6\|$w/dest/usr/lib/libxbps.so.6"'
check "rpath: thor too" 'ldd "$w/dest/usr/bin/thor" | grep -q "$w/dest/usr/bin/../lib/libxbps.so.6\|$w/dest/usr/lib/libxbps.so.6"'
sh "$repo_src/thor/package.sh" "$w/dest" "$arch" /var/lib/thor/repo >/dev/null
echo "repository=/var/lib/thor/repo" > /etc/xbps.d/01-thor.conf
printf 'ignorepkg=xbps\nignorepkg=libxbps\n' > /etc/xbps.d/20-vh-ignorepkg.conf
mkdir -p /etc/thor; echo mode=enforce > /etc/thor/policy.conf
xbps-install -S >/dev/null 2>&1

echo "== installing thor with the stock xbps"
xbps-install -y thor > "$w/inst.log" 2>&1 || { cat "$w/inst.log"; bad "install thor"; }
check "thor installed" 'xbps-query -p pkgver thor | grep -q "^thor-"'
check "xbps removed from the pkgdb" '! xbps-query -p pkgver xbps 2>/dev/null | grep -q "^xbps-"'
check "libxbps removed from the pkgdb" '! xbps-query -p pkgver libxbps 2>/dev/null | grep -q "^libxbps-"'
check "/usr/bin/xbps-install belongs to thor" '[ "$(xbps-query -o /usr/bin/xbps-install | cut -d: -f1)" = "$(xbps-query -p pkgver thor)" ]'
check "/usr/bin/thor works" 'thor --version | grep -q "^thor "'
check "Void key in place" '[ -f "/var/db/xbps/keys/60:ae:0c:d6:f0:95:17:80:bc:93:46:7a:89:af:a3:2d.plist" ]'
check "libxbps carries the policy" 'grep -q thor_unpack_entry /usr/lib/libxbps.so.6'

echo "== a system with thor"
check "xbps-install -Su: no update loop of xbps itself" 'xbps-install -Sun > "$w/u.log" 2>&1; ! grep -q "^xbps-[0-9]" "$w/u.log"'
check "xbps-install xbps does not replace thor (xbps is a virtual package of thor)" 'xbps-install -y xbps >/dev/null 2>&1; xbps-query -p pkgver thor | grep -q "^thor-" && ! xbps-query -p pkgver xbps | grep -q "^xbps-"'
check "a dependency on xbps is satisfied by thor (virtual)" 'xbps-query -p provides thor | grep -q "^xbps-"'
check "xbps-pkgdb thor: package files intact" 'xbps-pkgdb thor > "$w/pkgdb.log" 2>&1 || { cat "$w/pkgdb.log"; false; }'
check "thor install: a package from the official repository" 'thor install -y tree > "$w/tree.log" 2>&1 && xbps-query tree >/dev/null'
check "thor remove" 'thor remove -y tree > /dev/null 2>&1 && ! xbps-query tree >/dev/null 2>&1'
# without -y, xbps-install's "Do you want to continue? [Y/n]" reads stdin: thor must leave it to
# the xbps-install it execs (a zeroed xbps handle once made xbps_end close descriptor 0)
check "thor install without -y: y on stdin installs" 'printf "y\n" | thor install tree > "$w/yes.log" 2>&1 && xbps-query tree >/dev/null'
check "thor install without -y: n on stdin aborts, nothing installed" 'thor remove -y tree > /dev/null 2>&1; printf "n\n" | thor install tree > "$w/no.log" 2>&1; grep -q "Aborting" "$w/no.log" && ! xbps-query tree >/dev/null 2>&1'
check "deny list: fuse3 is not installed without an allow" '! thor install -y fuse3 > "$w/deny.log" 2>&1 && grep -q "fuse3.*denied" "$w/deny.log"'
echo fuse3 > /etc/thor/allow.conf
check "SUID stripped from official packages too (fusermount3)" 'thor install -y fuse3 > "$w/fuse.log" 2>&1; [ -f /usr/bin/fusermount3 ] && [ ! -u /usr/bin/fusermount3 ] && grep -q "SUID/SGID stripped: /usr/bin/fusermount3" "$w/fuse.log"'

[ "$fail" = 0 ] && echo "ok all thor package checks" || exit 1
