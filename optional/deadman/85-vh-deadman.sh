# vim: set ts=4 sw=4 et:
# void-hardperf-light: the end of a regular shutdown (optional/deadman, docs/13). The root
# is already read-only (80-filesystems): data is flushed. Wiping the volume key, zram and
# the caches and rebooting through the firmware (MOR) is vh-deadman final. No return from here.
if [ -e /etc/vh/optional/deadman ] && [ -x /usr/local/sbin/vh-deadman ]; then
    msg "vh: wiping the LUKS key and RAM..."
    /usr/local/sbin/vh-deadman final
fi
