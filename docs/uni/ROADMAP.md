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
            runtime (U2): udev rules by attributes, vh-power, vh-acpid's built-in input,
            the deadman's watchdog, vh-backlight; later vh-sched (U4)
verify      the stock signed UKI always stays in Limine; a machine kernel becomes the default
            only after it has booted (U3); vh-kconf check at boot compares the machine with
            hw.zon (U2); vh-audit shows the tier and checks the plan (U2)
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
machine below the floor (no UEFI 64-bit on x86_64, less than 1.5 GiB of memory) is refused in
both modes. The memory floor is the installation's: from our live image (U6), which brings the
programs built, it peaks at about 1.4 GiB with Argon2id at 1 GiB and near 0.7 GiB with Argon2id
at a quarter of the RAM. Building the programs in the live system's RAM, on Void's own image,
peaks at 2.1 GiB (the RefursWM build; measured on the VM rig, kvm-smoke run 39310221609, with the
RAM the installer prints at every step): the installer refuses that below 3 GiB. The protection
asks for 2 GiB: Argon2id with 1 GiB per guess of the LUKS passphrase, because cryptsetup gives
the PBKDF at most half of the RAM; `tiered` below that gives it a quarter of the RAM.
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
  from the plan (in CI: a model -> `-march` table, else `-march=x86-64-vN`, and always the
  level in a virtual machine; on the machine: `CONFIG_X86_NATIVE_CPU`,
  [kernel.md](kernel.md#-march)). Every x86_64 machine of `kernel/hw` is resolved on every
  push and built on request ([kernel.md](kernel.md#the-ci-matrix)).
- **The GF63 oracle.** `resolve` on `kernel/hw/gf63.zon` gives the same `lsmod` and `.config`
  before and after the split; the golden files are in `tests/kernel/golden/gf63/`.
- **Where the kernel is built (U3).** Locally in `/var/lib/vh/roots/kbuild` (already allowed
  by the upstream principles: compilers only there, 0700 root): namespaces, no network,
  Landlock on the build directory, `SCHED_IDLE`, `-j` by cores and memory, ThinLTO only with
  enough memory [VERIFY]. Or in CI from a committed `hw.zon`, as upstream does for the GF63.
  The local build is designed ([kernel.md](kernel.md#the-local-build-later)) and waits for
  upstream v0.3.
- **Boot assessment (U3).** `vh-limine-update` makes a new machine UKI the default only after
  it has booted successfully N times; the stock UKI is never removed or demoted. Through
  Limine's Boot Loader Interface: the trials are one-shot entries, the default is
  `LoaderEntryDefault`, limine.conf does not change at boot ([kernel.md](kernel.md#the-boot-assessment)).
- **ARM64 (U5).** The pins of Void's arm64 `linux6.18` (`.config`, `modules.*`), the arm64
  profiles, `-mcpu` by core.

### U2. Runtime adaptation

Done; [runtime.md](runtime.md) describes every piece.

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
and NICs), and the installer needs the network to fetch packages. With the programs built into
the image, the installer no longer compiles in RAM: the gate's memory floor, the installer's
and not the system's, came down from 3 GiB to 1.5 GiB. The design and the decisions:
[live-image.md](live-image.md); the x86_64 image is `live/` and the `live-image` workflow, the
aarch64 one comes with U5.

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

### State (2026-10-26, evening): the three pieces on the VM rig

The first runs of track I, track S and track E on GitHub's KVM rig (`kvm-smoke`, EPYC-Milan ×4,
the stock kernel 6.18.58_1 and the machine kernel of kernel-custom run 40321559300:
`kernel/hw/qemu-q35.zon`, features `auto,selinux`, `CONFIG_SCHED_CLASS_EXT=y`,
`CONFIG_SECURITY_SELINUX=y`). The rig grew the steps `vhinit`, `vhinit-rollback`, `sched` and
`selinux` (`tests/vm/steps/`), a comma-separated `step` list, the input `mac` (the policy
compiled on the runner by `selinux/build.sh` and installed through `VH_SELINUX_DIR`, which
`10-install.sh` now honours), an init-aware `base`, and the input `mirror` (`VH_MIRROR` for the
installer's live environment, the dev image and the sysroot: Void's default mirror was down for
hours that evening; the live ISO step tries the mirrors of `tests/vm/void-live.pins`); the
scheduled run is unchanged.

- **vh-init as PID 1: verified** (run 40343277197, `vhinit,base,vhinit-rollback`, 98 checks;
  run 40340658992, `vhinit,sched`, 66 checks). The boot after `vh-init --install` and the UKI
  rebuild runs vh-init: stage 1 in PID 1 in 970 to 1118 ms over four boots (udev-settle about
  half of it), 15 services started in parallel (agetty-tty1 at +6 ms, dbus ready in 103 ms),
  settled 5.1 s after the manager (vh-check's delay), `vh-ctl status` and the `sv` shim agree,
  vh-audit ok 178 with the rig's one FAIL (Secure Boot off) against ok 171 under runit,
  `check.py base` green under vh-init, runit-void's `poweroff` through stage 3 (67 to 76 ms)
  and `reboot(2)`, `--rollback` back to runit with every service up. The rig found four
  faults of the container-verified v0.2, all fixed here: the shim ran runit's `sv` under the
  name `sv.runit` (an LSB init script to runit), the manager saw no service because runit's
  stage 2 makes `/var/service` resolve, a service enabled again after `disable` stayed down,
  and the audit took a done oneshot for a dead service. Open: PID 1 holds 4.2 MiB of RSS. The
  install of that day rebuilt this kernel version's UKI in place, so no runit UKI remained until
  the rollback (the message claimed a fallback); the follow-up is done on 2026-10-27: `vh-init
  --install` goes through the boot assessment (the newest stock UKI's twin with `init=` appended,
  `linux-A.B.C_D-vh-init.efi`, on trial through Limine's one-shot entry, the default after three
  good boots, the stock UKI untouched as the fallback, a kernel update's twin on trial by itself;
  [init/README.md](../../init/README.md#the-uki-with-vh-init-the-install-through-the-boot-assessment)),
  verified on the rig: run RUN_ID_PENDING `vhinit,base,vhinit-rollback` (RESULTS_SHORT_PENDING).
  `init=` stays runit's by default.
- **vh-sched under vh-init: verified** (run 40340658992). The installer puts the loader and
  `vh_sched.o` in place (it never had: the service named a program that was not installed);
  on the machine kernel's trial boot the service is ready 83 ms after its start, the loader
  found 1 LLC of 4 CPUs, loaded the 10 programs in 41 ms, the kernel reports `state=enabled
  switch_all=1 root/ops=vh_sched`; `vh-ctl stop` ends it through SIGTERM (`SCX_EXIT_UNREG`,
  exit 0) and the kernel is back on EEVDF; `start` loads it again (`--ready-fd`); on the stock
  kernel the loader says "no sched_ext in this kernel" and the manager waits with its backoff.
  No speed claim: the bench method applies.
- **SELinux permissive: verified as far as the rig goes** ([selinux.md](selinux.md), runs
  40349043789, 40373457582, 40383056402, 40388319429, 40401275073, 40407123621, 40411465314,
  40416570814). With `VH_MAC=selinux` the
  installation is labelled, the machine kernel (features `auto,selinux`) runs SELinux as its
  LSM, stage 1 loads the policy and locks it, every label is as `file_contexts` says
  (`vh-selabel --check /` clean), every daemon runs in its domain, the admin reaches `sysadm_t`
  through doas, a login on tty1 starts the desktop as `user_t` and `wm_t`, `vh-audit`'s SELinux
  area has no FAIL. Each boot taught the policy its missing rules (195 AVC lines on the first,
  18 on the sixth, seventh and eighth, a new layer each time; the eighth's rules are the last
  commit, [VERIFY] run 40416570814) and two faults beyond it: the manager's channel to PID 1 was inherited by
  every service (closed on exec now) and the admin's home carried the user's type
  (`file_contexts.local`). The dual-kernel cost: the stock kernel labels nothing, so stage 1
  relabels `/etc`, `/usr`, `/var`, `/root`, `/home` and `/boot` once after a boot on it (stage 1
  955 to 1008 ms with it on the rig; [VERIFY] a large `/home`). Not verified: enforcing mode, a day of
  use, the browser, the gaming session, iwd and bluetoothd, real hardware. `VH_MAC=selinux` stays
  opt-in and permissive.

### State (2026-10-26): init, scheduler, SELinux, the desktop configuration

Three tracks moved on the Mac (containers and the S1 QEMU rig), none on the VM rig or real
hardware yet; every claim below says which.

- **Track I, `vh-init` v0.2** ([init/README.md](../../init/README.md)): PID 1 with a separate
  manager process (the same binary), runit directories and the native `.svc` format, readiness
  (started, exit, fd, socket, check), restarts with backoff, a cgroup per service, adoption of the
  services after a manager crash, native logs with rotation, oneshots and timers, per-service user,
  capabilities, `no_new_privs` and the ABI seccomp filter, `vh-ctl` and the `sv` shim, stage 3
  natively. Verified as PID 1 of a privileged container (`tests/init/init_test.sh`, 13 s, every
  check) and by the stage-1 oracles; the runit path stays the default `init=` until the rig has
  booted it (`tests/vm/steps/init.py`, [VERIFY on the rig]).
- **Track S, `vh-sched` v1 = U4** ([sched/README.md](../../sched/README.md)): the topology read at
  load time (LLCs, big cores, NUMA) into the frozen `.rodata`, one DSQ per LLC, weighted vtime, the
  interactive bonus, big-core preference, a cross-LLC steal. Verified on the S1 rig with the
  6.18.57 kernels: arm64 under hvf and x86_64 with two sockets under TCG, seven loads each. No
  speed claim yet: the bench method applies, and the first measurement is the GF63's.
- **Track E, SELinux** ([selinux.md](selinux.md)): one policy for this system's inventory, no
  unconfined domain, roles chosen at login, a one-way policy lock after stage 1; compiles with
  every invariant satisfied, 19 checks over the compiled policy, `vh-selabel` relabels a tree
  idempotently. `VH_MAC=selinux` is opt-in and permissive until the rig boots it enforcing with no
  denial: the stock kernel keeps AppArmor on the same command line.
- **Track D, the configuration** ([desktop.md](desktop.md)): both configs reviewed setting by
  setting for run-time cost; one change (the font search order); the measurable work is in the
  programs and stays on upstream's D list.
- The sysctl set reviewed and left as it is ([runtime.md](runtime.md#the-sysctl-set)).

### State (2026-10-20)

M0, U1, U2 and U3 are done; U3 but for what waits: the local build in the kbuild root
(upstream v0.3; designed in [kernel.md](kernel.md#the-local-build-later)). On 2026-10-20 all of
it ran on GitHub's KVM rig for the first time. U6 is done for x86_64 (aarch64 comes with U5).

U6 on the VM rig: the `live-image` workflow builds the programs (23 minutes) and the ISO
(void-mklive, 5 minutes; 1.3 GB: linux6.18 6.18.57 and the official image's packages, services
and firmware) with its sha256 and a build provenance attestation (run 39379089134). `kvm-smoke`
with `live_run` checks both and the commit, then installs from it: the installer took
`vh-kconf` and `vh-plan`, thor and RefursWM/RefursLine `x86-64-v3-btmenu` from the image, with no
Zig and nothing compiled. The installation took 2.6 minutes instead of 16.4, its tmpfs held
30 MiB instead of 1.1 GiB, and the lowest MemAvailable sampled was 1.9 GiB instead of 756 MiB
(of 2.8): the peak is now the LUKS Argon2id (1 GiB), which the 2-second sampler only partly
sees. `check.py base` passed 19 of 19 (run 39381993073), the step `machine` 23 of 23 (run
39382001559). The install-time probe is made by the system's own kernel (6.18.57), and `vh-kconf
check` on the stock kernel finds nothing lost. What the first build found: mklive runs tools of
the build host and goes on without them (without `mkfs.vfat` it made an unformatted EFI boot
image); they are installed and checked before it, and the ISO's UEFI boot image after it. At
the new floor, 1.5 GiB in tiered mode (MemTotal 1428 MiB; kvm-smoke run 39409288166 on
live-image run 39405682930): the gate marks the machine reduced and the memory requirement is
acknowledged, Argon2id gets 320 MiB, the lowest MemAvailable is 789 MiB (the UKI build), the
installation takes 2.5 minutes, `check.py base` passes 19 of 19, and zram gives the installed
system 713 MiB of swap.

U6 not verified: the ISO booted by UEFI from a USB stick on real hardware (the rig boots the
image's kernel directly); the x86-64-v1 builds on a CPU below v3 (the rig is v3); the release on
a `v*` tag; a real machine at the floor.

From the system, found on the rig with Void's image as with ours: `vh-kconf check` reported
`regulatory.db` as firmware that failed to load, at every boot of a rig without Wi-Fi. The stock
kernel loaded cfg80211 because dhcpcd asks for the nl80211 family (cfg80211's one alias) at
every start, and a machine kernel had it built in by the base profile; cfg80211 then asks for
the database, which the plan keeps only with a wireless interface. Fixed by
`rootfs/etc/modprobe.d/vh-cfg80211.conf` (a blacklist: cfg80211 loads only as a Wi-Fi driver's
dependency) and the kernel feature `wifi`, which the plan selects with a wireless interface
([runtime.md](runtime.md#vh-kconf-check)). `check.py base` and the step `machine` now require
`firmware=0`, and pass on the rig with the image of cb10024: `base` 21 of 21 (kvm-smoke run
39416639943), `machine` 23 of 23 with a q35 kernel built without cfg80211 (kernel-custom run
39413157691, "feature wifi not selected"; kvm-smoke run 39416650235), `firmware=0 lost=0` on the
stock kernel and at each trial boot.

Also from the system: stage 1 loaded every module of `modules.devname` at every boot (runit-void's
`01-static-devnodes.sh` as vh-stage1), 27 modules with their dependencies on the rig, which has
no Bluetooth, no sound and `VH_VIRT=no`: the Bluetooth stack through the test driver `hci_vhci`,
tun, vhost-net, vhost-vsock and VFIO with world-writable nodes, and `30-lock.sh` preloaded them
all before the lock. Under KVM the step took 328 ms of a 1211 ms stage 1 (kvm-smoke run
39411670080). Fixed by `rootfs/etc/modprobe.d/vh-devnodes.conf` and `vh-novirt.conf` (the
latter removed with `VH_VIRT=yes`): `modprobe -b` skips them, a driver still loads them as its
dependency; the live image carries both ([runtime.md](runtime.md#kernel-modules-at-boot)).
`check.py base`, `stage1` and `lock` check it; the rig has not run them yet. The machine kernel
built from a probe that saw them is a separate finding (the qemu-q35 kernel of kernel-custom run
39359766281 has tun, vhost-net, VFIO and others built in although resolve refused their
feature).

On the VM rig (`kvm-smoke` under KVM; the EPYC-Milan CPU that `tests/vm/vhvm.py` pins, 4 GiB):
the installation from the Void live image to a system that boots through Limine, the signed UKI
and LUKS2; `check.py base` with every check passing (lockdown, AppArmor, every runit service,
DoT, NTS, nftables, RefursWM and RefursLine, vh-bench, xbps-pkgdb; vh-audit 170 ok, its one FAIL
Secure Boot before `20-firstboot.sh`); the fixed ACPI power button pressed as a hypervisor does
(`system_powerdown`) ending in a regular poweroff; and the step `machine`: `vh-kconf install` of
the q35 machine kernel of a `kernel-custom` run, three trial boots through Limine's one-shot
entry, each with no loadable module and `vh-kconf check` finding every driver, the machine
kernel Limine's default after the third, `--demote` and the removal giving the stock UKI back.
`kernel-custom hw=all` built the four x86_64 machines, every requested symbol surviving, each
with its `-march` (skylake, znver4, alderlake, x86-64-v3). The `adapt`, `zig-test`,
`docker-tests` and `init-tests` workflows pass on every push.

What the rig found, each fixed by a commit: its own bugs from upstream (Void's BSD-format
`sha256sum.txt`, `bsdtar` for the live ISO, the ISO kept out of the VM's copies of the
repository, `udevadm settle`); `fetch-zig.sh` installing before xbps had updated itself (the
20250202 image's xbps refuses every other package); the kernel.org keys (from WKD now); the
fragments asking for drivers without their cores (DRM, HW_RANDOM, USB, HID, SCSI and sd, SND);
the synthesised q35 fixture (now the rig's own hw.zon); the fixed power button on 6.18 (`button`
became a platform driver: `tiny_power_button`, SIGINT, `/etc/runit/ctrlaltdel`, `vh-acpid`);
`vh-kconf check` judging a machine kernel against the live image's kernel instead of the stock
one; a test harness that hid failing unit tests. The installer needs 2.1 GiB of RAM at its peak
when it builds (the RefursWM build): the gate's memory floor was 3 GiB in both modes until U6,
1.5 GiB since, and 3 GiB only for building in RAM.

U3 verified, in containers on the Mac: `tests/kernel/matrix.sh` plans every x86_64 machine of
`kernel/hw` (gf63, amd-desktop, intel-hybrid-laptop, qemu-q35) in tiered mode and resolves it,
twice, with the same bytes, every class symbol known to the pinned config, no conflict with a
class, the build's invariants, `NR_CPUS` and the plan's `-march` (accepted by the Mac's clang);
it fails on a class symbol the pins do not have and on two classes in conflict. `-march`: a unit
test on the real hwdb (each fixture's model, and the x86-64 level for the same CPUs in a virtual
machine); every golden plan unchanged. `vh-kconf check`: `lost=N`, and on a machine kernel the
modules its build left out count as refused (the GF63's camera and card reader are not lost);
the GF63 oracle holds with resolve's deny list factored out. The boot assessment: Limine's
behaviour read in the source of 12.9.3, the version Void ships; unit tests of the identifiers,
the variables, the verdict, the state file and every transition; end to end on a tmpfs ESP and
a tmpfs in place of efivarfs through simulated Limine boots (44 checks: three good boots to the
default with limine.conf unchanged, a lost driver, a hang, another entry chosen, a Limine that
does not erase, an unknown identifier, `--demote`, the rotation, a rebuilt trial, no stock UKI);
stock-only ESPs exactly as upstream's `vh-limine-update` (`limine_diff.sh` against a build of
`upstream/main`: no difference in 24 cases); `vh-audit`'s new lines by hand on a mock ESP.
`vh-kconf install`: unit tests of every step and an install end to end under `--root`; the
install with Void's dracut 112 in a container (`tests/kernel/dracut_test.sh`, aarch64:
`--no-kernel` with `--kernel-image` and `--uefi`, the firmware in the initrd, `.linux` the
bzImage byte for byte); the kernel-side assumptions read in the 6.18 source (the firmware loader
waits for the initramfs, an unknown dotted parameter is dropped and one without a dot reaches
PID 1, `modules.builtin*` are written with every vmlinux); vh-audit's plan area without
`/proc/modules` in `audit_test.sh`, its boot area by hand.

U3 not verified: the step `assess` (kvm-smoke `step=assess`); a machine kernel for any machine
but the rig; vh-uki-verify's machine references beyond their unit tests (the first install asks
on /dev/tty); the workflows linted with actionlint (not installed). Nothing on real hardware.
[VERIFY]: Limine erasing the one-shot entry on each firmware (OVMF does), `sbctl sign` leaving a
signed file unchanged, clang 19 for `znver5`, the speed of each `-march` by class; a machine
with only the fixed power button and a GPU driver that selects `ACPI_BUTTON` (none in 6.18.57).

U2 verified, in containers on the Mac (aarch64; the `adapt` workflow repeats it on x86_64 once
the repository is on GitHub): the unit tests of `kernel/` (30), `adapt/` (12), `init/` (27) and
the Zig tools; `vh-power`'s native step and shell script give the same EPP, platform profile
and runtime PM on a fake sysfs of a hybrid laptop, on AC and on battery, the dGPU's slot and
the bridge untouched; `vh-backlight`'s choice on a fake `/sys/class/backlight`; the probe's
keyboard places on the six fixtures and the plan's internal input of a machine with a built-in
USB, an external USB and an SPI keyboard; `vh-kconf check` on the fixtures (the same machine,
another machine, a lost driver, a refused module, new devices with and without a module, the
kernel log's firmware failures, the trim's verdict) and end to end with a fresh plan;
`vh-plan env` gives every golden `plan.env` back; `vh-audit plan` on the golden plans of the
GF63 and the Raspberry Pi 5 in a mocked installed system; the GF63 oracle with the two
schedulers named in `perf` (its `.config` unchanged); the installer's lists; the lint with no
U2 entry left in `tests/adapt/lint.allow`.

U2 on the VM rig: `vh-audit` on the installed system (no FAIL but Secure Boot), `vh-kconf check`
at every boot (on the stock kernel it found the fixed power button without a driver, a real
loss on 6.18, now fixed), the power button. U2 not verified: nothing on a real machine. The udev
scheduler rule has no test of its own; the schedulers and the platform profiles are [VERIFY by
measurement per class]; `vh-power` at a real plug event; the watchdog timeouts of each driver
(sbsa_gwdt, bcm2835_wdt, sp5100_tco) through WDIOC on hardware; whether the 5 s delay of
`vh-kconf check` catches the asynchronous firmware loads; a built-in USB keyboard that the kernel
calls `fixed`; the backlight on a hybrid laptop; `install/00-probe.sh` on a live system; the
control-method power button (`PNP0C0C`) on 6.18 through the `button` platform driver.

U1 verified: the unit tests of `kernel/` (24) and `adapt/` (10) in a container;
the golden plans of the six machines of `kernel/hw`, each planned twice with the same bytes; the
gate (the four x86_64 machines full in strict mode, the two ARM64 ones refused in strict and
installed in tiered); the GF63 oracle (the classes reassemble upstream's 264 fragment symbols
and `.config`, one explained difference in LSMOD); the installer's packages, blacklist,
firmware and command line, which for the GF63 are exactly upstream's; the lint.

U1 not verified yet: any real machine; the four synthesised fixtures (qemu-q35 is the rig's own
since kvm-smoke run 39342292948); the
[VERIFY] items of `hwdb/` (the firmware narrowed for amdgpu, i915 and iwlwifi on hardware, the
Secure Boot menu names); intel-iommu under TCG (KVM runs it).

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
| kernel | the GF63 oracle; `resolve --plan` on every x86_64 fixture (`tests/kernel/matrix.sh`); `diff` reports no lost class symbol; CI builds of every x86_64 machine (`kernel-custom` with `hw=all`) |
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
