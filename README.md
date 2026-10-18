# void-hardperf-light

A hardened, fast and minimal Linux distribution for one laptop (MSI GF63 Thin, i5-10500H,
UHD 630 + GTX 1650 Max-Q), built on top of Void Linux packages. It is the successor of
[Void-Hardened-Refurs](https://github.com/FalconBinary/Void-Hardened-Refurs) and keeps its
protection: LUKS2 + a signed UKI + our own Secure Boot keys + Limine, `lockdown=confidentiality`,
nftables per UID, DoT DNS, NTS time, a sandboxed browser, the RefursWM compositor and the
RefursLine bar. On top of that it grows its own components, all in **Zig 0.17**:

| Component | Replaces | Directory | Status |
|---|---|---|---|
| `vh-kconf`: a kernel built for this machine only (drivers built in, no loadable modules) | the stock `linux6.18` as the main kernel | `kernel/` | planned (track K) |
| `vh-init` + `vh-ctl` + `vh-logd`: a tiny PID 1 and a parallel service manager | runit, runit-void, socklog | `init/` | planned (track I) |
| `vh-sched`: a sched_ext CPU scheduler, BPF part and loader both in Zig | EEVDF + autogroup | `sched/` | planned (track S) |
| `thor` 2: a package manager over the Void repositories with parallel downloads | xbps + thor 1 | `thor/` | thor 1 here (track P) |
| `vh-install`: an English TUI installer | `install/*.sh` | `installer/` | planned (track N) |
| `vh-root`, `vh-game`: an isolated gaming session on tty3, removable with one command | — | `session/` | planned (track G) |
| RefursWM + RefursLine tuned for games and idle | — | their own repositories | planned (track D) |

The plan, with milestones, measurement rules and honest success criteria, is
[docs/ROADMAP.md](docs/ROADMAP.md). The rules that do not change are in
[docs/principles.md](docs/principles.md).

**Current state: milestone 0.** The repository holds the working system of
Void-Hardened-Refurs (installer, system configuration, the Zig tools, thor 1, the optional
hardening modules, the test rig) with every message and comment in English, plus the
scaffolding for the parallel tracks. Nothing new is wired into a running system yet.

```
UEFI (own SB keys) -> Limine (config hash enrolled)
   |- UKI "custom": this machine's kernel + initrd (LUKS, firmware, microcode)   [track K]
   '- UKI "stock":  the signed stock linux6.18 (fallback, always present)
 -> vh-init (PID 1) -> service manager -> vh-sched (sched_ext)                   [tracks I, S]
 -> tty1 user  -> RefursWM + RefursLine
    tty2 admin
    tty3 game  -> /var/lib/vh/roots/game (multilib, Steam, gamescope, NVIDIA libs) [track G]
```

## Repository layout

```
install/        the shell installer (00-probe, 10-install, chroot, 20-firstboot, 30-lock,
                build-desktop, build-tools, build-thor, fetch-zig, lib, packages): the
                specification for vh-install
rootfs/         files that land in the system (*.in are templates with @VH_*@ from vh.conf)
optional/       hardening modules: <module>/enable, disable; status
zig/            the Zig tools (vh-wlfilter, vh-acpid, vh-deadman, vh-limine-update, vh-pkg,
                vh-deep-clean, vh-seccomp, vh-uki-verify, vh-open, vh-usb-udev, pin-fetch,
                vh-hashpw); lib/ is shared code; README.md holds the code rules
thor/           thor 1: a patch to xbps 0.60.7, the policy (policy/), the thor command (src/)
desktop/        snapshots of RefursWM and RefursLine (track D replaces them with pinned fetches)
kernel/ init/ sched/ installer/ session/ bench/   the new tracks (scaffolding, see each README)
tools/          vh-bench, vh-session-usage
tests/vm/       the qemu + OVMF (Secure Boot) + swtpm rig: vhvm.py installs and boots without a
                human, check.py runs the steps from tests/vm/steps/*.py
tests/zig/      the Zig tools in docker: unit tests, self-tests, optional differential tests
tests/thor/     thor in docker: the policy on test packages, downloads, replacing xbps
docs/           ROADMAP.md, principles.md; ru/ holds the Russian guide of the predecessor
build.zig       the aggregator: zig build / zig build test over every Zig component
```

## Building and testing

Zig 0.17.0 exactly (`zig/ZIG_VERSION`; `install/fetch-zig.sh` downloads and verifies it).

```sh
zig build -Dtarget=x86_64-linux --prefix build/out   # every Zig program of every track
zig build tests -Dtarget=x86_64-linux --prefix build/zt && for t in build/zt/test/*; do "$t"; done
                                                      # unit tests: built once, run directly on Linux
sh tests/zig/run.sh                                   # the tools in a Void container (docker)
sh tests/thor/run.sh                                  # thor in a Void container (docker)
python3 tests/vm/vhvm.py install --iso void-live-x86_64-20250202-base.iso
python3 tests/vm/check.py all                         # base, enroll, sb, lock, desktop
```

CI (`.github/workflows/`) runs the unit tests and the docker tests on every push, and the
QEMU/KVM smoke test and the `kernel-fat` build on demand; their artifacts are attached to
releases so they can be downloaded without GitHub credentials.

## Hardware

Written for the **MSI GF63 Thin 10SCXR/10SCSR (MS-16R5)**: Intel Core i5-10500H (6C/12T,
Comet Lake), UHD 630 + GTX 1650 Max-Q (TU117), Intel AX201, Realtek RTL8111, NVMe, TPM 2.0.
The hardware probe (`install/00-probe.sh`, later `vh-kconf probe`) tells what to change for a
similar Intel laptop. The dGPU stays powered off unless the gaming session is installed; the
gaming session uses the open NVIDIA kernel modules, built and signed together with the kernel.

## Documentation

- [docs/ROADMAP.md](docs/ROADMAP.md): the plan: components, milestones, measurements, risks.
- [docs/principles.md](docs/principles.md): the rules that every change follows.
- [docs/ru/](docs/ru/): the Russian guide of Void-Hardened-Refurs (chapters 00-18). It describes
  the system this repository starts from; the English chapters are written per milestone.

## License

GPL-3.0 ([LICENSE](LICENSE)). The BPF part of the scheduler, `sched/bpf/`, is GPL-2.0-only:
the kernel requires a GPL-compatible licence for GPL-only kfuncs.

Source: Void-Hardened-Refurs @ 8af9d04 plus its working tree, transferred without history.
