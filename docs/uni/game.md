# UniVoidDistro: the gaming session (track G)

Games run in an isolated session on tty3: the user `game`, a Void userland of its own under
`/var/lib/vh/roots/game`, namespaces, no access to the everyday user's files, a sound server of
its own. The everyday system stays as it is: no new package, service, kernel feature or open port
in it; what the session needs of it (the account, the login, a udev rule for the sound cards)
comes with `vh-game install` and goes with `vh-game remove`. Upstream planned the
track ([ROADMAP.md](../ROADMAP.md#g-vh-root-vh-game)) and has not started it; it is built here, and
where UniVoidDistro's design differs from upstream's plan this file says so.

The rules of [principles](principles.md) apply, the four maximums above all: lightness,
optimisation, performance and protection each at their maximum; where one can only be bought with
another, the user chooses. The user's decisions of 2026-10-20 are in the table below.

## Phases

| Phase | What | State |
|---|---|---|
| **G1** | `vh-root`, the gaming root, the login of `game` on tty3; Vulkan through Mesa (the GPU's driver from the plan); no network, no sound, no 32-bit, no kernel change; the remove-and-compare test | built; verified in a container and on the VM rig, 23 of 23 ([below](#what-is-verified)); not yet on hardware |
| **G2** | sound: the session's own PipeWire (with WirePlumber and its pulse server) in the gaming root, on the sound cards' playback and control nodes alone, which `game` gets by an ACL entry of a udev rule; no microphone, no camera, no process of the everyday user in reach ([below](#g2-sound)) | built; verified in a container and on the VM rig, 36 of 36 ([below](#what-is-verified)); not yet on hardware |
| **G3a** | the gaming boot, on any machine: the stock UKI's twin with `ia32_emulation=1`, the last entry of Limine's menu, booted once by `vh-game play`; in it every process tree but the gaming session's under a seccomp filter that kills a 32-bit system call, the controllers' drivers, the login of `game` on tty3 by itself; no build, no key ([below](#g3a-the-gaming-boot)) | built; verified in containers; the VM rig: pending |
| G3b | the build root (thor `-r`, removed after each build) and the gaming kernel built on the machine: the machine kernel's resolve with `features/game` (ia32, NTSYNC, controllers, modules for NVIDIA only), the user's certificate the only module key it trusts, `MODULE_SIG_FORCE`, lockdown and kCFI kept | planned |
| G3c | the open NVIDIA modules (Turing and newer) built DKMS-style in the build root against the gaming kernel, signed outside it with the user's key under a passphrase; `/dev/nvidia*` for `game` alone; the NVIDIA userspace of the same version (with 32-bit) in the gaming root | planned |
| G3d | the NVIDIA driver by the GPU's PCI id (hwdb): the open modules for Turing and newer, Void's closed 580 for Maxwell to Volta, 470 for Kepler, none for older GPUs | planned |
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

The user's decisions of 2026-10-21, on the gaming boot (G3a):

| Question | Decision |
|---|---|
| the gaming boot of a machine without NVIDIA | the **stock signed UKI with `ia32_emulation=1`**, for every machine: no build, no compiler, no key; a machine gaming kernel without loadable modules becomes an option once the build root exists (G3b) |
| ia32 in the gaming boot | a **seccomp filter "the x86_64 ABI only"** on every process tree of that boot but the gaming session's (the services, the gettys and logins, the desktop): a 32-bit system call kills the process, and only the gaming session reaches the kernel's ia32 code. Upstream planned this (`kernel/profiles/features/game`) and did not build it |

The user's decisions of 2026-10-21, on sound (G2):

| Question | Decision |
|---|---|
| through the everyday user's PipeWire, or a server of the session's own | **the session's own PipeWire** in the gaming root: no game talks to a process of the everyday user, and the session has sound without the desktop too; the price: one card, two servers taking it in turn, and no Bluetooth headphones in the session ([below](#g2-sound)) |
| how `game` reaches the sound cards | an **ACL entry** on each card's playback and control nodes, by a udev rule `vh-game install` adds (at every boot and hotplug); not the group `audio`, which would bring the capture nodes too |
| realtime scheduling for the session's sound | **none**, as the desktop's PipeWire (`realtime = false`): an `rtprio` limit for `game` is a later choice, should the sound crackle under a game's load |

Upstream's plan made the everyday user's restricted pulse socket the main path (after the
browser's, `60-vh-sandbox.conf`). Checked before G2 was built, on PipeWire 1.6.9 and WirePlumber
0.5.18: that socket is no boundary. A client sets `pipewire.client.access` in its own pulse
property list, pipewire-pulse copies it over the socket's, and PipeWire's access module in its
default mode trusts it: the client then has the whole PipeWire of the user, the microphone with
it. Without that, a client of the socket still loads pulse modules into the user's server and
records every sink's monitor. So no socket of the everyday user's sound server is handed to the
gaming session; the browser's socket is a finding of its own, outside track G.

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
  ia32 (Steam and 32-bit games need it), in one of two ways; the user chose the first (2026-10-21),
  the second becomes an option with G3b:
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

## G2: sound

```
vh-game install         the root's packages: pipewire (its pulse server in it) and wireplumber;
                        the udev rule 99-vh-game.rules: game's ACL entry (rw) on every sound
                        card's control and playback nodes, now and at every boot and hotplug
tty3: login game
  -> vh-game-enter      the session's /dev/snd: the system's, its playback and control nodes as
                        they are, every other node /dev/null; PID 1 starts the root's PipeWire,
                        which starts WirePlumber and its pulse server; the program (PID 2) waits
                        for the pulse socket, at most 5 s
     gamescope -f -- GAME   a game plays through $XDG_RUNTIME_DIR/pulse/native (Proton, Wine,
                        FMOD, Steam) or PipeWire's own socket (SDL), both the session's own
vh-game remove          the rule, then game's entry on every node: the mode alone again
```

- **The devices.** The udev rule names the nodes a game plays through: `controlC*` (the card's
  mixer, which alsa-lib opens with every PCM) and `pcmC*D*p` (playback). Never a capture node
  (the microphone), the codec's hwdep, the sequencer or the timer; and `game` stays out of the
  group `audio`, which would give it all of them. The session binds the system's `/dev/snd` as it
  is, for PipeWire takes a card only when every PCM node of it opens and reads the node types of
  the directory, and covers each node but those two kinds with `/dev/null`: what a game opens
  as the microphone is empty. A card plugged in during a session is not seen (as an input
  device): the next session has it.
- **The server.** The root's own `/usr/bin/pipewire`, started by the session's PID 1 when the
  session has a playback node `game` opens and the root has PipeWire; as the session's programs,
  without privilege or capability, without the terminal, its output in
  `$XDG_RUNTIME_DIR/vh-sound.log`. Its configuration is in the root (`/etc/pipewire`,
  `/etc/wireplumber`, written by `vh-game install`): linked in as the system's (install/chroot.sh);
  no realtime module, no portal, no JACK detection, no X11 bell, no D-Bus name; WirePlumber for the
  sound cards alone (no Bluetooth, cameras, MIDI or D-Bus: 8 MB of memory in place of 18). Its
  state (the volume, the chosen output) lives in the home, from one session to the next.
- **One card, two servers.** The desktop's PipeWire and the session's both open the card's
  playback device, which ALSA gives to one at a time; each lets it go after 5 seconds of
  silence (WirePlumber suspends an idle card). A session started while the desktop plays (music,
  a background tab with Web Audio) finds the card busy and waits: it takes the card as soon as the
  desktop's PipeWire has closed it (an inotify event of `/dev/snd`). While a game plays, the
  desktop's sound is refused the same way. Mixing the two would need a server both reach, which
  is what G2 does not give a game.
- **Not in the session:** Bluetooth headphones (BlueZ answers on the system's D-Bus, which the
  session does not reach), a microphone (game voice chat), a camera.

## G3a: the gaming boot

```
doas vh-game boot on    /etc/vh/game-boot (the marker) and /etc/runit/core-services/98-vh-game.sh;
                        vh-limine-update: the twin of the newest stock UKI in EFI/vh-game,
                        signed, the last entry of Limine's menu, "Void Linux VER (games)"
doas vh-game play       Limine's one-shot entry names it; the reboot
  -> Limine             the gaming entry, once (Limine erases the one-shot entry before it boots it)
  -> stage 1            the controllers' drivers, before the module lock; the marker bound over
                        /etc/runit/2
  -> stage 2            runit runs the marker, "#!/usr/local/sbin/vh-game stage2": the bind mount
                        goes, tty3's getty starts outside the filter, the x86_64 filter is set on
                        stage 2 itself, runit-void's /etc/runit/2 runs under it
  -> tty3: login game   the gaming session as in G1 and G2, ia32 within its reach alone
the next boot           the everyday one, as before: ia32_emulation=0, no filter, no getty on tty3
doas vh-game boot off   the marker, the script, the twin and its entry go (vh-game remove too)
```

- **The twin** (`zig/lib/twin.zig`, vh-limine-update). Under Secure Boot systemd-stub ignores a
  command line from the boot loader, so the gaming boot needs a UKI of its own. The plan's rule
  `x86.ia32-off` puts `ia32_emulation=0` into every x86_64 command line; the twin is the newest
  stock UKI with that one byte changed to `1`, in place: every section where it was, the kernel,
  the initrd and every other parameter the stock UKI's, as dracut made them and the everyday boot
  runs them. No second dracut run. The stock UKI's signature is cut off and the twin signed with
  the db key as every UKI; limine.conf carries its BLAKE2B. A twin already on the ESP is kept as
  it is; a stock kernel update makes the new twin and deletes the older one. A stock UKI whose
  command line lacks `ia32_emulation=0` gets no twin: vh-limine-update stops before it writes
  anything. The PE image is untrusted data: every offset and size is checked.
- **The entry and `play`.** The gaming entry is the last of the menu and never the default.
  `vh-game play` runs `vh-limine-update --game-once`: Limine's one-shot entry names it, and the boot
  after the gaming one is the default again. It is refused while a machine kernel's trial waits for
  the next boot (the one-shot entry is the trial's). A kernel update between `play` and the
  reboot carries the one-shot entry to the new twin; `boot off` deletes one that names it. The
  boot assessment of a machine kernel counts the gaming boot neither for nor against it.
- **The filter** (`session/src/boot.zig`): seven classic BPF instructions. Not x86_64: the process
  is killed (`SECCOMP_RET_KILL_PROCESS`) before the kernel's ia32 code runs, whether the call came
  from a 32-bit program or from `int $0x80`; the x32 ABI: `ENOSYS`; everything else: allowed. Root
  sets it with `CAP_SYS_ADMIN` and without `no_new_privs`, so doas and the other SUID programs work
  under it. Every x86_64 verdict rests on the call's number alone, so the kernel's seccomp cache
  answers those calls without running the program [VERIFY by bench: the cost on a system-call-heavy
  load]. Every process tree of the boot inherits it, the desktop and the browser too (their own
  sandboxes stack on top); the gaming session, started from tty3's getty outside it, does not.
- **tty3.** In the gaming boot its getty starts with stage 2; `vh-game tty on` from a filtered
  shell is refused there (a getty started from it would carry the filter).
- **Controllers.** `xpad`, `joydev`, `hid-playstation`, `hid-sony`, `hid-nintendo`, `hid-steam`,
  `hid-microsoft`, `hid-logitech` (and `-dj`, `-hidpp`), `usbhid`, `hid-generic`: modules of the stock
  kernel, loaded in the gaming boot before the module lock, so that a pad plugged in later works.
  The everyday boot loads none of them unless such a pad is there at boot. `uhid` (on the plan's
  `module_blacklist`) and `uinput` (Steam Input): G4.
- **Stage 1, either one.** runit-void's stage 1 sources `98-vh-game.sh`; vh-stage1 (track I, where
  it replaces runit's stage 1) runs `vh-game stage1` by argv in its step `vh-game`, before the
  module lock. Either checks the command line first: in an everyday boot nothing else runs.
- **What the system gets:** two files in `/etc` (the marker, 0755, and the script, 0644) and the
  twin on the ESP, while the gaming boot is on; `vh-game boot off` and `vh-game remove` take them
  away.

## The cost (G1 and G2, the GF63 of the fixtures)

Sizes measured with `xbps-install -n` in a fresh x86_64 root (Void, 2026-10-20 and -21); memory of
the sound server measured idle in a container (aarch64, PipeWire 1.6.9, WirePlumber 0.5.18); the
others are estimates until the GF63 measures them.

| | Size | RAM | Boot | Speed | Protection |
|---|---|---|---|---|---|
| the gaming root (gamescope, Mesa for Intel, Vulkan) | 584 MiB installed, 161 MiB downloaded; less without documentation | none until a session runs | none | native: namespaces cost nothing on the hot path [VERIFY by bench] | the system's packages and policy unchanged; Xwayland only in the root |
| the programs `vh-root`, `vh-game`, `vh-game-enter` | about 1.1 MiB in `/usr/local`, on every installation | none: no process before `vh-game install` and `tty on` | none | — | — |
| the session | the home's data | gamescope and Xwayland [estimate 0.2 GiB] | — | the GPU's own driver; on a laptop with the NVIDIA dGPU asleep (`VH_GPU=auto`), the iGPU; NVK with `VH_GPU=nouveau` (slower in games) | a login on tty3 with a password, while `tty on`; the user's files out of reach (other uid, 0700 homes, the root as `/`); no network |
| G2: the session's sound server | +21.9 MiB installed, +7.9 MiB downloaded in the root (23 packages: pipewire, wireplumber and theirs; 603 to 625 MiB); in the system one udev rule while installed | none until a session runs; in a session 14.5 MB PSS (PipeWire 3.5, WirePlumber 7.8, its pulse server 3.3; 24 MB RSS) | none: no service; the udev rule sets an ACL on the cards' playback and control nodes (3 to 6 of them) [estimate: milliseconds] | the session's own graph; SDL speaks PipeWire's own protocol, Proton and Wine pulse; no realtime scheduling (as the desktop); the program waits for the pulse socket at the session's start (53 ms in the container) | no microphone and no camera in the session: the capture nodes are `/dev/null` there, no video node at all; no process of the everyday user in reach; `game` reaches the playback and control nodes only, also outside a session |

G3a, the gaming boot:

| | Size | RAM | Boot | Speed | Protection |
|---|---|---|---|---|---|
| the twin UKI | one more UKI on the ESP while the gaming boot is on, the size of the stock one [estimate 60-90 MB of the 1 GiB ESP; the rig measures it] | none | the everyday boot: the stage-1 script's test of the command line; the gaming boot: the controllers' drivers [estimate: some 100 ms] | the stock kernel's (Void's, built by GCC, its modules signed) | the everyday boot unchanged (`ia32_emulation=0`, its own UKI) |
| the gaming boot | — | the controllers' drivers [estimate: a few hundred KB] | — | the filter: nothing for an x86_64 call the seccomp cache answers [VERIFY by bench] | ia32 open to the gaming session only; the stock kernel there, with loadable modules (Void's signature, then the module lock) and without kCFI: weaker than a machine kernel's everyday boot, a machine gaming kernel with G3b |

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
| a game changes the card's mixer (G2) | the control node is the mixer's: volumes, mutes, the codec's switches, the capture gain among them; no sound data comes through it, and the desktop's PipeWire sets its own levels when it next opens the card |
| the desktop's sound and a game's take turns (G2) | one ALSA device, two servers: each lets it go after 5 seconds of silence; a session waits for a card the desktop plays on and takes it when it is free |
| the filter cannot be set at stage 2 (G3a) | it cannot fail on Void's kernel; if it did, the boot goes on (a boot without its services is worse), says so on the console, and vh-audit fails the gaming boot |
| `ia32_emulation=1` in `VH_EXTRA_CMDLINE` (G3a) | every boot is then a gaming one while the gaming boot is on: the filter and tty3's login with it |
| the twin is signed at every stock kernel update (G3a) | as every UKI: the db key signs what is on the ESP; with `optional/sb-offline-keys`, `boot on` and kernel updates need the keys' medium |

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

G2 (sound), 2026-10-21:

- The unit tests: the nodes of a card the session plays through (`controlC<n>`, `pcmC<n>D<m>p`)
  and none else (capture, hwdep, sequencer, timer, compress offload, MIDI, look-alikes); `game`'s
  ACL entry on a node added and taken away to the mode alone, the mask recomputed; the udev rule
  names the same nodes and the user.
- End to end in the container, with a card's nodes made as udev makes them (root:audio 0660:
  control, playback, capture, hwdep, timer, sequencer): the rule in place, `game`'s entry on the
  control and playback nodes only, `game` opens the playback node and not the capture node; the
  root's PipeWire configuration (and, with every package, pipewire and wireplumber in it); after
  the removal the whole system byte for byte and no ACL left on the nodes. The session itself,
  unprivileged, in the `session` workflow (every package; run 39579610273, 2026-10-21): its
  `/dev/snd` (the playback and control nodes as they are, the rest `/dev/null`), `--check` with
  its sound lines, its own server's pulse socket there before the program, which is PID 2. Its
  first run found that the server's process could not drop its capabilities once PID 1 had made
  an access check (`EPERM`): the process now gives them up before it looks at the cards.
- Before it was built, in a container: the session's PipeWire and WirePlumber start without
  D-Bus with this configuration and play through a pulse client (14.5 MB PSS against 25 with the
  full WirePlumber).
- On the VM rig, `kvm-smoke` with `step=game` and QEMU's sound card (an HD Audio controller and a
  codec with a playback and a capture PCM, its output into a WAV file on the runner): 36 of 36 (run
  39591214131, 2026-10-21). The root: 198 packages, 606 MiB. `game`'s ACL entry on `controlC0` and
  `pcmC0D0p` after the install and, after a reboot, from the udev rule; none on `pcmC0D0c` or the
  codec's hwdep. The session's own PipeWire has the card's sink and no source but its monitor; noise
  played through the pulse server and through PipeWire's protocol came out of the card (the WAV
  file's peak 32763 of 32767). The everyday user's PipeWire, started as the desktop starts it,
  played; a session started meanwhile had no sink of the card, took it 7 to 8 seconds later (the
  user's PipeWire had let it go) and played, and the user's PipeWire then found it busy (`playback
  open failed: Device or resource busy`). The login on tty3 runs PipeWire, WirePlumber and the pulse
  server in the session's PID namespace. After the removal the whole system byte for byte, no ACL
  left on the card's nodes (mode 660), vh-audit as before. The runs before it found: the server's
  process unable to drop its capabilities (the `session` workflow), and four faults of the step
  itself (a `wait` that would have waited for the user's PipeWire, WirePlumber's first sink volume
  of 0.4 under the WAV's threshold, two lines read from their start after the shell's prompt, a
  snapshot taken before the boot's `vh-kconf check` had written its view of the machine with the new
  sound card).

G3a (the gaming boot), 2026-10-21:

- The unit tests: the twin of a stock UKI (unsigned and signed: the certificate table cut, its entry
  zeroed, one byte of the command line changed, nothing moved), the comparison with a twin signed
  since, the refusals (no `ia32_emulation=0`, ia32 on already, not a PE image, a certificate table
  not at the end); the gaming entry's identifier, and the boot assessment that reports nothing for
  a gaming boot while a machine kernel is the default; `ia32_emulation=` as the kernel reads it
  (the last one decides, kstrtobool's values); the filter's verdicts (x86_64 allowed, i386 killed,
  x32 `ENOSYS`, no argument read) and, on x86_64, a real process killed by `SIGSYS` at `int $0x80`.
- vh-limine-update on a tmpfs ESP with a tmpfs in place of efivarfs (`tests/zig/assess_test.py`):
  the twin and its entry, the twin kept by a second run, `--game-once` and the boots Limine 12.9.3
  makes of it, a kernel update between `play` and the reboot, `play` refused while a trial waits,
  no twin of a command line without `ia32_emulation=0`, `boot off`.
- End to end in the container: `vh-game boot on` and `off` (with a stand-in for vh-limine-update),
  stage 1 doing nothing outside the gaming boot, stage 2 refused by hand, `remove` turning the
  gaming boot off, the system byte for byte.
- The VM rig (`kvm-smoke`, `step=gameboot`): pending.

[VERIFY on hardware]: gamescope on the GF63's UHD 630 (ANV) and, with `VH_GPU=nouveau`, on its GTX
1650 (NVK); the switch between tty1 and tty3 under seatd (DRM master and the input devices taken
back); the session's speed against the same game outside it. G2: the session's sound on the
GF63's speakers, its headphones (the codec mutes the speakers by itself) and HDMI; the switch
from the desktop playing music to a game and back; the latency in a real game; crackles under a
game's load (then the realtime question).
