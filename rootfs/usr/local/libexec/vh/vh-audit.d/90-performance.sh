# shellcheck shell=sh
# vh-audit: the performance settings that must be in effect (docs/11). Sourced by vh-audit.
sec "Performance"
[ -e /etc/xbps.d/40-vh-firmware.conf ] && ok "firmware: needed files only ($(du -sm /usr/lib/firmware 2>/dev/null | cut -f1) MB)" \
	|| unk "firmware: everything extracted ($(du -sm /usr/lib/firmware 2>/dev/null | cut -f1) MB)"
chk "THP defrag" "$(sed 's/.*\[\(.*\)\].*/\1/' /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null)" "defer+madvise"
swapon --noheadings --show=NAME 2>/dev/null | grep -q zram && ok "zram is active" || bad "zram is not active"
# the I/O scheduler of every disk, by what it is, as rootfs/etc/udev/rules.d/99-vh-iosched.rules sets it
for b in /sys/block/*; do
	[ -r "$b/queue/scheduler" ] || continue
	n=${b##*/}
	case $n in nvme*|vd*|sd*|mmcblk*) ;; *) continue ;; esac
	case $n:$(readlink -f "$b") in
		nvme*|*/virtio*) want=none ;;
		mmcblk*) want=bfq ;;
		*) if [ "$(cat "$b/queue/rotational")" = 1 ]; then want=bfq; else want=mq-deadline; fi ;;
	esac
	chk "I/O scheduler of $n" "$(sed 's/.*\[\(.*\)\].*/\1/' "$b/queue/scheduler")" "$want"
done
st=$(cat /run/vh/power 2>/dev/null || echo ?)
epp=$(cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference 2>/dev/null || echo none)
case $st:$epp in ac:balance_performance|battery:balance_power) ok "EPP $epp ($st)" ;; *) unk "EPP $epp while on $st power" ;; esac
if [ "$VH_GPU" = igpu ]; then
	for d in /sys/bus/pci/devices/*; do
		[ "$(cat "$d/vendor")" = 0x10de ] || continue
		chk "dGPU ${d##*/} runtime" "$(cat "$d/power/runtime_status")" suspended
	done
fi
