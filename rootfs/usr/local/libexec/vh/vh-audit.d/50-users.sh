# shellcheck shell=sh
# vh-audit: accounts and the hardware watchdog (docs/05). Sourced by vh-audit.
sec "Users"
for u in "$VH_ADMIN" "$VH_USER"; do
	case $(getent shadow "$u" | cut -d: -f2) in
		'$y$'*) ok "$u: yescrypt password" ;;
		*) bad "$u: password is not yescrypt" ;;
	esac
done
grep -q '^root:!' /etc/shadow && ok "root is locked" || bad "root has a password"
id -nG "$VH_USER" | grep -qw wheel && bad "$VH_USER is in wheel" || ok "$VH_USER is not in wheel"
for g in input video kvm; do id -nG "$VH_USER" | grep -qw "$g" && bad "$VH_USER is in group $g"; done
doas -C /etc/doas.conf >/dev/null 2>&1 && ok "doas.conf parses" || bad "doas.conf has errors"

nmi=$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null || echo ?)
[ "$nmi" = 1 ] && ok "NMI watchdog is on (hardlockup_panic works)" || unk "NMI watchdog = $nmi (normal in a VM without a PMU; must be 1 on hardware)"
