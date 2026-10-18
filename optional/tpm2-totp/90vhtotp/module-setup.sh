#!/bin/bash
# void-hardperf-light: the tpm2-totp dracut module (optional/tpm2-totp, docs/13).
# Differences from the package's stock 70tpm2-totp: its own PCR set (with PCR 14),
# generation and resealing in the initramfs driven by a flag on the root file system,
# extending PCR 14 after showing the code, so the running system can no longer compute codes.

check() {
	[ -s /etc/vh/totp.conf ] && return 0
	return 255
}

depends() {
	echo crypt
}

install() {
	inst_libdir_file 'libtss2-tcti-device.so*'
	inst_multiple tpm2-totp tpm2_pcrextend tpm2_pcrread date od head tr stty
	inst /usr/libexec/tpm2-totp/show-tpm2-totp /bin/show-tpm2-totp
	inst_simple "$moddir/vh-totp-start.sh" /bin/vh-totp-start
	inst_simple /etc/vh/totp.conf /etc/vh/totp.conf
	inst_hook pre-udev 70 "$moddir/vh-totp-show.sh"
	inst_hook pre-pivot 10 "$moddir/vh-totp-pivot.sh"
	inst_hook cleanup 70 "$moddir/vh-totp-cleanup.sh"
	inst_hook emergency 01 "$moddir/vh-totp-extend.sh"
	inst_simple "$moddir/vh-totp-lib.sh" /lib/vh-totp-lib.sh
	dracut_need_initqueue
}

installkernel() {
	instmods =drivers/char/tpm
}
