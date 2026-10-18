#!/bin/sh
# The earliest hook: before TOTP and the passphrase prompt. The flag is the NVRAM variable
# VhPoweroff; forging it gives an attacker only a DoS (power-off), not access.
f=/sys/firmware/efi/efivars/VhPoweroff-cfc8fc79-be2e-4ddc-97f0-9f98bfe298a0
grep -q ' /sys/firmware/efi/efivars ' /proc/mounts || mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null
if [ -e "$f" ]; then
	# delete the flag; if that fails, do not power off (otherwise every boot would be a power-off)
	if rm -f "$f" && [ ! -e "$f" ]; then
		echo "void-hardperf-light: RAM was wiped by the firmware (MOR) after an emergency or regular shutdown: powering off"
		echo o > /proc/sysrq-trigger
		sleep 10
	else
		echo "void-hardperf-light: the VhPoweroff flag cannot be deleted: continuing the boot"
	fi
fi
