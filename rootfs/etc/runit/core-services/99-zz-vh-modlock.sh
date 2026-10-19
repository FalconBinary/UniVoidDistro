# vim: set ts=4 sw=4 et:
# void-hardperf-light: kernel.modules_disabled=1 at the very end of stage 1 (docs/05).
# Until then any process can trigger the autoload of a rare module (socket(AF_...),
# nft_ expressions, qdiscs); by the end of stage 1 udev has loaded the drivers of the
# present hardware, and the modules needed later are preloaded here.
# Enabled by stage 3 (install/30-lock.sh). To disable: rm /etc/vh/modlock.enabled
[ -e /etc/vh/modlock.enabled ] || return 0
# a kernel without loadable modules (a machine kernel, CONFIG_MODULES=n) has nothing to preload
# and no kernel.modules_disabled to set
[ -e /proc/modules ] || { msg "vh: this kernel has no loadable modules: no module lock needed"; return 0; }
if [ -s /etc/vh/modules.preload ]; then
    msg "vh: preloading modules..."
    grep -v '^#' /etc/vh/modules.preload | xargs -r modprobe -a
fi
msg "vh: kernel module loading is blocked until reboot"
echo 1 > /proc/sys/kernel/modules_disabled
