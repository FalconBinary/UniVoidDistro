# hwdb: what the hardware means for the system

Every decision UniVoidDistro makes about a machine is a rule here, with its reason. `vh-plan`
reads `/etc/vh/hw.zon` (written by `vh-kconf probe`), every `*.zon` file of this directory and
the user's `vh.conf`, and writes the plan: `plan.zon` (each item with the rules that put it
there), `plan.env` (for the shell installer) and `plan-report.txt`. `vh-plan explain ITEM`
answers "why is this here". The principles are in
[docs/uni/principles.md](../docs/uni/principles.md): hardware is detected, never assumed; a
vendor, a model, a PCI or USB id, a firmware file name appears here and in the fixtures, not in
the code.

```sh
vh-plan plan --hw /etc/vh/hw.zon --hwdb hwdb --pins kernel/pins --config vh.conf.example --config vh.conf --out /tmp/vh
vh-plan explain intel-ucode --plan /tmp/vh/plan.zon --hwdb hwdb
sh tests/adapt/run.sh            # the golden plans of every machine in kernel/hw
```

| File | What |
|---|---|
| `arch.zon` | the architecture, the x86-64 levels, what every x86_64 or ARM64 machine gets |
| `cpu-intel.zon`, `cpu-amd.zon`, `cpu-arm.zon` | microcode, the IOMMU, the kernel's CPU class, `-march`, the watchdog, KVM |
| `gpu.zon` | the GPU drivers, VA-API and Vulkan, the firmware of each GPU, a dGPU that sleeps, the renderer |
| `net.zon` | Wi-Fi, Ethernet, Bluetooth: packages, services, firmware |
| `audio.zon` | HDA, the SOF DSP |
| `storage.zon` | the controllers of the disks, TRIM |
| `platform.zon` | the machine's class (laptop, desktop, server, vm, sbc), the lid and the buttons, the TPM, the camera and the card reader |
| `board.zon` | motherboards and vendors: sensors, the names of the Secure Boot menus |
| `quirks.zon` | hardware with a known problem and what is done about it |
| `security.zon` | the requirements of the security gate |

## A rule

```zon
.{
    .id = "gpu.i915.cml",                       // unique, stable: it appears in plans and reports
    .why = "Comet Lake graphics: the DMC of Kaby Lake and the GuC/HuC of Comet Lake.",
    .when = .{ .device = .{ .pci_vendor = .{"8086"}, .pci_device = .{ "9bc4", "9bc8" } } },
    .firmware_only = .{ "i915/kbl_*", "i915/cml_*" },
    .priority = 10,
},
```

**`when`**: every field that is given must hold. A list holds when any of its values matches,
except `cpu_flags` and `has`, which need all of theirs. Globs (`*`, `?`, `[...]`) where noted.

| Condition | Holds when |
|---|---|
| `arch` | the architecture is one of these (`x86_64`, `aarch64`) |
| `cpu_vendor`, `cpu_family`, `cpu_model_min`, `cpu_model_max` | the CPU of x86 (`GenuineIntel`, `AuthenticAMD`) |
| `cpu_flags` | every flag is in cpuinfo (ARM: the Features line) |
| `arm_implementer`, `arm_part` | the ARM core, as cpuinfo writes it (`0x41`, `0xd0b`) |
| `dt_compatible` | the machine's device tree has a compatible string matching a glob |
| `dmi` | `.{ .field = "board_vendor", .any = .{"ASUSTeK*"} }`: a DMI field matches a glob |
| `acpi_table` | an ACPI table with this signature exists (`DMAR`, `IVRS`, `IORT`) |
| `has`, `lacks` | every tag of `has` is present, none of `lacks` |
| `ram_min_mib`, `ram_max_mib`, `cpus_min`, `cpus_max` | the memory the kernel sees, the possible CPUs |
| `config` | `.{ .key = "VH_GPU", .any = .{ "auto", "igpu" } }`: a value of vh.conf |
| `device` | at least one device satisfies every field of it: `bus`, `pci_vendor`, `pci_device`, `pci_class` (a hex prefix), `usb_vendor`, `usb_product`, `usb_class` (the interface class), `acpi_id`, `dt_compatible`, `modalias` (glob), `module` (glob: the bound module or any the stock kernel's tables name for it), `driver` (glob), `boot_vga` |

`unless` takes the same conditions: the rule does not apply when they all hold.

**Effects** (lists are merged over every rule that applies, and each item keeps the ids of its
rules): `packages`, `kconfig` (a fragment of `kernel/profiles/class/`), `features` (a kernel
feature of `kernel/profiles/features/`), `firmware` (patterns
under `/usr/lib/firmware`), `firmware_only` (the firmware of the matched devices' modules,
narrowed to these patterns; the rule of the highest `priority` wins for a module),
`firmware_none` (the matched devices' modules keep no firmware), `cmdline`,
`services`, `udev` (files of `rootfs/etc/udev/rules.d` installed only when named), `deny`
(modules), `dracut` (initrd drivers), `modules` (needed although no device names them),
`sets` (tags), `note`, `set` (scalars: `.{ .key = "march", .value = "skylake" }`; the higher
`priority` wins, equal priorities with different values are a reported conflict), `export`
(a property of the first matched device, for the installer: `.{ .key = "DGPU_VENDOR", .from = "pci_vendor" }`).

Scalars the system reads: `class` (laptop, desktop, server, vm, sbc), `march` (the kernel's
`-march` when it is built elsewhere: the CPU model's on real hardware, the x86-64 level or
`armv8-a` in a virtual machine, [docs/uni/kernel.md](../docs/uni/kernel.md#-march)),
`renderer` (gles2, pixman), `watchdog`, `luks_cipher`, `luks_memory`.

The modules of a device are what the running system bound, or, without a driver, what the
pinned tables of the stock kernel (`kernel/pins`) name for its modalias. The firmware kept is,
for every module of the machine's devices after the deny list, the files the module names
(`kernel/pins/modules.firmware`), unless a `firmware_only` rule narrows them, plus every
`firmware` pattern of the rules that apply. A machine UKI's initrd carries every kept file
except those of the rules whose id ends in `.microcode` (`cpu.intel.microcode`, ...): dracut's
early cpio carries the CPU's own microcode file (`vh-kconf install`, [kernel/README.md](../kernel/README.md#install)).

## Tags

Rules set tags with `sets`; the conditions `has` and `lacks` read them. The tags are settled
before any effect: each pass starts from the built-in tags and adds what the rules set, until
nothing changes (a rule whose `unless` or `lacks` undoes the tag of another is reported as a
cycle). The built-in tags come from hw.zon alone:

| Tag | When |
|---|---|
| `efi`, `efi64` | booted through UEFI; 64-bit UEFI |
| `secure-boot`, `secure-boot-on`, `setup-mode`, `mor` | the SecureBoot variable exists; it is on; the firmware is in Setup Mode; the MOR variable exists |
| `tpm`, `tpm2` | a TPM; a TPM 2.0 |
| `iommu-active` | the probed kernel drives an IOMMU |
| `acpi`, `devicetree`, `sys-hypervisor` | the firmware describes the machine with ACPI tables; with a device tree; /sys/hypervisor names a hypervisor (Xen) |
| `smt`, `hybrid`, `numa`, `multi-llc`, `epp` | SMT is on; P and E cores; several NUMA nodes; several last-level caches; cpufreq offers EPP |
| `battery`, `mains`, `usb-power`, `backlight`, `platform-profile` | power supplies, a backlight, ACPI platform profiles |
| `wifi`, `wired` | a wireless, a wired network interface backed by a device |
| `disk`, `disk-discard`, `disk-rotational` | a disk; a fixed disk that accepts discard; a spinning one (virtio excepted) |
| `disk-BUS`, `disk-on-MODULE` | a disk on that bus (`nvme`, `ata`, `usb`, `mmc`, `virtio`, `scsi`); a disk with that module on the way to it (`disk-on-vmd`) |
| `keyboard`, `keyboard-i8042`, `keyboard-usb`, `keyboard-i2c` | a keyboard, by bus |
| `sound`, `display`, `displays-2` | a sound card; a display controller; two PCI ones |

The rules of this directory add: `x86-64-v2`, `x86-64-v3`, `x86-64-v4`, `vm`, `laptop`,
`server`, `sbc`, `lid`, `power-button`, `power-button-fixed` (the fixed ACPI button alone),
`iommu`, `bluetooth`, `camera`, `cardreader`, `dgpu`.

## Requirements (`security.zon`)

```zon
.{ .id = "tpm2", .why = "...", .when = .{ .has = .{"tpm2"} }, .risk = "...", .fix = "..." },
```

A requirement is met when `when` holds; `only` limits it to some machines (an architecture);
`floor = true` refuses the machine in any mode; `otherwise` sets scalars in tiered mode when it
is not met. `VH_SECURITY=strict` (the default) refuses a machine that misses any requirement;
`tiered` installs it with every missing requirement in `acknowledge`, which the installer makes
the user confirm by typing.

## Adding hardware

1. `vh-kconf probe --save DIR` on the machine; commit the snapshot as
   `tests/kernel/fixtures/NAME` and its `hw.zon` as `kernel/hw/NAME.zon`.
2. `vh-plan plan` on it: `plan-report.txt` lists the devices no driver, table or rule knows,
   and the modules whose firmware is not narrowed.
3. Write the rules, each with its reason and [VERIFY] where it is not checked on hardware;
   `sh tests/adapt/run.sh --update` writes the golden plan, and the diff of every other
   machine's plan shows what the rule changed elsewhere.
