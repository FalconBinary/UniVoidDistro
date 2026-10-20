# UniVoidDistro: the gaming session (track G)

Games run in an isolated session on tty3: the user `game`, a Void userland of its own under
`/var/lib/vh/roots/game`, namespaces, no access to the everyday user's files. The everyday system
stays as it is: no new package, service, kernel feature or open port in it. Upstream planned the
track ([ROADMAP.md](../ROADMAP.md#g-vh-root-vh-game)) and has not started it; it is built here, and
where UniVoidDistro's design differs from upstream's plan this file says so.

The rules of [principles](principles.md) apply, the four maximums above all: lightness,
optimisation, performance and protection each at their maximum; where one can only be bought with
another, the user chooses. The user's decisions of 2026-10-20 are in the table below.

## Phases

| Phase | What | State |
|---|---|---|
| **G1** | `vh-root`, the gaming root, the login of `game` on tty3; Vulkan through Mesa (the GPU's driver from the plan); no network, no sound, no 32-bit, no kernel change; the remove-and-compare test | built; verified in a container and on the VM rig, 23 of 23 ([below](#what-is-verified)); not yet on hardware |
| G2 | sound: a second restricted pulse socket of the user's PipeWire for the group `game` (playback, no microphone), or the root's own PipeWire when no desktop runs [a spike] | planned |
| G3 | the gaming boot, on any GPU: a Limine entry of its own with ia32 for Steam and 32-bit games ([without NVIDIA](#machines-without-a-discrete-gpu-and-amd) no build and no key); where the plan finds an NVIDIA GPU, the gaming kernel (modules for NVIDIA only, ia32, NTSYNC, controllers) with the NVIDIA kernel module built on the machine in an isolated build root and signed with the user's own key under a passphrase, and the NVIDIA userspace (with 32-bit) in the gaming root | planned |
| G4 | Steam: multilib, the 32-bit Mesa, the network of the UID `game`, controllers | planned |
| G5 | the remove-and-compare test grows with every phase (the gaming boot, the build root, the key) | continuous |

## The user's decisions (2026-10-20)

| Question | Decision |
|---|---|
| where the NVIDIA module may live | a **separate gaming boot entry**: the everyday boot stays without modules, ia32 and the NVIDIA driver; a kernel module cannot be isolated (there is one kernel), so it exists only in the boot made for games |
| how the NVIDIA module is built | DKMS-style **on the machine**, in an isolated build root (compilers never in the system, nor in the gaming root, where untrusted game code writes), unprivileged, without network; signed with the **user's own key**, kept encrypted under a passphrase typed at each rebuild; the gaming kernel trusts that certificate only and keeps `MODULE_SIG_FORCE` and lockdown; a rebuild never runs in the background |
| open or closed module | the **open modules** for Turing and newer (all of their kernel code is source, built by the kernel's own compiler, so kCFI can stay [VERIFY]); NVIDIA's source pinned by sha256, so each driver version needs a pin update. Older GPUs: Void's closed branches by hwdb rules on the PCI id (580 for Maxwell to Volta, 470 for Kepler) |
| where the gaming kernel is built | locally, in the build root |
| the build root between builds | removed: no compiler on the disk between rebuilds |
| the session's network in G1 | a **network namespace of its own**: no network, and the abstract sockets of the session's Xwayland out of every other process's reach |
| the login of `game` | a password (yescrypt), tty3 only |
| the home | `/home/game`, a mount of its own with exec (games and their data run from it), nosuid, nodev |

What this changes against upstream's plan: the NVIDIA modules are built on the machine with the
user's key, not in CI with a one-time key; and the gaming kernel boots only from its own entry, so
`ia32_emulation=0` and `CONFIG_MODULES=n` hold for the everyday boot.

## Machines without a discrete GPU, and AMD

The gaming session does not need a discrete GPU. What a machine gets is a decision of the plan
(`hwdb/gpu.zon`), by the GPUs the probe finds:

- **G1 as it is.** The session uses the GPU's in-kernel driver, which the system has anyway (i915
  or xe for Intel, amdgpu for AMD: a signed module of the stock kernel, or built into the machine
  kernel), and Mesa in the gaming root: Vulkan through ANV or RADV, OpenGL through iris or
  radeonsi (`mesa-dri`). An AMD dGPU is the same case. A GPU without a Vulkan driver of Mesa gets
  lavapipe (the CPU). Tested on the plan of every fixture and on two machines made iGPU-only from
  them: the laptop without its NVIDIA dGPU (Intel, ANV) and the AMD desktop without its Radeon card
  (its Ryzen's iGPU, RADV); `intel-hybrid-laptop` is an iGPU-only Alder Lake laptop already.
- **G3 without NVIDIA: no build root, no compiler, no signing key, no module.** The hwdb rules that
  bring them match NVIDIA devices only. What G3 leaves on such a machine is the gaming boot for
  ia32 (Steam and 32-bit games need it), in one of two ways, the user's choice when G3 comes:
  - the **stock signed UKI with `ia32_emulation=1`** in place of `=0`: Void's kernel has ia32,
    NTSYNC, `modify_ldt` and System V IPC built in, and the controllers' drivers as modules,
    which go into the gaming boot's preload list before `modules_disabled=1`. No build at all.
    Cost: one more UKI on the ESP [estimate: 60-90 MB with its initrd] and the stock kernel's
    speed instead of the machine kernel's [VERIFY by bench];
  - a **machine gaming kernel**: the machine kernel with ia32, NTSYNC and the controllers built in
    and no loadable module at all, so no key. Cost: a kernel build for every kernel update (the
    build root, removed afterwards, or CI).

  The everyday boot's machine kernel is built without ia32 (`kernel/profiles/hardening`), so the
  same kernel with another command line is a gaming boot on the stock kernel only.
- **G4 (Steam)**: the 32-bit Mesa of the same GPU (`mesa-dri-32bit` and `mesa-vulkan-intel-32bit`
  or `-radeon-32bit`), from the same rules.
- **Old AMD GPUs** on the radeon driver (GCN 1.0 and 1.1 and older): radeon has no Vulkan of
  Mesa, so lavapipe. GCN 1.0 and 1.1 run on amdgpu with `amdgpu.si_support=1 amdgpu.cik_support=1
  radeon.si_support=0 radeon.cik_support=0` and get RADV: a later rule [VERIFY on hardware].
- **Hybrid laptops**: the desktop stays on the iGPU. With an AMD dGPU, games render on it through
  Mesa (DRI_PRIME), with no proprietary part; with an NVIDIA dGPU, in the gaming boot, through
  PRIME render offload of NVIDIA's driver. gamescope then shows on the iGPU's panel what the
  dGPU rendered [VERIFY on the GF63: gamescope with two GPUs is the main practical risk of a
  laptop].

## G1: how it works

```
doas vh-game install      the user game (its password asked for), /home/game, the gaming root
                          with the plan's Vulkan driver, the login on tty3
doas vh-game tty on       the getty of tty3 until the next boot (no process of the session before)
  -> tty3: login game     PAM: pam_access (game on tty3 only), pam_shells, the password
  -> vh-game-enter        the session: namespaces, the root as /, a login shell of the root
     gamescope -f -- GAME a game in gamescope on tty3 (DRM and input through seatd)
doas vh-game tty off      the getty and the session end
doas vh-game remove       everything install made, the home with it
```

- **The root** (`vh-root`, `session/profiles/game.zon`): thor installs it with `-r ROOT`, with the
  system's repository keys and repositories, under the root's own policy: learn while the profile's
  packages go in, then enforce, and thor's deny list holds there too except for the profile's
  exceptions (`xorg-server-xwayland`: gamescope's X server, which shows the games' windows only).
  The packages: `base-files`, `bash`, `coreutils`, `mesa-dri`, `vulkan-loader`, `Vulkan-Tools`,
  `gamescope` and the Vulkan driver of the machine's GPU, which a rule of `hwdb/gpu.zon` names
  (`game_packages`: `mesa-vulkan-intel`, `-radeon`, `-nouveau`; `mesa-vulkan-lavapipe` without a
  GPU that has one, as on the VM rig). Documentation and firmware are not extracted; the package
  cache is emptied after each install. `/var/lib/vh/roots` is a bind mount of itself with nosuid and
  nodev; thor strips SUID bits and file capabilities in every root as in the system. `game`, and
  nobody else, passes through `/var/lib/vh` (the system's state: vh-kconf check's, the boot
  assessment's, the kernel records) by one named-user entry of its ACL with the search bit; the
  ACL and the mode as they were are recorded, and the last root's removal puts them back. vh-root and vh-game work with umask
  022 whatever doas leaves them (the admin's 077), so that the root's directories and the caches
  its package scripts write stay readable to `game`.
- **The account**: `game`, its own group, the groups `_seatd` (seatd's socket) and `render` (the
  render nodes) only; never `input` (seatd hands the active session its input devices and takes
  them back at a VT switch), `video`, `audio` or `wheel`. vh-game writes the lines of passwd,
  shadow, group and gshadow itself, under the lock of lckpwdf(3): shadow's tools would rewrite the
  backups `/etc/passwd-` and the others, and the removal would not give the system back byte for
  byte. The password is hashed with yescrypt by libxcrypt (`vh-hashpw`, cost 7 as system-auth).
- **The session** (`vh-game-enter`, the login shell of `game`): no privilege and no helper running
  as root. It makes namespaces of user (game stays game inside: its uid and gid map to themselves,
  setgroups denied), mount, PID, IPC, UTS, network and cgroup; the root read-only as `/`; the home;
  a `/dev` of its own (null, zero, full, random, urandom, tty, the login's terminal, a new pts, shm,
  `/dev/dri`, nothing else); a `/proc` of its PID namespace; sysfs read-only; `/run` with seatd's
  socket and udev's database (read-only); `/tmp` and `/var/tmp` in memory; only `lo`; the host
  name `game`. The programs run with no new privileges and no capability. The session's first
  process is PID 1 of its namespace: when the login shell ends, everything of the session ends.
- **tty3**: the installer leaves logins on tty1 and tty2 only, and so does vh-game: `vh-game tty
  on` starts the getty under its own runsv until the next boot.
- **The removal** takes away every line it added, the root, the home, the mounts and their fstab
  lines, and the directories the first root brought. The test compares the whole file system
  before the install and after the removal: path, type, mode, owner, size, link target, the
  sha256 of every file and every extended ACL.

## The cost (G1, the GF63 of the fixtures)

Sizes measured with `xbps-install -n` in a fresh x86_64 root (Void, 2026-10-20); the others are
estimates until the GF63 measures them.

| | Size | RAM | Boot | Speed | Protection |
|---|---|---|---|---|---|
| the gaming root (gamescope, Mesa for Intel, Vulkan) | 584 MiB installed, 161 MiB downloaded; less without documentation | none until a session runs | none | native: namespaces cost nothing on the hot path [VERIFY by bench] | the system's packages and policy unchanged; Xwayland only in the root |
| the programs `vh-root`, `vh-game`, `vh-game-enter` | about 1.1 MiB in `/usr/local`, on every installation | none: no process before `vh-game install` and `tty on` | none | — | — |
| the session | the home's data | gamescope and Xwayland [estimate 0.2 GiB] | — | the GPU's own driver; on a laptop with the NVIDIA dGPU asleep (`VH_GPU=auto`), the iGPU; NVK with `VH_GPU=nouveau` (slower in games) | a login on tty3 with a password, while `tty on`; the user's files out of reach (other uid, 0700 homes, the root as `/`); no network |

Later phases, measured the same way: Steam with the 32-bit Mesa brings the root to 1355 MiB, the
NVIDIA userspace with its 32-bit part adds 869 MiB, the build root's clang toolchain takes about
1.0-1.2 GiB while it exists (removed after each build).

## Residual risks of G1

| Risk | Answer |
|---|---|
| a bug in the kernel reached through user namespaces | they are open to every user already (the browser's sandbox uses them); the session adds no new interface; its programs have no capability and no new privileges |
| a game reads what the user types elsewhere | the session is on its own VT; seatd gives gamescope the input devices only while tty3 is the active VT |
| no hotplug of input devices during a session | the network namespace of the session's own user namespace receives no uevents (`lib/kobject_uevent.c`, `uevent_net_init`) [VERIFY]: a device plugged in later works from the next session |
| the gaming root falls behind | `doas vh-root update game` (thor update in the root) |

## What is verified

- The unit tests of `session/` (`sh tests/session/run.sh`): the line edits and their exact
  inverses (passwd, group, shadow, gshadow, access.conf, /etc/shells, fstab), the lock and the
  owner and mode of replaced files, the removal of a tree (no symlink followed, no file system
  entered), the plan's values.
- End to end in a privileged Void container (`tests/session/run.sh`), the container's own root as
  the system, with xbps-install in place of thor: install, every line, mount, mode and policy;
  remove; the whole file system before the install and after the removal the same, byte for
  byte; a second removal changes nothing. The unprivileged session itself needs user namespaces
  that colima's Ubuntu restricts (`kernel.apparmor_restrict_unprivileged_userns=1`); the `session`
  workflow lifts that on its runner.
- The plan: `game_packages` on the golden plans of every machine (`tests/adapt/run.sh`) and a unit
  test on the real hwdb (the GF63: `mesa-vulkan-intel`, with `VH_GPU=nouveau` NVK beside it; the
  AMD desktop: RADV; the Intel laptop with its iGPU alone: ANV; the q35 rig: lavapipe; ARM: none;
  the GF63 without its dGPU: ANV, no dGPU tag; the AMD desktop without its card: RADV of the
  Ryzen's iGPU).
- On the VM rig, `kvm-smoke` with `step=game` ([tests/vm/steps/session.py](../../tests/vm/steps/session.py)):
  23 of 23 (run 39500995500, 2026-10-21). vh-game install through doas with the rig's own plan
  and thor from the mirrors (175 packages, 583 MiB, lavapipe); the root 0750 root:game; game
  reaches it, another user does not (the ACL of `/var/lib/vh`); vh-audit without a new FAIL (170
  ok before, 182 with the session's area, the one FAIL Secure Boot before `20-firstboot.sh`);
  `vh-game-enter --check` from inside, 24 of 24; Vulkan in the root (llvmpipe, Vulkan 1.4); after a
  reboot both mounts from fstab with nosuid and nodev and tty3 off; `vh-game tty on`, the login of
  `game` on tty3 typed on the VM's keyboard: a session in namespaces of its own (user, mount, PID,
  network, IPC, UTS, cgroup), no capability, no new privileges, no seccomp filter, in the root,
  on `/dev/tty3`; `tty off` ends the getty and the session; remove; the whole system before the
  install and after the removal, across the reboot, the same byte for byte (with every extended
  ACL), the nft ruleset and hw.zon too; vh-audit as before. What the runs before it found, each
  fixed: doas's umask 077 made `/var/lib/vh` and the root's directories root's alone (vh-game-enter
  found no root); the search bit for every user that first fixed it became an ACL entry for game
  alone; and the step's own scaffolding (its snapshot in `/var/tmp`, which the reboot empties;
  runsv's state files of the system's own services on the disk).

[VERIFY on hardware]: gamescope on the GF63's UHD 630 (ANV) and, with `VH_GPU=nouveau`, on its GTX
1650 (NVK); the switch between tty1 and tty3 under seatd (DRM master and the input devices taken
back); the session's speed against the same game outside it.
