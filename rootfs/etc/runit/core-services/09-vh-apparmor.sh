# vim: set ts=4 sw=4 et:
# void-hardperf-light: AppArmor profiles (docs/08). Only the listed ones are loaded, not
# all ~150 profiles of the apparmor package, and from the compiled policy cache: compilation
# happens once, after an apparmor or kernel update (the cache validates itself).
[ -d /sys/kernel/security/apparmor ] || return 0
msg "vh: AppArmor profiles..."
_vh_aa="/etc/apparmor.d/vh.firefox /etc/apparmor.d/vh.unbound /etc/apparmor.d/vh.chronyd /etc/apparmor.d/vh.iwd /etc/apparmor.d/unix-chkpwd"
for _vh_p in /etc/apparmor.d/vh.local.*; do
    [ -e "$_vh_p" ] && _vh_aa="$_vh_aa $_vh_p"
done
# shellcheck disable=SC2086
apparmor_parser --replace --write-cache --cache-loc /var/cache/apparmor -- $_vh_aa \
    || printf '! AppArmor: not every profile loaded: docs/08\n'
unset _vh_aa _vh_p
