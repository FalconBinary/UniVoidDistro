#!/bin/sh
# vh-sched spike S1: the sched_ext tests inside the QEMU VM (6.18.57, lockdown=confidentiality)
echo "=== state before"
/vh-sched state
echo "=== lint"
/vh-sched lint /bpf/vh_sched.o
echo "=== lockdown: a program that needs bpf_probe_read_kernel must be refused"
/vh-sched load /bpf/lockdown_probe.o --hold 0 2>&1 | tail -6
echo "=== load 1: the scheduler under a CPU load, 4 s, stats every second (verbose: every step and the verifier logs)"
yes > /dev/null &
y1=$!
yes > /dev/null &
y2=$!
/vh-sched load /bpf/vh_sched.o --hold 4 --stats --verbose --log-level 2
kill $y1 $y2
echo "=== load 2: an error raised from BPF at the 20th enqueue (cfg.fail_after through the frozen .rodata)"
yes > /dev/null &
y1=$!
/vh-sched load /bpf/vh_sched.o --hold 8 --set cfg.fail_after=20
kill $y1
echo "=== load 3: sysrq S after 2 s with kernel.sysrq=256 (the RTNICE group that holds the sched_ext keys)"
echo 256 > /proc/sys/kernel/sysrq
/vh-sched load /bpf/vh_sched.o --hold 6 --sysrq-after 2
echo "=== load 4: BPF_LINK_DETACH after 2 s (does the link fd report EPOLLHUP?)"
/vh-sched load /bpf/vh_sched.o --hold 6 --detach-after 2
echo "=== load 5: 30 load/unload cycles"
i=0
fails=0
while [ $i -lt 30 ]; do
  /vh-sched load /bpf/vh_sched.o --hold 0 >/dev/null 2>&1 || fails=$((fails+1))
  i=$((i+1))
done
echo "cycles: $i, failures: $fails"
/vh-sched state
echo "=== dmesg (sched_ext)"
dmesg | grep -i "sched_ext\|scx\|lockdown" | tail -30
