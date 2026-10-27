# shellcheck shell=sh
# vh-audit: boot chain and kernel (docs/03, docs/05). Sourced by vh-audit.
sec "Boot and kernel"
cmd=$(cat /proc/cmdline)
# a kernel without loadable modules (a machine kernel, CONFIG_MODULES=n: vh-kconf install,
# docs/uni/kernel.md) has no /proc/modules: nothing can be loaded into it, so neither
# module.sig_enforce (its UKI's command line leaves it out) nor the module lock has a job there
nomod=0
[ -e /proc/modules ] || nomod=1
# every machine's parameters; what the hardware asks for (the IOMMU of a DMAR table ...) is
# checked against the plan (area plan)
# the LSM line names selinux before apparmor with VH_MAC=selinux (docs/uni/selinux.md): the
# machine kernel runs SELinux, the stock kernel of the fallback UKI AppArmor
mac=$(sed -n 's/^VH_MAC=//p' /root/vh/vh.conf 2>/dev/null | tr -d '"')
lsm_want=lsm=landlock,lockdown,yama,apparmor
[ "$mac" = selinux ] && lsm_want=lsm=landlock,lockdown,yama,selinux,apparmor
for p in lockdown=confidentiality module.sig_enforce=1 $lsm_want \
	iommu.strict=1 init_on_free=1 rd.shell=0 rd.emergency=poweroff panic=10; do
	if [ "$p" = module.sig_enforce=1 ] && [ "$nomod" = 1 ]; then
		ok "no loadable modules in this kernel ($(uname -r)): module.sig_enforce has nothing to check"
		continue
	fi
	case " $cmd " in *" $p "*) ok "cmdline: $p" ;; *) bad "cmdline: missing $p" ;; esac
done
chk lockdown "$(cat /sys/kernel/security/lockdown)" "none integrity [confidentiality]"
lsm=$(cat /sys/kernel/security/lsm)
case ",$lsm," in *,bpf,*) bad "LSM: bpf is enabled ($lsm)" ;; *) ok "LSM: $lsm" ;; esac
case ",$lsm," in
*,selinux,*) [ "$mac" = selinux ] && ok "SELinux is active, AppArmor is not (VH_MAC=selinux; area selinux)" || bad "SELinux is active but VH_MAC=${mac:-apparmor}" ;;
*,apparmor,*) ok "AppArmor is active" ;;
*) bad "neither AppArmor nor SELinux is active ($lsm)" ;;
esac
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
	# three series (docs/uni/kernel.md): the stock UKIs, KEEP of them and the running one; the
	# machine UKIs linux-A.B.C-vh_N.efi and the init twins linux-A.B.C_D-vh-init.efi (vh-init
	# --install), which never take their place
	nstock=0 nmachine=0 ninit=0
	for f in /boot/efi/EFI/void/linux-*.efi; do
		[ -e "$f" ] || continue
		case $f in *-vh_[0-9]*.efi) nmachine=$((nmachine + 1)) ;; *-vh-init.efi) ninit=$((ninit + 1)) ;; *) nstock=$((nstock + 1)) ;; esac
	done
	[ "$nstock" -ge 1 ] && [ "$nstock" -le 3 ] && ok "stock UKIs on the ESP: $nstock" || bad "stock UKIs on the ESP: $nstock (expected 1-3)"
	[ "$nmachine" = 0 ] || ok "machine UKIs on the ESP: $nmachine"
	if [ -e /etc/vh/init-boot ]; then
		[ "$ninit" -ge 1 ] && ok "UKIs with vh-init on the ESP: $ninit (vh-init is wanted)" || bad "vh-init is wanted (/etc/vh/init-boot) but no UKI with vh-init is on the ESP (doas vh-limine-update with /boot/efi mounted)"
	else
		[ "$ninit" = 0 ] && ok "no UKI with vh-init on the ESP (vh-init is not wanted)" || bad "UKIs with vh-init on the ESP: $ninit, but vh-init is not wanted (no /etc/vh/init-boot): doas vh-limine-update removes them"
	fi
	[ "$esp" = 1 ] && umount /boot/efi
else
	unk "the ESP did not mount: signatures not checked"
fi
# the boot assessment of a machine kernel or of vh-init's UKI: limine.conf does not change for
# it, the EFI variables do
if [ -e /var/lib/vh/boot-assess ]; then
	assess=$(/usr/local/sbin/vh-limine-update --status 2>/dev/null | sed -n 's/^VH_BOOT_ASSESS //p')
	case $assess in
		*" state=failed "*) unk "boot assessment: a trial failed, the default did not change ($assess; doas vh-limine-update --status)" ;;
		*" state=trying "*) unk "boot assessment: on trial, not the default yet ($assess)" ;;
		default=stock*) ok "boot assessment: nothing passed one yet, the stock UKI boots ($assess)" ;;
		?*) ok "boot assessment: the default passed it ($assess)" ;;
		*) unk "boot assessment: vh-limine-update --status gave no summary" ;;
	esac
fi
if [ "$nomod" = 1 ]; then
	ok "no loadable modules in this kernel ($(uname -r)): no module lock is needed (kernel.modules_disabled does not exist)"
elif [ -e /etc/vh/modlock.enabled ]; then
	chk kernel.modules_disabled "$(cat /proc/sys/kernel/modules_disabled)" 1
else
	unk "module lock not enabled (stage 3: 30-lock.sh)"
fi
for m in fuse overlay; do
	if [ "$nomod" = 1 ]; then
		# built in or not at all: the file system types this kernel has
		grep -qw "$m" /proc/filesystems && bad "$m is built into this kernel" || ok "$m is not in this kernel"
	else
		grep -q "^$m " /proc/modules && bad "module $m is loaded" || ok "module $m is not loaded"
	fi
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
