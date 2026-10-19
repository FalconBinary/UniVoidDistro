# Runbook: the GF63 laptop

Procedures for the real machine, run by its owner. A development session never runs
anything on the laptop ([principles.md](principles.md)); every section here says what a step
changes, how to check it and how to go back. Recovery from a live USB stick is in
`recovery.md` (written with the milestone that needs it; until then
[ru/09-updates.md](ru/09-updates.md) and [ru/10-audit.md](ru/10-audit.md) hold the procedures
of the predecessor, which still apply).

## 1. The custom kernel: probe, build in CI, download (track K, v0.1)

**What changes on the laptop:** one file, `/etc/vh/hw.zon`. Nothing boots differently.

### 1.1 Get `vh-kconf`

The laptop has no compiler (the thor policy forbids them in the base), so the binary comes
from outside. Either:

- the release asset `vh-tools-x86_64.tar.gz` of the newest `v*` tag of
  https://github.com/FalconBinary/void-hardperf-light/releases (built by `zig-test.yml` from the
  root aggregator, `vh-kconf` included), checked against its `.sha256`; or
- a build on the Mac, copied over SSH:

```sh
cd ~/Documents/systems/void-hardperf-light/kernel
zig build -Dtarget=x86_64-linux -Dcpu=baseline --prefix /tmp/kt
scp /tmp/kt/bin/vh-kconf admin@gf63:/tmp/
```

On the laptop, as the admin on tty2:

```sh
doas install -m 0755 /tmp/vh-kconf /usr/local/sbin/vh-kconf
vh-kconf version
```

It is a static PIE: it needs no library and runs under the module lock and lockdown.

### 1.2 Probe the hardware

Plug in and use everything you want the custom kernel to drive during this boot: Wi-Fi,
Ethernet, a USB stick, headphones, Bluetooth, an external monitor. The probe records the
modules that are loaded now; what was never loaded is only found through its modalias.

```sh
doas vh-kconf probe
```

It writes `/etc/vh/hw.zon` and prints how many devices and loaded modules it saw. Read the
file once (`less /etc/vh/hw.zon`): the modalias of every device on every bus, the bound
driver and its module, the loaded modules, the CPU (family 6 model 165 for the i5-10500H,
caches, SMT), the DMI strings of the machine, EFI and TPM presence, the mounted file
system types. It never contains serial numbers, the product UUID, MAC addresses or
LUKS/partition UUIDs: `grep -ci -e serial -e uuid /etc/vh/hw.zon` prints `0`. The file is
meant to be committed.

Optional, for debugging: `doas vh-kconf probe --save /root/hw-snapshot` also copies every
sysfs and procfs file the probe read into that directory, with the shape of sysfs. That
snapshot replays on any machine (`vh-kconf probe --from DIR`) and is how
`tests/kernel/fixtures/gf63` should be replaced by the real thing; it copies raw files
(`/proc/mounts` carries device names and UUIDs), so keep it private, never commit it.

### 1.3 Commit `hw.zon`

From the Mac:

```sh
scp admin@gf63:/etc/vh/hw.zon ~/Documents/systems/void-hardperf-light/kernel/hw/gf63.zon
cd ~/Documents/systems/void-hardperf-light
git add kernel/hw/gf63.zon && git commit -m "kernel: hw.zon of the GF63, probed on $(date -u +%F)"
git push origin main
```

(`kernel/hw/gf63.zon` in the repository today is generated from the synthesised fixture
in `tests/kernel/fixtures/gf63`; the probed file replaces it.)

### 1.4 Run the `kernel-custom` workflow

On GitHub: Actions -> kernel-custom -> Run workflow. The inputs:

| Input | Value |
|---|---|
| `hw` | `kernel/hw/gf63.zon` |
| `kver` | the 6.18.y version, `6.18.57` today (the pins in `kernel/pins` are for 6.18.57; another version still builds, the diff report shows what moved) |
| `features` | `usb-common,bluetooth` by default; add `camera` for the webcam, `virt` for KVM; `game` only with vh-game (v0.3); `auto` picks from hw.zon |
| `release` | on: the result is published as a release, readable without credentials |

Or, from a machine where `gh` is logged in:

```sh
gh workflow run kernel-custom -R FalconBinary/void-hardperf-light -f hw=kernel/hw/gf63.zon -f features=usb-common,bluetooth
```

The job: verifies the kernel.org tarball by PGP signature (fingerprints in
`kernel/pins/kernel-org.fingerprints`), runs `vh-kconf resolve` (hw.zon + the pinned Void
config + `kernel/profiles/*`), then the kernel's own `make LLVM=1 localyesconfig` with the
LSMOD list and `olddefconfig`, then `vh-kconf diff`, then checks the invariants (no modules,
sched_ext and BTF on, lockdown forced, io_uring off) and builds `bzImage` with clang, lld,
ThinLTO, kCFI and `-march=skylake`, with fixed `KBUILD_BUILD_*` so the same inputs give the
same image. Expect 30 to 60 minutes. The progress is public:

```sh
curl -s 'https://api.github.com/repos/FalconBinary/void-hardperf-light/actions/workflows/kernel-custom.yml/runs?per_page=1' | grep -E '"(status|conclusion|html_url)"'
```

### 1.5 Download and verify

The release is named `kernel-custom-gf63-6.18.57-rN` (N = the run number). Its assets:

| File | What |
|---|---|
| `bzImage-vh-6.18.57` | the kernel, `uname -r` = `6.18.57-vh` |
| `config-vh-6.18.57` | the final `.config` after olddefconfig |
| `diff-report.txt` | which requested symbols survived and why the others did not; every LSMOD module and its symbol |
| `resolve-report.txt` | every device: modalias -> driver -> modules taken, the alternatives, the refused ones, the fragments and their conflicts |
| `fragment.config`, `lsmod`, `gf63.zon` | the inputs, for the record |
| `System.map-vh-6.18.57`, `vmlinux-vh-6.18.57.btf` | symbols and BTF (vh-sched builds against the BTF) |
| `BUILD`, `SHA256SUMS` | the build parameters; the hashes |

```sh
mkdir -p ~/vh-kernel && cd ~/vh-kernel
tag=kernel-custom-gf63-6.18.57-r1   # the run you want
for f in bzImage-vh-6.18.57 config-vh-6.18.57 diff-report.txt resolve-report.txt BUILD SHA256SUMS; do
  curl -fsSLO "https://github.com/FalconBinary/void-hardperf-light/releases/download/$tag/$f"
done
sha256sum -c --ignore-missing SHA256SUMS
```

Read `diff-report.txt` first. Its last line is `Result: ok`, `ok with differences` or `FAIL`
(a mandatory symbol was lost: the job already failed). Look at:

- requested symbols that did not survive and their reason (`unmet: ...` names the dependency
  that is off; `no prompt` means the symbol is set by selects only; `not a symbol` means the
  profile names something this kernel version does not have);
- LSMOD modules that are not built in: a driver this machine uses is missing from the kernel;
- in `resolve-report.txt`: "Modaliases with no driver" (new hardware without a driver in the
  stock kernel either) and "Refused" (nouveau, mei, the tiny power button, the modules of
  features you did not select).

### 1.6 What not to do yet

The image is not installed by hand. `limine.conf` is hash-enrolled into `BOOTX64.EFI`
(docs/03): editing it, or copying a UKI onto the ESP, leaves the laptop unable to boot that
entry. `vh-kconf install` (kernel/README.md, "install") is the next piece: it builds the
UKI with dracut `--no-kernel`, puts the firmware and the microcode into the initrd, signs it
and adds it to Limine as a second series next to the stock UKI, which always stays. Until
it exists, this runbook ends here: the laptop has gained `/etc/vh/hw.zon` and nothing else.

## 2. vh-stage1, stage 1 of the boot without a shell (track I, v0.1)

**What it is.** A static Zig binary ([init/README.md](../init/README.md)) that replaces
`/etc/runit/1` and runs the same steps as runit-void's core-services and the `-vh-` scripts
of this system, natively. runit stays PID 1; stage 2 and stage 3 do not change; every
service, mount, sysctl, the firewall and AppArmor come up exactly as before. The way back
is one command and a reboot.

**What it changes on disk.** `/etc/runit/1` (the previous file is kept as
`/etc/runit/1.orig`), `/usr/local/sbin/vh-stage1` (new), `/etc/vh/stage1.conf` (new:
the zram and /dev/shm values of your vh.conf, read from the installed core-services),
`/usr/local/libexec/vh/vh-audit.d/12-stage1.sh` (new audit area). Nothing else.

### 2.1 Get the binary

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

### 2.2 Measure the shell stage 1 first (optional, 11 boots)

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

### 2.3 Install

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

### 2.4 Check

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

### 2.5 Rollback

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

### 2.6 After a runit-void update

`/etc/runit/1` is not a configuration file of the runit-void package: an update puts the
shell script back without a word. `doas vh-stage1 --status` then says "the runit-void
shell script" and `doas vh-audit stage1` FAILs ("although 1.orig exists"). The fix is
`doas vh-stage1 --install` again. v0.2 removes this seam: vh-init boots from its own UKI
with `init=`.

### 2.7 What the measurement cannot tell you

Stage 1 is a few percent of the whole boot; the udev settle inside it is identical in both
variants and dominates it. The honest win of v0.1 is a stage 1 with no shell at all, a
per-step breakdown, and the base for v0.2 (vh-init as PID 1). Losses, if the laptop shows
any, go into 19-benchmarks.md as they are.
