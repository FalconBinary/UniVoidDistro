# sched/test: the rig of spike S1

Everything here reproduces [docs/spikes/S1.md](../../docs/spikes/S1.md) from a Mac with
colima (any Linux box with clang, lld and pahole does as well). The work directory is
`$VHL_S1`, by default `~/.cache/vhl-s1`; inside colima the Mac's home is mounted at the
same path, so pass the Mac path explicitly there.

| File | What |
|---|---|
| `frag-common.config`, `frag-arm64.config`, `frag-x86_64.config` | the smallest 6.18 configuration that boots under QEMU with sched_ext, BTF and lockdown: `allnoconfig` + these fragments |
| `build-kernel.sh ARCH` | builds linux-6.18.57 from `~/k/linux-6.18.57` (in colima) with LLVM, copies `Image`/`bzImage`, the `.config` and the vmlinux BTF into `$VHL_S1` |
| `prep.sh` | toolchain versions, the 6.18 uapi headers, `uapi_sizes.c` -> the numbers `zig/lib/bpf_uapi.zig` asserts, the 6.8 BTF ids of the colima kernel |
| `uapi_sizes.c`, `uapi-sizes-6.18.57.txt` | the offsets and constants of the 6.18 `union bpf_attr`, measured |
| `mkinitrd.py DIR OUT.gz` | a newc cpio initramfs, gzip-compressed |
| `initrd/init`, `initrd/test.sh` | the init of the test initramfs (busybox) and the test sequence: lint, the lockdown probe, the scheduler under load, an error from BPF, sysrq-S, BPF_LINK_DETACH, 30 load/unload cycles |
| `run-vm.sh ARCH [kernel args]` | assembles the initramfs from `$VHL_S1/out-ARCH` (vh-sched and the .o files) and busybox, boots the kernel under QEMU (hvf for arm64, TCG for x86_64) with `lockdown=confidentiality`, keeps the serial log in `$VHL_S1/serial-ARCH.log` |
| `test-colima.sh` | the loader mechanics on colima's 6.8 kernel through `tcp_congestion_ops` (as root) |

```sh
# once, in colima: the toolchain and the source
colima ssh -- sudo apt-get install -y clang lld llvm make flex bison bc libssl-dev libelf-dev dwarves linux-tools-common
colima ssh -- sh -c 'mkdir -p ~/k && cd ~/k && curl -fsSLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.57.tar.xz && tar -xJf linux-6.18.57.tar.xz'
# the kernels (about 7 minutes each on 4 cores)
colima ssh -- env VHL_S1=/Users/$USER/.cache/vhl-s1 /Users/$USER/Documents/systems/void-hardperf-light/sched/test/build-kernel.sh arm64
colima ssh -- env VHL_S1=/Users/$USER/.cache/vhl-s1 /Users/$USER/Documents/systems/void-hardperf-light/sched/test/build-kernel.sh x86_64
# busybox (static) for the initramfs: busybox-static from Alpine, unpacked into $VHL_S1/busybox/{aarch64,x86_64}/bin/busybox.static
# vh-sched and the objects
(cd sched && zig build -Dtarget=aarch64-linux --prefix ~/.cache/vhl-s1/out-arm64 && zig build -Dtarget=x86_64-linux --prefix ~/.cache/vhl-s1/out-x86_64)
# the VMs
sched/test/run-vm.sh arm64
sched/test/run-vm.sh x86_64
# the loader mechanics without sched_ext (colima, 6.8)
colima ssh -- sudo env VHL_S1=/Users/$USER/.cache/vhl-s1 /Users/$USER/Documents/systems/void-hardperf-light/sched/test/test-colima.sh
```
