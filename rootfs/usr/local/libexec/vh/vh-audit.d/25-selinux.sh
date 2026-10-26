# shellcheck shell=sh
# vh-audit: SELinux (docs/uni/selinux.md). Sourced by vh-audit. With VH_MAC=apparmor the area
# only says so; with selinux it checks the state the policy promises: active, the shipped policy
# loaded (its hash), the mode, the one-way boolean set, no permissive type, the labels, the
# denials of this boot.
sec "SELinux"
mac=$(sed -n 's/^VH_MAC=//p' /root/vh/vh.conf 2>/dev/null | tr -d '"')
if [ "${mac:-apparmor}" != selinux ]; then
	unk "VH_MAC=${mac:-apparmor}: SELinux is not this system's MAC (vh.conf)"
elif [ ! -d /sys/fs/selinux ] || ! grep -q selinux /sys/kernel/security/lsm 2>/dev/null; then
	bad "VH_MAC=selinux but this kernel runs no SELinux (lsm: $(cat /sys/kernel/security/lsm 2>/dev/null)): the stock kernel keeps AppArmor"
else
	ok "SELinux is active (lsm: $(cat /sys/kernel/security/lsm))"
	mode=$(sed -n 's/^mode //p' /run/vh/selinux 2>/dev/null)
	enf=$(cat /sys/fs/selinux/enforce 2>/dev/null)
	want=$(cat /etc/vh/selinux/mode 2>/dev/null)
	[ -s /run/vh/selinux ] && ok "stage 1 loaded $(sed -n 's/^policy //p' /run/vh/selinux) ($(sed -n 's/^bytes //p' /run/vh/selinux) bytes, $mode)" || bad "no /run/vh/selinux: stage 1 did not load the policy"
	if [ "$enf" = 1 ]; then ok "enforcing"; else
		if [ "$want" = permissive ]; then unk "permissive, as /etc/vh/selinux/mode says (the policy is not at its definition of done: doas vh-selinux denials)"
		else bad "permissive although /etc/vh/selinux/mode says $want"; fi
	fi
	( cd /etc/vh/selinux 2>/dev/null && sha256sum -c --quiet SHA256SUMS ) >/dev/null 2>&1 && ok "the policy files match their SHA256SUMS" || bad "/etc/vh/selinux: a file does not match SHA256SUMS"
	b=/sys/fs/selinux/booleans/secure_mode_policyload
	[ -r "$b" ] && [ "$(cut -d' ' -f1 "$b")" = 1 ] && ok "secure_mode_policyload is set: no policy load, no setenforce until the next boot" || bad "secure_mode_policyload is not set"
	[ "$(cat /sys/fs/selinux/checkreqprot 2>/dev/null || echo 0)" = 0 ] && ok "checkreqprot 0 (the kernel checks the real protection of a mapping)" || bad "checkreqprot is 1"
	cur=$(cat /proc/self/attr/current 2>/dev/null)
	case $cur in *:sysadm_t:*) ok "vh-audit runs as sysadm_t ($cur)" ;; *:unconfined*) bad "an unconfined domain exists: $cur" ;; *) unk "vh-audit runs as $cur" ;; esac
	n=$(dmesg 2>/dev/null | grep -ac 'avc:  denied')
	if [ "$n" = 0 ]; then ok "no AVC denial in this boot's kernel log"; else
		if [ "$enf" = 1 ]; then bad "$n AVC denials this boot (doas vh-selinux denials)"; else unk "$n AVC denials this boot, permissive (doas vh-selinux denials shows what the policy lacks)"; fi
	fi
	if [ -x /usr/local/sbin/vh-selabel ]; then
		d=$(/usr/local/sbin/vh-selabel --check /usr /etc 2>/dev/null | tail -1)
		case $d in *" 0 differ"*) ok "the labels of /usr and /etc match the policy" ;; *) bad "labels differ from the policy: $d (doas vh-selinux relabel)" ;; esac
	fi
fi
