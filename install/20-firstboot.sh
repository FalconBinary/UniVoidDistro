#!/bin/bash
# Stage 2: first boot of the installed system. Run as the admin on tty2:
#   doas /root/vh/install/20-firstboot.sh
# The script works out which step you are at and tells you what to do next:
#   A. the system booted without Secure Boot -> base layer check;
#   B. the firmware is in Setup Mode -> enrol your own keys (sbctl enroll-keys);
#   C. Secure Boot is on -> signature check. Then stage 3 (30-lock.sh).
# Details: docs/03-boot.md.

. "$(dirname "$0")/lib.sh"
need_root
load_config /root/vh/vh.conf
FORCE_MS=0
[ "${1:-}" = "--microsoft" ] && FORCE_MS=1

# empty when the firmware has no such variable (no Secure Boot support at all), not an exit
efv() { od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/"$1"-* 2>/dev/null | tr -d ' ' || true; }
SB=$(efv SecureBoot) SETUP=$(efv SetupMode)

say "base layer check"
grep -q 'lockdown=confidentiality' /proc/cmdline && ok "cmdline from the UKI" || warn "cmdline not from the UKI?"
[ "$(cat /sys/kernel/security/lockdown)" = "none integrity [confidentiality]" ] \
	&& ok "lockdown: confidentiality" || warn "lockdown: $(cat /sys/kernel/security/lockdown)"
ok "LSM: $(cat /sys/kernel/security/lsm)"
nft list table inet vh >/dev/null 2>&1 && ok "nftables: table vh" || warn "no vh table"
for s in dbus iwd unbound chronyd seatd; do
	sv status "$s" | grep -q '^run:' && ok "service $s" || warn "service $s is not running"
done
getent hosts voidlinux.org >/dev/null && ok "DNS through unbound (DoT)" || warn "DNS does not answer: connect to a network with iwctl"
chronyc -n tracking 2>/dev/null | grep -q 'Leap status *: Normal' && ok "time synchronised (NTS)" \
	|| warn "time not synchronised yet (chronyc -N authdata)"

say "Secure Boot: SecureBoot=$SB SetupMode=$SETUP"
if [ "$SB" = 1 ]; then
	sbctl status
	# the ESP is noauto in fstab: for the signature check it is mounted read-only and briefly
	esp=0
	mountpoint -q /boot/efi || { mount -o ro /boot/efi && esp=1; }
	vrc=0
	sbctl verify || vrc=1
	[ "$esp" = 1 ] && umount /boot/efi
	[ "$vrc" = 0 ] || die "unsigned EFI files present"
	ok "Secure Boot is on, signatures in place. Next: stage 3 -- doas /root/vh/install/30-lock.sh"
	exit 0
fi

if [ "$SETUP" != 1 ]; then
	cat <<EOF

The firmware is not in Setup Mode. In the BIOS settings (docs/00, docs/03):
  1. set a BIOS administrator (supervisor) password;
  2. Secure Boot -> "Reset to Setup Mode" / "Delete all keys" / "Clear Secure Boot keys"
     (the name depends on the vendor; Secure Boot stays off meanwhile);
  3. boot the system and run this script again.
EOF
	exit 0
fi

say "enrolling your own keys"
sbctl status
EVLOG=/sys/kernel/security/tpm0/binary_bios_measurements
n=-1
if [ -r "$EVLOG" ]; then
	n=$(tpm2_eventlog "$EVLOG" 2>/dev/null | grep -c EV_EFI_BOOT_SERVICES_DRIVER || true)
fi
args=()
if [ "$FORCE_MS" = 1 ]; then
	warn "--microsoft: the Microsoft certificates go into db (UEFI CA 2011 signs shim, which has known vulnerabilities)"
	args=(--microsoft)
elif [ "$n" = 0 ]; then
	ok "no Option ROMs in the measurement log: own keys only"
elif [ "$n" -gt 0 ] 2>/dev/null; then
	warn "Option ROMs found: $n. Their hashes go into db (--tpm-eventlog); the Microsoft certificates do not"
	args=(--tpm-eventlog)
else
	die "the TPM measurement log is unavailable: Option ROMs cannot be checked. Enrolling without this could leave the machine without a display. Options: docs/03"
fi
confirm_exact enroll "The PK/KEK/db keys will be written to the firmware."
sbctl enroll-keys "${args[@]}"
ok "keys enrolled"
cat <<EOF

Next:
  1. reboot into the BIOS and enable Secure Boot (the BIOS password must already be set);
  2. there as well: disable USB/network boot, CSM and the UEFI Shell; put Limine
     ("Void Linux (Limine)") first in the boot order;
  3. boot and run this script again: it will check the signatures.
If the system does not boot: docs/03, section "Recovery".
EOF
