#!/bin/sh
# pre-udev: a rule to show the code as soon as the kernel creates /dev/tpm0.
echo 'KERNEL=="tpm0", RUN+="/sbin/initqueue --settled --onetime /bin/vh-totp-start"' \
	> /etc/udev/rules.d/80-vh-totp.rules
