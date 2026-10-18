#!/bin/sh
# The thor command: parallel download, fallback mirrors, signature checks (docs/18).
#   sh tests/thor/fetch_test.sh THOR_DESTDIR
# Only in a throwaway Void container: two HTTP mirrors (python3 -m http.server) with a
# signed test repository; installs into the container root.
set -eu
d=${1:?"DESTDIR of the thor build"}
export LD_LIBRARY_PATH=$d/usr/lib
X=$d/usr/bin
w=$(mktemp -d)
fail=0
okk() { echo "ok $*"; }
bad() { echo "FAIL $*"; fail=1; }
check() { if eval "$2"; then okk "$1"; else bad "$1"; fi; }
arch=$("$X/xbps-uhelper" arch)

command -v openssl >/dev/null || xbps-install -Sy openssl >/dev/null 2>&1

# --- signed repository: good has everything, bad has only the index (packages give 404)
mkdir -p "$w/good/current" "$w/bad/current" "$w/pk"
openssl genrsa -out "$w/key.pem" 2048 2>/dev/null
cd "$w/pk"
for i in $(seq 1 12); do
	mkdir -p "p$i/usr/share/t-pkg$i"
	head -c 300000 /dev/urandom > "p$i/usr/share/t-pkg$i/data"
	"$X/xbps-create" -A "$arch" -n "t-pkg$i-1.0_1" -s "thor test $i" "p$i" >/dev/null
done
mkdir -p evil/usr/share/t-evil; echo good > evil/usr/share/t-evil/x
"$X/xbps-create" -A "$arch" -n "t-evil-1.0_1" -s "tamper test" evil >/dev/null
mv ./*.xbps "$w/good/current/"
cd "$w/good/current"
"$X/xbps-rindex" -a ./*.xbps >/dev/null 2>&1
"$X/xbps-rindex" --sign --signedby "thor-test" --privkey "$w/key.pem" . >/dev/null 2>&1
"$X/xbps-rindex" --sign-pkg --privkey "$w/key.pem" ./*.xbps >/dev/null 2>&1
# tampering: the t-evil package is replaced with different contents, the signature is the real one
mkdir -p "$w/pk/evil2/usr/share/t-evil"; echo EVIL > "$w/pk/evil2/usr/share/t-evil/x"
(cd "$w/pk" && "$X/xbps-create" -A "$arch" -n "t-evil-1.0_1" -s "tamper test" evil2 >/dev/null && mv "t-evil-1.0_1.$arch.xbps" "$w/good/current/")
cp "$w/good/current/$arch-repodata" "$w/bad/current/"

(cd "$w/good" && exec python3 -m http.server 8001 --bind 127.0.0.1 >/dev/null 2>&1) &
(cd "$w/bad" && exec python3 -m http.server 8002 --bind 127.0.0.1 >/dev/null 2>&1) &
sleep 1

mkdir -p /etc/xbps.d /etc/thor
# same file name as in /usr/share/xbps.d, so the official repository is switched off:
# the test does not touch the network, and the container's stock xbps stays out of the transaction
echo "repository=http://127.0.0.1:8002/current" > /etc/xbps.d/00-repository-main.conf
for f in /usr/share/xbps.d/*repository*; do [ -e "$f" ] && : > "/etc/xbps.d/${f##*/}"; done
echo "repository=http://127.0.0.1:8002/current" > /etc/xbps.d/00-repository-main.conf
printf 'parallel=4\nmirror-fallback=http://127.0.0.1:8001\n' > /etc/thor/thor.conf
echo "mode=enforce" > /etc/thor/policy.conf
rm -rf /var/cache/xbps; mkdir -p /var/cache/xbps
# repository key: imported at the first sync (the question is answered with "y")
yes y | "$X/xbps-install" -S >/dev/null 2>&1 || true

pkgs=""; for i in $(seq 1 12); do pkgs="$pkgs t-pkg$i"; done

echo "== thor install: the main mirror has no packages, the fallback has them"
# shellcheck disable=SC2086
"$X/thor" install -y $pkgs > "$w/inst.log" 2>&1 || { cat "$w/inst.log"; bad "thor install"; }
check "download with 4 workers" 'grep -q "Downloading 12 packages .* workers: 4" "$w/inst.log"'
check "all 12 downloaded" '[ "$(grep -c "^  \[[0-9]*/12\] t-pkg" "$w/inst.log")" = 12 ] && ! grep -q "NOT downloaded" "$w/inst.log"'
check "all 12 installed" '[ "$("$X/xbps-query" -l | grep -c " t-pkg")" = 12 ]'
check "signatures from the cache verified by xbps" 'grep -qi "verifying\|Verifying" "$w/inst.log"'
check "files in place" '[ -s /usr/share/t-pkg7/data ]'

echo "== tampered package: xbps-install refuses"
if "$X/thor" install -y t-evil > "$w/evil.log" 2>&1; then bad "tampered package installed"; else okk "tampered package not installed"; fi
check "reason: the signature" 'grep -qi "signature" "$w/evil.log"'
check "tampered file did not appear" '[ ! -e /usr/share/t-evil/x ]'

echo "== thor fetch: download only"
"$X/xbps-remove" -Ry t-pkg1 t-pkg2 >/dev/null 2>&1
rm -f /var/cache/xbps/t-pkg1-* /var/cache/xbps/t-pkg2-*
"$X/thor" fetch -j 1 t-pkg1 t-pkg2 > "$w/fetch.log" 2>&1 || { cat "$w/fetch.log"; bad "thor fetch"; }
check "fetch: -j 1 is a single worker" 'grep -q "workers: 1" "$w/fetch.log"'
check "fetch: packages and signatures in the cache" '[ -f "/var/cache/xbps/t-pkg1-1.0_1.$arch.xbps" ] && [ -f "/var/cache/xbps/t-pkg1-1.0_1.$arch.xbps.sig2" ]'
check "fetch: not installed" '! "$X/xbps-query" t-pkg1 >/dev/null 2>&1'
"$X/thor" install -y t-pkg1 > "$w/cached.log" 2>&1 || { cat "$w/cached.log"; bad "install from the cache"; }
check "from the cache: no second download" '! grep -q "Downloading" "$w/cached.log"'

echo "== policy commands"
"$X/thor" keep /usr/bin/t-test > "$w/keep.log" 2>&1
check "keep: path recorded" 'grep -qx /usr/bin/t-test /etc/thor/keep.conf'
"$X/thor" keep /usr/bin/t-test > /dev/null 2>&1
check "keep: no duplicates" '[ "$(grep -c t-test /etc/thor/keep.conf)" = 1 ]'
echo y | "$X/thor" allow cups > "$w/allow.log" 2>&1
check "allow: with a reason and a confirmation" 'grep -q "print server" "$w/allow.log" && grep -qx cups /etc/thor/allow.conf'
echo n | "$X/thor" allow polkit > /dev/null 2>&1 || true
check "allow: declined, not recorded" '! grep -qx polkit /etc/thor/allow.conf'
"$X/thor" allow firefox > "$w/allow2.log" 2>&1
check "allow: not on the list, nothing to allow" 'grep -q "not on the deny list" "$w/allow2.log"'
"$X/thor" baseline > "$w/base.log" 2>&1 || { cat "$w/base.log"; bad "thor baseline"; }
check "baseline: written" 'grep -q "Written by thor baseline" /etc/thor/baseline'
"$X/thor" policy > "$w/policy.log" 2>&1
check "policy: shows the mode" 'grep -q "mode: enforce" "$w/policy.log"'

kill %1 %2 2>/dev/null || true
[ "$fail" = 0 ] && echo "ok all thor checks" || exit 1
