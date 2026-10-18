#!/bin/sh
# The installer path in the live environment (like 10-install.sh): build-thor.sh, packages
# installed into an empty root through thor in learn mode, build-tools.sh, then enforce.
#   sh tests/thor/live_test.sh     -- in a throwaway Void container of the native architecture
#   (on a Mac that is aarch64: Zig under amd64 emulation crashes; the script logic does not
#   depend on the architecture)
# Needs the network: Zig from ziglang.org, xbps from GitHub, packages from a Void mirror.
set -eu
R=/tmp/root
A=$(xbps-uhelper arch)
case $A in x86_64) M=https://repo-default.voidlinux.org/current ;; *) M=https://repo-default.voidlinux.org/current/$A ;; esac
fail=0
okk() { echo "ok $*"; }
bad() { echo "FAIL $*"; fail=1; }
check() { if eval "$2"; then okk "$1"; else bad "$1"; fi; }
cd /src
mkdir -p "$R/var/db/xbps/keys" "$R/etc/xbps.d"
cp -a /var/db/xbps/keys/. "$R/var/db/xbps/keys/"
for f in rootfs/etc/xbps.d/*; do
	b=$(basename "$f")
	case $b in
		*.in) sed "s|@VH_MIRROR@/current|$M|" "$f" > "$R/etc/xbps.d/${b%.in}" ;;
		*) install -m 0644 "$f" "$R/etc/xbps.d/$b" ;;
	esac
done

echo "== build-thor.sh"
bash install/build-thor.sh "$R" > /tmp/bt.log 2>&1 || { tail -30 /tmp/bt.log; exit 1; }
check "thor package in the local repository" 'ls $R/var/lib/thor/repo/thor-*.xbps >/dev/null'
check "01-thor.conf" 'grep -q "^repository=/var/lib/thor/repo" $R/etc/xbps.d/01-thor.conf'
check "/var/lib/thor/repo link in the live environment" '[ -L /var/lib/thor/repo ]'
check "thor takes libxbps from its own tree (rpath)" 'ldd /tmp/vh-thor/dest/usr/bin/thor | grep -q "/tmp/vh-thor/dest/usr/bin/../lib/libxbps"'

echo "== install into an empty root (learn), like 10-install.sh"
printf 'mode=learn\n' > "$R/etc/thor/policy.conf"
/tmp/vh-thor/dest/usr/bin/thor install -y -r "$R" \
	-R $M \
	base-files thor runit-void bash coreutils opendoas socklog-void util-linux shadow dracut eudev pam linux-base \
	> /tmp/inst.log 2>&1 || { tail -40 /tmp/inst.log; exit 1; }
check "parallel download" 'grep -q "Downloading .* packages" /tmp/inst.log'
check "thor installed into the root instead of xbps" 'xbps-query -r $R -p pkgver thor | grep -q ^thor- && ! xbps-query -r $R -p pkgver xbps | grep -q ^xbps-'
check "libxbps with the policy in the root" 'grep -q thor_unpack_entry $R/usr/lib/libxbps.so.6'
check "learn: every kernel.d hook of the new root is in the baseline" '[ -n "$(cd $R && find etc/kernel.d -type f)" ] && ( for f in $(cd $R && find etc/kernel.d -type f); do grep -qx "/$f" $R/etc/thor/baseline || exit 1; done )'
check "learn: dracut modules in the baseline" 'grep -q "^/usr/lib/dracut/modules.d/" $R/etc/thor/baseline'
check "learn: eudev 0666 udev rules in the baseline, not masked" 'grep -q "^/usr/lib/udev/rules.d/" $R/etc/thor/baseline && [ ! -e $R/etc/udev/rules.d/50-udev-default.rules ]'
check "SUID: doas kept" '[ -u $R/usr/bin/doas ]'
check "SUID: stripped from the rest (no mount, passwd, su)" '! find $R/usr -xdev -perm -4000 -type f | grep -v -e /usr/bin/doas -e /usr/bin/unix_chkpwd'
check "cap_syslog of nanoklogd in place" 'getcap $R/usr/bin/nanoklogd | grep -q cap_syslog'
check "policy log" 'grep -q "SUID/SGID stripped" $R/var/log/thor.log'

echo "== build-tools.sh"
mkdir -p "$R/usr/local" "$R/root/vh/tools"
bash install/build-tools.sh "$R" > /tmp/tools.log 2>&1 || { tail -30 /tmp/tools.log; exit 1; }
check "tools in place" '[ -x $R/usr/local/bin/vh-wlfilter ] && [ -x $R/usr/local/sbin/vh-pkg ] && [ -x $R/root/vh/tools/vh-hashpw ]'
check "static (no system libraries)" 'ldd $R/usr/local/bin/vh-wlfilter 2>&1 | grep -q "statically linked\|not a dynamic"'
check "vh-seccomp --selftest" '$R/usr/local/libexec/vh/vh-seccomp --selftest | grep -q "selftest: OK"'

printf 'mode=enforce\n' > "$R/etc/thor/policy.conf"
echo "== enforce: a package with a dracut hook installed into the root; the module is not extracted"
/tmp/vh-thor/dest/usr/bin/thor install -y -r "$R" tpm2-totp > /tmp/totp.log 2>&1 || { tail -20 /tmp/totp.log; bad "tpm2-totp"; }
check "enforce: tpm2-totp dracut module not extracted" '[ ! -e $R/usr/lib/dracut/modules.d/70tpm2-totp/module-setup.sh ] && grep -q "70tpm2-totp" /tmp/totp.log'

[ "$fail" = 0 ] && echo "ok all live-environment checks" || exit 1
