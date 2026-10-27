# tests/kernel: vh-kconf

```sh
sh tests/kernel/run.sh              # the unit tests of kernel/ in an Alpine container, plus a smoke run
sh tests/kernel/oracle.sh           # the GF63 oracle: resolve gives what void-hardperf-light gives
sh tests/kernel/matrix.sh           # every machine, x86_64 and aarch64: plan (tiered) and resolve, the checks without a kernel tree
sh tests/kernel/dracut_test.sh      # vh-kconf install with Void's dracut, in a container (network: Void's mirror)
python3 tests/kernel/mkfixture.py   # rewrites the synthesised fixtures from tests/kernel/machines/
```

`run.sh` cross-builds the test binary for Linux (the host's architecture) and runs it in a
container, because Zig cannot run Linux binaries on the Mac; on a Linux host `zig build test`
in `kernel/` does the same. The files the tests read are streamed into the container with
tar: Docker Desktop on macOS refuses to read bind-mounted files that carry the
`com.apple.provenance` attribute ("Resource deadlock would occur"), which files written from
the Claude app carry. `COPYFILE_DISABLE=1` keeps macOS tar from adding AppleDouble (`._name`)
files for those attributes; the probe skips dot entries anyway.

## The fixtures

A fixture is a sysfs/procfs snapshot with the shape `vh-kconf probe --save DIR` produces:
`sys/bus/BUS/devices/NAME` symlinks to the real device directories under `sys/devices/`, each
with its `modalias` and a `driver` symlink into `sys/bus/BUS/drivers/`, where a `module`
symlink names the module; the CPUs with their topology, caches and cpufreq policies;
`sys/class/{dmi,tpm,net,block,power_supply,backlight,drm,sound,iommu}`; `sys/firmware/{efi,acpi/tables,devicetree}`;
`proc/{cpuinfo,meminfo,modules,mounts,bus/input/devices,sys/kernel/{osrelease,arch}}`. A snapshot
holds only what the probe keeps: no serial number, no MAC address, no UUID (cpuinfo without a
board's Serial line, mounts with the file system types only, input devices without Phys and
Uniq lines, ACPI tables as empty files named by signature).

| Fixture | Machine | Source |
|---|---|---|
| `gf63` | MSI GF63 Thin 10SCXR: i5-10500H, UHD 630 + GTX 1650 (no driver), AX201, RTL8111, NVMe, fTPM | synthesised, `machines/gf63.py` |
| `amd-desktop` | ASUS TUF GAMING B650-PLUS WIFI: Ryzen 9 7950X3D (two CCDs, 96 + 32 MB L3), Raphael iGPU + RX 7600 (boot VGA), RTL8125, MT7922, NVMe + SATA HDD, USB keyboard, fTPM, IVRS | synthesised, `machines/amd_desktop.py` |
| `intel-hybrid-laptop` | Dell XPS 13 9320: i7-1260P (4P + 8E), Iris Xe, AX211, SOF audio, Thunderbolt 4, NVMe behind VMD, PTT, DMAR | synthesised, `machines/intel_hybrid_laptop.py` |
| `qemu-q35` | the rig of `tests/vm` at installation time: q35, OVMF in Setup Mode, swtpm CRB, intel-iommu, the EPYC-Milan CPU that `vhvm.py` pins, 4 GiB, NVMe, e1000, virtio-vga | `kernel/hw/qemu-q35.zon` **real**: the rig's own `/etc/vh/hw.zon` from `kvm-smoke` (run 39342292948, 2026-10-20, under KVM); the tree for the probe tests is still synthesised, `machines/qemu_q35.py` |
| `aarch64-virt` | a Linux VM on Apple's Virtualization framework (colima): Apple CPU cores, UEFI without Secure Boot, no TPM, no IOMMU, virtio disks and network | **real**: `vh-kconf probe --save` in the colima VM, 2026-10-19 |
| `rpi5` | Raspberry Pi 5 Model B: BCM2712 (Cortex-A76 with crypto), RP1, CYW43455 on SDIO, v3d + vc4, SD card, no UEFI, no ACPI, no TPM | synthesised, `machines/rpi5.py` |

Every synthesised fixture is **[VERIFY]**: its IDs are public ones of that hardware and its
drivers those of the stock kernel (`kernel/pins`), but nothing was read from the machine.
`doas vh-kconf probe --save DIR` on a real one gives the snapshot that replaces it (and its
module in `machines/`); the GF63's is a step of `docs/runbook-gf63.md`; the rig's hw.zon at
installation is printed by the `kvm-smoke` workflow (`build-vm-probe.log`, `/etc/vh/hw.zon`). A machine of your own: [docs/uni/hardware.md](../../docs/uni/hardware.md#adding-a-machine).

## What the tests assert

`kernel/src/*.zig`, the `test` blocks: the probe reads every bus, driver and module link, the
CPU and its topology (SMT siblings, last-level caches, the core types of a hybrid CPU), the
memory, DMI, EFI and its variables, the TPM, the ACPI table signatures, the IOMMU units, the
device tree, the disks with the drivers up to their controller (an NVMe namespace under
multipath through its subsystem's controller, a disk behind VMD), the network interfaces,
power supplies, backlights, displays with `boot_vga` and their connectors (a virtio GPU on its
PCI function), keyboards with the chain of drivers the initrd needs, sound cards; writes no
serial number; and survives a `--save` round trip. resolve maps the GF63's Wi-Fi, Ethernet,
Bluetooth, touchpad, audio and TPM to the right stock modules against the pinned
`modules.alias`, keeps the loaded modules, leaves out the built-in drivers, refuses nouveau,
mei, the tiny power button and the modules of unselected features, and reports the conflicts
between hardening and the game feature.

install (`install.zig`, `uki.zig`): SHA256SUMS and BUILD, the release a bzImage's header reports,
PE sections and the names of an early cpio (untrusted data: cut or lying files stay in bounds),
the machine command line (module_blacklist= and module.* without modules, the parameters of
modules the kernel lacks, modprobe.d's options of built-in modules, init's arguments last), dracut's
compressor against the final `.config`, the plan's firmware without the microcode, the number of
an install, and an install end to end under `--root` with stand-ins for dracut and
vh-limine-update: the arguments dracut gets, the UKI on the ESP, `--new`, the record, the second
install as `_2`, a failed `--new` that removes the UKI; refused: another machine, another probe,
a damaged file, a run without `modules.builtin`, an initrd the kernel cannot unpack, no stock UKI.
`dracut_test.sh` runs the same install with Void's dracut (dracut, dracut-uefi,
systemd-boot-efistub, binutils, cryptsetup from the mirror) and lists the UKI's initrd with
lsinitrd: the firmware at `usr/lib/firmware`, `lib` a link to `usr/lib`, no module, the crypt
module, `.linux` the bzImage byte for byte. On Apple Silicon the UKI is an aarch64 one (dracut
takes `linuxaa64.efi.stub` when the configured x64 stub is missing, and there is no microcode).

`oracle.sh` holds the GF63 to void-hardperf-light: `tests/kernel/golden/gf63` is the LSMOD list,
the fragment's symbols and the sorted `.config` that upstream's resolve and profiles give for
`kernel/hw/gf63.zon`.

`matrix.sh` is the cheap half of the CI matrix ([docs/uni/kernel.md](../../docs/uni/kernel.md#the-ci-matrix)):
every machine of `kernel/hw`, x86_64 and aarch64, planned in tiered mode and resolved with its
plan against the pins of its architecture, twice;
the same bytes both times, every symbol a class of the plan sets known to the pinned config,
no fragment conflict with a class or the machine fragment, the build's invariants in the
requested `.config`, `NR_CPUS` within the pinned range, and the plan's `-march` in `kcflags`,
accepted by clang where there is one. The results stay in `build/km/MACHINE`.
