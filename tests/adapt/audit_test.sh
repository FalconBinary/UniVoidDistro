#!/bin/sh
# vh-audit's plan area (rootfs/usr/local/libexec/vh/vh-audit.d/15-plan.sh) in a throwaway
# privileged Void container, started by tests/adapt/run.sh. The installed system of a golden
# plan is mocked: /etc/vh, /var/service, an sv that reports vh-fstrim down, /proc/cmdline and
# /proc/modules bind-mounted in a mount namespace, /usr/lib/firmware, /run/vh. The area's
# verdicts are compared with what they must be.
#   sh tests/adapt/audit_test.sh SRC   -- SRC: rootfs/, tests/adapt/golden, build/at/bin/vh-plan
set -u
S=${1:?the directory with rootfs, tests/adapt/golden and build/at/bin}
fails=0
ok()  { echo "ok $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1: no '$3' in: $(printf '%s' "$2" | tr '\n' '|')"; fi; }

install -D -m 0755 "$S/rootfs/usr/local/sbin/vh-audit" /usr/local/sbin/vh-audit
install -D -m 0644 "$S/rootfs/usr/local/libexec/vh/vh-audit.d/15-plan.sh" /usr/local/libexec/vh/vh-audit.d/15-plan.sh
# the image's /var/service is a link to runit's directory: a plain directory here
rm -rf /var/service
mkdir -p /etc/vh /var/service /run/vh /root/vh /etc/xbps.d
printf 'VH_KERNEL="linux6.18"\nVH_USER="user"\nVH_ADMIN="admin"\nVH_BROWSER_USER="browser"\nVH_BLUETOOTH="optional"\nVH_GPU="auto"\n' > /etc/vh/vh.env
# every service runs, but vh-fstrim
cat > /usr/bin/sv <<'EOF'
#!/bin/sh
case $2 in vh-fstrim) echo "down: $2: 3s, normally up" ;; *) echo "run: $2: (pid 1) 5s" ;; esac
EOF
chmod 0755 /usr/bin/sv

audit() { # $1: the kernel's command line, $2: the loaded modules -> the plan area's lines
	printf '%s\n' "$1" > /tmp/cmdline
	printf '%s\n' $2 | awk 'NF { print $1 " 16384 0 - Live 0x0" }' > /tmp/modules
	unshare -m sh -c 'mount --bind /tmp/cmdline /proc/cmdline && mount --bind /tmp/modules /proc/modules && /usr/local/sbin/vh-audit plan' 2>&1
}

echo "== a full machine: the GF63's plan, read through vh-plan env"
g=$S/tests/adapt/golden/gf63/strict
install -D -m 0755 "$S/build/at/bin/vh-plan" /usr/local/sbin/vh-plan
cp "$g/plan.zon" "$g/plan-report.txt" /etc/vh/
deny=$(sed -n "s/^VH_PLAN_DENY='\(.*\)'\$/\1/p" "$g/plan.env")
cmdl=$(sed -n "s/^VH_PLAN_CMDLINE='\(.*\)'\$/\1/p" "$g/plan.env")
for s in $(sed -n "s/^VH_PLAN_SERVICES='\(.*\)'\$/\1/p" "$g/plan.env"); do mkdir -p "/var/service/$s"; done
{
	echo "noextract=/usr/lib/firmware/*"
	for p in $(sed -n "s/^VH_PLAN_FIRMWARE='\(.*\)'\$/\1/p" "$g/plan.env"); do echo "noextract=!/usr/lib/firmware/$p"; done
} > /etc/xbps.d/40-vh-firmware.conf
mkdir -p /usr/lib/firmware/i915 /usr/lib/firmware/gpu
: > /usr/lib/firmware/i915/kbl_dmc_ver1_04.bin.zst
: > /usr/lib/firmware/regulatory.db
: > /usr/lib/firmware/gpu/left-out.bin.zst
echo "VH_CHECK machine=same devices=0 firmware=0 lost=0" > /run/vh/check.done
out=$(audit "root=UUID=x module_blacklist=sctp,$(echo "$deny" | tr ' ' ',') $cmdl quiet" "xfs dm_crypt")
has "the tier" "$out" "[ ok ] protection tier: full (strict mode)"
has "a service of the plan runs" "$out" "[ ok ] service iwd of the plan is running"
has "a service of the plan is down" "$out" "[FAIL] service vh-fstrim of the plan is not running"
has "the refused modules" "$out" "[ ok ] the 11 modules the plan refuses are refused by the kernel, none is loaded"
has "the command line" "$out" "[ ok ] command line: the plan's parameters ($cmdl)"
has "the firmware patterns" "$out" "[ ok ] firmware: the plan's 7 patterns are kept"
has "firmware the plan does not keep" "$out" "[FAIL] firmware on disk the plan does not keep: 1 file(s), for example gpu/left-out.bin.zst"
has "vh-kconf check" "$out" "[ ok ] vh-kconf check: the machine of /etc/vh/hw.zon"
has "the summary" "$out" "VH_AUDIT ok=8 fail=2 unchecked=0"
# a refused module missing from the command line, another one loaded, a parameter missing
out=$(audit "root=UUID=x module_blacklist=$(echo "$deny" | sed 's/mei_me //' | tr ' ' ',') ia32_emulation=0" "nouveau xfs")
has "a refused module not on the command line" "$out" "[FAIL] modules the plan refuses, missing from module_blacklist= of the command line: mei_me"
has "a refused module loaded" "$out" "[FAIL] modules the plan refuses are loaded: nouveau"
has "a parameter missing" "$out" "[FAIL] command line: the plan's parameters missing: efi=disable_early_pci_dma intel_iommu=on"

echo "== a reduced machine, every risk acknowledged: the Raspberry Pi's tiered plan, without vh-plan"
r=$S/tests/adapt/golden/rpi5/tiered
rm -f /usr/local/sbin/vh-plan /etc/vh/plan.zon /etc/xbps.d/40-vh-firmware.conf
cp "$r/plan.env" /root/vh/plan.env
cp "$r/plan-report.txt" /etc/vh/
echo "VH_CHECK machine=different devices=0 firmware=0 lost=0" > /run/vh/check.done
mkdir -p /run/vh/plan
echo "VH_PLAN_TIER='full'" > /run/vh/plan/plan.env
out=$(audit "root=UUID=x module_blacklist=rtsx_pci,rtsx_pci_sdmmc,uvcvideo" "")
has "an acknowledged risk, with its residual risk" "$out" "[ ?? ] acknowledged at installation (tiered mode): secure-boot missing: The boot chain is not verified: an evil maid can replace the kernel and capture the LUKS passphrase."
has "every missing requirement" "$out" "[ ?? ] acknowledged at installation (tiered mode): iommu missing:"
has "no trim" "$out" "[ ?? ] firmware: not trimmed"
has "another machine" "$out" "[FAIL] vh-kconf check: another machine than the one of the plan"
has "the fresh plan's tier" "$out" "[FAIL] the fresh plan of this boot has the protection tier full, the installation reduced"

echo "== a reduced machine in strict mode: a missing requirement nobody acknowledged"
cp "$S/tests/adapt/golden/rpi5/strict/plan.env" /root/vh/plan.env
rm -rf /run/vh/plan /run/vh/check.done
out=$(audit "root=UUID=x" "")
has "not acknowledged" "$out" "[FAIL] the requirement uefi is missing and was not acknowledged at installation"
has "check did not run" "$out" "[ ?? ] vh-kconf check did not run this boot"
rm -f /root/vh/plan.env
out=$(audit "root=UUID=x" "")
has "no plan at all" "$out" "[FAIL] no plan: neither vh-plan env --plan /etc/vh/plan.zon nor /root/vh/plan.env gives one"

echo
if [ "$fails" = 0 ]; then echo "audit_test: all checks passed"; else echo "audit_test: $fails FAILED"; fi
[ "$fails" = 0 ]
