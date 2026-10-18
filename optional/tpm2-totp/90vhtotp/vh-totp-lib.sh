#!/bin/sh
# void-hardperf-light: shared tpm2-totp functions in the initramfs.
. /etc/vh/totp.conf            # PCRS="0,2,4,7,14"  LOCK_PCR=14
# Extend PCR LOCK_PCR with a random value: the TOTP secret can no longer be computed until
# the next boot, neither by the running system nor by a forged boot chain after it.
vh_totp_lock() {
	[ -e /run/vh-totp-locked ] && return 0
	r=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
	tpm2_pcrextend "${LOCK_PCR}:sha256=$r" >/dev/null 2>&1 && : > /run/vh-totp-locked
}
