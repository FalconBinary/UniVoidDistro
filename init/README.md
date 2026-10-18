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
| static-devnodes | 01-static-devnodes.sh | `modules.devname` read natively, one `modprobe -abq` |
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
| dmesg | 97-dmesg.sh | syslog(2) into /var/log/dmesg.log (0600 under dmesg_restrict) |
| sbin-merge | 98-sbin-merge.sh | the /usr/sbin symlink of old installations |
| cleanup | 99-cleanup.sh | wtmp/btmp/lastlog, /tmp/.X11-unix, the one-shot flag files removed |
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

## Later milestones (planned layout)

```
init/
  build.zig
  src/stage1.zig       v0.1: stage 1 (this)
  src/pid1.zig         PID 1
  src/manager.zig      the service graph and the control socket
  src/ctl.zig          vh-ctl
  logd/                vh-logd
  services/            /etc/vh/services/*.svc of the base system
```

Spike S2 tries vh-init as PID 1 in a container and a VM; v0.2 makes it PID 1 through a
separate UKI with `init=` ([docs/ROADMAP.md](../docs/ROADMAP.md#i-vh-init-vh-ctl-vh-logd)).
