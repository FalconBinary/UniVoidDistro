# 19. Benchmarks

The numbers of this distribution from v0.1 on, by the method of
[ROADMAP.md](ROADMAP.md#measurements-bench-an-honest-method): the metrics are fixed before
measuring, variants alternate in a random order with the warm-up discarded, median and p95,
a bootstrap 95 % confidence interval, "faster" only when the interval excludes 0 and the
difference is at least 3 %. Losses are published next to wins. The raw data of every run is
in `bench/results/` (one CSV per run, every boot a row).

## v0.1: stage 1 of the boot, runit-void's shell against vh-stage1

**What is measured.** The wall time of runit's stage 1: from the first line of
`/etc/runit/1` to its last, as two markers in the kernel log (the shell variant is the stock
script plus two `echo` lines into `/dev/kmsg`, `bench/init/1.shell-marked`; vh-stage1 writes
its own). A second number counts from the kernel's "Run /sbin/init as init process" line,
so the exec of stage 1 itself is inside it. Both variants run the same core-services: the
same mounts, sysctls, udev trigger and settle, nftables ruleset, AppArmor profiles, zram.

**Where.** The test rig of `tests/vm` (QEMU q35, OVMF with Secure Boot, swtpm, NVMe, the
full installation of this repository: LUKS2, the Void 6.18 kernel, runit-void-20250212_4),
driven by `bench/init/stage1_boot.py`. The first run below is QEMU **TCG** (software
emulation) on an Apple M-series Mac with 4 vCPUs and 3 GB: absolute times are several times
those of real hardware and the emulation adds its own noise. A KVM run (the kvm-smoke
workflow, `step=stage1`, or any Linux host with `--accel kvm`) and the laptop's own numbers
by [runbook-gf63.md](runbook-gf63.md) replace it as they come in.

PENDING: the table of the first run goes here (the install of the rig under TCG was still
running when this file was written; the run is `bench/results/stage1-tcg-20261019.csv`).

**What the numbers do not show.** Stage 1 is a few percent of the whole boot. Inside it the
udev settle (the kernel probing the hardware, the same in both variants) is the largest
step by far; the shell's own cost is the interpretation of about twenty scripts and the
processes they spawn (`mount`, `sysctl`, `awk`, `getent`, `install`, `mkswap`, `swapon`,
`chmod`, `grep`, `xargs`, `kmod`...). That is what vh-stage1 removes; the device manager, the
firewall and the policy compiler are the same programs run by argv. The GF63 numbers are
**[VERIFY]** until the owner runs the runbook procedure; the TCG run says nothing about them
beyond the direction.
