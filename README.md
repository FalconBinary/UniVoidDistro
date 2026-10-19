# UniVoidDistro

A hardened, fast and minimal Linux distribution on top of Void Linux packages that adapts
itself to the machine it is installed on: any x86_64 UEFI computer (laptops, desktops and
their motherboards, servers, virtual machines) and ARM64. It is a fork of
[void-hardperf-light](https://github.com/FalconBinary/void-hardperf-light), which does the
same for one laptop (the MSI GF63 Thin), and keeps its protection and its components in
**Zig 0.17**: LUKS2 + a signed UKI + our own Secure Boot keys + Limine,
`lockdown=confidentiality`, a kernel without loadable modules, nftables per UID, DoT DNS, NTS
time, a sandboxed browser, the RefursWM compositor and the RefursLine bar.

What changes is where the hardware comes from. void-hardperf-light names its laptop in about
35 files: kernel options, packages, firmware, the kernel command line, udev rules, the
scheduler's topology. UniVoidDistro detects the machine and decides by rules:

```
probe    sysfs, procfs, the device tree -> /etc/vh/hw.zon       (no serial numbers, MACs, UUIDs)
plan     hw.zon + hwdb/*.zon (rules, each with an id and a reason) + vh.conf
           -> /etc/vh/plan.zon, plan.env, plan-report.txt
use      the installer (packages, firmware, command line, services, initrd drivers, LUKS),
         vh-kconf resolve (the kernel of this machine); later stage 1, power, watchdog, scheduler
verify   the stock signed UKI always stays in Limine; vh-audit shows the protection tier
```

| Goal | How it holds on any machine |
|---|---|
| performance | a kernel built for the machine (drivers built in, its CPU's `-march`, the exact `NR_CPUS`), the CPU's own frequency driver, a sched_ext scheduler that reads the topology when it loads |
| security | the full protection of void-hardperf-light wherever the hardware allows it. `VH_SECURITY=strict`, the default, refuses a machine without UEFI 64-bit, Secure Boot, TPM 2.0, an IOMMU or AES in the CPU; `tiered` installs with every missing property named as a residual risk and confirmed by typing |
| lightness | only the packages, firmware files and services the detected hardware needs |
| speed | built-in drivers, a stage 1 without a shell, no waiting for hardware that is not there |
| optimisation per machine | every decision is a rule in `hwdb/` with its reason; `vh-plan explain ITEM` says why |

**Current state: M0 and U1** (detect and decide): see [docs/uni/ROADMAP.md](docs/uni/ROADMAP.md).
The rules every change follows are in [docs/uni/principles.md](docs/uni/principles.md); what
hardware is supported, and how each piece is detected, is in [docs/uni/hardware.md](docs/uni/hardware.md).

## Relation to void-hardperf-light

UniVoidDistro is a fork with history, and void-hardperf-light is its `upstream` remote. The
tracks that do not depend on the hardware come from there by `git merge upstream/main`:
I (`vh-init`), S (`vh-sched`), P (`thor` 2), N (`vh-install`), G (the gaming session), D
(RefursWM and RefursLine). Their plan stays in [docs/ROADMAP.md](docs/ROADMAP.md) and
[docs/principles.md](docs/principles.md). This project's own work lives in new paths
(`adapt/`, `hwdb/`, `kernel/profiles/class/`, `docs/uni/`), so that the merges stay small;
the program names (`vh-*`), `/etc/vh` and the `VH_*` settings are the same as upstream.

```
UEFI (own SB keys) -> Limine (config hash enrolled)
   |- UKI "custom": this machine's kernel + initrd (LUKS, firmware, microcode)   [U3, track K]
   '- UKI "stock":  the signed stock linux6.18 (fallback, always present)
 -> vh-init (PID 1) -> service manager -> vh-sched (sched_ext)                   [tracks I, S]
 -> tty1 user  -> RefursWM + RefursLine
    tty2 admin
    tty3 game  -> /var/lib/vh/roots/game                                         [track G]
```

## Repository layout

```
adapt/          vh-plan: hw.zon + hwdb -> the plan of this machine (track A)
hwdb/           the hardware rules: CPU, GPU, network, audio, storage, platform, board, security
install/        the shell installer (00-probe, plan, 10-install, chroot, 20-firstboot, 30-lock, ...):
                the specification for vh-install
rootfs/         files that land in the system (*.in are templates with @VH_*@ from vh.conf)
optional/       hardening modules: <module>/enable, disable; status
kernel/         vh-kconf: probe (hw.zon), resolve, diff; profiles/ (universal), profiles/class/
                (per hardware class), pins/ (the Void kernel's config and tables), hw/ (machines)
zig/            the Zig tools (vh-acpid, vh-deadman, vh-limine-update, vh-pkg, vh-seccomp, ...);
                lib/ is shared code; README.md holds the code rules
init/ sched/ thor/ installer/ session/   the upstream tracks (see each README)
desktop/        snapshots of RefursWM and RefursLine
tools/ bench/   vh-bench, vh-session-usage; measurements and their results
tests/          vm/ (qemu + OVMF Secure Boot + swtpm rig), kernel/ (fixtures of real and
                synthesised machines), adapt/ (golden plans, the hardware-constant lint), zig/, thor/, init/
docs/           uni/ (this distribution), ROADMAP.md and principles.md (upstream), ru/ (the Russian
                guide of the predecessor), runbook-gf63.md, spikes/
```

## Building and testing

Zig 0.17.0 exactly (`zig/ZIG_VERSION`; `install/fetch-zig.sh` downloads and verifies it).

```sh
zig build -Dtarget=x86_64-linux --prefix build/out    # every Zig program of every track
zig build tests -Dtarget=x86_64-linux --prefix build/zt && for t in build/zt/test/*; do "$t"; done
                                                       # unit tests: built once, run on Linux
sh tests/adapt/run.sh                                  # vh-plan against the golden plans of every fixture
sh tests/kernel/run.sh                                 # vh-kconf: probe, resolve, the GF63 oracle
sh tests/zig/run.sh                                    # the tools in a Void container (docker)
python3 tests/vm/vhvm.py install --iso void-live-x86_64-20250202-base.iso
python3 tests/vm/check.py all                          # base, enroll, sb, lock, desktop
```

## License

GPL-3.0 ([LICENSE](LICENSE)). The BPF part of the scheduler, `sched/bpf/`, is GPL-2.0-only:
the kernel requires a GPL-compatible licence for GPL-only kfuncs.

Source: void-hardperf-light @ 2c6ab1f, forked with its history.
