# shellcheck shell=sh
# vh-audit: boot chain and kernel (docs/03, docs/05). Sourced by vh-audit.
sec "Boot and kernel"
cmd=$(cat /proc/cmdline)
# every machine's parameters; what the hardware asks for (the IOMMU of a DMAR table ...) is
# checked against the plan (area plan)
for p in lockdown=confidentiality module.sig_enforce=1 lsm=landlock,lockdown,yama,apparmor \
	iommu.strict=1 init_on_free=1 rd.shell=0 rd.emergency=poweroff panic=10; do
	case " $cmd " in *" $p "*) ok "cmdline: $p" ;; *) bad "cmdline: missing $p" ;; esac
done
chk lockdown "$(cat /sys/kernel/security/lockdown)" "none integrity [confidentiality]"
lsm=$(cat /sys/kernel/security/lsm)
case ",$lsm," in *,bpf,*) bad "LSM: bpf is enabled ($lsm)" ;; *) ok "LSM: $lsm" ;; esac
case ",$lsm," in *,apparmor,*) ok "AppArmor is active" ;; *) bad "AppArmor is not active" ;; esac
chk kernel.panic "$(cat /proc/sys/kernel/panic)" 10
sb=$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | tr -d ' ')
[ "$sb" = 1 ] && ok "Secure Boot is on" || bad "Secure Boot is off (stage 2: 20-firstboot.sh)"
# signatures of every EFI file on the ESP (the ESP is noauto: mounted read-only and briefly)
esp=0
mountpoint -q /boot/efi || { mount -o ro /boot/efi 2>/dev/null && esp=1; }
if mountpoint -q /boot/efi; then
	if [ -e /var/lib/sbctl/keys/db/db.key ] || mountpoint -q /var/lib/sbctl/keys; then
		unsigned=$(sbctl verify 2>&1 | grep -i 'not signed' || true)
		[ -z "$unsigned" ] && ok "every EFI file on the ESP is signed (sbctl verify)" || bad "unsigned: $unsigned"
	else
		unk "Secure Boot keys are offline: sbctl verify skipped without the media"
	fi
	n=$(ls /boot/efi/EFI/void/linux-*.efi 2>/dev/null | wc -l)
	[ "$n" -ge 1 ] && [ "$n" -le 3 ] && ok "UKIs on the ESP: $n" || bad "UKIs on the ESP: $n (expected 1-3)"
	[ "$esp" = 1 ] && umount /boot/efi
else
	unk "the ESP did not mount: signatures not checked"
fi
if [ -e /etc/vh/modlock.enabled ]; then
	chk kernel.modules_disabled "$(cat /proc/sys/kernel/modules_disabled)" 1
else
	unk "module lock not enabled (stage 3: 30-lock.sh)"
fi
for m in fuse overlay; do
	grep -q "^$m " /proc/modules && bad "module $m is loaded" || ok "module $m is not loaded"
done
/usr/local/libexec/vh/vh-seccomp --selftest >/dev/null 2>&1 \
	&& ok "sandbox seccomp filters: self-test" || bad "vh-seccomp --selftest failed"
# an interpreter with FFI (ctypes) creates executable memory and bypasses noexec; a
# compiler builds a tool in place: neither exists in the system (docs/05)
found=""
for b in python3 perl ruby node luajit gcc cc clang tcc; do
	command -v "$b" >/dev/null 2>&1 && found="$found $b"
done
[ -z "$found" ] && ok "no interpreters with FFI and no compilers (noexec cannot be bypassed)" \
	|| bad "installed:$found -- they bypass noexec (docs/05); remove with: doas vh-pkg rm"
grep -q . /sys/kernel/security/apparmor/profiles 2>/dev/null && \
	ok "AppArmor profiles: $(wc -l < /sys/kernel/security/apparmor/profiles)" || unk "no AppArmor profiles"
