# init/ — track I: `vh-init`, `vh-ctl`, `vh-logd`

A tiny PID 1 (zombies, signals, shutdown, restarting the manager) and a separate service
manager process from the same binary: stage 1 natively without a shell, a service graph
started in parallel by readiness, runit-compatible service directories, `vh-ctl` (also as the
`sv` shim) and `vh-logd` for `/dev/log`, `/dev/kmsg` and service stdout. Owned files: this
directory, `rootfs/etc/runit`, `rootfs/etc/sv`, the `sv` shim.

## v0.1: `vh-stage1`

`vh-stage1` replaces `/etc/runit/1` and the core-services: runit stays PID 1 and runs this
binary as stage 1; stage 2 (`runsvdir`) and stage 3 (shutdown) are unchanged. It does what
runit-void's `/etc/runit/core-services/*.sh` and the `*-vh-*.sh` scripts of this system do,
in the same order, as system calls; the programs that cannot be replaced are run by argv,
never through `sh`. An honest frame: the shell itself costs milliseconds; the win is a
stage 1 with no shell at all and a per-step breakdown in the kernel log
([docs/19-benchmarks.md](../docs/19-benchmarks.md)).

```sh
cd init && zig build -Dtarget=x86_64-linux -Dcpu=baseline --prefix DIR   # DIR/bin/vh-stage1 (static PIE)
sh tests/init/run.sh                                                      # unit + container tests (docker)
sh tests/init/build.sh && python3 tests/vm/check.py stage1 --repo         # the real boot on the VM rig
doas vh-stage1 --install     # /etc/runit/1 -> 1.orig, the binary in its place (docs/runbook-gf63.md)
doas vh-stage1 --status      # which stage 1 is installed; "done N ms" of this boot
doas vh-stage1 --rollback    # /etc/runit/1.orig back
```

| Step | runit-void / vh script | How |
|---|---|---|
| pseudofs | 00-pseudofs.sh | mount(2): proc, sysfs, /run, /dev, devpts, /dev/shm, securityfs, efivarfs, cgroup2 (unified), plus bpffs for vh-sched |
| static-devnodes | 01-static-devnodes.sh | `modules.devname` read natively, one `modprobe -abq`: `-b` skips what modprobe.d blacklists (`vh-devnodes.conf`, `vh-novirt.conf`, [runtime](../docs/uni/runtime.md#kernel-modules-at-boot)) |
| kmods | 02-kmods.sh (modules-load) | modules-load.d and the command line read natively, one `modprobe -ab` |
| udev-start, -trigger, -settle | 02-udev.sh | `udevd --daemon`, `udevadm trigger` ×2, `udevadm settle` by argv (three timed steps) |
| console | 03-console-setup.sh | `setfont` only with FONT set, `loadkeys` only for a non-us keymap; the kernel time zone of `hwclock --systz` natively (TZif from /etc/localtime) |
| remount-root, mount-all | 03-filesystems.sh | fstab parsed natively, mount(2) with the flags of mount(8); fsck only for lines with a pass number (none here) |
| swap | 04-swap.sh | swapon(2) for fstab swap lines (none here) |
| vh-mounts | 04-vh-mounts.sh | remounts: hidepid=invisible with the proc group, nosuid/nodev/noexec, the shm size from /etc/vh/stage1.conf |
| misc | 05-misc.sh | /run/utmp, the wtmp boot record of `halt -B`, seedrng (the algorithm of seedrng.c), lo up by ioctl, sethostname(2), the time zone link |
| vh-zram | 05-vh-zram.sh | the module (modprobe), algorithm and size, the swap signature of mkswap, swapon(2) priority 100 |
| vh-nftables | 06-vh-nftables.sh | `nft -f /etc/nftables.conf`; on failure the fail-closed ruleset over a pipe (`nft -f -`) |
| vh-mm | 07-vh-mm.sh | THP defrag `defer+madvise` |
| sysctl | 08-sysctl.sh | the priorities of `sysctl --system`: /etc masks /usr/lib, base-name order, unknown keys skipped and logged |
| vh-apparmor | 09-vh-apparmor.sh | `apparmor_parser --replace --write-cache` with the listed profiles and `vh.local.*` |
| runit-control | 10-runit-control.sh | /run/runit/stopit, /run/runit/reboot |
| vh-runtime | 11-vh-runtime.sh | /run/vh-sandbox (2750 user:browser), the power profile of `vh-power boot` natively |
| vh-suid | 12-vh-suid.sh (vh-suid-strip) | chmod and the `security.capability` attribute removed natively |
| dmesg | 97-dmesg.sh | syslog(2) into /var/log/dmesg.log, every record the ring holds (0600 under dmesg_restrict) |
| sbin-merge | 98-sbin-merge.sh | the /usr/sbin symlink of old installations |
| cleanup | 99-cleanup.sh | wtmp/btmp/lastlog, /tmp/.X11-unix, the one-shot flag files removed |
| vh-game | 98-vh-game.sh (`vh-game boot on`, [docs/uni/game.md](../docs/uni/game.md#g3a-the-gaming-boot)) | with the script there and `ia32_emulation=1` on the command line, `vh-game stage1` by argv: the controllers' drivers, the marker bound over /etc/runit/2 |
| vh-modlock | 99-zz-vh-modlock.sh | one `modprobe -a` with /etc/vh/modules.preload, then kernel.modules_disabled=1 |

Markers: `vh-stage1: start`, `vh-stage1: done in N ms (E errors)` and `vh-stage1: steps a=1 b=2 ...`
in the kernel log; `/run/vh/stage1` with the same for `--status` and the audit area
`rootfs/usr/local/libexec/vh/vh-audit.d/12-stage1.sh`. Settings: `/etc/rc.conf` (KEYMAP,
FONT, HARDWARECLOCK, TIMEZONE, CGROUP_MODE, SEEDRNG_SKIP_CREDIT), `/etc/vh/vh.env`
(VH_USER, VH_BROWSER_USER) and `/etc/vh/stage1.conf` (VH_SHM_SIZE, VH_ZRAM_ALGO,
VH_ZRAM_PERCENT; `--install` writes it from the rendered core-services on an existing system,
the installer renders `rootfs/etc/vh/stage1.conf.in`).

The one shell: on a failure the boot cannot go on from (root not writable, an fstab line,
swap, the RTC mode), vh-stage1 starts `/bin/sh -l` on the console exactly as runit-void's
`emergency_shell` does; nothing else is ever a shell. Differences from runit-void, all
deliberate: `/etc/sysctl.d` has priority over `/run/sysctl.d` (as procps; runit-void puts
/run first; this system has no /run/sysctl.d); sysctl keys with glob patterns are skipped
with a message; only `CGROUP_MODE=unified` is mounted; dmraid, mdadm, btrfs, LVM, ZFS
and crypttab are not activated (the root is opened by dracut, nothing else exists here; a
warning names the tool if one is installed); a `localtime` RTC falls back to `hwclock`
by argv. runit-void does not own `/etc/runit/1` as a configuration file: a runit-void
update puts the shell script back, `vh-stage1 --status` and `vh-audit stage1` notice it,
`vh-stage1 --install` repeats the install (v0.2 removes this: vh-init boots from its own UKI).

Tests: the unit tests in the sources (`zig build test`, run on Linux: the aggregator's
`tests` step and CI build them, `tests/init/run.sh` runs them in the container);
`tests/init/stage1_test.sh` runs every step possible in a privileged Void container
against the stock tools as oracles (`sysctl --system`, `mount -a`, `halt -B` + `utmpdump`,
the stock `seedrng` round trip, `nft`) and under a fake root for what would touch the
host kernel; `tests/vm/steps/init.py` (`check.py stage1 --repo`) installs it on the rig,
reboots, checks the marker, every service, the audit, and rolls back. The measurement:
[bench/init](../bench/init/README.md).

## v0.2: `vh-init`, `vh-ctl`, the `sv` shim

`vh-init` is PID 1 (`init=/usr/local/sbin/vh-init` in the UKI's command line) and the service
manager, two processes from one binary (docs/ROADMAP.md, I: "Process split"):

```
vh-init (PID 1, 4.2 MiB RSS)    stage 1 in-process (the steps above), the manager as its child,
                                 zombies, the shutdown signals, stage 3
  '- vh-init --manager           the service graph: epoll over a signalfd, the control socket,
                                 the services' log and readiness pipes; starts, stops, restarts
       |- NAME (its cgroup /sys/fs/cgroup/vh/NAME)       the services, in parallel by readiness
       '- NAME/log (runit directories only)              DIR/log/run, reading the service's output
vh-ctl / sv                      the client over /run/vh/init.sock (root only)
```

- **PID 1 is tiny on purpose.** A ReleaseSafe panic in PID 1 is a kernel panic, so the service
  graph lives in the manager. When the manager dies, PID 1 starts it again (1, 2, 4 ... 30 s
  between tries) and the new manager finds the services a previous one left running in their
  cgroups and watches them through pidfds: no service restarts because the manager did.
- **Services.** `/var/service/NAME` enables a service, as under runit: a runit directory
  (`run`, `log/run`, `check`, `finish`, `down`) runs as runit runs it, and a
  `/etc/vh/services/NAME.svc` of the same name says how it runs instead. A service without a
  runit directory is enabled by `/etc/vh/services/enabled/NAME` (`doas vh-ctl enable NAME`). The
  `.svc` keys, `key = value`:

  | key | meaning (default) |
  |---|---|
  | `exec` | argv, an absolute path; `"double quotes"` keep spaces. No shell runs it |
  | `kind` | `longrun` (restarted) or `oneshot` (runs to its end; `ready` becomes `exit`) |
  | `ready` | `started` (after exec, runit's assumption), `exit` (exited 0), `fd N` (the program writes a line to fd N and closes it: s6, dinit), `socket PATH` (the path exists); runit's `./check` for a runit directory. `ready_timeout` (30s): then it counts as up, with a warning |
  | `needs`, `wants`, `after`, `before` | the graph: `needs` waits for the ready dependency, `wants` and `after` order the start when the other is enabled, `before` is the other side's `after` |
  | `restart` | `always` (1), `on-failure`, `no`; `restart_delay` (1s) doubles for each quick exit in a row up to `restart_max` (30s); a run of a minute resets it |
  | `every`, `delay` | a periodic oneshot (`1w`; the last run is kept in /var/lib/vh/init so the week survives reboots) and the wait before the first start (`5s`) |
  | `user`, `group`, `caps` | the user (its groups from /etc/group), the group, the capabilities kept (`net_bind_service`; `none` drops them all, also for root): bounding, effective, permitted and ambient sets are exactly these |
  | `no_new_privs` (yes), `abi_filter` (yes) | `PR_SET_NO_NEW_PRIVS`; the seccomp filter "only the native ABI" (a foreign architecture or the x32 bit kills; six instructions, the kernel caches the verdict per call). `abi_filter = no` for the gaming tree |
  | `umask` (022), `nice`, `sched` (`normal`, `batch`, `idle`), `oom_score_adj`, `rlimit_nofile`, `env`, `dir` | the process |
  | `memory_max`, `cpu_weight` | cgroup2 limits of the service's cgroup |
  | `log` (`file`), `log_size` (1M), `log_keep` (5) | `file`: /var/log/vh/NAME/current with UTC stamps, rotated to @STAMP.s (as svlogd, without the svlogd process); `kmsg`: the kernel log with the name as prefix; `none` |
  | `stop_timeout` (10s) | TERM, then KILL of the whole cgroup |

  `rootfs/etc/vh/services/` has the `.svc` of this system's own services: `vh-acpid`, `vh-check`
  (a oneshot 5 s after the start), `vh-boot-assess` (a oneshot after it), `vh-fstrim` (a
  weekly oneshot: no shell loop and no `sleep` process stay resident, as the runit scripts
  needed), `vh-sched` (the scheduler's loader, restarted with a backoff; `doas vh-ctl enable
  vh-sched`). The stock runit services (udevd, dbus, unbound, chronyd, seatd, socklog, agetty,
  iwd, dhcpcd) run from their runit directories unchanged.
- **Shutdown** (`vh-ctl poweroff|reboot|halt`, `poweroff` of runit-void through
  `/run/runit/stopit` and SIGCONT, Ctrl+Alt+Del and the fixed power button through
  `/etc/runit/ctrlaltdel` and SIGINT, SIGTERM, SIGUSR1 halt, SIGUSR2 poweroff): the manager
  stops the services in the reverse order of the graph (a service stops when nothing that needs
  it still runs; TERM, after `stop_timeout` KILL of its cgroup), then stage 3 in PID 1: TERM
  and KILL of what is left, the seed for the next boot, the wtmp record, swap off, `vh-deadman
  final` when the module is enabled, the file systems detached and the root read-only,
  `reboot(2)`. Each phase goes to the kernel log.
- **`vh-ctl`:** `status [NAME]`, `start|stop|restart NAME [-w SECONDS]`, `once`, `signal NAME SIG`,
  `enable|disable`, `tree`, `why NAME` (what it waits for), `blame` (the time to ready at boot),
  `reload`, `ping`, `poweroff|reboot|halt`. **`sv`:** the same binary as `/usr/bin/sv` takes
  sv(8)'s commands (`up`, `down`, `restart`, `status`, `once`, `check`, `-w`, the signal letters)
  and prints sv's lines (`run: NAME: (pid N) Ns`), so vh-audit, iwd's `conf`, `ctrlaltdel` and
  the tests work unchanged; while runit is PID 1 the shim runs runit's own `sv`, kept as
  `/usr/bin/sv.runit`. `--install` writes `/etc/xbps.d/31-vh-init.conf` (`noextract=/usr/bin/sv`)
  so that an update of runit keeps the shim; `xbps-pkgdb -a` reports the hash mismatch of
  `/usr/bin/sv` meanwhile, and `--rollback` takes both away.

```sh
cd init && zig build -Dtarget=x86_64-linux -Dcpu=baseline --prefix DIR   # DIR/bin/{vh-stage1,vh-init,vh-ctl}
doas vh-init --check         # the definitions as the manager reads them: the graph, the start order
doas vh-init --install       # /etc/vh/init-boot, then vh-limine-update: the newest stock UKI's twin with init=
                             # appended, signed, "Void Linux VER (vh-init)" in Limine's menu and on trial through
                             # the one-shot entry; the stock UKI (runit) untouched; the sv shim. Then reboot
vh-init --status             # which init is PID 1, where vh-init's UKI stands (on trial, the default), the manager
doas vh-init --rollback      # the twin demoted and removed, runit's sv back: the next boot is runit's again
sh tests/init/init_test.sh   # vh-init as PID 1 of a privileged container (below)
python3 tests/vm/check.py vhinit,base,vhinit-rollback --repo   # the rig: the install, a reset trial, the trial boots
                                                                # to the default, the base checks under vh-init, the
                                                                # rollback (kvm-smoke: step=...)
```

### The UKI with vh-init: the install through the boot assessment

The kernel command line lives inside the signed UKI and, under Secure Boot, nothing can be typed
at Limine's prompt: vh-init needs a UKI of its own. `vh-init --install` writes the marker
`/etc/vh/init-boot` and runs `vh-limine-update`, which from then on gives the newest stock UKI a
twin, `linux-A.B.C_D-vh-init.efi` beside it in `EFI/void`: the same PE image, the same kernel and
initrd byte for byte, with `init=/usr/local/sbin/vh-init` appended to its `.cmdline` section
(`zig/lib/twin.zig`, as the gaming boot's twin is made; a longer command line takes the padding
of its section or one more block of the file, and the sections after it move by that block). It
is signed with the db key as every UKI, enters Limine's menu as "Void Linux A.B.C_D (vh-init)"
after the machine entries, and goes through the
[boot assessment](../docs/uni/kernel.md#the-boot-assessment) exactly as a machine UKI: the next
boot tries it once through Limine's one-shot entry, a trial boot that does not reach its end (a
hang, a panic, a reset at the passphrase prompt) leaves the boot after it to the stock UKI,
runit, by itself, and after `MACHINE_BOOTS` good boots (3) it is Limine's default. The stock UKI
is not touched, `/etc/default/dracut-uefi-hook` is not edited, and a stock kernel update makes
the new kernel's twin and puts it on trial by itself (the hook runs vh-limine-update): the old
twin stays the default until the new one has passed. `vh-init --status` says where the twin
stands; `vh-limine-update --status`, `--retry NAME` and `--demote` take it like a machine UKI.
`--rollback` demotes the twin, removes the marker and runs vh-limine-update, which deletes the
twin and forgets its trial; runit's `sv` comes back. A machine kernel: while the marker exists
`vh-kconf install` appends `init=` to the machine UKI's command line too, so a machine kernel
installed then boots vh-init and its trial covers both; a machine kernel that is Limine's default
keeps its place through a stock kernel update (the new twin waits in the menu). The gaming
kernel's UKI and the gaming twin keep runit: the gaming boot is runit's stage 2
([game.md](../docs/uni/game.md#g3a-the-gaming-boot)). A new installation keeps runit as `init=`.

**Verified** (2026-10-26, Apple Silicon, the aarch64 Void container of `tests/docker`):
`tests/init/init_test.sh` runs vh-init as PID 1 of a privileged container with the services of
`tests/init/svc` and the driver `tests/init/init_driver.sh`: readiness by fd, by a socket path,
by exit and by runit's `check`; the order (a ready before b, a oneshot before its dependent,
`delay`); the restart backoff (200, 400 ms); user, groups, `caps` (bounding, effective and
ambient sets), `no_new_privs`, the ABI filter (Seccomp 2), `nice`, `sched`, the cgroup, `env`,
`dir`, `umask`; the log file with stamps; stop, start, restart, signal, tree, why, blame,
enable, disable, reload with a runit directory (its logger, `check` and `finish`); the `sv`
shim's lines and exit codes; the manager killed with SIGKILL and started again by PID 1 with
every service kept (adopted from its cgroup, same pid); the poweroff: b stopped before a, stage
3, `reboot(2)`. 37 unit tests.

**Verified on the VM rig** (2026-10-26, kvm-smoke runs 40343277197 `vhinit,base,vhinit-rollback`
and 40340658992 `vhinit,sched`; EPYC-Milan ×4 under KVM, the stock kernel 6.18.58_1, x86_64; with
the install of that day, which put `init=` into the hook's command line and rebuilt the stock
UKI in place): the boot after `vh-init --install` runs vh-init as PID 1: stage 1 in-process in 970 to
1118 ms over four boots with 0 errors (of it udev-settle 466 to 496, static-devnodes 176 to 219,
vh-nftables 141 to 165, pseudofs 84 to 119 ms), the manager starts the 15 services of
`/var/service` in parallel (agetty-tty1 at +6 ms, dbus ready in 103 ms, nanoklogd started at
+1042 ms, every oneshot done, vh-fstrim delayed) and reports them settled 5.1 s after its start
(vh-check's `delay = 5s`); `vh-ctl status` and the `sv` shim agree for every service, no runsv,
PID 1 at 4.2 MiB RSS; vh-stage1's state (hidepid, noexec, zram, the nft table, the power profile,
THP, sysctl, the sandbox directory, the dmesg log); vh-audit: ok 178 and the one FAIL of the rig
(Secure Boot off) against ok 171 under runit, the init area clean; `check.py base` passes under
vh-init (DNS, NTS, vh-kconf check, the desktop programs, the ruleset, `vh-ctl disable` and
`enable` of a runit service, the power button through tiny_power_button, `ctrlaltdel` and
vh-acpid); runit-void's `poweroff` ends in stage 3 (67 to 76 ms) and `reboot(2)`;
`vh-init --rollback` with the rebuild gives runit back with every service up. The rig found and
this verified: the shim must give runit's `sv` the name `sv`; the manager must make
`/var/service` resolve, which runit's stage 2 did; a service enabled again after a disable
must start; the audit judges a done oneshot by vh-ctl, not by `sv`.
**Not verified:** real hardware (the GF63), `vh-deadman final` at a vh-init shutdown, a runit
runlevel from the command line and `/etc/rc.local` (not taken over), the boot time against
runit by the bench method (below). **Open:** PID 1 keeps 4.2 MiB of RSS (stage 1 runs in it and
its allocations stay; the audit's line is `[ ?? ]` above 4 MiB).

**The install through the boot assessment, verified on the VM rig** (2026-10-27, kvm-smoke run
40472898818 `vhinit,base,vhinit-rollback`, 64 checks, 0 FAIL; run 40468673377 before it passed the
same flow with two failures of the step's own parsing; Limine 12.9.4, the stock kernel 6.18.59_1):
`vh-init --install` makes the twin `linux-6.18.59_1-vh-init.efi` in a second (the stock command
line is 1078 bytes, so the parameter fits the section's padding; the one-more-block layout ran in
the unit tests and `assess_test.py` only), signed and enrolled, on trial and set for the next boot
through the one-shot entry; the stock UKI's bytes are unchanged, the twin carries `init=` once and
the stock UKI never, the hook is untouched. The first trial boot reset at its passphrase prompt:
the boot after it runs runit by itself, the trial is "failed: the trial boot did not reach the end
of the boot", `vh-init --status` names `--retry`. After `--retry` the trial boot runs vh-init as
PID 1 (stage 1 in 1013 ms, 0 errors; udev-settle 478, static-devnodes 204, vh-nftables 148 ms;
the 15 services settled 5.1 s after the manager; PID 1 RSS 4300 kB; `vh-ctl status` and the shim
agree; vh-audit ok 179 with the rig's Secure Boot FAIL, the init area clean, the boot area counts
the twin and the trial), the service counts it (1 of 3) and sets the entry again; runit-void's
`poweroff` ends in stage 3 (110 ms). `check.py base` under vh-init is the second good boot; the
third makes the twin `LoaderEntryDefault` with limine.conf unchanged, the default boots it with no
one-shot entry and the service has no news; `vh-init --rollback` demotes it, deletes the twin and
its entry, restores runit's `sv` and the noextract file goes; the boot after it runs runit with
every service up, nothing on trial, no UKI with vh-init on the ESP. **Not verified:** real
hardware with Secure Boot on (the twin is signed as every UKI; the rig has no Secure Boot), a
stock kernel update with the marker (the e2e test covers it), a machine kernel with `init=`
(`vhinit,sched` / `vhinit,selinux` on this branch).

**Not done:** `vh-logd` (/dev/log stays with socklog; the manager
writes the services' own logs), the Landlock and mount-namespace sandbox of a service, the
`SCX` link held by the manager (vh-sched is a service that holds its own link).

| | runit + vh-stage1 (v0.1) | vh-init (v0.2) |
|---|---|---|
| processes for N services | runsvdir + N runsv + a svlogd per logged service | 2 (PID 1, the manager) + the services |
| readiness | none (`sv -w` polls `check`) | fd, socket, exit, check; dependents start when it is reached |
| restart | after 1 s, always | backoff 1 .. 30 s, `on-failure`, `no`, oneshots |
| our timers | `sleep 3600` loops in shell (vh-fstrim), `sleep 5; exec pause` (vh-check) | oneshots with `delay` and `every`, nothing resident |
| sandbox of a service | the run script's own | user, caps, nnp, the ABI filter, nice/sched, rlimits, cgroup limits |
| manager crash | runsvdir dies: nothing restarts services | PID 1 starts it again; the services are kept |
| speed | stage 1 in PID 1: 970 to 1118 ms on the KVM rig (kernel log, four boots; docs/19's TCG bench of v0.1 is another machine: 5041 ms vh-stage1, 6034 ms runit's shell); stage 3: 67 to 76 ms. [VERIFY] against runit's stage 1 and 2 on the same rig and the GF63 by the bench method (bench/init, docs/19) |

The speed claim stays open: PID 1 itself yields milliseconds (docs/ROADMAP.md, I: "An honest
frame"); what v0.2 removes is the processes, the shell loops and the polling of readiness.

## Layout

```
init/
  build.zig            vh-stage1, vh-init, vh-ctl; the unit tests
  src/stage1.zig       v0.1: stage 1 (vh-stage1, and runBoot() for vh-init)
  src/init.zig         vh-init: the modes
  src/pid1.zig         PID 1: signals, the manager's life, the shutdown request
  src/manager.zig      the manager: the graph at run time, epoll, the control socket
  src/svc.zig          the service model: .svc parsing, runit directories, the graph (pure)
  src/spawn.zig        starting a service process: user, caps, nnp, the ABI filter, cgroup, stdio
  src/log.zig          the services' logs (file with stamps and rotation, kmsg)
  src/cgroup.zig       cgroup2 under /sys/fs/cgroup/vh
  src/proto.zig        the vh-ctl protocol, the status lines, sv's form (pure)
  src/ctl.zig          vh-ctl and the sv shim
  src/shutdown.zig     stage 3
  src/initsetup.zig    --install, --rollback, --status
  src/{sys,mounts,sysctl,misc,vhsteps,udev,seed,tz,setup}.zig   stage 1 (v0.1)
rootfs/etc/vh/services/*.svc   this system's services for vh-init
tests/init/init_test.sh, init_driver.sh, svc/   the container test
tests/vm/steps/init.py         the rig: stage1 and vhinit
```
