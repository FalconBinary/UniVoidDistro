# Runbook: the GF63 and milestone v0.1

What a person does on the laptop, step by step. A session never touches the laptop
(docs/principles.md): everything here is run by you, and every step says what it changes
and how to undo it. The laptop runs Void-Hardened-Refurs with the stock `linux6.18` UKI,
the module lock and Secure Boot with your own keys; nothing in this runbook changes that
until the step that says so.

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

## 2. `vh-stage1` (track I)

Written by track I when it is ready: `vh-stage1` in place of `/etc/runit/1`, the previous
file kept as `1.orig`, the way back one command.

## 3. Measurements (`bench/`)

Written with the first numbers of `docs/19-benchmarks.md`.
