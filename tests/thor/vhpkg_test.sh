#!/bin/sh
# vh-pkg (Zig) on a system with thor: a wrapper over thor install/keep, --ignore, the config ledger.
#   sh tests/thor/vhpkg_test.sh PATH_TO_VH-PKG
# Runs after package_test.sh in the same container (thor has already replaced xbps).
set -eu
P=${1:?"vh-pkg"}
w=$(mktemp -d)
fail=0
okk() { echo "ok $*"; }
bad() { echo "FAIL $*"; fail=1; }
check() { if eval "$2"; then okk "$1"; else bad "$1"; fi; }
rm -f /etc/thor/allow.conf

check "add: installs through thor" '"$P" add -y tree > "$w/add.log" 2>&1 && xbps-query tree >/dev/null'
check "add without -y: the answer comes from stdin" 'thor remove -y tree > /dev/null 2>&1; printf "y\n" | "$P" add tree > "$w/add-ask.log" 2>&1 && xbps-query tree >/dev/null'
check "add: a denied package is refused with a reason" '! "$P" add -y polkit > "$w/deny.log" 2>&1 && grep -q "polkit.*denied" "$w/deny.log"'
check "add --ignore: ignorepkg recorded" '"$P" add -y tree --ignore gcc > /dev/null 2>&1; grep -qx "ignorepkg=gcc" /etc/xbps.d/51-vh-pkg-ignore.conf'
check "add --keep: a thor policy exception" '"$P" add -y tree --keep /usr/bin/t-keep > /dev/null 2>&1; grep -qx /usr/bin/t-keep /etc/thor/keep.conf'
check "scan: no error" '"$P" scan tree > "$w/scan.log" 2>&1 && grep -q "thor" "$w/scan.log"'
"$P" add -y chrony > /dev/null 2>&1
echo "# changed" >> /etc/chrony.conf
check "rm: removes" '"$P" rm chrony > /dev/null 2>&1 && ! xbps-query chrony >/dev/null 2>&1'
check "rm: a changed config goes to the ledger for vh-deep-clean" 'grep -qx /etc/chrony.conf /var/lib/vh/removed-conf.list'
check "unknown command exits with 2" '"$P" xyz >/dev/null 2>&1; [ $? = 2 ]'

[ "$fail" = 0 ] && echo "ok all vh-pkg checks" || exit 1
