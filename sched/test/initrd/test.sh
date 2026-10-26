#!/bin/sh
# vh-sched: the sched_ext tests inside the QEMU VM (6.18.57, lockdown=confidentiality).
# S1's checks (the lint, the lockdown probe, an error from BPF, sysrq-S, BPF_LINK_DETACH, the
# load cycles) and v1's: the topology the loader sees, the scheduler under load with the
# per-LLC counters, the interactive path, `run` ending when the kernel ends the scheduler.
echo "=== state before"
/vh-sched state
echo "=== topology"
/vh-sched topology
echo "=== lint"
/vh-sched lint /bpf/vh_sched.o
echo "=== lockdown: a program that needs bpf_probe_read_kernel must be refused"
/vh-sched load /bpf/lockdown_probe.o --hold 0 2>&1 | tail -6
echo "=== load 1: the scheduler under a CPU load, 4 s, stats every second (verbose: every step and the verifier logs)"
yes > /dev/null &
y1=$!
yes > /dev/null &
y2=$!
/vh-sched load /bpf/vh_sched.o --hold 4 --stats --verbose --log-level 1
kill $y1 $y2
echo "=== load 2: more runners than CPUs, an interactive one among them (a loop that sleeps)"
i=0; pids=""
while [ $i -lt 8 ]; do yes > /dev/null & pids="$pids $!"; i=$((i+1)); done
( while :; do sleep 0.01; done ) &
pids="$pids $!"
/vh-sched load /bpf/vh_sched.o --hold 5 --stats 5
kill $pids
echo "=== load 3: an error raised from BPF at the 20th enqueue (cfg.fail_after through the frozen .rodata)"
yes > /dev/null &
y1=$!
/vh-sched load /bpf/vh_sched.o --hold 8 --set cfg.fail_after=20
kill $y1
echo "=== load 4: run (the service form) ends with 1 when the kernel ends the scheduler"
/vh-sched run --object /bpf/vh_sched.o --set cfg.fail_after=30 --stats 1 &
rp=$!
yes > /dev/null &
y1=$!
wait $rp
echo "run exit $?"
kill $y1
echo "=== load 5: sysrq S after 2 s with kernel.sysrq=256 (the RTNICE group that holds the sched_ext keys)"
echo 256 > /proc/sys/kernel/sysrq
/vh-sched load /bpf/vh_sched.o --hold 6 --sysrq-after 2
echo "=== load 6: BPF_LINK_DETACH after 2 s (does the link fd report EPOLLHUP?)"
/vh-sched load /bpf/vh_sched.o --hold 6 --detach-after 2
echo "=== load 7: 30 load/unload cycles"
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
