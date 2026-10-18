#!/bin/sh
# The thor policy inside libxbps: an end-to-end test on the real xbps (docs/18).
#   sh tests/thor/policy_test.sh THOR_DESTDIR
# Only in a throwaway Void container: installs test packages into the container root,
# writes to /etc/thor, /etc/sysctl.d, /etc/udev. Needs libcap-progs (setcap/getcap).
set -eu
d=${1:?"DESTDIR of the thor build"}
export LD_LIBRARY_PATH=$d/usr/lib
X=$d/usr/bin
w=$(mktemp -d)
fail=0
okk() { echo "ok $*"; }
bad() { echo "FAIL $*"; fail=1; }
check() { if eval "$2"; then okk "$1"; else bad "$1"; fi; }

# --- test packages
mk() { # mk NAME FILES_DIR [xbps-create options]
	name=$1 dir=$2; shift 2
	"$X/xbps-create" -A noarch -n "$name-1.0_1" -s "thor test" "$@" "$dir" >/dev/null
	mv "$name-1.0_1.noarch.xbps" "$w/repo/"
}
mkdir -p "$w/repo"
cd "$w"

p=$w/p-suid
mkdir -p "$p/usr/bin"
printf '#!/bin/sh\n' > "$p/usr/bin/t-suid"; chmod 4755 "$p/usr/bin/t-suid"
printf '#!/bin/sh\n' > "$p/usr/bin/t-sgid"; chmod 2755 "$p/usr/bin/t-sgid"
printf '#!/bin/sh\n' > "$p/usr/bin/t-keep"; chmod 4755 "$p/usr/bin/t-keep"
printf '#!/bin/sh\n' > "$p/usr/bin/t-script"; chmod 0755 "$p/usr/bin/t-script"
printf '#!/bin/sh\n' > "$p/usr/bin/t-cap"; chmod 0755 "$p/usr/bin/t-cap"
printf '#!/bin/sh\n' > "$p/usr/bin/nanoklogd"; chmod 0755 "$p/usr/bin/nanoklogd"
# the INSTALL script restores SUID and sets a capability: the post-configure pass strips them
# (xbps passes the action in $1; the marker proves the script really ran)
cat > "$p/INSTALL" <<'EOF'
case "$1" in post) chmod u+s usr/bin/t-script; setcap cap_net_raw+ep usr/bin/t-cap; setcap cap_syslog=ep usr/bin/nanoklogd; : > /tmp/t-install-ran ;; esac
EOF
mk t-suid "$p"

p=$w/p-hooks
mkdir -p "$p/etc/kernel.d/post-install" "$p/etc/profile.d" "$p/usr/lib/dracut/modules.d/99evil" \
	"$p/usr/lib/sysctl.d" "$p/usr/lib/udev/rules.d" "$p/etc/udev/rules.d" "$p/etc/sv/t-svc" "$p/usr/bin"
echo 'echo evil' > "$p/etc/kernel.d/post-install/50-evil"; chmod 0755 "$p/etc/kernel.d/post-install/50-evil"
echo 'echo evil' > "$p/etc/profile.d/evil.sh"
echo 'echo evil' > "$p/usr/lib/dracut/modules.d/99evil/module-setup.sh"
echo 'kernel.kptr_restrict = 0' > "$p/usr/lib/sysctl.d/99-evil.conf"
echo 'KERNEL=="evil", MODE="0666"' > "$p/usr/lib/udev/rules.d/99-evil.rules"
echo 'KERNEL=="evil2", MODE:="0777"' > "$p/etc/udev/rules.d/98-evil.rules"
echo 'KERNEL=="fine", GROUP="video", MODE="0660"' > "$p/usr/lib/udev/rules.d/60-fine.rules"
printf '#!/bin/sh\nexec sleep 1\n' > "$p/etc/sv/t-svc/run"; chmod 0755 "$p/etc/sv/t-svc/run"
echo x > "$p/usr/bin/t-ok"
mk t-hooks "$p"

p=$w/p-learn
mkdir -p "$p/etc/kernel.d/post-install" "$p/usr/lib/dracut/modules.d/90base" "$p/usr/lib/udev/rules.d"
echo 'echo base' > "$p/etc/kernel.d/post-install/20-base"
echo 'echo base' > "$p/usr/lib/dracut/modules.d/90base/module-setup.sh"
echo 'KERNEL=="null", MODE="0666"' > "$p/usr/lib/udev/rules.d/50-base.rules"
mk t-learn "$p"

p=$w/p-deny
mkdir -p "$p/usr/share/doc/polkit"
echo x > "$p/usr/share/doc/polkit/x"
mk polkit "$p"
p=$w/p-dep
mkdir -p "$p/usr/share/doc/t-dep"
echo x > "$p/usr/share/doc/t-dep/x"
mk t-dep "$p" -D "polkit>=0"

"$X/xbps-rindex" -a "$w"/repo/*.xbps >/dev/null 2>&1
inst() { "$X/xbps-install" -R "$w/repo" -y "$@"; }

mkdir -p /etc/thor
rm -f /etc/thor/* /var/log/thor.log

echo "== learn mode: the base system"
echo "mode=learn" > /etc/thor/policy.conf
inst t-learn > "$w/learn.log" 2>&1 || { cat "$w/learn.log"; bad "install in learn mode"; }
check "learn: kernel hook extracted" '[ -f /etc/kernel.d/post-install/20-base ]'
check "learn: dracut module extracted" '[ -f /usr/lib/dracut/modules.d/90base/module-setup.sh ]'
check "learn: hook in the baseline" 'grep -qx /etc/kernel.d/post-install/20-base /etc/thor/baseline'
check "learn: dracut module in the baseline (as a directory)" 'grep -qx /usr/lib/dracut/modules.d/90base/ /etc/thor/baseline'
check "learn: udev 0666 rule in the baseline" 'grep -qx /usr/lib/udev/rules.d/50-base.rules /etc/thor/baseline'
check "learn: base udev rule not masked" '[ ! -e /etc/udev/rules.d/50-base.rules ]'

echo "== enforce mode"
echo "mode=enforce" > /etc/thor/policy.conf
echo "/usr/bin/t-keep" > /etc/thor/keep.conf
inst t-suid t-hooks > "$w/enforce.log" 2>&1 || { cat "$w/enforce.log"; bad "install in enforce mode"; }
check "SUID stripped on unpack" '[ -f /usr/bin/t-suid ] && [ ! -u /usr/bin/t-suid ] && [ -x /usr/bin/t-suid ]'
check "SGID stripped on unpack" '[ ! -g /usr/bin/t-sgid ]'
check "keep.conf: SUID kept" '[ -u /usr/bin/t-keep ]'
check "INSTALL script ran (otherwise the checks below are empty)" '[ -e /tmp/t-install-ran ]'
check "SUID set by the INSTALL script stripped" '[ ! -u /usr/bin/t-script ] && grep -q "SUID/SGID stripped: /usr/bin/t-script (set by the package script)" /var/log/thor.log'
check "capability set by the INSTALL script stripped" '[ -z "$(getcap /usr/bin/t-cap)" ] && grep -q "capabilities stripped: /usr/bin/t-cap" /var/log/thor.log'
check "cap_syslog of nanoklogd (socklog) kept" 'getcap /usr/bin/nanoklogd | grep -q cap_syslog'
check "kernel hook not extracted" '[ ! -e /etc/kernel.d/post-install/50-evil ]'
check "profile.d not extracted" '[ ! -e /etc/profile.d/evil.sh ]'
check "dracut module not extracted" '[ ! -e /usr/lib/dracut/modules.d/99evil/module-setup.sh ]'
check "sysctl.d masked" 'grep -q "thor" /etc/sysctl.d/99-evil.conf'
check "udev 0666 in /usr/lib masked" 'grep -q "thor" /etc/udev/rules.d/99-evil.rules'
check "udev 0777 in /etc removed" '[ ! -e /etc/udev/rules.d/98-evil.rules ]'
check "ordinary udev rule untouched" '[ -f /usr/lib/udev/rules.d/60-fine.rules ] && [ ! -e /etc/udev/rules.d/60-fine.rules ]'
check "ordinary file extracted" '[ -f /usr/bin/t-ok ]'
check "runit service reported" 'grep -q "runit service t-svc" "$w/enforce.log"'
check "log /var/log/thor.log" 'grep -q "SUID/SGID stripped: /usr/bin/t-suid" /var/log/thor.log'

echo "== an update does not restore SUID (the file is already on disk, the hash matches)"
inst -f t-suid > "$w/reinst.log" 2>&1 || { cat "$w/reinst.log"; bad "reinstall"; }
check "reinstall: SUID did not come back" '[ ! -u /usr/bin/t-suid ]'

echo "== a real update: same file, xbps does not unpack but chmods to the package mode"
cd "$w/p-suid" && "$X/xbps-create" -A noarch -n "t-suid-1.1_1" -s "thor test" . >/dev/null && mv t-suid-1.1_1.noarch.xbps "$w/repo/" && cd "$w"
"$X/xbps-rindex" -a "$w"/repo/t-suid-1.1_1.noarch.xbps >/dev/null 2>&1
inst -u t-suid > "$w/upd.log" 2>&1 || { cat "$w/upd.log"; bad "update"; }
check "update went through" '"$X/xbps-query" -p pkgver t-suid | grep -q 1.1_1'
check "update: SUID did not come back" '[ ! -u /usr/bin/t-suid ] && [ ! -g /usr/bin/t-sgid ]'
check "update: keep.conf SUID still there" '[ -u /usr/bin/t-keep ]'

echo "== deny list"
if inst polkit > "$w/deny.log" 2>&1; then bad "polkit got installed"; else okk "polkit not installed"; fi
check "reason in the output" 'grep -q "polkit-1.0_1 denied: SUID pkexec" "$w/deny.log"'
if inst t-dep > "$w/dep.log" 2>&1; then bad "the polkit dependency got installed"; else okk "a dependency on the deny list is denied too"; fi
check "checked with -n (dry run)" '! "$X/xbps-install" -R "$w/repo" -n t-dep >/dev/null 2>&1'
echo polkit > /etc/thor/allow.conf
if inst t-dep > "$w/allow.log" 2>&1; then okk "allow.conf: allowed"; else cat "$w/allow.log"; bad "allow.conf had no effect"; fi

[ "$fail" = 0 ] && echo "ok all policy checks" || { echo "--- enforce.log"; cat "$w/enforce.log"; exit 1; }
