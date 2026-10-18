# void-hardperf-light: development plan

## Context

**What we build.** A distribution that succeeds `void-hardened-refurs`. It keeps the hardening
and adds its own components:

1. A kernel built only for the hardware of one machine.
2. Our own init.
3. Our own CPU scheduler.
4. Our own package manager with parallel downloads.
5. A terminal installer in English.
6. An isolated gaming session on tty3 that is removed with one command.
7. RefursWM and RefursLine brought up to speed.

The init, the scheduler and the package manager are written in Zig 0.17.0 only. The other new
components are in Zig too.

**User decisions (2026-10-18):**

| Question | Decision |
|---|---|
| repository | **clean**, without history; what is needed from `void-hardened-refurs` is transferred selectively |
| dGPU for games | the **open NVIDIA kernel modules**; the proprietary libraries only inside the gaming root |
| language | **documentation and all program output in English** |
| names | `vh-*`; the package manager stays `thor` (version 2) |

**Execution.** The planning session stopped once the plan was approved. The work is done by a
new session on **Fable 5.1** with `/effort ultracode`. Its first step put this plan into the
repository as `docs/ROADMAP.md`, in English.

**Result:**
- `~/Documents/systems/void-hardperf-light` and `FalconBinary/void-hardperf-light` (empty at the
  start; push over SSH works);
- work by milestones, each verified by tests and by a measurement.

## Inputs

### What is transferred from `~/Documents/systems/void-hardened-refurs`

The **working tree** is taken: it holds 3 uncommitted edits: yescrypt in every pam.d, `foot.ini`,
`vh-session` rolled back to pixman. `void-hardened-refurs` itself is not touched.

| What | From | How it is used |
|---|---|---|
| shared Zig code | `zig/lib/{vh,hash,seccomp}.zig`, `zig/ZIG_VERSION`, the rules in `zig/README.md` | the base of every new program |
| 12 Zig tools | `zig/tools/*.zig` | transferred as needed; `vh-limine-update` learns two UKI series |
| the thor policy | `thor/policy/{policy,rules}.zig` | straight into thor 2 |
| the thor 1 downloader | `thor/src/thor.zig` | the model: parallel workers, mirrors |
| the installer | `install/*.sh`, `vh.conf.example` | the specification for `vh-install` |
| system configuration | `rootfs/` (sysctl, nftables, unbound, chrony, iwd, PAM, doas, udev, AppArmor, dracut, kernel.d hooks) | transferred with the comments translated |
| the paranoid layers | `optional/` (deadman, tpm2-totp, usb-auth, ...) | — |
| the rig and the tests | `tests/vm/{vhvm.py,check.py}`, `tests/zig`, `tests/thor`, `tools/{vh-bench,vh-session-usage}` | — |
| documentation | `docs/00...18` (Russian) | the source for the English chapters |

### Key facts about the current system

- **Boot:** Limine (config hash enrolled) -> UKI (dracut-uefi + systemd-stub) -> LUKS2 Argon2id -> runit.
- **Kernel:** the stock `linux6.18`, protected through the cmdline and sysctl. Modules are
  preloaded, then `modules_disabled=1` (`30-lock.sh`).
- **Services** (~13): agetty tty1/tty2, eudev, dbus, iwd, unbound, chronyd, seatd, socklog,
  nanoklogd, vh-acpid, dhcpcd-eth0, vh-fstrim.
- **Users:**
  - admin on tty2;
  - user on tty1, gets RefursWM right away through `vh-session`;
  - browser, the UID of the Firefox sandbox; bwrap uses user namespaces.
- **thor** = xbps 0.60.7 + a policy in Zig + parallel downloads: 31-36 s against 68-85 s for xbps.
- **Rig:** QEMU TCG on a Mac + OVMF Secure Boot + swtpm. `check.py` used to look for Russian
  strings -> it moves to machine-readable markers.

### RefursWM and RefursLine (`~/Documents/systems/refurswm`, `refursline`)

- **RefursWM 0.2.0** (~5k LOC):
  - wlroots 0.20.2, libinput 1.31.3 and libseat 0.9.3 built statically from sources pinned by hash;
  - GLES2 and pixman renderers, no Xwayland;
  - a Landlock + seccomp sandbox; the configuration is compiled in.
- **RefursLine** (~16k LOC, no libc): 0 wakeups when idle.
- **The distribution's `desktop/` has diverged from the repositories.** In the new project the
  RefursWM and RefursLine repositories are the source of truth.

### Environment

- Mac M1, 8 GB RAM, **~17 GB free**.
- Zig 0.17.0.
- QEMU 11.1: x86_64 only through TCG; aarch64 through HVF is fast.
- colima: Ubuntu aarch64, kernel 6.8.
- `gh` is not logged in.
- **The real hardware** is an MSI GF63 Thin:
  - i5-10500H, 6C/12T, Comet Lake;
  - UHD 630 + GTX 1650 Max-Q (TU117);
  - AX201, RTL8111, NVMe, TPM2.

  A session cannot reach it: only runbooks for the user.

### Facts as of October 2026

Sources: the research report of the planning session.

- **Zig 0.17.0** (2026-10-01):
  - 5 known regressions; move to 0.17.1 when it is out;
  - `@cImport` removed;
  - LLVM loop vectorisation is off, so hot loops use explicit `@Vector`;
  - `std.Io.Threaded` is ready, Evented/Uring are experimental;
  - `std.http.Client`, `std.crypto.tls`, `std.compress.zstd` (decompression only; the checksum
    is not verified; default window 8 MiB) and `std.tar` are built on `std.Io`;
  - no Landlock wrappers;
  - the BPF target has no guarantees. Zig's BTF is defective (no argument names, type names
    differ from C), no CO-RE. sched_ext in Zig **has not been demonstrated anywhere**.
  - `ProgLoadAttr` in std is outdated: no `fd_array`, `log_true_size`; the typo `attact_btf_id`.
- **Kernel:**
  - 6.18 LTS is at 6.18.57, EOL December 2028. This is the default line;
  - `CONFIG_X86_NATIVE_CPU` since 6.16 (Clang >= 19); AutoFDO/Propeller since 6.13 (Comet Lake
    has LBR); kCFI = `CONFIG_CFI` since 6.18;
  - cost: init_on_free 3-8 %, init_on_alloc < 1 %;
  - the linux-firmware files in Void are zstd-compressed.
- **sched_ext:**
  - the references for games are scx_lavd, scx_flash, scx_bpfland, scx_cosmos (scx 1.1.4);
  - Starfield, 1 % lows: lavd +10.6 %, flash +8.9 % over EEVDF; no difference in GPU-bound games;
  - hackbench is a pathological load for some scx schedulers.
  - Under sched_ext **autogroup and the cgroup `cpu.weight`/`cpu.max` do not work** unless the
    scheduler implements them.
  - `scx_bpf_cpuperf_set` has an effect only with schedutil.
- **Init:** a methodical Artix measurement (QEMU): s6 4.7 s, dinit 5.0 s, runit 6.5 s of full
  boot. PID 1 itself costs under a second; most of the time is firmware, drivers and blocking
  services. nitro (Leah Neukirchen) is the allocation-free model.
- **Packages:**
  - xbps 0.60.7: only `.sig2` is signed (RSA PKCS#1 v1.5 over the file's SHA-256), repodata **is
    not signed**;
  - pacman 7.1;
  - apk-tools 3 (Alpine 3.23);
  - moss: content-addressed + atomic replacement.
- **Games:**
  - Steam, even with the 64-bit client (beta 2026-10-15), needs i386 multilib and user
    namespaces (pressure-vessel);
  - gamescope pulls in libinput, libudev, wlroots, luajit;
  - the open NVIDIA modules are loadable only (Turing+);
  - NVK is noticeably slower in games.
- **Without udevd:** libudev-zero needs uevent relaying to group 0x4; PipeWire and bluez need
  patches in places.

## Project rules: what changes

Kept:
- protection is not traded for speed silently;
- a measure with a cost comes only with a measurement and a row in the summary table
  "protects / residual risk / speed cost / convenience cost";
- the [VERIFY] tag instead of guesses;
- ReleaseSafe, static PIE, no shell spawned;
- sources pinned by hash.

| Was | Becomes | How the risk is held |
|---|---|---|
| only the stock kernel | our own 6.18 LTS kernel from kernel.org, for this machine | the kernel.org signature is verified by Zig code; the build runs in an isolated root without network; Limine always has the signed **stock** UKI |
| no building from source | the kernel, the NVIDIA modules, our components, RefursWM/RefursLine may be built | compilers only in `/var/lib/vh/roots/kbuild` (0700 root) |
| runit | `vh-init` | runit stays as the fallback `init=` until the DoD |
| sched_ext forbidden | only our own `vh-sched` is allowed | unprivileged BPF off; BPF LSM off; on failure the watchdog returns to EEVDF |
| thor = libxbps | thor 2 in Zig over the Void repositories | the pkgdb stays in the xbps format; thor 1 and `xbps-*` work as the fallback |
| ia32, Xwayland forbidden | Xwayland only inside the gaming root. IA32 is enabled in the kernel **only when `vh-game` is installed** | vh-init puts the seccomp filter "not the x86_64 ABI -> kill" on every process tree except the gaming one |
| NVIDIA forbidden (DKMS against lockdown) | the open modules are built together with the kernel and signed with a one-time key | lockdown and `modules_disabled=1` after preloading are kept |
| "no `std.Io`" | `Io.Reader`/`Io.Writer` allowed everywhere; an `Io` instance (Threaded) only in thor's network adapter | amendment in `zig/README.md` |
| Russian | English: docs, program output, the installer | — |

**Licence:** GPL-3.0, as before. The BPF part `sched/bpf/` is GPL-2.0-only: the kernel requires
a GPL-compatible licence for GPL-only kfuncs.

## Target architecture

```
UEFI (own SB keys) -> Limine (config hash)
   |- UKI "custom": this machine's kernel (Clang ThinLTO, -march=native, drivers built in) + initrd (dracut: LUKS, firmware, microcode)
   '- UKI "stock":  the signed stock linux6.18 (fallback, always)
 -> vh-init (PID 1: only reaping zombies, signals, shutdown) -> service manager (same binary, separate process)
      stage 1 natively -> the service graph in parallel by readiness; the manager holds the struct_ops link fd of vh-sched
 -> tty1 user  -> RefursWM + RefursLine
    tty2 admin
    tty3 game  -> root /var/lib/vh/roots/game (glibc multilib, Steam, gamescope, Xwayland, NVIDIA libraries)
```

| Component | Replaces | Directory |
|---|---|---|
| `vh-kconf` (probe, config, build, install of the kernel) | `linux6.18` as the main kernel, `module_blacklist`, `30-lock.sh` | `kernel/` |
| `vh-init` + `vh-ctl` (+ the `sv` shim) | runit, runit-void, core-services | `init/` |
| `vh-logd` | socklog, nanoklogd, vlogger | `init/logd/` |
| `vh-sched` (BPF in Zig + a loader in Zig) | EEVDF + autogroup | `sched/` |
| `thor` 2 | xbps + thor 1 | `thor/` |
| `vh-install` (TUI) | `install/*.sh` | `installer/` |
| `vh-root`, `vh-game` | — | `session/` |
| after 1.0: `vh-unlock` (LUKS in the initramfs), `vh-devd` + libudev-zero | dracut, eudev | — |

`zig/lib/`:
- transferred: `vh.zig`, `hash.zig`, `seccomp.zig`; `landlock.zig` and `seccomp.zig` from
  RefursWM; `sys.zig` from RefursLine;
- new: `bpf_uapi` (our own 6.18 structures with size checks), `btf`, `elf`, `tui`, `http` (an
  adapter over `std.http`/`std.crypto.tls`), `pgp` (RSA PKCS#1 v1.5 + OpenPGP packet parsing);
- existing lib files are not edited, only new files are added. Otherwise parallel tracks conflict.

## Components

### K. `vh-kconf`: the kernel of this machine

- **When it is built: after the first boot, not in the live installer.** By then the SB keys
  exist and the user has exercised all the hardware: the same order as `30-lock.sh`.
  - The existing GF63 is converted **in place**: the custom kernel is added as an extra Limine
    entry and becomes the main one only after the runbook.
  - No reinstallation is needed.
- **`probe`** -> `/etc/vh/hw.zon`:
  - the modalias of every bus, the bound drivers, `/proc/modules`, the CPU (CPUID, caches, SMT),
    DMI, EFI/TPM, filesystems;
  - sysfs/procfs only;
  - serial numbers are not written to the file: it may travel to CI.
- **`resolve` v1**: Kconfig is resolved by the kernel itself (its `conf` knows the toolchain
  macros); no resolver of our own in Zig.
  1. Take the pinned `.config` of Void `linux6.18`.
  2. Add the profile fragments (`merge_config.sh`).
  3. `make LLVM=1 localyesconfig LSMOD=<module list>` -> the drivers built in.
  4. `olddefconfig`.
- **`resolve` v2**: `allnoconfig` + fragments; v1 serves as the oracle.
- **What Zig does in resolve:**
  - modalias -> module through `modules.alias`/`modules.builtin.modinfo` of the stock kernel;
  - module -> symbol by parsing Kbuild (the oracle is `streamline_config.pl`);
  - a report "did every needed symbol survive and if not, why".
- **The mandatory list** (modalias does not see it):
  - RTC_DRV_CMOS + RTC_HCTOSYS;
  - XFS_POSIX_ACL;
  - ZRAM_BACKEND_ZSTD/LZ4;
  - every NFT_* expression from `nftables.conf`;
  - PINCTRL_CANNONLAKE (the i2c-hid touchpad);
  - USER_NS (the browser's bwrap, Steam);
  - KEYS, the cgroup2 controllers;
  - BPF + JIT + DEBUG_INFO_BTF + SCHED_CLASS_EXT;
  - INTEL_RAPL, CORETEMP, ACPI_FPDT (measurements);
  - ITCO_WDT (deadman);
  - MAGIC_SYSRQ;
  - FW_LOADER_COMPRESS_ZSTD.

  `kernel-hardening-checker` is applied with judgement, not blindly: it removes USER_NS, for example.
- **Profiles** `kernel/profiles/`:
  - `base`, `hardening`: the cmdline defaults become build options; X32, kexec, hibernation,
    debugfs, kcore, devmem, binfmt_misc, io_uring, MODIFY_LDT, MPTCP are off; rare protocols
    and filesystems are not built;
  - `perf`: HZ=1000, preempt full against lazy [VERIFY by measurement], NR_CPUS=12, ThinLTO.
    `CONFIG_X86_NATIVE_CPU` only when building on the machine itself; in CI `-march=skylake`.
  - `features/`: usb-common, bluetooth, camera, virt and **game**: IA32_EMULATION, NTSYNC,
    HIDRAW, UHID, SYSVIPC, MODIFY_LDT [VERIFY for Wine], `MODULES=y` for NVIDIA.
- **Firmware and microcode:**
  - go **into the UKI's initrd** through dracut `install_items` by `hw.zon`, not into
    `EXTRA_FIRMWARE`: otherwise every firmware update relinks the kernel. [VERIFY: the firmware
    loader in 6.18 waits for the initramfs];
  - microcode as dracut's early cpio;
  - `regulatory.db` + `.p7s` in the initrd, otherwise the built-in cfg80211 falls into the world domain;
  - firmware is decompressed from `.zst`.
- **Modules:**
  - without NVIDIA: `CONFIG_MODULES=n`;
  - with `vh-game` on the GF63: `MODULES=y`, `MODULE_SIG_FORCE`, a one-time key (erased after
    signing), the NVIDIA modules built in the same kbuild. Then preloading, `modules_disabled=1`,
    the `/dev/nvidia*` devices 0660 for the `game` group only;
  - [VERIFY] RTD3: the dGPU sleeps with the driver loaded (`NVreg_DynamicPowerManagement=0x02`).
- **Consequences of `MODULES=n`:**
  - dracut with `--no-kernel`;
  - the `modprobe.d` options (iwlwifi `power_save=0`, `iwlmvm.power_scheme=1`, iTCO
    `nowayout`/`heartbeat`) move to the cmdline;
  - the sysctls that vanish (`modules_disabled`, `io_uring_disabled`, `mptcp`, ...) are skipped by
    the sysctl loader on ENOENT, and `vh-audit` checks "the feature is absent" instead of a value;
  - the custom UKI's cmdline carries no parameters of modules that do not exist: unknown
    parameters go to PID 1 as env/argv.
- **`fetch`:** the kernel.org tarball is verified through `.tar.sign` (PGP) with the keys of
  Torvalds and Kroah-Hartman. Fingerprints are pinned; `zig/lib/pgp` verifies, xz decompression
  comes from std.
- **`build`** in the kbuild root: clang, lld, make, flex, bison, bc, perl, pahole, elfutils,
  openssl from Void packages through thor `-r`. Namespaces, no network, Landlock on the build
  directory. The same step builds `vh-sched` against the new kernel's BTF.
  In v0.1 the build runs in CI: see "How v0.1 reaches the GF63".
- **`install`:**
  - dracut-uefi -> `vh-limine-update`, which learns **two series**: custom (KEEP=2) and stock
    (pinned). Today `parseUki` accepts only `linux-A.B.C_D.efi` and would delete the fallback;
  - the "UKI: 1-3" check in `vh-audit` too.
- **`check`**: a service at start: new modalias without a driver -> a message at the admin
  login on tty2.
- **CI:** the `kernel-fat` job (the Void config + SCHED_CLASS_EXT/BTF) is needed right away,
  for S1. Kernels from CI contain no firmware.

### I. `vh-init`, `vh-ctl`, `vh-logd`

**An honest frame.** PID 1 itself yields milliseconds. The goal:
- a minimal cost of its own: supervisor CPU, PSS, wakeups, number of processes;
- the fastest stage 1 (no shell);
- readiness no worse than dinit/s6-rc.

References: runit (the stock scripts), s6 + s6-rc + s6-linux-init, dinit, sinit (no supervision,
labelled as such in the report), nitro.

- **Process split.** PID 1 is tiny: it reaps zombies, takes signals, shuts the system down,
  restarts the manager. The service graph and the control socket live in a **separate manager
  process** (the same binary). A ReleaseSafe panic in PID 1 = a kernel panic, so the complex
  part stays out of PID 1. A new manager picks the services up from their cgroups through
  `pidfd_open`.
- **Starting a service:**
  - `clone(CLONE_VM|CLONE_VFORK|CLONE_PIDFD|SIGCHLD)`; signals are blocked around clone and reset
    in the child;
  - an exec error arrives through a CLOEXEC pipe;
  - the child writes itself into `cgroup.procs`.
- **Stage 1 natively**: the list from `runit-void` + `core-services/*-vh-*`:
  - mount: /proc (hidepid), /sys, /dev, /dev/pts, /dev/shm, /run, cgroup2, securityfs, bpffs, efivarfs;
  - remount `/` rw, fstab;
  - sysctl.d with the priorities of `sysctl --system` (masking by a same-named file in /etc);
  - hostname, `lo` up, seedrng (load), `/run/utmp`, loadkeys/setfont for a non-us layout;
  - zram, THP, `/run/vh-sandbox`, SUID-strip;
  - eudev: start + trigger + settle;
  - `nft -f` and `apparmor_parser` (cache): exec without a shell.
- **Services** are `/etc/vh/services/*.svc` (`key = value`):
  - `exec`, `needs`/`wants`/`after`;
  - `ready = fd N | socket PATH | exit | started`, compatible with s6/dinit;
  - `restart` with backoff, `user`, `caps`;
  - sandbox: no_new_privs, Landlock, a seccomp profile, a private /tmp, ro /usr, no network,
    cgroup limits, `SCHED_IDLE` for background ones;
  - **the "x86_64 ABI only" filter** on everything except the gaming tree.

  No binary cache of the graph until a measurement shows that parsing is noticeable.
- **Compatibility:**
  - the `runit` type: `/etc/sv/*/run`, `log/`, `check`, `finish`, `down`;
  - the `/var/service` links;
  - `vh-ctl` invoked as `sv` works as a shim.
- **Shutdown:**
  1. the services in reverse order;
  2. TERM, then KILL for the rest;
  3. save the seed and wtmp;
  4. swapoff;
  5. `/` to ro;
  6. the `shutdown.d` hooks (deadman does not return; iTCO `nowayout`);
  7. `reboot(2)`.
- **`vh-ctl`:** status, start/stop/restart, enable/disable, log, tree, why, check, blame,
  `reexec` (state version -> a trial run by the new binary -> exec; on failure the services are
  picked up by cgroup).
- **`vh-logd`:** init creates `/dev/log` and hands it over; plus `/dev/kmsg` and the services'
  stdout. Categories, rotation, limits, control characters stripped.
- **Transferring `optional/`:** deadman (`shutdown.d`, iTCO), session-netns (getty arguments).
  The dracut modules tpm2-totp/deadman stay while dracut is in place.

### S. `vh-sched`: sched_ext, all in Zig

**Why sched_ext.** The kernel is C, Zig cannot be embedded into it. sched_ext is the only path
without kernel patches.

- **The BPF part:**
  - Zig `bpfel-freestanding`, ReleaseFast: memory safety comes from the verifier;
  - our own panic calls `scx_bpf_error`;
  - one ELF section per callback; helpers are `inline fn` (no bpf-to-bpf calls);
  - external symbols = kfuncs with the 6.13+ names (`scx_bpf_dsq_insert`,
    `scx_bpf_dsq_move_to_local`, ...);
  - kernel types are the offsets of the fields in use only, from the BTF of **this** kernel (no CO-RE needed);
  - the topology (6C/12T, one LLC, SMT pairs) is a build constant.
- **BTF is not taken from Zig/LLVM.** The BTF that is needed (map types, the struct_ops value) is
  generated at compile time from Zig types with C names. The fallback is a post-processor, as in zbpf.
- **The loader** (pure Zig, our own 6.18 uapi structures):
  1. ELF and BTF_LOAD;
  2. maps; `.rodata` is frozen;
  3. programs: `attach_btf_id` = `sched_ext_ops`, `expected_attach_type` = the member index;
     kfunc -> `src_reg=2`, imm = the BTF id from vmlinux;
  4. the `bpf_struct_ops_sched_ext_ops` value with the program fds;
  5. `BPF_F_LINK` + `LINK_CREATE`.

  **The link fd is held by the vh-init manager in epoll** [VERIFY pollable]; it writes the exit
  reason (`exit_info`) and restarts with backoff. Under `lockdown=confidentiality` there is no
  `bpf_probe_read_kernel`, `bpf_printk` or tracefs -> only direct BTF loads and diagnostics
  through a ringbuf.
- **The `.o` lint in CI:**
  - no u128, no signed division without `-mcpu=v4`;
  - no compiler-rt or memcpy calls;
  - stack <= 512 bytes;
  - `insn_processed` in the report.
- **Policy v1:**
  - **fairness per session** (the cgroup of each VT): otherwise "the desktop under `make -j12`"
    gets worse than with autogroup;
  - `p->scx.weight` (nice) and SCHED_IDLE honoured;
  - vtime with a bonus for tasks that sleep; an idle full core next to the cache;
  - a latency class for gamescope (it has no CAP_SYS_NICE).
- **Policy v2:**
  - criticality by the wakeup graph (as lavd);
  - frequencies through `intel_pstate=passive` + schedutil only if the measurement beats active + EPP;
  - a battery mode.
- **Rollout:**
  - first `SCX_OPS_SWITCH_PARTIAL`: only the gaming cgroup under vh-sched;
  - then the whole session; then the whole system.
  - Emergency reset: a `kernel.sysrq` mask with only the sched_ext reset bit [VERIFY the bit];
    `vh-sched off`.
  - A BTF mismatch -> it does not load.
- **The fast loop on the Mac:**
  - the loader mechanics on colima's 6.8 kernel through `tcp_congestion_ops` in Zig (also struct_ops);
  - sched_ext in `qemu-system-aarch64 -accel hvf` with an arm64 kernel >= 6.12;
  - x86_64 in CI.

### P. thor 2

- **Compatibility before speed:**
  - **the source of truth is the xbps pkgdb** (`pkgdb-0.38.plist` + `.files.plist`); the binary
    index is only a cache;
  - `xbps-query`, `xbps-reconfigure`, vkpurge and thor 1 keep working;
  - the INSTALL/REMOVE scripts run through `/bin/sh` exactly as in xbps (arguments, cwd, chroot for `-r`).
- **Semantics:**
  - run_depends with versions; shlib-requires/provides; provides, replaces, conflicts;
  - alternatives; conf_files (`.new-*`); ignorepkg and hold; `noextract`; preserve.
- **Speed:**
  - a binary mmap cache of repodata;
  - parallel downloads from several mirrors (keep-alive, Range, resume);
  - a pipeline: verification and unpacking into staging in parallel per package;
  - commit by renames + one `syncfs`;
  - the xbps-triggers **are deduplicated**: a shim over `xbps-triggers` in a private mount ns
    records the calls, the heavy caches are refreshed once at the end.
- **zstd:** the window is taken from the frame header. The speed of `std.compress.zstd` against
  libzstd on real packages is the go/no-go criterion in S3.
- **Protection:**
  - the thor 1 policy is transferred; each root has its own profile: base, kbuild, game;
  - **every repodata entry is checked against the package's signed `props.plist`** (pkgver,
    dependencies, shlibs, conflicts/replaces, alternatives, conf_files). This closes the
    unsigned-index hole of xbps;
  - against a freeze attack: freshness is compared across >= 2 independent mirrors; an index
    older than one already seen is rejected;
  - the downloader runs under a separate UID with Landlock (the cache only) and seccomp.
- **CLI:** the thor 1 commands; queries and `-r ROOT`. Later (after 1.0) atomic `/usr`
  generations (content-addressed, `renameat2`).

### N. `vh-install`

- A TUI in Zig (termios + ANSI); a `--config` mode for the rig.
- Steps and protection as in `10-install.sh`/`chroot.sh`: the disk confirmed by name, LUKS2, XFS,
  users, thor installs the system, RefursWM/RefursLine built for the CPU, Limine + sbctl.
- **It does not build the kernel:** the first boot runs on stock. Then `vh-firstboot`: Secure
  Boot (as `20-firstboot.sh`), then `vh-kconf`.
- Runs from the official Void live image, old as it is (20250202). Our own live image comes after 1.0.

### G. `vh-root`, `vh-game`

- **`vh-root`:** creates, lists and removes the roots `/var/lib/vh/roots/<name>`; packages are
  installed by thor `-r` with a policy profile. thor 1 `-r` is enough at first, no need to wait for thor 2.
- **`vh-game install`:**
  - the `game` UID, tty3 in pam_access;
  - the root: glibc multilib, Steam, Mesa/Vulkan 32/64, gamescope, Xwayland, `nvidia-libs`
    (+32bit) of the same version as the kernel modules. Module and library versions are updated together;
  - `features/game` + a kernel rebuild.
- **Entry:**
  - the login shell of `game` = `vh-game-enter`: an unprivileged userns + mount/pid/ipc/uts, the
    root and `/run/seatd.sock` mounted, no root helper needed;
  - nested userns allowed (pressure-vessel);
  - the "x86_64 only" filter is not put on this tree.
- **Devices:**
  - DRM through seatd (gamescope);
  - the `gamepad` group: only the joystick and hidraw of controllers; the `input` group never;
  - `/dev/ntsync` and `/dev/nvidia*` for the `game` group;
  - uinput off. If enabled, RefursWM ignores `/devices/virtual/input/*` by path.
- **Sound:** the ALSA device is exclusive, so the main path is the user's restricted PipeWire
  pulse socket (the model is `60-vh-sandbox.conf`). If the desktop is not running, its own
  PipeWire in the root [decide in the spike].
- **Network:** nftables per UID and `socket cgroupv2` for Steam's incoming ports.
- **Scheduling:** the session cgroup passes a hint to `vh-sched`.
- **`vh-game remove`** removes the root, the home, the UID, the nft and device rules, the
  pam_access line and rolls `features/game` back (a rebuild without IA32 and modules).
  Test: `find / -xdev`, `hw.zon`, the ruleset, passwd/group before the install and after the
  removal are identical.

### D. RefursWM and RefursLine

Changes go into their repositories; the distribution takes them through `desktop/build.zig.zon`
(URL + hash) and its own `config.zig` through the new `-Dconfig=` option.

- **v0.1 (critical for tty3):**
  - seccomp allows `bind`, but `socket()` only for AF_UNIX and AF_NETLINK/`NETLINK_KOBJECT_UEVENT`.
    Otherwise libinput is left without input after returning to the VT (`refurswm/src/seccomp.zig:57`);
  - `session.events.active`: do not count idle while the VT is inactive;
  - the bar's lock is per display, not per user (`refursline/src/bar.zig:209`);
  - ignore virtual input devices.
- **Games:** pointer-constraints, keyboard-shortcuts-inhibit, VRR only for a fullscreen window,
  the flat acceleration profile.
- **GPU and CPU:**
  - under a fullscreen window everything is disabled so direct scanout works with an opaque buffer too;
  - a cache of the tearing test; no hit-test under a fullscreen window;
  - configure to layers only on change;
  - suspended for hidden windows; DPMS.
- **RefursLine:**
  - commit no more often than a frame;
  - the menu background without fullscreen blending;
  - a shared wallpaper buffer for identical monitors;
  - a filter of raw uevents;
  - non-blocking radio waits;
  - XRGB8888.
- **Build:** the machine's `-Dcpu`. LTO for the C dependencies and Mesa with only the needed
  drivers (`platforms=wayland`) after a measurement.
- **Check on the GF63:** KMS, VT switch there and back, direct scanout, tearing, idle wakeups.

## Milestones and order

The system works at every milestone. The old parts (the stock kernel, runit, thor 1) stay as
the fallback until the replacement has passed its DoD.

| Milestone | Content | Depends on |
|---|---|---|
| **0. Repository** | see below | — |
| **v0.1: the first measurable win on the GF63, in place** | the D critical items (VT/input); `vh-stage1`, a Zig replacement of `/etc/runit/1` and the core services (runit stays PID 1); `vh-kconf` v1, the custom UKI as an extra Limine entry; `bench/` and `docs/19-benchmarks.md` with the first numbers | 0 |
| **spikes (in parallel with v0.1)** | **S1:** sched_ext in Zig (KVM + `kernel-fat`, lockdown). **S2:** vh-init PID 1 + manager in a container and a VM. **S3:** thor 2: repodata -> a plan that matches `xbps-install -n`; sig2; zstd go/no-go. Reports in `docs/spikes/S*.md` | 0 |
| **v0.2** | vh-init as PID 1 (a separate UKI with `init=`), vh-logd, the sv shim; vh-sched v1 (PARTIAL -> session); the read path of thor 2 (index, plan, download, verification) | v0.1, S1, S2, S3 |
| **v0.3** | thor 2 writes: the kbuild and game roots first, the base last; `vh-root`/`vh-game` with NVIDIA; `vh-install` + `vh-firstboot` | v0.2 |
| **v1.0** | `resolve` v2; vh-sched v2; RefursWM/RefursLine per the D list; `vh-audit.d` with checks of the new components; `check.py all` on machine markers; docs in English; recovery and the runbook | v0.3 |
| **after 1.0** | `vh-unlock` (LUKS2 in Zig instead of dracut, together with the tpm2-totp and deadman hooks); `vh-devd` + libudev-zero; AutoFDO/Propeller; atomic generations in thor; our own live image | — |

**How v0.1 reaches the GF63.** Onto the running `void-hardened-refurs` system, by `docs/runbook-gf63.md`:

- **`vh-stage1`** is installed in place of `/etc/runit/1`; the previous file stays as `1.orig`,
  the way back is one command.
- **The custom UKI of v0.1 is built in CI** from `hw.zon`: no serial numbers, `-march=skylake`,
  a reproducible build with fixed `KBUILD_BUILD_*`.
  - The user downloads the release asset.
  - `vh-kconf install` checks the sha256, puts the firmware into the initrd and signs locally.
  - No compilers appear on the laptop: the thor 1 policy forbids them in the base.
- **The local kbuild root** (needed for the NVIDIA modules too) arrives in v0.3, together with
  the thor policy profiles for separate roots.

**Milestone 0 (one session):**

1. `git init ~/Documents/systems/void-hardperf-light`; remote `origin` ->
   `git@github.com:FalconBinary/void-hardperf-light.git`.
2. Transfer the table "What is transferred" (from the working tree) with the messages and
   comments translated into English. The first commit names the source:
   `Void-Hardened-Refurs @ 8af9d04 + working tree`.
3. README, `docs/ROADMAP.md` (this plan, in English), `docs/principles.md` (the rules table),
   LICENSE GPL-3.0 + SPDX GPL-2.0-only in `sched/bpf/`.
4. **Mark file ownership for the parallel tracks:**
   - a root `build.zig` aggregator;
   - one workflow per track;
   - `check.py` as a step registry;
   - `vh-audit` -> `vh-audit.d/`;
   - only new files in `zig/lib`.
5. CI (GitHub Actions):
   - `zig build test`;
   - the docker tests on x86_64;
   - a QEMU/KVM smoke test (permissions on `/dev/kvm`);
   - `kernel-fat`;
   - artifacts published as release assets: the session's `gh` is not logged in.
6. `git push -u origin main`.

**Tracks and file ownership** (in parallel, separate sessions):

| Track | Files |
|---|---|
| D | the RefursWM/RefursLine repositories |
| K | `kernel/`, the Limine hooks, dracut, kernel.d |
| I | `init/`, runit, `sv` |
| P | `thor/`, `tests/thor` |
| S | `sched/`, `zig/lib/{btf,elf,bpf_uapi}` |

On the Mac: one VM at a time and no more than two local tracks; the heavy work goes to CI.

## Measurements (`bench/`): an honest method

- **Rules:**
  - the metrics are fixed before measuring;
  - the variants alternate in random order, the warm-up is discarded;
  - >= 30 boots (KVM, pinned vCPUs) and >= 10 long runs;
  - median, p95, a bootstrap 95 % CI;
  - "faster" only if the CI does not include 0 and the difference is >= 3 %;
  - on the GF63: mains power, a fixed EPP, cooled below 50 °C, a log of frequency, temperature and RAPL;
  - raw CSV in `bench/results/`.
- **init:**
  - identical services and readiness semantics;
  - the time from "Run /sbin/init" to the kmsg marker "all ready";
  - supervisor CPU, PSS, wakeups, shutdown time;
  - a synthetic graph of 50 services.
- **pkg:**
  - a local mirror in a netns with `tc netem delay 30ms rate 100mbit` and with 0 ms;
  - the stages separately; the same fsync policy;
  - xbps 0.60.7, thor 1, thor 2, pacman 7 (Arch), apk 3 (Alpine) on comparable volumes.
- **sched** (every variant under the same lockdown: a separate bench UKI):
  - schbench p99;
  - deadline misses of a 144 Hz task under `make -j12`;
  - MangoHud CSV (2 native benchmarks + 1 game through Proton);
  - `make -j12` time;
  - RAPL when idle and on video;
  - hackbench as the pathology check;
  - variants: EEVDF + autogroup, bpfland, lavd, flash, vh-sched; the CachyOS reference from a live USB.
- **boot:**
  - the stages firmware -> Limine -> kernel -> init -> ready -> desktop;
  - kernel size, initcall time;
  - idle RAM.
- **session:** `tools/vh-session-usage` + the RefursWM frame time.

## Verification

| What | Checks |
|---|---|
| unit | `zig build test` in every component; seccomp/Landlock through the BPF interpreter |
| K | `vh-kconf diff --oracle localyesconfig`; the CI KVM matrix: q35 x {virtio-blk, nvme, ahci} x {virtio-net, e1000e} x {bochs, virtio-gpu}; no `firmware.*fail` in dmesg; `test ! -e /proc/modules` (without NVIDIA); `iw reg get` != 00; the readiness marker from kmsg (independent of vh-init); on the GF63 by runbook: Wi-Fi, Ethernet, sound, backlight, HDMI, a USB stick, lid and button, TPM, msi-ec, a green `vh-audit` |
| I | a container with vh-init as PID 1: crash, backoff, readiness, killing a cgroup, `reexec` x100, 0 zombies; in the VM `check.py`, including deadman and deadmandump |
| S | load/unload x1000 under stress-ng; a build with an injected hang -> watchdog -> `/sys/kernel/sched_ext/state` = disabled; refusal on a foreign BTF |
| P | a corpus of scenarios: an empty base root, Firefox, an update from a locally re-signed repository (`xbps-rindex` + a test key), removal `-R`/`-o`, changed conf_files, switching alternatives, `noextract` of firmware. Must match: the plan with `xbps-install -n`, the file tree (`find -printf` + sha256), the normalised pkgdb. SIGKILL at random commit points -> recovery -> `xbps-pkgdb -a` clean; tampering: a bad sig2, a props/repodata mismatch, a lagging mirror |
| G | the leftovers test after remove; evdev revoked after a VT switch; Steam starts; nvidia-smi from the root |
| whole system | `vh-install --config` in a VM -> `check.py all`; `vh-audit` green; the GF63 runbook |

## Honest success criteria

- **Kernel:**
  - no loadable modules (except NVIDIA in the game profile); all GF63 hardware works;
  - the differences in size, kernel init time and idle RAM are published;
  - the expected runtime speed gain is about zero; the win is in boot time and attack surface.
- **Init:**
  - stage 1 faster than runit-void, with a breakdown (udev settle, nft, apparmor);
  - supervisor CPU, PSS and wakeups the lowest among the references;
  - readiness time on the level of dinit/s6-rc is acceptable.
- **Scheduler:**
  - <= 2 % throughput loss against EEVDF;
  - better p99 and 1 % lows than EEVDF + autogroup under background load;
  - no worse than lavd/bpfland on most metrics; losses are published;
  - "better than everything that exists" is a hypothesis, not a DoD.
- **thor 2:** faster than thor 1 (which is already ~2x faster than xbps) at 30 ms RTT; faster
  than pacman on equal bytes; apk is published as it is.

## Risks

| Risk | Answer |
|---|---|
| Zig -> sched_ext does not take off | S1 first. Fallback A: a small BPF part in Zig + the policy in Zig userspace (as scx_rustland). Fallback B: a BPF bytecode emitter in Zig. Otherwise back to the user |
| kernel configuration mistakes | localyesconfig v1, the report of surviving symbols, the CI matrix, the stock UKI always in Limine |
| thor 2 parity with xbps | the xbps pkgdb is the source of truth, differential tests, thor 1 alongside |
| `std.Io`/TLS/zstd in Zig 0.17 | an adapter in one module; go/no-go by zstd; the move to 0.17.1 |
| NVIDIA: module and library versions, RTD3, heat | update in one transaction; the RTD3 check in the runbook |
| games: sound, userns, ia32 | only inside the gaming root and tree; a spike in v0.3; a cost table in docs |
| no access to the GF63 | CI + VM; runbooks for the user |
| 17 GB on the Mac | kernels and measurements in CI and on the GF63; caches are cleaned |
| the amount of work | milestones with a DoD; the fallbacks are not removed before 1.0 |

## Rules for the executing session

- **Directory:** `~/Documents/systems/void-hardperf-light`.
- **Git:** one logical step is one commit; `git push origin main` is allowed by the user.
- **RefursWM/RefursLine:** changes and pushes into their repositories (allowed).
- `void-hardened-refurs` is not modified.
- **Code:** `zig/README.md` with the `std.Io` amendment (see the rules); documentation and
  program output in English.
- **CI:** logs and artifacts are unreachable without `gh auth login`: ask the user, or publish
  release assets.
- Nothing destructive on the real laptop: only runbooks (`docs/runbook-gf63.md`,
  `docs/recovery.md`: live ISO -> cryptsetup -> chroot).
