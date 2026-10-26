#!/bin/sh
# The SELinux policy (selinux/): compiled by secilc (every neverallow of
# selinux/policy/90-neverallow.cil checked at compile time), then read back with setools in the
# same Fedora container: the invariants of docs/uni/selinux.md that a neverallow cannot say,
# the domains and their entry points, the file contexts against vh-selabel's subset.
#   sh tests/selinux/run.sh
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=$repo/build/selinux
rm -rf "$out"
mkdir -p "$out"
img=${VH_SELINUX_IMAGE:-registry.fedoraproject.org/fedora:42}
fails=0
ok()  { echo "ok $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
echo "== compile (secilc), then the checks (seinfo, sesearch) in $img"
docker run --rm -v "$repo/selinux:/s:ro" -v "$repo/tests/selinux:/t:ro" -v "$out:/out" "$img" sh -c '
	set -e
	dnf -q install -y secilc setools-console python3 >/dev/null 2>&1 || dnf -q install -y secilc setools-console python3
	secilc -c 33 -O -o /out/policy.33 -f /out/file_contexts /s/policy/*.cil
	echo "compiled: $(stat -c %s /out/policy.33) bytes, $(grep -c . /out/file_contexts) file contexts"
	python3 -I /t/checks.py /out/policy.33 /out/file_contexts
	chown -R '"$(id -u):$(id -g)"' /out' > "$out/log" 2>&1 && ok "compiled and checked ($(grep -c '^ok' "$out/log") checks)" || { bad "compile or checks: see $out/log"; tail -40 "$out/log"; }
grep '^FAIL' "$out/log" | sed 's/^/   /' || true
n=$(grep -c '^FAIL' "$out/log" || true)
[ "$n" = 0 ] || fails=$((fails + n))
[ "$fails" = 0 ] && echo "== selinux: PASS" || { echo "== selinux: FAIL"; exit 1; }
