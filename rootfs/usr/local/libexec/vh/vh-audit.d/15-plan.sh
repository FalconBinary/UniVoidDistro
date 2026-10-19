# shellcheck shell=sh
# vh-audit: the plan of this machine (docs/uni/runtime.md): the protection tier and the risks
# acknowledged at installation, then that the services, the refused modules, the command line
# and the firmware on disk are those of /etc/vh/plan.zon, and what vh-kconf check found at
# boot. Sourced by vh-audit, which reads the plan ("plan KEY").
sec "Plan (/etc/vh/plan.zon)"
# the residual risk of a missing requirement, as plan-report.txt states it
risk() {
	awk -v id="$1" '/^Requirements not met/ { s = 1; next } s && /^$/ { exit }
		s && /^  [^ ]/ { cur = $1; sub(/:$/, "", cur) }
		s && cur == id && /^    residual risk: / { sub(/^    residual risk: /, ""); print; exit }' /etc/vh/plan-report.txt 2>/dev/null
}
tier=$(plan TIER)
if [ -z "$tier" ]; then
	bad "no plan: neither vh-plan env --plan /etc/vh/plan.zon nor /root/vh/plan.env gives one"
else
	security=$(plan SECURITY)
	case $tier in
		full) ok "protection tier: full ($security mode): every protective property of this architecture" ;;
		reduced)
			# tiered mode: every missing requirement was confirmed by typing at installation
			for id in $(plan MISSING); do
				case " $(plan ACKNOWLEDGE) " in
					*" $id "*) unk "acknowledged at installation ($security mode): $id missing: $(risk "$id")" ;;
					*) bad "the requirement $id is missing and was not acknowledged at installation" ;;
				esac
			done ;;
		*) bad "protection tier: $tier (the security gate refuses this machine in any mode)" ;;
	esac

	# the services the hardware needs (iwd with Wi-Fi, vh-acpid with a lid or a button ...)
	for s in $(plan SERVICES); do
		if [ ! -e "/var/service/$s" ]; then bad "service $s of the plan is not enabled"
		elif sv status "$s" 2>/dev/null | grep -q '^run:'; then ok "service $s of the plan is running"
		else bad "service $s of the plan is not running"; fi
	done

	# the refused modules: on the command line (module_blacklist=), and none loaded; a kernel
	# without loadable modules (a machine kernel, built without them by vh-kconf resolve's deny
	# list) has no module_blacklist= and no /proc/modules: nothing can load them
	cmd=" $(cat /proc/cmdline) "
	# shellcheck disable=SC2086 # one parameter per line
	bl=" $(printf '%s\n' $cmd | sed -n 's/^module_blacklist=//p' | tr ',' ' ') "
	n=0 notbl="" loaded=""
	for m in $(plan DENY); do
		n=$((n + 1))
		[ -e /proc/modules ] || continue
		case $bl in *" $m "*) ;; *) notbl="$notbl $m" ;; esac
		grep -q "^$m " /proc/modules && loaded="$loaded $m"
	done
	if [ ! -e /proc/modules ]; then
		ok "the $n modules the plan refuses cannot be loaded: this kernel has no loadable modules ($(uname -r))"
	else
		[ -z "$notbl" ] || bad "modules the plan refuses, missing from module_blacklist= of the command line:$notbl"
		[ -z "$loaded" ] || bad "modules the plan refuses are loaded:$loaded"
		[ -z "$notbl$loaded" ] && ok "the $n modules the plan refuses are refused by the kernel, none is loaded"
	fi

	# the command line of the plan (the IOMMU, early DMA, ia32 ...)
	missing=""
	for p in $(plan CMDLINE); do
		case $cmd in *" $p "*) ;; *) missing="$missing $p" ;; esac
	done
	[ -z "$missing" ] && ok "command line: the plan's parameters ($(plan CMDLINE))" || bad "command line: the plan's parameters missing:$missing"

	# the firmware on disk: every pattern of the plan kept, every file kept by a pattern
	conf=/etc/xbps.d/40-vh-firmware.conf
	if [ -e "$conf" ]; then
		notkept=""
		for p in $(plan FIRMWARE); do
			grep -qxF "noextract=!/usr/lib/firmware/$p" "$conf" || notkept="$notkept $p"
		done
		[ -z "$notkept" ] && ok "firmware: the plan's $(plan FIRMWARE | wc -w) patterns are kept ($conf)" \
			|| bad "firmware patterns of the plan missing from $conf:$notkept"
		keep=$(sed -n 's|^noextract=!/usr/lib/firmware/||p' "$conf")
		extra=0 example=""
		for f in $(cd /usr/lib/firmware 2>/dev/null && find . -type f | sed 's|^\./||'); do
			kept=0
			for p in $keep; do
				# shellcheck disable=SC2254 # the pattern is a glob on purpose, as xbps matches it
				case $f in $p) kept=1; break ;; esac
			done
			[ "$kept" = 1 ] || { extra=$((extra + 1)); [ -n "$example" ] || example=$f; }
		done
		[ "$extra" = 0 ] && ok "firmware on disk: every file is one the plan keeps" \
			|| bad "firmware on disk the plan does not keep: $extra file(s), for example $example (extracted before the trim? xbps-install -f its package)"
	else
		unk "firmware: not trimmed (VH_FIRMWARE_TRIM=no): every file of the packages is on disk"
	fi
fi

# vh-kconf check at this boot: the machine of /etc/vh/hw.zon, the drivers, the firmware
if [ -r /run/vh/check.done ]; then
	case $(cat /run/vh/check.done) in
		# lost=N: since U3; the line of an older vh-kconf ends at firmware=N
		"VH_CHECK machine=same devices=0 firmware=0"|"VH_CHECK machine=same devices=0 firmware=0 lost=0")
			ok "vh-kconf check: the machine of /etc/vh/hw.zon, every device with its driver, no firmware failure" ;;
		*machine=different*) bad "vh-kconf check: another machine than the one of the plan (/run/vh/check; a fresh plan: /run/vh/plan)" ;;
		*) unk "vh-kconf check: $(sed 's/^VH_CHECK //' /run/vh/check.done) (/run/vh/check)" ;;
	esac
else
	unk "vh-kconf check did not run this boot (the vh-check service)"
fi
if [ -n "$tier" ] && [ -r /run/vh/plan/plan.env ]; then
	fresh=$(sed -n "s/^VH_PLAN_TIER='\(.*\)'\$/\1/p" /run/vh/plan/plan.env)
	[ "$fresh" = "$tier" ] && ok "the fresh plan of this boot keeps the protection tier $tier" \
		|| bad "the fresh plan of this boot has the protection tier $fresh, the installation $tier (/run/vh/plan/plan-report.txt)"
fi
