#!/bin/sh
# vh-sched spike S1: boot the test kernel of ARCH under QEMU with an initramfs that holds
# busybox, vh-sched and the BPF objects, run /test.sh, keep the serial log.
#   run-vm.sh arm64 | x86_64 [extra kernel arguments]
set -eu
arch=$1
shift
cache=${VHL_S1:-$HOME/.cache/vhl-s1}
mk=$(dirname "$0")/mkinitrd.py
case $arch in
  arm64) bb=aarch64; out=$cache/out-arm64; img=$cache/Image-arm64-6.18.57 ;;
  x86_64) bb=x86_64; out=$cache/out-x86_64; img=$cache/bzImage-x86_64-6.18.57 ;;
esac
d=$cache/initrd-$arch
rm -rf "$d"
mkdir -p "$d/bin" "$d/bpf" "$d/proc" "$d/sys" "$d/dev"
cp "$cache/busybox/$bb/bin/busybox.static" "$d/bin/busybox"
ln -s busybox "$d/bin/sh"
cp "$cache/initrd/init" "$d/init"
cp "$cache/initrd/test.sh" "$d/test.sh"
cp "$out/bin/vh-sched" "$d/vh-sched"
cp "$out"/bpf/*.o "$d/bpf/"
chmod +x "$d/init" "$d/test.sh" "$d/vh-sched" "$d/bin/busybox"
python3 -I "$mk" "$d" "$cache/initrd-$arch.gz"
log=$cache/serial-$arch.log
rm -f "$log"
case $arch in
  arm64)
    qemu-system-aarch64 -M virt -accel hvf -cpu host -smp 4 -m 1024 -display none -monitor none \
      -serial "file:$log" -kernel "$img" -initrd "$cache/initrd-$arch.gz" \
      -append "console=ttyAMA0 lockdown=confidentiality $*" -no-reboot ;;
  x86_64)
    qemu-system-x86_64 -M q35 -accel tcg,thread=multi -cpu max -smp 4 -m 1024 -display none -monitor none \
      -serial "file:$log" -kernel "$img" -initrd "$cache/initrd-$arch.gz" \
      -append "console=ttyS0 lockdown=confidentiality $*" -no-reboot ;;
esac
echo "=== serial log: $log ($(wc -l < "$log") lines)"
