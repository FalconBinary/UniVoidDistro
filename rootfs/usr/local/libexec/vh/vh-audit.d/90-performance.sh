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
# the power profile of vh-power: EPP where the frequency driver offers it (intel_pstate,
# amd-pstate-epp), the ACPI platform profile where the firmware offers one
st=$(cat /run/vh/power 2>/dev/null || echo ?)
cf=/sys/devices/system/cpu/cpufreq/policy0
if [ -e "$cf/energy_performance_preference" ]; then
	epp=$(cat "$cf/energy_performance_preference")
	case $st:$epp in ac:balance_performance|battery:balance_power) ok "EPP $epp ($st)" ;; *) unk "EPP $epp while on $st power" ;; esac
else
	unk "EPP: the frequency driver $(cat "$cf/scaling_driver" 2>/dev/null || echo '(none)') offers none"
fi
pp=/sys/firmware/acpi/platform_profile
if [ -e "$pp" ]; then
	case $st in ac) want=balanced ;; *) want="low-power quiet balanced" ;; esac
	for w in $want; do
		case " $(cat "${pp}_choices") " in *" $w "*) chk "platform profile ($st)" "$(cat "$pp")" "$w"; break ;; esac
	done
fi
# the dGPU, a display controller that did not bring the console up, whatever its vendor:
# asleep where the plan says so (the tag dgpu, set by a rule of hwdb/gpu.zon)
case " $(sed -n "s/^VH_PLAN_TAGS='\(.*\)'\$/\1/p" /root/vh/plan.env 2>/dev/null) " in *" dgpu "*)
	for d in /sys/bus/pci/devices/*; do
		case $(cat "$d/class") in 0x03*) ;; *) continue ;; esac
		[ "$(cat "$d/boot_vga" 2>/dev/null)" = 1 ] && continue
		chk "dGPU ${d##*/} runtime" "$(cat "$d/power/runtime_status")" suspended
	done ;;
esac
