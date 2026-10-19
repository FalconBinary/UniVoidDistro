#!/bin/sh
# vh-sched spike S1: the loader mechanics on colima's 6.8 arm64 kernel through tcp_congestion_ops
out=${VHL_S1:-$HOME/.cache/vhl-s1}/out-arm64
echo "=== kernel $(uname -r), lockdown: $(cat /sys/kernel/security/lockdown)"
echo "=== lint vh_sched.o"
$out/bin/vh-sched lint $out/bpf/vh_sched.o
echo "=== lint tcp_ca_probe.o"
$out/bin/vh-sched lint $out/bpf/tcp_ca_probe.o
echo "=== before: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
$out/bin/vh-sched load $out/bpf/tcp_ca_probe.o --ops tcp_congestion_ops --hold 4 --stats --verbose --detach-after 3 &
pid=$!
sleep 2
echo "=== while loaded: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
wait $pid
echo "=== loader exit $?"
echo "=== after: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
dmesg 2>/dev/null | tail -5
