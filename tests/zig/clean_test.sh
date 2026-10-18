#!/bin/sh
# Test of vh-deep-clean on a real xbps: what is removed, what stays, the backup and restore.
#   sh tests/zig/clean_test.sh BUILD_DIR
# Only in a throwaway Void container: installs and removes packages, creates users, writes
# to /etc, /var/lib/vh, /var/cache/xbps.
set -u
b=${1:?"directory with vh-deep-clean and vh-pkg"}
dc=$b/vh-deep-clean
bad=0
ok() { echo "ok $*"; }
no() { echo "FAIL: $*"; bad=$((bad + 1)); }
t() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

# ---- garbage
xbps-install -Sy >/dev/null 2>&1
mkdir -p /etc/vh /etc/sv/real /etc/runit/runsvdir/default
printf 'VH_KERNEL="linux6.18"\nVH_BROWSER_USER="browser"\n' > /etc/vh/vh.env
# (vh-pkg rm also removes every orphan, so this comes first) a config of a package removed through vh-pkg rm (the /var/lib/vh/removed-conf.list journal)
xbps-install -y dhcpcd >/dev/null 2>&1
echo "# edit" >> /etc/dhcpcd.conf
"$b/vh-pkg" rm dhcpcd >/dev/null 2>&1
t "vh-pkg rm recorded the config in the journal" 'grep -qx /etc/dhcpcd.conf /var/lib/vh/removed-conf.list'
# an orphan with an edited config; an orphan from the keep list with a dependency; a plain orphan
xbps-install -Ay chrony tree jq >/dev/null 2>&1
echo "# edit" >> /etc/chrony.conf
printf '# keep\njq\n/etc/keep.conf.new-2.0_1\n' > /etc/vh/deep-clean.keep
# *.new-VERSION from xbps, and similar names that must not be touched
echo new > /etc/foo.conf.new-1.2_1
echo x > /etc/bar.new-notversion
echo x > /etc/vh/x.conf.new-1.0_1
echo x > /etc/keep.conf.new-2.0_1
# services: a dangling and a live link
ln -s /etc/sv/ghost /etc/runit/runsvdir/default/ghost
ln -s /etc/sv/real /etc/runit/runsvdir/default/real
# users: cache, a busy file, trash, symlink traps; root; the browser
useradd -m -u 1000 alice
mkdir -p /home/alice/.cache/a/b /home/alice/.cache/busy /home/alice/.local/share/Trash/files /home/alice/.config
head -c 300000 /dev/urandom > /home/alice/.cache/a/b/blob
echo busy > /home/alice/.cache/busy/f
echo trash > /home/alice/.local/share/Trash/files/old.txt
echo conf > /home/alice/.config/app.conf
ln -s /etc /home/alice/.cache/evil-dir
ln -s /etc/passwd /home/alice/.cache/a/evil-file
chown -R alice:alice /home/alice
setpriv --reuid=alice --regid=alice --init-groups sh -c 'exec 3</home/alice/.cache/busy/f; exec sleep 600' &
holder=$!
mkdir -p /root/.cache/r && echo r > /root/.cache/r/f
useradd -r -m -d /var/lib/vh-browser browser
mkdir -p /var/lib/vh-browser/trusted/profile/cache2/entries /var/lib/vh-browser/trusted/.cache/mozilla
echo c > /var/lib/vh-browser/trusted/profile/cache2/entries/x
echo 'user_pref("a", 1);' > /var/lib/vh-browser/trusted/profile/prefs.js
echo m > /var/lib/vh-browser/trusted/.cache/mozilla/y
chown -R browser:browser /var/lib/vh-browser
# when removing a package xbps itself changes the line of its system user (chrony)
passwd_same() { [ "$(grep -v '^chrony:' /etc/passwd)" = "$(grep -v '^chrony:' /tmp/passwd.orig)" ]; }
cp /etc/passwd /tmp/passwd.orig
sleep 1

snap() {
	find /etc /home /root /var/lib/vh-browser /var/lib/vh /var/cache/xbps -xdev \
		-printf '%p %s %m %T@\n' 2>/dev/null | sort | sha256sum
	xbps-query -l | sha256sum
}

# ---- the plan changes nothing
s1=$(snap)
"$dc" --user > /tmp/plan.txt 2>&1
s2=$(snap)
t "plan: the system did not change" '[ "$s1" = "$s2" ]'
t "plan: the orphan tree is listed" 'grep -q "^   tree-" /tmp/plan.txt'
t "plan: the keep package jq is shown as kept" 'grep -q "kept.*: jq" /tmp/plan.txt'
t "plan: the .new file is listed" 'grep -q "/etc/foo.conf.new-1.2_1" /tmp/plan.txt'
t "plan: the config from the vh-pkg journal is listed" 'grep -q "/etc/dhcpcd.conf" /tmp/plan.txt'
t "plan: the dangling service link is listed" 'grep -q "default/ghost" /tmp/plan.txt'
t "plan: the busy cache is shown as kept" 'grep -q "kept: busy" /tmp/plan.txt'
t "plan: kernels: the group is skipped without a kernel in the database" 'grep -q "group skipped" /tmp/plan.txt'
t "-y without --apply is an error" '! "$dc" -y >/dev/null 2>&1'

# ---- apply
"$dc" --apply -y --user > /tmp/apply.txt 2>&1
rc=$?
t "apply: exit code 0, no new package database errors" '[ $rc = 0 ] && grep -q "^System is in order" /tmp/apply.txt'
t "orphans: tree and chrony removed" '! xbps-query tree >/dev/null && ! xbps-query chrony >/dev/null'
t "keep: jq and its dependency oniguruma stayed, jq is manual" \
	'xbps-query jq >/dev/null && xbps-query oniguruma >/dev/null && xbps-query -m | grep -q "^jq-"'
t "the orphan's edited config is in the backup" \
	'[ ! -e /etc/chrony.conf ] && grep -q edit /var/lib/vh/deep-clean/last/root/etc/chrony.conf'
t "the config from the journal is in the backup, the journal is cleared" \
	'[ ! -e /etc/dhcpcd.conf ] && [ -e /var/lib/vh/deep-clean/last/root/etc/dhcpcd.conf ] && [ ! -e /var/lib/vh/removed-conf.list ]'
t "the .new file is in the backup" '[ ! -e /etc/foo.conf.new-1.2_1 ]'
t "a similar name, /etc/vh and the keep path stayed" \
	'[ -e /etc/bar.new-notversion ] && [ -e /etc/vh/x.conf.new-1.0_1 ] && [ -e /etc/keep.conf.new-2.0_1 ]'
t "other packages' configs are in place" '[ -e /etc/hosts ] && passwd_same'
t "the dangling service link is gone, the live one stayed" \
	'[ ! -L /etc/runit/runsvdir/default/ghost ] && [ -L /etc/runit/runsvdir/default/real ]'
t "the xbps cache is empty" '[ -z "$(find /var/cache/xbps -type f)" ]'
t "~/.cache cleaned, the busy file stayed" \
	'[ ! -e /home/alice/.cache/a ] && [ -e /home/alice/.cache/busy/f ]'
t "symlink traps removed as links, /etc intact" \
	'[ ! -L /home/alice/.cache/evil-dir ] && [ -d /etc/sv ] && passwd_same'
t "trash is empty, ~/.config intact" \
	'[ -z "$(ls -A /home/alice/.local/share/Trash 2>/dev/null)" ] && [ -e /home/alice/.config/app.conf ]'
t "root's cache cleaned" '[ ! -e /root/.cache/r ]'
t "the Firefox cache cleaned, the profile intact" \
	'[ ! -e /var/lib/vh-browser/trusted/profile/cache2/entries ] && [ ! -e /var/lib/vh-browser/trusted/.cache/mozilla ] && [ -e /var/lib/vh-browser/trusted/profile/prefs.js ]'
t "the backup is closed: 0700" '[ "$(stat -c %a /var/lib/vh/deep-clean/last)" = 700 ]'
t "the summary is printed" 'grep -q "^Freed: " /tmp/apply.txt'

# ---- Firefox running: the browser cache is left alone
mkdir -p /var/lib/vh-browser/trusted/profile/cache2/z && chown -R browser:browser /var/lib/vh-browser
setpriv --reuid=browser --regid=browser --init-groups sleep 600 &
fx=$!
sleep 1
"$dc" --apply -y --only user > /tmp/fx.txt 2>&1
t "the browser is running: its cache is skipped" \
	'grep -q "Firefox is running" /tmp/fx.txt && [ -d /var/lib/vh-browser/trusted/profile/cache2/z ]'
kill $fx 2>/dev/null

# ---- restore
"$dc" restore > /tmp/restore.txt 2>&1
echo "restore rc=$?"
t "restore brought back the configs, the .new file and the service link" \
	'grep -q edit /etc/chrony.conf && grep -q edit /etc/dhcpcd.conf && [ -e /etc/foo.conf.new-1.2_1 ] && [ -L /etc/runit/runsvdir/default/ghost ]'
t "the backup is deleted after restore" '[ ! -e /var/lib/vh/deep-clean/last ]'
t "a second restore fails with \"no backup\"" '! "$dc" restore >/dev/null 2>&1'

# ---- run again: nothing to remove except what came back
"$dc" --apply -y --only services > /dev/null 2>&1
"$dc" --only services > /tmp/again.txt 2>&1
t "again: no service links" 'grep -A1 "services:" /tmp/again.txt | grep -q "none"'

kill $holder 2>/dev/null
if [ $bad != 0 ]; then
	echo "--- plan"; cat /tmp/plan.txt; echo "--- apply"; cat /tmp/apply.txt
fi
echo "vh-deep-clean: $bad failures"
[ $bad = 0 ]
