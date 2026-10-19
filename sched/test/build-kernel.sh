#!/bin/sh
# vh-sched spike S1: build a small 6.18.57 test kernel inside colima.
#   build-kernel.sh arm64 | x86_64
set -eu
arch=$1
src=$HOME/k/linux-6.18.57
out=$HOME/k/b-$arch
cache=${VHL_S1:-$HOME/.cache/vhl-s1}
mkdir -p "$out"
cat "$cache/frag-common.config" "$cache/frag-$arch.config" > "$out/frag"
cd "$src"
make O="$out" ARCH="$arch" LLVM=1 allnoconfig
scripts/kconfig/merge_config.sh -O "$out" -m "$out/.config" "$out/frag"
make O="$out" ARCH="$arch" LLVM=1 olddefconfig
echo "=== key symbols"
grep -E '^CONFIG_(SCHED_CLASS_EXT|EXT_GROUP_SCHED|DEBUG_INFO_BTF|BPF_JIT|BPF_SYSCALL|SECURITY_LOCKDOWN_LSM|LSM|VIRTIO_BLK|VIRTIO_PCI|SERIAL_AMBA_PL011_CONSOLE|SERIAL_8250_CONSOLE|9P_FS|NET_9P_VIRTIO|MAGIC_SYSRQ|PCI_HOST_GENERIC|TCP_CONG_ADVANCED|ACPI|SMP|NR_CPUS|PREEMPT|IKCONFIG_PROC)=' "$out/.config" || true
echo "=== missing"
for s in SCHED_CLASS_EXT DEBUG_INFO_BTF BPF_JIT SECURITY_LOCKDOWN_LSM VIRTIO_BLK MAGIC_SYSRQ; do
  grep -q "^CONFIG_$s=y" "$out/.config" || echo "MISSING CONFIG_$s"
done
case $arch in
  arm64) img=Image ;;
  x86_64) img=bzImage ;;
esac
date
make O="$out" ARCH="$arch" LLVM=1 -j"$(nproc)" "$img" > "$cache/make-$arch.log" 2>&1 || { echo "MAKE FAILED"; tail -40 "$cache/make-$arch.log"; exit 1; }
date
grep -E "error|warning: .*BTF|pahole|BTF" "$cache/make-$arch.log" | tail -20 || true
ls -l "$out/arch/$arch/boot/$img" "$out/vmlinux"
cp "$out/arch/$arch/boot/$img" "$cache/$img-$arch-6.18.57"
cp "$out/.config" "$cache/config-$arch-6.18.57"
llvm-objcopy --dump-section .BTF="$cache/vmlinux-$arch-6.18.57.btf" "$out/vmlinux" /dev/null || true
ls -l "$cache"
echo "BUILD_DONE $arch"
