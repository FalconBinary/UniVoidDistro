# UniVoidDistro: development plan

## Context

**What we build.** A distribution that adapts itself to the machine it is installed on and
stays, on every machine, as fast, as protected and as small as
[void-hardperf-light](https://github.com/FalconBinary/void-hardperf-light) is on the one
laptop it was written for (MSI GF63 Thin: i5-10500H, UHD 630 + GTX 1650 Max-Q, AX201,
RTL8111). void-hardperf-light already has the start of it: `vh-kconf probe` writes `hw.zon`
and `resolve` builds a kernel for that machine. Everything else names the GF63, in about 35
files:

- the kernel profiles: `DRM_I915`, `BLK_DEV_NVME`, `PINCTRL_CANNONLAKE`, intel_pstate, RAPL,
  iTCO, `NR_CPUS=12`, `-march=skylake`;
- the packages: `intel-ucode`, `linux-firmware-intel`, `intel-media-driver`;
- the firmware kept on disk (`vh_firmware_noextract`), the command line (`intel_iommu=on`),
  the network service (`dhcpcd-eth0`), the udev rules (the NVIDIA dGPU, r8169), the
  scheduler's topology (6C/12T as a build constant).

**User decisions (2026-10-19):**

| Question | Decision |
|---|---|
| hardware scope | x86_64 UEFI and ARM64. The data model and the rules cover ARM64 from U1; the ARM64 installation path is U5 |
| repository | a fork with history; void-hardperf-light is the `upstream` remote. The names `vh-*`, `/etc/vh`, `VH_*` stay |
| first session | M0 (repository, documents, scaffolding) and U1 (detect and decide) |
| protection | both policies: `VH_SECURITY=strict` is the default and refuses a machine without the full protection; `tiered` is chosen explicitly and installs with every residual risk confirmed by typing |

The upstream rules apply unchanged ([principles](principles.md) lists them and adds the rules
of adaptivity). void-hardperf-light itself is not modified by this project.

## Target architecture: detect, decide, specialise, verify

```
detect      vh-kconf probe: sysfs, procfs, the device tree -> /etc/vh/hw.zon (format 2)
            no serial numbers, MAC addresses, UUIDs; --save/--from make a snapshot a fixture
decide      vh-plan: hw.zon + hwdb/*.zon + vh.conf -> /etc/vh/plan.zon, plan.env, plan-report.txt
            every item carries the id of the rule that put it there; the security gate
specialise  the installer: packages, firmware kept, command line, denied modules, services,
                           initrd drivers, LUKS parameters
            vh-kconf resolve --plan: class fragments, NR_CPUS, -march -> the machine kernel
            later: vh-stage1, vh-power, vh-acpid, vh-deadman, vh-sched (U2-U4)
verify      the stock signed UKI always stays in Limine; a machine kernel becomes the default
            only after it has booted (U3); vh-audit shows the tier and checks the plan
```

```
UEFI (own SB keys) -> Limine (config hash enrolled)
   |- UKI "custom": this machine's kernel (drivers built in, its -march, NR_CPUS) + initrd
   |                (LUKS, the firmware of its devices, microcode)
   '- UKI "stock":  the signed stock linux6.18 (fallback, always)
 -> vh-init (PID 1) -> service manager -> vh-sched (topology read at load)
 -> tty1 user  -> RefursWM (renderer from the plan) + RefursLine
    tty2 admin
    tty3 game  -> /var/lib/vh/roots/game (GPU-vendor neutral)
```

Two kinds of adaptation:

- **runtime rules** that match attributes and cost nothing: a udev rule by `rotational` and
  transport chooses the I/O scheduler; a rule by driver turns EEE off on r8169. They are
  installed on every machine.
- **specialisation per machine** where it measurably pays: the kernel, the firmware set, the
  package set, the initrd.

| Goal | How it holds on any machine |
|---|---|
| performance | the machine kernel (drivers built in, Clang ThinLTO, the CPU's `-march`, the exact `NR_CPUS`), the CPU's own frequency driver (intel_pstate, amd-pstate-epp, CPPC on ARM), vh-sched with the real topology (SMT, LLC/CCD, P/E cores, NUMA) |
| security | the full protection of void-hardperf-light wherever the hardware allows it; strict refuses less; tiered names every gap |
| lightness | the packages, firmware files and services of the detected hardware only |
| speed | built-in drivers, a stage 1 without a shell, no waiting for absent hardware |
| optimisation | every decision a rule with a reason; `vh-plan explain ITEM` |

### The security gate

`vh-plan` derives the protective properties from `hw.zon`; the table is in
[principles](principles.md#the-protective-properties-per-architecture). With every property
present the tier is **full**. With one or more missing it is **reduced**: in `strict` mode
`vh-plan` exits with code 3 and a report that names each missing property, its residual risk
and the firmware setting that fixes it (`hwdb/board.zon`); in `tiered` mode the plan carries
the list `acknowledge` that the installer shows and makes the user confirm by typing. A
machine below the floor (no UEFI 64-bit on x86_64, less than 1 GiB) is refused in both modes.
The memory requirement follows from the protection it serves: Argon2id with 1 GiB per guess of
the LUKS passphrase needs 2 GiB, because cryptsetup gives the PBKDF at most half of the RAM.
`vh-audit` reports the tier and the acknowledged risks of the running system.

## Components

### A. `vh-plan` and `hwdb/` (new, `adapt/`)

- **Input.** `hw.zon` (format 2), the rules in `hwdb/*.zon`, the user's `vh.conf` (choices that
  are not hardware: `VH_BLUETOOTH`, `VH_CAMERA`, `VH_VIRT`, `VH_SECURITY`, `VH_GPU` when not
  `auto`, ...), the stock kernel's tables in `kernel/pins/` (`modules.alias`,
  `modules.builtin.modinfo`, `modules.firmware`).
- **Derived facts** (`adapt/src/facts.zig`): the architecture; the x86-64 level v1-v4 from
  the CPU flags; the machine class (laptop, desktop, server, vm, sbc); the GPUs and which one
  is primary (`boot_vga`); `has` (battery, lid, wifi, wired, bluetooth, tpm2, iommu, aes,
  secure_boot, efi64, backlight, discard); the RAM; the keyboard driver chains; the modules
  every device's modalias resolves to (the same `alias.zig` and the same tables as
  `resolve`, so the plan and the kernel agree).
- **A rule** has an `id`, a `why`, a `when` (every condition must hold: architecture, CPU
  vendor, flags, family, model range, x86-64 level, ARM implementer and part, device tree
  compatible, PCI vendor/device/class, USB id, ACPI id, module, a DMI field by pattern,
  machine class, hypervisor, `has`, RAM and CPU ranges; `unless` negates), list effects
  (`packages`, `kconfig` (class fragments), `firmware`, `firmware_only` (a device's narrowing
  of its module's firmware), `cmdline`, `services`, `udev`, `deny`, `dracut`, `note`) and
  scalar effects (`renderer`, `watchdog`, `zram_percent`, `luks_cipher`, ...). A scalar set
  by two rules with different values is a conflict, reported unless one rule has a higher
  `priority`.
- **The firmware set** is the union of `modules.firmware` over the modules of the plan,
  narrowed by `firmware_only` where a rule knows the device (amdgpu, i915 and iwlwifi list
  every generation they support), plus microcode and `regulatory.db`.
- **Output.** `plan.zon` (every decision with its rule id), `plan.env` (the values the shell
  installer needs, all from `hwdb/`, each single-quoted, `'` rejected: no firmware string
  reaches the shell), `plan-report.txt` (every rule that matched and why, conflicts, devices
  no rule covered, the tier). `vh-plan explain ITEM` prints the chain for one item.
- **Tests.** Golden plans for every fixture; a second run must be identical byte for byte.

### K. The kernel of any machine (track K, generalised)

- **Profiles.** `kernel/profiles/{base,mandatory,hardening,perf}` and `features/*` keep what
  every machine needs; what belongs to a hardware class moves to `kernel/profiles/class/*`
  and is chosen by the plan: `cpu-intel`, `cpu-amd`, `cpu-x86-aes`, `gpu-{i915,xe,amdgpu,
  nouveau,virtio,bochs}`, `storage-{nvme,ahci,vmd,mmc,virtio}`, `input-i8042`,
  `tpm-{crb,tis}`, `pinctrl-*`, `virt-{intel,amd}`, `bt-*`. A lost symbol of a selected class
  is an error, as for `mandatory`. `hardening` gains CET (`X86_USER_SHADOW_STACK`,
  `X86_KERNEL_IBT`): the kernel checks CPUID itself.
- **`resolve --plan`**: class fragments from the plan, `NR_CPUS` from `cpu.possible`, `KCFLAGS`
  from the plan (in CI: a model -> `-march` table, else `-march=x86-64-vN`; on the machine:
  `CONFIG_X86_NATIVE_CPU`).
- **The GF63 oracle.** `resolve` on `kernel/hw/gf63.zon` gives the same `lsmod` and `.config`
  before and after the split; the golden files are in `tests/kernel/golden/gf63/`.
- **Where the kernel is built (U3).** Locally in `/var/lib/vh/roots/kbuild` (already allowed
  by the upstream principles: compilers only there, 0700 root): namespaces, no network,
  Landlock on the build directory, `SCHED_IDLE`, `-j` by cores and memory, ThinLTO only with
  enough memory [VERIFY]. Or in CI from a committed `hw.zon`, as upstream does for the GF63.
- **Boot assessment (U3).** `vh-limine-update` makes a new machine UKI the default only after
  it has booted successfully N times; the stock UKI is never removed or demoted.
- **ARM64 (U5).** The pins of Void's arm64 `linux6.18` (`.config`, `modules.*`), the arm64
  profiles, `-mcpu` by core.

### U2. Runtime adaptation

- udev rules by attributes: the I/O scheduler (NVMe and virtio: `none`; SATA SSD:
  `mq-deadline`; HDD and eMMC: `bfq`) [VERIFY by measurement per class].
- `vh-power` for every EPP driver (intel_pstate, amd-pstate-epp), `platform_profile`, the dGPU
  of any vendor (the non-boot display device) instead of NVIDIA by vendor id.
- `optional/deadman`: the watchdog of the board: iTCO, sp5100_tco, sbsa, softdog as the
  weaker fallback (a row in the cost table).
- `vh-backlight`: the right interface when there are several; `vh-acpid`'s
  `INTERNAL_INPUT` from the probe.
- `vh-kconf check` at boot: a modalias without a driver, firmware that failed to load, or a
  different machine (CPU model, DMI board) -> a message at the admin login and a new plan.
- `vh-audit.d`: an area for the plan and the tier.

### U4. A scheduler for any topology

The `vh-sched` loader reads the topology at load time and fills BPF maps (SMT siblings, the
LLC of each CPU, CCDs, P/E core capacity, NUMA nodes, the V-Cache CCD of an X3D part), so one
BPF object serves every machine with no compile-time constants. Tests on QEMU topologies
(`-smp sockets,dies,clusters,cores,threads`); hybrid and X3D [VERIFY on hardware].

### U5. ARM64 installation

- UEFI ARM machines (servers, laptops): Limine for aa64, a UKI on `linuxaa64.efi.stub`
  [VERIFY: Void's systemd-boot-efistub for aarch64], Secure Boot with our keys, TPM where
  present.
- Raspberry Pi 4/5: the Pi firmware boots the kernel. `strict` is possible only with the Pi's
  own secure boot, whose key goes into OTP **irreversibly**: a runbook and an explicit
  agreement, never automatic. Otherwise `tiered` with "the boot chain is not verified".

### U6. Our own live image

void-mklive images for x86_64 and aarch64 with a current stock kernel, the Zig tools and the
installer. The official Void image (20250202) does not know new hardware (Wi-Fi 7, new GPUs
and NICs), and the installer needs the network to fetch packages.

### Shared tracks from upstream

I (`vh-init`), S (`vh-sched`), P (`thor` 2), N (`vh-install`), G (`vh-root`, `vh-game`), D
(RefursWM, RefursLine) come by `git merge upstream/main`. UniVoidDistro adapts them where the
hardware enters: N shows the plan and the tier and runs the gate; G is GPU-vendor neutral
(AMD, Intel, NVIDIA); D takes the renderer (GLES2 or pixman) from the plan.

## Milestones

| Milestone | Content | Depends on |
|---|---|---|
| **M0** | the fork, identity, `docs/uni/` (this plan, principles, hardware), scaffolding | — |
| **U1: detect and decide** | probe v2 (`hw.zon` format 2); fixtures of six machines (gf63, amd-desktop, intel-hybrid-laptop, qemu-q35, aarch64-virt, rpi5); `kernel/pins/modules.firmware`; `adapt/` with `vh-plan` and `hwdb/`; the kernel profiles split into classes with `resolve --plan` and the GF63 oracle; the installer takes packages, firmware, command line, denied modules, services, initrd drivers and LUKS parameters from the plan; `VH_SECURITY`; CI and the hardware-constant lint | M0 |
| **U2: runtime** | the runtime rules, `vh-power`, deadman, backlight, `vh-kconf check`, the audit area | U1 |
| **U3: the machine kernel anywhere** | the kbuild root, `-march`/native, boot assessment, the CI matrix resolve+build over every fixture | U1; upstream v0.3 (the kbuild root, thor profiles) |
| **U4: the scheduler** | topology maps in the loader | upstream S v1 |
| **U5: ARM64** | pins, profiles, the UEFI ARM path, the Raspberry Pi path | U1, U3 |
| **U6: live image** | x86_64 and aarch64 images | U1 |
| **V (continuous)** | the VM matrix, the fixture corpus from real snapshots, runbooks per vendor | — |

## Measurements

The upstream method applies (`bench/`, alternating runs, medians and p95, bootstrap CI,
"faster" only with a CI that excludes 0 and a difference of at least 3 %). Added:

- results per machine: `bench/results/<machine>/`;
- the machine kernel against the stock one per hardware class: boot time (firmware ->
  Limine -> kernel -> init -> ready), idle RAM, kernel and initrd size;
- the footprint: installed size and firmware size on the GF63 against void-hardperf-light
  (no regression from generality), and on the other fixtures;
- tuning claimed per class (I/O schedulers, zram sizes, EPP values, `-march`) only with a
  measurement on that class.

## Verification

| What | Checks |
|---|---|
| probe | round trip of format 2; probe on every fixture; `--save` then `--from` gives the same `hw.zon` |
| plan | golden plans of every fixture; determinism; strict on a reduced fixture exits 3; tiered lists the acknowledgements; `explain` |
| kernel | the GF63 oracle; `resolve --plan` on every x86_64 fixture; `diff` reports no lost class symbol; CI builds (U3) |
| installer | the package, firmware, blacklist and command-line functions against golden output per fixture; for the GF63 against the current upstream output; `bash -n`; `10-install.sh --dry-run` with a fixture plan |
| lint | no hardware constant outside `hwdb/`, `kernel/profiles/class/`, the fixtures and the pins |
| VM matrix (V) | q35 x {nvme, ahci, virtio-blk, virtio-scsi} x {virtio-net, e1000e, igb} x {virtio-gpu, bochs, qxl} x CPU {Skylake-Client, Icelake-Server, EPYC-Genoa, x86-64-v2} x {tpm-crb, tpm-tis, none} x {SB on, off} x RAM {2G, 8G}: installs and boots, or is refused exactly as expected; SeaBIOS: refused; aarch64 virt |
| real hardware | runbooks; `probe --save` snapshots become fixtures |

## Honest success criteria

- Every cell of the VM matrix installs and boots, or is refused exactly as the gate says.
- The plan is deterministic and every item in it has a rule and a reason.
- On the GF63 the packages, firmware, command line and kernel configuration match
  void-hardperf-light (the differences are listed), and the installation is no bigger.
- On other hardware the firmware on disk is that of the bound drivers plus microcode.
- Unknown hardware never yields an unbootable system: the stock UKI and the stock drivers
  remain.
- "Any hardware" is a goal checked per class of hardware, not a promise.

## Risks

| Risk | Answer |
|---|---|
| the variety of hardware is endless | rules per class, not per model; the fixture corpus grows from real snapshots; unknown devices are reported, never fatal |
| a synthesised fixture is wrong | [VERIFY] on each; replaced by `probe --save` from a real machine (the q35 one from `kvm-smoke`; aarch64-virt is real from the start) |
| a machine kernel without modules meets a new class of hotplugged device | feature bundles (`usb-common`, later `usb-net`), the stock UKI, `vh-kconf check` |
| built-in drivers need firmware before the initrd is unpacked | inherited [VERIFY] of upstream track K; else `EXTRA_FIRMWARE` per plan |
| Secure Boot with our own keys on unknown firmware | Option ROM hashes from the TPM event log (`20-firstboot.sh`); per-vendor menu names in `board.zon`; strict refuses a machine without a TPM event log |
| ARM boards without UEFI or TPM | tiered only; the Pi's OTP key only by an explicit runbook |
| merge conflicts with upstream | own files in new paths; shared files edited only where hardware enters |
| `std.zon`, Zig 0.17 regressions | the same as upstream: pinned Zig, move to 0.17.1 when out |
| the Mac has little free space | heavy work (kernels, the VM matrix) in CI; caches cleaned |

## Rules for the executing sessions

- Directory: `~/Documents/systems/UniVoidDistro`; void-hardperf-light is read, never written
  (`upstream` has no push URL).
- One logical step is one commit on `main`. Pushing needs the GitHub repository
  `FalconBinary/UniVoidDistro` and the user's confirmation; until then CI does not run.
- Code: the upstream rules of `zig/README.md`; documentation and program output in English.
- Nothing destructive on a real machine from a session: runbooks only.
