# shellcheck shell=sh
# vh-audit: stage 1 of the boot, vh-stage1 (init/, docs/runbook-gf63.md). Sourced by vh-audit.
sec "Stage 1 (vh-stage1)"
s1=/etc/runit/1
if [ "$(head -c 2 "$s1" 2>/dev/null)" = "#!" ]; then
	if [ -e "$s1.orig" ]; then
		bad "stage 1 is the runit-void shell script although $s1.orig exists (a runit-void update put it back?): doas vh-stage1 --install"
	else
		unk "stage 1 is the runit-void shell script (vh-stage1 is not installed: docs/runbook-gf63.md)"
	fi
elif [ "$(head -c 4 "$s1" 2>/dev/null | tr -d '\177')" = ELF ] && grep -aq vh-stage1 "$s1"; then
	ok "stage 1 is vh-stage1 ($s1)"
	if [ -e "$s1.orig" ]; then ok "the previous stage 1 is kept as $s1.orig (doas vh-stage1 --rollback)"
	else bad "$s1.orig is missing: no rollback without xbps-install -f runit-void"; fi
	if [ -r /run/vh/stage1 ]; then
		done_ms=$(sed -n 's/^done \([0-9]*\) ms$/\1/p' /run/vh/stage1)
		errs=$(sed -n 's/^errors \([0-9]*\)$/\1/p' /run/vh/stage1)
		[ -n "$done_ms" ] && ok "vh-stage1 finished this boot in $done_ms ms" || bad "/run/vh/stage1 has no 'done' line"
		[ "${errs:-1}" = 0 ] && ok "vh-stage1: no step reported an error" || bad "vh-stage1: ${errs:-?} step(s) reported an error (dmesg | grep vh-stage1)"
	else
		bad "no /run/vh/stage1: stage 1 did not finish as vh-stage1 this boot (dmesg | grep vh-stage1)"
	fi
	dmesg 2>/dev/null | grep -aq 'vh-stage1: done in' && ok "kmsg marker: vh-stage1: done in N ms" \
		|| unk "no vh-stage1 marker in dmesg (the kernel log may have wrapped)"
else
	bad "$s1 is neither the runit-void script nor vh-stage1"
fi
