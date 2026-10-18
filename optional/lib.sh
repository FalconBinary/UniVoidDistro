# shellcheck shell=bash
# void-hardperf-light: shared functions of the paranoid modules optional/* (docs/13).
# A module runs in the installed system as root:
#   doas /root/vh/optional/<module>/enable    -- enable
#   doas /root/vh/optional/<module>/disable   -- disable (back to the base layer)
#   doas /root/vh/optional/status             -- what is enabled
# Every module is idempotent: a repeated enable breaks nothing.

. "$(dirname "${BASH_SOURCE[0]}")/../install/lib.sh"
need_root
load_config "$VH_ROOT/vh.conf"
MOD_DIR=$(cd "$(dirname "$0")" && pwd)
MOD=$(basename "$MOD_DIR")
STATE=/etc/vh/optional

mark_enabled()  { install -d -m 0755 "$STATE"; date -u +%FT%TZ > "$STATE/$MOD"; ok "module $MOD enabled"; }
mark_disabled() { rm -f "$STATE/$MOD"; ok "module $MOD disabled"; }
is_enabled()    { [ -e "$STATE/${1:-$MOD}" ]; }

# A copy of the original file before the first edit; restore_orig puts it back.
save_orig()    { [ -e "$1" ] && [ ! -e "$1.vh-orig" ] && cp -a "$1" "$1.vh-orig"; return 0; }
restore_orig() { if [ -e "$1.vh-orig" ]; then mv -f "$1.vh-orig" "$1"; fi; }

# The nftables ruleset: check first, then load, so an error never leaves the system without rules.
reload_nft() {
	nft -c -f /etc/nftables.conf || return 1
	nft -f /etc/nftables.conf
}

# Rebuild the UKI of the current kernel (after changing the cmdline, dracut modules and so on).
rebuild_uki() {
	say "rebuilding and signing the UKI ($VH_KERNEL)"
	xbps-reconfigure -f "$VH_KERNEL"
}

# Add/remove a parameter in KERNEL_CMDLINE (/etc/default/dracut-uefi-hook).
cmdline_add() {
	local f=/etc/default/dracut-uefi-hook p
	for p in "$@"; do
		grep -q "KERNEL_CMDLINE=\".* $p\( \|\"\)" "$f" && continue
		sed -i "s|^KERNEL_CMDLINE=\"\(.*\)\"|KERNEL_CMDLINE=\"\1 $p\"|" "$f"
	done
}
cmdline_del() {
	local f=/etc/default/dracut-uefi-hook p
	for p in "$@"; do
		sed -i "s| $p\( \|\"\)|\1|" "$f"
	done
}
