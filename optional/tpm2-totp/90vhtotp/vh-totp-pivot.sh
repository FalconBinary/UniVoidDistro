#!/bin/sh
# After unlocking LUKS, before switch_root: generation or resealing driven by a flag on the
# root file system (the flag's content is not read, only its presence), then extend the PCR.
. /lib/vh-totp-lib.sh
[ -s /run/vh-totp.pid ] && kill "$(cat /run/vh-totp.pid)" 2>/dev/null
GEN=/sysroot/var/lib/vh/totp-generate
RESEAL=/sysroot/var/lib/vh/totp-reseal
tty=/dev/console
# The tpm2-totp recovery password: 0.3.0 accepts it only as the -P argument (it does not
# read stdin). There are no other users in the initramfs, so nobody but us sees the argument.
# The root is mounted read-only in the initramfs (cmdline "ro"): the flag is removed with a
# temporary remount (found on the bench; otherwise generation would repeat)
clear_flag() {
	mount -o remount,rw /sysroot && rm -f "$1"
	mount -o remount,ro /sysroot
}
ask_pw() {
	stty -echo < $tty 2>/dev/null
	printf '%s' "$1" > $tty
	read -r pw < $tty
	stty echo < $tty 2>/dev/null
	echo > $tty
}
if [ -e "$GEN" ]; then
	{
		echo
		echo "=== tpm2-totp: generating the secret (PCR $PCRS) ==="
		echo "Expected ONLY right after \"optional/tpm2-totp/enable\". An unexpected prompt is"
		echo "a sign of tampering: power the laptop off and inspect it from the live USB."
		echo "Choose a recovery password (5 diceware words, NOT the LUKS passphrase): it is"
		echo "needed for resealing after updates. Then scan the QR code."
	} > $tty
	tpm2-totp clean >/dev/null 2>&1      # an old secret (the module was enabled before)
	while :; do
		ask_pw "Recovery password: "; p1=$pw
		ask_pw "Again: "; p2=$pw
		[ -n "$p1" ] && [ "$p1" = "$p2" ] && break
		echo "mismatch or empty: again" > $tty
	done
	if tpm2-totp -p "$PCRS" -P "$p1" generate > $tty 2>&1; then
		# the secret is sealed to the current state: resealing (the flag from the UKI rebuild
		# when the module was enabled) is no longer needed
		clear_flag "$GEN"
		[ -e "$RESEAL" ] && clear_flag "$RESEAL"
		echo "Press Enter once the code is added to the app..." > $tty; read -r _ < $tty
	else
		echo "generation failed: the flag is kept, another attempt at the next boot" > $tty
	fi
	p1="" p2="" pw=""
elif [ -e "$RESEAL" ]; then
	{
		echo
		echo "=== tpm2-totp: reseal request ==="
		echo "Expected ONLY right after a kernel, microcode or firmware update."
		echo "Kernel: $(cat /proc/version)"
		echo "Compare the version with the one noted during the update (vh-update). An unexpected"
		echo "request = a sign of a tampered boot: power the laptop off and inspect it from the live USB."
		printf 'Reseal to the current state? Type RESEAL: '
	} > $tty
	read -r ans < $tty
	if [ "$ans" = RESEAL ]; then
		ask_pw "tpm2-totp recovery password: "
		tpm2-totp -p "$PCRS" -P "$pw" reseal > $tty 2>&1 && clear_flag "$RESEAL" \
			&& echo "resealed; the code will match at the next boot" > $tty
		pw=""
	else
		echo "refused: the flag is kept, the code still does not match" > $tty
	fi
fi
vh_totp_lock
