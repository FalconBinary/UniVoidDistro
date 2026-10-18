# shellcheck shell=sh
# vh-audit: SUID, capabilities, device permissions, the package manager (docs/05, docs/18). Sourced by vh-audit.
sec "SUID, capabilities, device permissions"
suid=$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | sort | paste -sd' ' -)
chk "SUID/SGID" "$suid" "/usr/bin/doas /usr/bin/unix_chkpwd"
# nanoklogd (socklog-void) reads the kernel log as an unprivileged user and needs
# cap_syslog; it is the only expected file capability
caps=$(getcap -r /usr 2>/dev/null | grep -v '^/usr/bin/nanoklogd cap_syslog=ep$')
[ -z "$caps" ] && ok "file capabilities: only nanoklogd cap_syslog" || bad "file capabilities: $caps"
for d in /dev/dri/renderD*; do
	[ -e "$d" ] && chk "$d" "$(stat -c '%a %U:%G' "$d")" "660 root:render"
done
for d in /dev/rfkill /dev/tpm0 /dev/tpmrm0 /dev/watchdog; do
	[ -e "$d" ] && chk "$d" "$(stat -c '%a %U' "$d")" "600 root"
done
for c in gcc cc clang make tcc; do
	command -v "$c" >/dev/null && bad "compiler in the system: $c"
done
ok "no C compilers (as/ld from binutils are a dracut-uefi dependency, docs/02)"
# thor (docs/18): xbps with the policy -- SUID is stripped before the file reaches the disk,
# package hooks and rules are checked against the baseline, the deny list also applies to updates
if xbps-query thor >/dev/null 2>&1; then ok "package manager: $(xbps-query -p pkgver thor)"
else bad "thor is not installed: packages are installed without the policy (docs/18)"; fi
xbps-query -p pkgver xbps 2>/dev/null | grep -q '^xbps-' && bad "plain xbps is installed: the thor policy does not apply" \
	|| ok "no plain xbps (thor replaces it)"
grep -q thor_unpack_entry /usr/lib/libxbps.so.6 2>/dev/null && ok "libxbps with the thor policy" || bad "libxbps without the thor policy"
chk "thor policy" "$(sed -n 's/^mode=//p' /etc/thor/policy.conf 2>/dev/null)" enforce
for c in crond snooze acpid polkitd udisksd avahi-daemon cupsd NetworkManager sshd; do
	command -v "$c" >/dev/null && bad "unwanted daemon: $c"
done
