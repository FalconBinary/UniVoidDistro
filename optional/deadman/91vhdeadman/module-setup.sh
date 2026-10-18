#!/bin/bash
# void-hardperf-light: the initramfs powers the machine off if vh-deadman rebooted it
# through MOR (optional/deadman, docs/13). By then the firmware has already wiped RAM.
check() { return 0; }
depends() { return 0; }
install() {
	inst_hook cmdline 01 "$moddir/vh-deadman-flag.sh"
}
