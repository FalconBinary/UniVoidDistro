#!/bin/sh
# vh-sched spike S1: toolchain versions, 6.18 uapi headers, the sizes bpf_uapi.zig asserts, 6.8 BTF ids
set -u
cache=${VHL_S1:-$HOME/.cache/vhl-s1}
echo "=== versions"; pahole --version; clang --version | head -1; ld.lld --version | head -1; bpftool version 2>&1 | head -1; uname -r
cd "$HOME/k/linux-6.18.57" || exit 1
if [ ! -f "$HOME/k/hdr/include/linux/bpf.h" ]; then
  make -s O="$HOME/k/hdr-install" ARCH=arm64 headers_install INSTALL_HDR_PATH="$HOME/k/hdr" >/tmp/hdr.log 2>&1 || { tail -5 /tmp/hdr.log; exit 1; }
fi
echo "=== uapi sizes (6.18.57)"
clang -I "$HOME/k/hdr/include" -o /tmp/uapi_sizes "$cache/uapi_sizes.c" && /tmp/uapi_sizes | tee "$cache/uapi-sizes-6.18.57.txt"
echo "=== 6.8 BTF ids (colima kernel) for the tcp_congestion_ops test"
sudo bpftool btf dump file /sys/kernel/btf/vmlinux 2>/dev/null | grep -E "STRUCT 'bpf_struct_ops_tcp_congestion_ops'|STRUCT 'tcp_congestion_ops'|FUNC 'tcp_reno_cong_avoid'|FUNC 'tcp_slow_start'|FUNC 'bpf_ringbuf_output'" | head
sudo bpftool btf dump file /sys/kernel/btf/vmlinux format c 2>/dev/null | grep -A 40 "^struct bpf_struct_ops_tcp_congestion_ops {" | head -60
sudo bpftool btf dump file /sys/kernel/btf/vmlinux format c 2>/dev/null | grep -A 30 "^struct tcp_congestion_ops {" | head -40
