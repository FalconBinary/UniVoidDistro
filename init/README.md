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
doas vh-init --install       # init= into the UKI's command line (/etc/default/dracut-uefi-hook), the sv shim;
                             # then: doas xbps-reconfigure -f linux6.18, which replaces this kernel
                             # version's UKI (no runit UKI is left to fall back to: see below)
vh-init --status             # which init is PID 1, this boot's markers, the manager
doas vh-init --rollback      # init= out again, runit's sv back; rebuild the UKI the same way
sh tests/init/init_test.sh   # vh-init as PID 1 of a privileged container (below)
python3 tests/vm/check.py vhinit,base,vhinit-rollback --repo   # the rig: install, the boot under vh-init, the base
                                                                # checks on it, the rollback (kvm-smoke: step=...)
```

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
3, `reboot(2)`. 37 unit tests. **Not verified:** a real boot (the rig's `vhinit` step is written,
not run: it needs `check.py` on the rig; kvm-smoke with `step=vhinit`), vh-stage1's steps under
vh-init on a machine, `vh-deadman final` at a vh-init shutdown, the x86_64 build in a running
system (built, not booted). **Not done:** `vh-logd` (/dev/log stays with socklog; the manager
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
| speed | [VERIFY] the boot time against runit's stage 2 on the rig and the GF63 (bench/init, the method of docs/19) |

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
