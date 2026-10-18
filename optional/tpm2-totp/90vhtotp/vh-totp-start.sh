#!/bin/sh
# Started from the initqueue once /dev/tpm0 appeared: shows the code every 30 s in the background.
. /etc/vh/totp.conf
echo
echo "=== void-hardperf-light: compare the TOTP code with your phone BEFORE typing the LUKS passphrase ==="
/bin/show-tpm2-totp -p "$PCRS" &
echo $! > /run/vh-totp.pid
