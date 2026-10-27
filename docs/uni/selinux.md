# UniVoidDistro: SELinux (track E)

A mandatory access control policy written for this system alone, stronger than Fedora's
`targeted` policy in the ways the table below lists, and meant to stay convenient: nothing to
configure, one command to see what the policy refused, one to switch the mode of the next
boot. It is `VH_MAC=selinux` in `vh.conf`; the default stays `apparmor` until the definition
of done below is met. Owned files: `selinux/`, `tests/selinux/`, `zig/lib/selabel.zig`,
`zig/tools/vh-selabel.zig`, `zig/tools/vh-shell.zig`, `rootfs/usr/local/sbin/vh-selinux`,
the audit area `25-selinux.sh`, the stage-1 steps `vh-selinux` and `vh-selinux-label`.

## Why not the reference policy

Fedora, Debian and Gentoo build their policies from the reference policy: about 1 300
modules for every program a distribution may ship, `unconfined_t` for the people and for
root, booleans that loosen what breaks, and a toolchain (libselinux, semanage, setfiles,
restorecon, audit2allow) that Void does not package. This system has a fixed inventory: about
forty programs, twelve of them daemons, three kinds of people. A policy for exactly that is
2 300 lines of CIL (`selinux/policy/`), readable in an afternoon, with no unconfined domain
and nothing it does not need. The kernel loads it from one file; no library is needed to
run with it: the labels are set by `vh-selabel` (Zig, `std.os.linux` only), the policy by
stage 1 with one `write(2)`.

## Stronger than Fedora: what, and what it costs

| | Fedora targeted | UniVoidDistro | protects / residual risk / cost |
|---|---|---|---|
| the people | `unconfined_t`: a logged-in user, and root, may do anything the DAC allows | `user_t`, `admin_t`, `game_t`: a domain with a list each; `doas` leads the admin into `sysadm_t`, a confined administration domain, and the everyday user into exactly the three commands doas.conf names, each a domain of its own; the roles make the admin's domains unreachable from the user's shell even with a wrong doas.conf | a compromised session or shell cannot read another person's files, the Wi-Fi passphrases, the Secure Boot keys, cannot load a module, a policy or a BPF program / the admin has to use doas for everything root does (already so) / none measured |
| the policy at run time | `setenforce 0`, `semodule -i`, `setsebool` by root at any time | **one-way**: after the load, stage 1 sets `secure_mode_policyload`; from then to the next boot no domain may load a policy, switch enforcing off or set a boolean (the rules that would allow it live inside the boolean's block; neverallow #1 keeps everything else out, checked by the compiler) | a root exploit cannot turn the policy off / the admin cannot either: a change is `doas vh-selinux mode` and a reboot / none |
| permissive domains | several in the shipped policy | none; `tests/selinux/checks.py` fails on one | |
| ptrace | `deny_ptrace` boolean, off by default | no ptrace anywhere, not even a domain on itself (neverallow #2) | debuggers do not attach; Firefox's crash reporter does not work / `strace` and `gdb` are not installed anyway |
| executable memory | `allow_execmem`, `allow_execstack` for `unconfined_t` and many domains | `execmem` for the browser's JIT and the gaming root only; `execstack` for the same two; `execmod` for nothing but the gaming root (neverallow #3) | a shellcode in a daemon or a shell cannot run; the memfd-exec class of attacks is closed by the policy, not only by the sysctl / a program that needs a JIT (python's ctypes, a JIT-ed language) does not run outside the browser or the game root |
| kernel modules, kexec | `insmod` by root | loaded by init during stage 1 and by udev; nobody has `sys_module` after that; no `kexec` for anyone (neverallow #4) | with the module lock this is the second lock / none |
| raw I/O, `/dev/mem`, MSRs | `sys_rawio` for several domains | the file-system tools, the dead man's switch and udev; `/dev/mem`, `/dev/port`, the MSRs are nobody's (and not built) | |
| BPF | several domains may load programs | the scheduler's loader and init (neverallow #6) | a compromised process cannot load a BPF program even with `CAP_BPF` |
| writing programs | `rpm_t`, root, `unconfined_t` | the package manager's domain and init alone write a program file, in `/usr` or in a service's path (neverallow #7) | a service that is compromised cannot leave a program behind; persistence needs the package manager / a program built by hand goes into `VH_DEV_DIR` under `/home`, where `noexec` already applies |
| secrets | `shadow_t` readable by many auth domains | shadow: login, doas, the password helper, the admin's domain, the package manager; the Wi-Fi passphrases: iwd; the Secure Boot keys: the package manager's hooks, the boot tools, the admin; the seed: init (neverallow #8) | |
| the people's files | the admin reads everything | the everyday user's home is the user's and the desktop's (the compositor, the bar, PipeWire, the lock): not the admin's, not a daemon's, not the browser's (neverallow #9) | an administrator account that is compromised cannot read the user's data / the admin manages the user's home through the user, or by booting the live image |
| input devices | the user's programs may read `/dev/input` with the DAC's leave | the compositor (through seatd), seatd, vh-acpid, the dead man's switch, the gaming session, udev, the admin as root (neverallow #10) | no keylogger in the user's session, whatever its DAC rights |
| the network | `nis_enabled`, `httpd_can_network_connect`... booleans | each daemon connects to the ports it is for: unbound to 853, chronyd to 4460, the browser to 80 and 443 (neverallow #13); the people's shells to any port, as nftables already allows them | a daemon that is compromised cannot phone home |
| unknown classes and permissions | `handle_unknown = allow` | `deny`: the classes come from the kernel's own `classmap.h` (`selinux/pins`), generated | a kernel newer than the pin needs the pin updated (`selinux/tools/classes.py`) |
| the SELinux user and MCS | `seusers`, `unconfined_u`, `staff_u`; MCS for containers | one SELinux user; the roles and the types carry the separation; MLS with one sensitivity and no categories (every context ends in `s0`) | categories would add nothing until the two browser profiles get domains of their own (v2) |
| `selinux=0`, `enforcing=0` on the command line | both work | `CONFIG_SECURITY_SELINUX_BOOTPARAM` is off; `enforcing=0` exists for the machine kernel's developer and the command line is inside the signed UKI | |

What Fedora has and this policy does not: the breadth (a policy for any program a user may
install), the tooling (`audit2allow`, `semanage`, booleans to loosen things), MCS/MLS beyond
`s0`, labelled networking (`netlabel`), the D-Bus and X mediation in user space. None of
them is a loss here: the inventory is fixed, there is no X, and D-Bus clients are the policy's
domains already.

## How it is built and loaded

```
selinux/pins/classmap-6.18.h            the kernel's object classes (security/selinux/include/classmap.h, v6.18)
selinux/tools/classes.py                -> selinux/policy/00-classes.cil (generated: 96 classes, 27 SIDs)
selinux/policy/01-base.cil              attributes, permission sets, macros, every file and device type,
                                        ports, SIDs, fsuse/genfscon, the constraints
selinux/policy/10-init.cil              kernel_t, init_t (init_domain), initrc_t (the service scripts),
                                        initctl_t (poweroff, vh-ctl), the one-way boolean
selinux/policy/20-system.cil            udev, dbus, the log, getty, login, doas, sysadm_t, pkg_t, chkpwd_t, fsadm_t
selinux/policy/30-network.cil           unbound, chronyd, iwd, dhcpcd, bluetoothd
selinux/policy/40-session.cil           user_t, admin_t, game_t, the compositor, the bar, PipeWire, the
                                        Wayland filter, the lock, the backlight, the browser sandbox, seatd
selinux/policy/50-vh.cil                vh-acpid, the plan and boot tools, the root scripts, vh-sched, vh-deadman
selinux/policy/90-neverallow.cil        the invariants of the table, named nv_*: secilc refuses a policy
                                        that breaks one
selinux/policy/95-filecon.cil           the labels by path -> file_contexts
selinux/build.sh OUT                    secilc -c 33 (in a Fedora container: Void has no secilc)
                                        -> OUT/policy.33, file_contexts, BUILD, SHA256SUMS
tests/selinux/run.sh                    compiles, then tests/selinux/checks.py reads the policy back
                                        with setools: no unconfined, no permissive, the setenforce and
                                        load_policy rules conditional and init's only, the people and
                                        the browser away from what is not theirs, every exec type entered
                                        by a transition, every domain in a role, the file contexts within
                                        vh-selabel's subset
tests/vm/steps/selinux.py               the VM rig (kvm-smoke: mac=selinux, step=vhinit,selinux with
                                        kernel_run): the policy built on the runner, an installation with
                                        VH_MAC=selinux, the machine kernel's trial boot under vh-init,
                                        the labels, the domains, a login on tty1 into the desktop, every
                                        AVC denial listed with the CIL it asks for
```

**At installation** (`VH_MAC=selinux`): the live image brings the policy built
(`live/prebuilt.sh` runs `selinux/build.sh`); from an image without it (Void's own, the VM
rig) `VH_SELINUX_DIR=DIR` in `vh.conf` names a directory `sh selinux/build.sh DIR` made,
checked against its `SHA256SUMS`; `10-install.sh` copies `policy.33`,
`file_contexts`, `BUILD` and `SHA256SUMS` into `/etc/vh/selinux`; `chroot.sh` writes the
mode and runs `vh-selabel /` with no policy active (a process with `CAP_SYS_ADMIN` may set
`security.selinux`), then checks that nothing differs. The plan (`hwdb/platform.zon`,
`security.mac.selinux`) adds the kernel feature `selinux` (`kernel/profiles/features/selinux`:
`CONFIG_SECURITY_SELINUX`, `BOOTPARAM` off, `DEVELOP` on), and the command line
(`install/lib.sh`) becomes `lsm=landlock,lockdown,yama,selinux,apparmor`: the machine kernel
runs SELinux, the first exclusive LSM it has; the stock kernel of the fallback UKI, which has
no SELinux, runs AppArmor with the same command line and the same files.

**At boot**, stage 1 (`vh-init`, or `vh-stage1` under runit; `init/src/vhsteps.zig`):

1. `vh-selinux`, right after the pseudo file systems: selinuxfs mounted, the policy written to
   `/sys/fs/selinux/load` in one write, `enforce` set from `/etc/vh/selinux/mode`, then
   `secure_mode_policyload` set and committed (the last boolean anyone sets this boot), and
   `/run/vh/selinux` written for the audit. Without selinuxfs (the stock kernel) the step says so
   and the boot goes on: AppArmor's step runs instead.
2. `vh-selinux-early`, right after it: `vh-selabel --one-fs /run /dev /dev/shm` as the kernel
   just made them (`tmpfs_t`, `device_t`), before udevd makes `/run/udev` and the nodes: the
   policy's type transitions key on `var_run_t` (the rig's first boot had udev's files as
   `tmpfs_t`, run 40349043789).
3. `vh-selinux-label`, after `mount-all`: `vh-selabel --one-fs /run /dev /dev/shm /tmp /var/tmp`,
   the tmpfs and devtmpfs mounts whose nodes udev made meanwhile (devpts takes no xattr: its
   labels are the policy's). **Two kernels, one disk:** the stock kernel of the fallback UKI
   has no SELinux and labels nothing it creates, so after a boot on it every new file is
   unlabelled (`file_t` to the machine kernel: unbound's `root.key`, chrony's NTS cookies, the
   logs, a shell's history). Stage 1 keeps the marker `/var/lib/vh/selinux.last` ("selinux" or
   "none"); when the previous boot ran without the policy, `/etc`, `/usr`, `/var`, `/root`,
   `/home` and `/boot` are relabelled once, before any service starts. [VERIFY] the cost on a
   large `/home` (the step's time is in the kernel log).

Everything stage 1 runs is `kernel_t` (the policy is loaded by the process that is already
running), which is an init domain like `init_t`; the manager (`vh-init --manager`), runsvdir and
runit's scripts become `init_t` on exec; a service becomes its own domain through the type
transition on its executable, also under `no_new_privs` (the policy capability
`nnp_nosuid_transition`). The person's domain is chosen at login by the account's shell:
`/usr/local/bin/vh-usersh` and `vh-adminsh` are the same tiny program (`zig/tools/vh-shell.zig`,
it runs bash) under two names, two files, two labels; `login` executing one or the other is the
one point where the policy tells the admin from the user without a PAM module. The game user's
shell is `vh-game-enter`.

The admin account's home is `admin_home_t`, like `/root`: the policy cannot name the account,
so `chroot.sh` writes its line into `/etc/vh/selinux/file_contexts.local`, which `vh-selabel`
reads after the table. `/root/vh`, the installer's copy of the repository (the plan, `vh.conf`,
the scripts), is `vh_repo_t`, the system's and not the admin's: the tools read it, `vh-update`
runs it, and the rule that keeps every daemon out of the people's files holds.

**After an update**, `vh-update` runs `vh-selabel /usr /etc`: a package's new files take their
directory's label (the kernel's inheritance), the few programs that enter a domain get theirs.

## Convenience

- `doas vh-selinux status`: active, the policy and its commit, this boot's mode and the next
  boot's, the boolean, the denials of this boot, the shell's domain.
- `doas vh-selinux denials`: every AVC denial of this boot, one line each (count, program,
  source domain, target type, class, permissions, the file's name), and the CIL rule that would
  allow it, to be judged and added to `selinux/policy`, never to the running system.
- `doas vh-selinux mode permissive|enforcing`: the mode of the next boot. This boot cannot
  change: that is the point.
- `doas vh-selinux relabel [PATH]`, `doas vh-audit selinux`.
- Nothing to label by hand, no booleans, no modules: the policy is one file, rebuilt from
  `selinux/policy` when the inventory changes.

## vh-selabel

`zig/lib/selabel.zig` matches a path against the file_contexts secilc writes, with its own
small matcher for the subset the policy keeps to (literals, `\.`, `.`, `.*`, `[...]`, `[^...]`,
`(a|b)`, `?`, `*`, `+`, `(/.*)?`); `tests/selinux/checks.py` fails on a pattern outside it. The
most specific line wins as in libselinux: the exact path before a pattern, the longer literal
prefix, the later line. `vh-selabel` walks the given trees (the whole root by default, crossing
into the tmpfs mounts and skipping the pseudo file systems and vfat, mount point included,
whose labels are the kernel's), compares `security.selinux` and sets it where it differs; `--check` only reports
(exit 1 on a difference); `--root DIR` for the installer's chroot and the tests.

## Definition of done, and what is verified

**Done** means: the VM rig boots the machine kernel with `VH_MAC=selinux` enforcing, every
service runs, `check.py base` passes, the desktop and the browser work, and a day of normal use
on a real machine leaves `vh-selinux denials` empty. Until then `VH_SELINUX_MODE=permissive`
is the default of `VH_MAC=selinux`: every denial is logged, nothing is refused, and the boot is
the same as without SELinux but for the labels and the audit lines.

**Verified** (2026-10-26, Apple Silicon): the policy compiles with secilc 3.8 and every
neverallow holds (37 domains, 225 file contexts; `tests/selinux`, 19 checks); `vh-selabel`
relabels a tree and reports no difference afterwards (a privileged Void container; its matcher
has 4 unit tests over the policy's own patterns); the stage-1 steps parse and compile with vh-init.

**Verified on the VM rig, permissive** (2026-10-26, kvm-smoke `mac=selinux`, `step=vhinit,selinux`
with the machine kernel of kernel-custom run 40321559300, features `auto,selinux`; the runs
40349043789, 40373457582, 40383056402, 40388319429, 40401275073, 40407123621, 40411465314,
40416570814 and 40468812437, each a boot after the previous one's rules): the installation with `VH_MAC=selinux` labels every file (the installer
relabels once more after the kernel package, whose modules came after the chroot's pass); on
the machine kernel SELinux is the active LSM (`lockdown,capability,landlock,yama,selinux`),
stage 1 loads `policy.33` (114 KB) in its first step, sets `secure_mode_policyload`, labels
`/run` and `/dev` before udev and, after a boot on the stock kernel, relabels `/etc`, `/usr`,
`/var`, `/root`, `/home` and `/boot` (stage 1 took 955 to 1008 ms with it against 970 to 1118 without);
`vh-selabel --check /` then finds no difference, `/run` included; PID 1 is `kernel_t`, the manager
`init_t`, every daemon in its domain (udev, dbus, socklog, agetty, unbound, chronyd, seatd,
dhcpcd, vh-acpid, vh-sched as `sched_t` with the scheduler loaded); the admin's login shell is
`admin_t` and `doas -s` gives `sysadm_t`; a login on tty1 typed on the VM's keyboard starts
the desktop on the virtio GPU as `user_t` with RefursWM `wm_t`, RefursLine `bar_t`,
`vh-wlfilter` `wlfilter_t`, PipeWire and WirePlumber `pipewire_t`; `vh-audit` has no FAIL in
its SELinux area. The first boot logged 195 AVC lines, the sixth, seventh and eighth 18 each,
the ninth 9, every boot a new layer once the previous one's accesses were allowed (the ninth's:
dhcpcd's generic netlink socket and the inode of its network namespace, agetty's inotify on
`/run/agetty.reload`, `/dev/log` on devtmpfs, dbus's `dac_override`, WirePlumber's watch on
`/dev/snd`; their rules are the last commit, **[VERIFY]** the tenth boot, run 40468812437,
shows what they leave): what the rig taught the policy is in the git
history of `selinux/policy` (no `filesystem associate` rule at all, the role change at login,
every domain's own `/proc` entry, the type transitions of what stage 1 and the run scripts
make in `/run`, the device directories and symlinks of udev and its inotify watches, libudev's
hwdb, data and monitor for the compositor and the bar, the bar's lock and rtnetlink, the
session programs' inherited log and tty, init reading what a stock-kernel boot left
unlabelled, yescrypt's huge-page attempt and the three exec sanitising checks as `dontaudit`),
and two things beyond the policy: the manager's channel to
PID 1 was inherited by every service (CLOEXEC now), and the admin's home had the user's type
(`file_contexts.local`). **Not verified:** enforcing mode (the definition of done above), a
day of use, the browser (`browser_t`, bwrap's caps, Firefox's crash reporter ptrace), the
kernel packages' hooks under `pkg_t`, the gaming session, iwd and bluetoothd (the rig has
neither), real hardware. **[VERIFY]** the cost of the relabel after a stock-kernel boot on a
large `/home`.

## Later

- MCS categories for the two browser profiles and the gaming root (`s0:c1`, `s0:c2`).
- The policy built on the machine, in the kbuild root (secilc from source, pinned by hash), so
  that `vh-selinux denials` can go to a rebuilt policy without the live image.
- `vh-sched`'s link held by the vh-init manager: then `sched_t` disappears into `init_t`.
