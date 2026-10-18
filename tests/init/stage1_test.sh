#!/bin/sh
# vh-stage1 inside the privileged Void container (started by tests/init/run.sh).
#   sh stage1_test.sh DIR     -- DIR/bin/vh-stage1 and DIR/test/vh-stage1 (the unit tests)
# The container is throwaway: the real steps change its mounts, hostname, utmp and the
# SUID bits of its own files. What would reach the host kernel (zram, THP, the module lock,
# nftables of the host) runs under a fake root (--root) or in the container's own netns.
set -u
T=${1:?directory with bin/ and test/}
S=$T/bin/vh-stage1
fails=0
ok()   { echo "ok $*"; }
bad()  { echo "FAIL $*"; fails=$((fails + 1)); }
skip() { echo "SKIP $*"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1 = '$2' (expected '$3')"; fi; }
has()  { if printf '%s' "$2" | grep -q "$3"; then ok "$1"; else bad "$1: no '$3' in: $(printf '%s' "$2" | tail -c 300 | tr '\n' '|')"; fi; }

echo "== unit tests"
if out=$("$T/test/vh-stage1" 2>&1); then ok "unit tests: $(echo "$out" | tail -1)"; else bad "unit tests"; echo "$out" | tail -30; fi

echo "== the binary"
if ldd "$S" 2>&1 | grep -q 'not a dynamic\|statically'; then ok "static, no libc"; else bad "vh-stage1 is dynamic: $(ldd "$S" 2>&1 | head -2)"; fi
has "--version" "$("$S" --version)" '^vh-stage1 [0-9]'
chk "--list: first and last step" "$("$S" --list | sed -n '1p;$p' | cut -d' ' -f1 | paste -sd' ' -)" "pseudofs vh-modlock"
"$S" --step nosuch >/dev/null 2>&1 && bad "an unknown step is accepted" || ok "an unknown step is refused"

echo "== sysctl: the priorities of sysctl --system (procps) on test files"
mkdir -p /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /tmp/stock-sysctl
mv /usr/lib/sysctl.d/*.conf /tmp/stock-sysctl/ 2>/dev/null   # the host kernel is not touched
printf 'net.ipv4.ip_forward = 1\nnet.ipv4.conf.all.rp_filter = 2\n' > /usr/lib/sysctl.d/40-test.conf
printf '# masks the file of the same name in /usr/lib\nnet.ipv4.ip_forward = 0\nnet.ipv4.conf.all.rp_filter = 1\n' > /etc/sysctl.d/40-test.conf
printf 'net.ipv4.conf.all.accept_redirects = 0\n-net.ipv4.no.such.key = 1\nnet.ipv4.conf.all.send_redirects=0\n' > /run/sysctl.d/30-run.conf
printf '; a later file wins\nnet.ipv4.conf.all.rp_filter = 0\nnet.ipv4.nosuch = 1\n' > /etc/sysctl.d/50-later.conf
reset() { sysctl -q -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.all.accept_redirects=1 net.ipv4.conf.all.send_redirects=1; }
state() { sysctl -n net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.send_redirects | paste -sd' ' -; }
reset
sysctl --system > /tmp/oracle.log 2>&1
want=$(state)
reset
"$S" --step sysctl -v > /tmp/ours.log 2>&1
got=$(state)
chk "sysctl: values as after sysctl --system" "$got" "$want"
if [ "$got" != "0 0 0 0" ]; then
	echo "   (this kernel: $got; the oracle agrees) oracle:"; grep -v '^\*' /tmp/oracle.log | sed 's/^/   /'
	echo "   ours:"; grep -v Applying /tmp/ours.log | sed 's/^/   /'
fi
chk "sysctl: ip_forward and rp_filter from the masking file, then the later file" "$(echo "$got" | cut -d' ' -f1,2)" "0 0"
want_order=$(grep '^\* Applying' /tmp/oracle.log | awk '{print $3}' | paste -sd' ' -)
got_order=$(grep 'Applying' /tmp/ours.log | awk '{print $3}' | paste -sd' ' -)
chk "sysctl: the file order of sysctl --system" "$got_order" "$want_order"
grep -qF 'net.ipv4.no.such.key' /tmp/ours.log && bad "sysctl: a -key error was reported" || ok "sysctl: a -key is silent"
has "sysctl: an unknown key is skipped and logged" "$(cat /tmp/ours.log)" 'sysctl: net.ipv4.nosuch: no such key (skipped)'
mv /tmp/stock-sysctl/*.conf /usr/lib/sysctl.d/ 2>/dev/null
rm -f /etc/sysctl.d/40-test.conf /etc/sysctl.d/50-later.conf /run/sysctl.d/30-run.conf /usr/lib/sysctl.d/40-test.conf

echo "== fstab: mount -a (util-linux) against mount-all, byte for byte in findmnt"
for r in r1 r2; do mkdir -p /tmp/$r/etc /tmp/$r/mnt/a /tmp/$r/mnt/b /tmp/$r/mnt/c /tmp/$r/mnt/d; done
fstab() { # $1: the prefix of the paths
	printf 'tmpfs %s/mnt/a tmpfs nosuid,nodev,noexec,mode=1777,size=16m 0 0\n' "$1"
	printf '%s/mnt/a %s/mnt/b none bind,nosuid,nodev,noexec,nosymfollow 0 0\n' "$1" "$1"
	printf 'tmpfs %s/mnt/c tmpfs noauto,size=1m 0 0\n' "$1"
	printf 'tmpfs %s/mnt/d tmpfs _netdev,size=1m 0 0\n' "$1"
}
fstab "" > /tmp/r1/etc/fstab          # ours: --root /tmp/r1 puts the targets under it
fstab /tmp/r2 > /tmp/r2/etc/fstab     # the oracle mounts the real paths
mount -a --fstab /tmp/r2/etc/fstab -t nosysfs,nonfs,nonfs4,nosmbfs,nocifs -O no_netdev
"$S" --root /tmp/r1 --step mount-all --force -v > /tmp/mount.log 2>&1 || bad "mount-all: exit $?"
for m in a b; do
	chk "fstab: /mnt/$m options" "$(findmnt -no OPTIONS /tmp/r1/mnt/$m)" "$(findmnt -no OPTIONS /tmp/r2/mnt/$m)"
done
findmnt /tmp/r1/mnt/c >/dev/null && bad "fstab: noauto was mounted" || ok "fstab: noauto skipped"
findmnt /tmp/r1/mnt/d >/dev/null && bad "fstab: _netdev was mounted" || ok "fstab: _netdev skipped"
n=$(findmnt -rno TARGET | grep -c '^/tmp/r1/mnt/')
"$S" --root /tmp/r1 --step mount-all --force -v > /tmp/mount2.log 2>&1
chk "fstab: a second run mounts nothing again" "$(findmnt -rno TARGET | grep -c '^/tmp/r1/mnt/')" "$n"
has "fstab: the bind is seen as already mounted" "$(cat /tmp/mount2.log)" '/mnt/b: already mounted'
umount /tmp/r1/mnt/b /tmp/r1/mnt/a /tmp/r2/mnt/b /tmp/r2/mnt/a 2>/dev/null

echo "== pseudofs and the vh remounts (hidepid, nosuid/nodev/noexec, the shm size)"
grep -q '^proc:' /etc/group || echo 'proc:x:981:' >> /etc/group
mkdir -p /etc/vh
printf 'VH_SHM_SIZE="7m"\n' > /etc/vh/stage1.conf
"$S" --step pseudofs,vh-mounts -v > /tmp/mounts.log 2>&1 || bad "pseudofs,vh-mounts: exit $?"
has "/proc: hidepid=invisible" "$(findmnt -no OPTIONS /proc)" 'hidepid=invisible'
has "/proc: the proc group" "$(findmnt -no OPTIONS /proc)" 'gid=981'
has "/proc: nosuid,nodev,noexec" "$(findmnt -no OPTIONS /proc)" 'nosuid,nodev,noexec'
has "/dev/shm: noexec and size" "$(findmnt -no OPTIONS /dev/shm)" 'noexec.*size=7168k'
has "/run: noexec" "$(findmnt -no OPTIONS /run)" 'noexec'
has "/dev: nosuid,noexec" "$(findmnt -no OPTIONS /dev)" 'nosuid.*noexec'
has "pseudofs: no errors" "$(grep -c ERROR /tmp/mounts.log)" '^0$'

echo "== 05-misc: utmp and the boot record against halt -B, hostname, seedrng"
rm -f /run/utmp /var/log/wtmp
echo vhtest > /etc/hostname
"$S" --step misc --force -v > /tmp/misc.log 2>&1 || bad "misc: exit $?"
chk "hostname from /etc/hostname" "$(cat /proc/sys/kernel/hostname)" vhtest
chk "/run/utmp mode and group" "$(stat -c '%a %U %G' /run/utmp)" "664 root utmp"
chk "/var/log/wtmp mode and group" "$(stat -c '%a %U %G' /var/log/wtmp)" "664 root utmp"
rec() { utmpdump "$1" 2>/dev/null | grep '^\[' | sed 's/\[20[0-9][0-9]-[^]]*\]//' | sed -n "$2p"; }
halt -B
chk "wtmp: two boot records (ours, halt -B)" "$(utmpdump /var/log/wtmp 2>/dev/null | grep -c '^\[')" 2
chk "the boot record equals the one of halt -B" "$(rec /var/log/wtmp 1)" "$(rec /var/log/wtmp 2)"
has "the boot record: reboot ~~ and the kernel release" "$(rec /run/utmp 1)" "\[2\].*\[~~.*\[reboot.*$(uname -r)"
has "lo is up" "$(cat /sys/class/net/lo/flags)" '0x9'
seedfile() { ls /var/lib/seedrng/seed.credit /var/lib/seedrng/seed.no-credit 2>/dev/null | head -1; }
f=$(seedfile)
if [ -n "$f" ]; then
	sz=$(stat -c %s "$f"); [ "$sz" -ge 32 ] && [ "$sz" -le 512 ] && ok "seedrng: a new seed of $sz bytes ($f)" || bad "seedrng: seed size $sz"
	chk "seedrng: the seed is private" "$(stat -c %a "$f")" 400
	if command -v seedrng >/dev/null; then
		if seedrng; then ok "seedrng (stock) accepts the seed we wrote: $(seedfile)"; else bad "the stock seedrng failed on our seed"; fi
		"$S" --step misc --force >/dev/null 2>&1
		[ -n "$(seedfile)" ] && ok "our seedrng accepts the seed the stock one wrote" || bad "no seed after the round trip"
	else skip "no stock seedrng in the container"; fi
else bad "seedrng: no seed file written ($(grep -i seedrng /tmp/misc.log | tail -2 | tr '\n' '|'))"; fi

echo "== under a fake root: zram, THP, the module lock, dmesg, cleanup, runit-control"
R=/tmp/fake
mkdir -p $R/sys/block/zram0 $R/dev $R/proc/sys/kernel $R/sys/kernel/mm/transparent_hugepage $R/etc/vh $R/var/log $R/run $R/tmp $R/etc/runit/core-services $R/usr/bin $R/usr/lib/utempter
grep '^utmp:\|^root:' /etc/group > $R/etc/group
echo 0 > $R/sys/block/zram0/disksize
: > $R/sys/block/zram0/comp_algorithm
printf 'MemFree: 1 kB\nMemTotal: 1000000 kB\n' > $R/proc/meminfo
dd if=/dev/zero of=$R/dev/zram0 bs=4096 count=64 2>/dev/null
printf 'VH_ZRAM_ALGO="lz4"\nVH_ZRAM_PERCENT="40"\n' > $R/etc/vh/stage1.conf
echo madvise > $R/sys/kernel/mm/transparent_hugepage/defrag
: > $R/etc/vh/modlock.enabled
printf '# preload\nvfat fat\nnls_utf8\n' > $R/etc/vh/modules.preload
echo 0 > $R/proc/sys/kernel/modules_disabled
echo 1 > $R/proc/sys/kernel/dmesg_restrict
echo x > $R/fastboot
"$S" --root $R --step vh-zram,vh-mm,vh-modlock,dmesg,cleanup,runit-control -v > /tmp/fake.log 2>&1 || bad "fake root run: exit $?"
chk "zram: the algorithm from stage1.conf" "$(cat $R/sys/block/zram0/comp_algorithm)" lz4
chk "zram: 40 percent of MemTotal" "$(cat $R/sys/block/zram0/disksize)" 400000K
chk "zram: the swap signature (mkswap)" "$(od -An -c -j 4086 -N 10 $R/dev/zram0 | tr -d ' ')" "SWAPSPACE2"
chk "zram: version 1 at offset 1024" "$(od -An -tu4 -j 1024 -N 4 $R/dev/zram0 | tr -d ' ')" 1
chk "THP defrag" "$(cat $R/sys/kernel/mm/transparent_hugepage/defrag)" "defer+madvise"
chk "module lock: modules_disabled" "$(cat $R/proc/sys/kernel/modules_disabled)" 1
has "module lock: one modprobe -a with the list" "$(cat /tmp/fake.log)" 'exec: modprobe -a vfat fat nls_utf8'
chk "dmesg.log: 0600 under dmesg_restrict" "$(stat -c %a $R/var/log/dmesg.log)" 600
chk "dmesg.log: the first kernel line, without the level prefix" "$(head -1 $R/var/log/dmesg.log)" "$(dmesg | head -1)"
[ -e $R/fastboot ] && bad "cleanup: /fastboot remains" || ok "cleanup: /fastboot removed"
chk "cleanup: /tmp/.X11-unix 1777" "$(stat -c %a $R/tmp/.X11-unix)" 1777
chk "cleanup: /var/log/btmp 0600 root:utmp" "$(stat -c '%a %G' $R/var/log/btmp)" "600 utmp"
chk "runit-control: /run/runit/stopit mode 000" "$(stat -c %a $R/run/runit/stopit)" 0
has "fake root: no errors" "$(grep -c ERROR /tmp/fake.log)" '^0$'

echo "== vh-suid under a fake root: bits and file capabilities"
for f in passwd su ping extra; do cp /usr/bin/true $R/usr/bin/$f; done
chmod u+s $R/usr/bin/passwd
chmod u+s,g+s $R/usr/bin/su
chmod g+s $R/usr/bin/extra
printf '# vh-pkg\n/usr/bin/extra\n/usr/bin/missing\n' > $R/etc/vh/suid-strip.list
if command -v setcap >/dev/null && setcap cap_net_raw+ep $R/usr/bin/ping 2>/dev/null; then
	setcap cap_net_admin+ep $R/usr/bin/extra
	caps=1
else caps=0; skip "setcap not available: file capabilities not tested"; fi
"$S" --root $R --step vh-suid -v > /tmp/suid.log 2>&1 || bad "vh-suid: exit $?"
chk "SUID stripped from passwd" "$(stat -c %a $R/usr/bin/passwd)" 755
chk "SUID/SGID stripped from su" "$(stat -c %a $R/usr/bin/su)" 755
chk "SGID stripped from the vh-pkg list entry" "$(stat -c %a $R/usr/bin/extra)" 755
if [ "$caps" = 1 ]; then
	chk "capabilities stripped from ping" "$(getcap $R/usr/bin/ping)" ""
	chk "capabilities stripped from the list entry" "$(getcap $R/usr/bin/extra)" ""
fi
has "vh-suid: no errors" "$(grep -c ERROR /tmp/suid.log)" '^0$'

echo "== nftables: fail-closed on a bad ruleset"
if command -v nft >/dev/null || xbps-install -Sy nftables >/dev/null 2>&1; then
	if nft list ruleset >/dev/null 2>&1; then
		echo 'garbage {' > $R/etc/nftables.conf
		"$S" --root $R --step vh-nftables > /tmp/nft.log 2>&1
		has "a bad ruleset: the emergency message" "$(cat /tmp/nft.log)" 'emergency ruleset is active'
		has "a bad ruleset: vh_failsafe is loaded" "$(nft list ruleset)" 'table inet vh_failsafe'
		printf 'flush ruleset\ntable inet t {\n\tchain c {\n\t\ttype filter hook input priority 0; policy accept;\n\t}\n}\n' > $R/etc/nftables.conf
		"$S" --root $R --step vh-nftables -v > /tmp/nft2.log 2>&1
		has "a good ruleset replaces the emergency one" "$(nft list ruleset)" 'table inet t'
		nft list ruleset | grep -q vh_failsafe && { bad "vh_failsafe is still loaded"; cat /tmp/nft2.log; } || ok "vh_failsafe is gone"
		nft flush ruleset
	else skip "nft cannot talk to this kernel: nftables not tested"; fi
else skip "nftables not installable (no network): nftables not tested"; fi

echo "== --install, --status, --rollback under a fake root"
printf '#!/bin/sh\n# the stock stage 1\n' > $R/etc/runit/1
chmod 755 $R/etc/runit/1
printf 'echo lz4 > /sys/block/zram0/comp_algorithm\n_vh_kb=$(awk "{print int($2 * 40 / 100)}")\n' > $R/etc/runit/core-services/05-vh-zram.sh
printf 'mount -o remount,nosuid,nodev,noexec,size=30%% /dev/shm\n' > $R/etc/runit/core-services/04-vh-mounts.sh
rm -f $R/etc/vh/stage1.conf
out=$("$S" --root $R --install 2>&1); rc=$?
chk "--install: exit code" "$rc" 0
has "--install: the message" "$out" 'installed .* as /etc/runit/1'
chk "--install: the previous file is 1.orig" "$(head -c 2 $R/etc/runit/1.orig)" '#!'
cmp -s "$S" $R/etc/runit/1 && ok "--install: /etc/runit/1 is this binary" || bad "--install: /etc/runit/1 differs from the binary"
chk "--install: mode 0755 root" "$(stat -c '%a %U' $R/etc/runit/1)" "755 root"
has "--install: stage1.conf from the rendered scripts" "$(cat $R/etc/vh/stage1.conf)" 'VH_SHM_SIZE="30%"'
has "--install: zram values" "$(cat $R/etc/vh/stage1.conf | paste -sd' ' -)" 'VH_ZRAM_ALGO="lz4".*VH_ZRAM_PERCENT="40"'
out=$("$S" --root $R --status 2>&1); rc=$?
has "--status after install: exit 0, vh-stage1" "rc=$rc $out" 'rc=0.*/etc/runit/1: vh-stage1'
out=$("$S" --root $R --install 2>&1)
has "--install twice: replaced" "$out" 'already vh-stage1'
chk "--install twice: 1.orig untouched" "$(head -c 2 $R/etc/runit/1.orig)" '#!'
out=$("$S" --root $R --rollback 2>&1); rc=$?
has "--rollback: exit 0" "rc=$rc $out" 'rc=0.*restored /etc/runit/1'
chk "--rollback: the shell script is back" "$(head -c 2 $R/etc/runit/1)" '#!'
[ -e $R/etc/runit/1.orig ] && bad "--rollback: 1.orig remains" || ok "--rollback: 1.orig consumed"
out=$("$S" --root $R --status 2>&1); rc=$?
has "--status after rollback: exit 1, the shell script" "rc=$rc $out" 'rc=1.*shell script'
"$S" --root $R --rollback >/dev/null 2>&1 && bad "--rollback without 1.orig succeeded" || ok "--rollback without 1.orig is refused"

echo
if [ "$fails" = 0 ]; then echo "stage1_test: all checks passed"; else echo "stage1_test: $fails FAILED"; fi
[ "$fails" = 0 ]
