# Runbook: the GF63 laptop

Procedures for the real machine, run by its owner. A development session never runs
anything on the laptop ([principles.md](principles.md)); every section here says what a step
changes, how to check it and how to go back. Recovery from a live USB stick is in
`recovery.md` (written with the milestone that needs it; until then
[ru/09-updates.md](ru/09-updates.md) and [ru/10-audit.md](ru/10-audit.md) hold the procedures
of the predecessor, which still apply).

## v0.1: vh-stage1, stage 1 of the boot without a shell

**What it is.** A static Zig binary ([init/README.md](../init/README.md)) that replaces
`/etc/runit/1` and runs the same steps as runit-void's core-services and the `-vh-` scripts
of this system, natively. runit stays PID 1; stage 2 and stage 3 do not change; every
service, mount, sysctl, the firewall and AppArmor come up exactly as before. The way back
is one command and a reboot.

**What it changes on disk.** `/etc/runit/1` (the previous file is kept as
`/etc/runit/1.orig`), `/usr/local/sbin/vh-stage1` (new), `/etc/vh/stage1.conf` (new:
the zram and /dev/shm values of your vh.conf, read from the installed core-services),
`/usr/local/libexec/vh/vh-audit.d/12-stage1.sh` (new audit area). Nothing else.

### 1. Get the binary

The laptop has no compiler (docs/05). Two ways:

- **The CI release asset.** Every tag `v*` of this repository publishes
  `vh-tools-x86_64.tar.gz` and its `.sha256` (the zig-test workflow); `bin/vh-stage1` is
  inside, built by the root aggregator. Download both on another machine, check
  `sha256sum -c vh-tools-x86_64.tar.gz.sha256`, unpack.
- **Build it yourself** on a machine with Zig 0.17.0 (`zig/ZIG_VERSION`):
  `cd init && zig build -Dtarget=x86_64-linux -Dcpu=baseline --prefix out` gives
  `out/bin/vh-stage1`. `file` must say `static-pie linked`.

Bring `vh-stage1`, `rootfs/usr/local/libexec/vh/vh-audit.d/12-stage1.sh` and
`bench/init/1.shell-marked` (for the measurement) to the laptop over a USB stick or `scp`.

### 2. Measure the shell stage 1 first (optional, 11 boots)

The numbers of [19-benchmarks.md](19-benchmarks.md) come from the VM rig; the laptop's
own numbers need the boots of both variants, the shell one before it is replaced:

```sh
doas cp -p /etc/runit/1 /root/runit-1.stock                 # the pristine script
doas install -m 0755 -o root -g root 1.shell-marked /etc/runit/1   # the same script plus two kmsg markers
```

Boot 11 times on mains power with the lid open and the machine cool (the first boot is
the warm-up, discarded). After each boot, as admin:

```sh
doas dmesg | grep -a 'Run /sbin/init\|vh-bench\|vh-stage1' | doas tee -a /root/stage1-shell.txt
```

### 3. Install

```sh
doas install -m 0755 -o root -g root vh-stage1 /usr/local/sbin/vh-stage1
doas install -m 0644 -o root -g root 12-stage1.sh /usr/local/libexec/vh/vh-audit.d/12-stage1.sh
doas vh-stage1 --install
```

`--install` prints what it did: `/etc/runit/1` kept as `/etc/runit/1.orig`, the binary in
its place, `/etc/vh/stage1.conf` written. Open the conf and compare it with your
`vh.conf` (`VH_ZRAM_ALGO`, `VH_ZRAM_PERCENT`; `VH_SHM_SIZE` is the `size=` of
`/etc/runit/core-services/04-vh-mounts.sh`). Before rebooting, a safe dry run of one step:

```sh
doas vh-stage1 --step sysctl -v     # re-applies the sysctls that are already in force; shows the file order
```

Reboot.

### 4. Check

```sh
doas vh-stage1 --status                   # /etc/runit/1: vh-stage1; this boot: done N ms, errors 0
doas dmesg | grep -a 'vh-stage1:'         # the marker, the per-step times, ERROR lines if any
doas vh-audit stage1                      # the new audit area
doas vh-audit                             # the whole checklist: no FAIL that was not there before
sv status /var/service/*                  # every service "run:"
swapon --show                             # zram0 with priority 100
findmnt -no OPTIONS /proc /dev/shm /run   # hidepid=invisible, noexec
doas nft list tables                      # table inet vh
cat /run/vh/power                         # ac
```

If a step reported an error, `dmesg` names it; `doas vh-stage1 --step NAME -v` reruns a
single step on the running system (safe for sysctl, vh-mm, vh-suid, vh-runtime, dmesg;
the mount steps only report "already mounted").

For the measurement, boot 11 more times as in step 2, into `/root/stage1-zig.txt`, then on
a machine with python3:

```sh
python3 bench/init/stage1_boot.py --from-dmesg stage1-shell.txt stage1-zig.txt
```

It prints the same table as the VM measurement (median, p95, the bootstrap CI, the verdict).
Send the two files and the table with the result; they go into `bench/results/` and
[19-benchmarks.md](19-benchmarks.md).

### 5. Rollback

```sh
doas vh-stage1 --rollback      # /etc/runit/1.orig -> /etc/runit/1
```

and reboot: runit-void's shell stage 1 runs again. `vh-stage1` itself may stay in
`/usr/local/sbin`.

If a boot ever stops in the emergency shell (vh-stage1 opens one exactly where runit-void
would: the root could not be remounted read-write, an fstab line failed, swap failed), the
shell is on the console: `mv /etc/runit/1.orig /etc/runit/1` and `exit` continue the boot
with the shell stage 1. From a live USB stick: open the LUKS volume, mount the root at
/mnt and do the same `mv` under /mnt/etc/runit.

### 6. After a runit-void update

`/etc/runit/1` is not a configuration file of the runit-void package: an update puts the
shell script back without a word. `doas vh-stage1 --status` then says "the runit-void
shell script" and `doas vh-audit stage1` FAILs ("although 1.orig exists"). The fix is
`doas vh-stage1 --install` again. v0.2 removes this seam: vh-init boots from its own UKI
with `init=`.

### 7. What the measurement cannot tell you

Stage 1 is a few percent of the whole boot; the udev settle inside it is identical in both
variants and dominates it. The honest win of v0.1 is a stage 1 with no shell at all, a
per-step breakdown, and the base for v0.2 (vh-init as PID 1). Losses, if the laptop shows
any, go into 19-benchmarks.md as they are.
