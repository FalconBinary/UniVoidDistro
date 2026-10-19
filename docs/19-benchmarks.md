# 19. Benchmarks

The numbers of this distribution from v0.1 on, by the method of
[ROADMAP.md](ROADMAP.md#measurements-bench-an-honest-method): the metrics are fixed before
measuring, variants alternate in a random order with the warm-up discarded, median and p95,
a bootstrap 95 % confidence interval, "faster" only when the interval excludes 0 and the
difference is at least 3 %. Losses are published next to wins. The raw data of every run is
in `bench/results/` (one CSV per run, every boot a row).

## v0.1: stage 1 of the boot, runit-void's shell against vh-stage1

**What is measured.** The wall time of runit's stage 1: from the first line of
`/etc/runit/1` to its last, as two markers in the kernel log. The shell variant is the stock
script of runit-void-20250212_4 plus two `echo` lines into `/dev/kmsg`
(`bench/init/1.shell-marked`); vh-stage1 writes its own markers at its entry and its end.
Both variants run the same core-services on the same installation: the same mounts,
sysctls, udev trigger and settle, nftables ruleset, AppArmor profiles, zram. Nothing else
is counted: the initramfs, the LUKS passphrase and stage 2 are outside the markers.

**Where.** The test rig of `tests/vm` (QEMU q35, OVMF with Secure Boot, swtpm, NVMe; the
full installation made by `install/10-install.sh`: LUKS2, the Void 6.18 kernel), driven by
`bench/init/stage1_boot.py --boots 10`. QEMU **TCG** (software emulation; the guest sees
"QEMU TCG CPU version 2.5+") on an Apple M-series Mac with 4 vCPUs and 3 GB: absolute
times are several times those of real hardware, and process creation is especially
expensive under emulation, which favours the variant that spawns no processes. The run of
2026-10-19: 11 boots per variant in the random order below, the first boot of each variant
discarded as the warm-up, every boot a cold boot of the VM.

```
order: zig zig shell zig shell shell shell zig shell zig zig shell zig shell zig shell zig zig shell zig shell shell
```

| stage 1, done − start (ms) | runit-void shell | vh-stage1 | difference | 95 % CI |
|---|---|---|---|---|
| median | 6034 | 5041 | −993 (−16.5 %) | [−1146, −659] |
| p95 | 6214 | 5164 | | |
| min / max | 5662 / 6214 | 4652 / 5164 | | |
| verdict (CI excludes 0 and at least 3 %) | | | faster | |

Raw data: `bench/results/stage1-tcg-20261019.csv`. vh-stage1's own measurement (the
"done in N ms" of the marker) agrees with the kernel-log difference within 7 ms on every
boot. The shell boots fall into two groups (around 5.7 s and around 6.1 s) and the
vh-stage1 boots into one (4.65 s, then 4.9–5.2 s): emulation noise that the interval
already contains.

**Where the time goes in vh-stage1** (median of the 10 measured boots, ms):

| step | ms | what it is |
|---|---|---|
| static-devnodes | 2573 | one `modprobe -abq` with the modules of `modules.devname`: loading signed, compressed modules under emulation |
| vh-nftables | 802 | `nft -f /etc/nftables.conf`: the firewall ruleset |
| udev-settle | 687 | `udevadm settle`: the kernel finishing the probe of the hardware |
| pseudofs | 254 | the first mounts (efivarfs, cgroup2, bpffs, securityfs); not broken down further |
| udev-trigger | 178 | `udevadm trigger` for subsystems and devices |
| vh-apparmor | 166 | `apparmor_parser` with the cached profiles |
| udev-start | 101 | `udevd --daemon` |
| vh-zram | 90 | the module, the device, the swap signature, swapon |
| sysctl | 80 | about 90 keys from sysctl.d |
| misc | 44 | utmp, the wtmp record, seedrng, lo, hostname |
| everything else | 50 | kmods, console, remount-root, mount-all, swap, vh-mounts, vh-mm, runit-control, vh-runtime, vh-suid, dmesg, sbin-merge, cleanup, vh-modlock |

About 90 % of vh-stage1's time is spent inside programs that both variants run the same
way (module loading, udev, nft, apparmor_parser); what the shell variant adds on top is
the interpretation of about twenty scripts and the processes they spawn (`mount`,
`sysctl`, `awk`, `getent`, `install`, `mkswap`, `swapon`, `chmod`, `grep`, `xargs`, `kmod`,
`modprobe` once per module, `seedrng`, `halt`, `ip`...). That is the one second this run
shows.

A first run with vh-stage1's start marker written after its first step
(`bench/results/stage1-tcg-20261019-run1-marker-after-pseudofs.csv`) is kept for the
record; it undercounts vh-stage1 by that step and is not used for any claim.

**What the numbers do not show.** Stage 1 is a few percent of the whole boot: the
initramfs, the LUKS unlock and stage 2 are larger. Emulation exaggerates the cost of
spawning processes, so the laptop's relative gain is expected to be smaller than 16 %
and its absolute times a fraction of these; both are **[VERIFY]** until the owner runs the
procedure of [runbook-gf63.md](runbook-gf63.md) (the same script computes the table from
two `dmesg` files with `--from-dmesg`). A KVM run (the kvm-smoke workflow with
`step=stage1`, or any Linux host with `--accel kvm`) is the next closer approximation. The
honest win of v0.1 is a stage 1 with no shell at all and a per-step breakdown in the kernel
log; the base for v0.2 (vh-init as PID 1).
