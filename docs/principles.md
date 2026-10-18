# Principles

The rules every change in this repository follows. They come from Void-Hardened-Refurs; the
table at the end lists what this project changes and how each change keeps its risk in check.

## Protection is never traded for speed silently

- A measure that costs something (speed, convenience) is adopted only with a measurement and a
  row in the summary table: **protects / residual risk / speed cost / convenience cost**.
- Where a fact is not verified it carries the **[VERIFY]** tag instead of a guess.
- "Faster" is claimed only when the method in [ROADMAP.md](ROADMAP.md#measurements-bench-an-honest-method)
  says so: alternating runs, warm-up discarded, median and p95, a bootstrap 95 % CI that
  does not include 0 and a difference of at least 3 %.
- Losses are published next to wins. "Better than everything that exists" is a hypothesis,
  never a definition of done.

## Code

The rules of [zig/README.md](../zig/README.md) apply to every Zig component:

- `std.os.linux` syscalls; no libc unless a system library is unavoidable (OpenSSL, libxcrypt).
- `Io.Reader` / `Io.Writer` are allowed everywhere; an `Io` instance (`std.Io.Threaded`) only in
  thor's network adapter.
- **ReleaseSafe**: bounds, overflow and null checks stay in the shipped program.
- Static PIE, full RELRO, stripped; no shell is spawned from a program.
- Sources of everything built from source are pinned by hash; kernel.org tarballs are verified
  by PGP signature with pinned fingerprints.
- Documentation, program output and the installer are in English.
- Shared code goes to `zig/lib/` as **new files only**; existing lib files are not edited by a
  track, otherwise parallel tracks conflict.

## The system

- The old path stays as the fallback until the replacement has passed its definition of done:
  the stock kernel's UKI is always in Limine, runit remains available as `init=`, thor 1 and
  the `xbps-*` commands keep working.
- `lockdown=confidentiality` and `modules_disabled=1` after preloading are kept.
- Compilers exist only inside `/var/lib/vh/roots/kbuild` (0700 root), never in the base.
- Nothing destructive is run on the real laptop by a session: the laptop gets runbooks
  (`docs/runbook-gf63.md`, `docs/recovery.md`).

## What changes against Void-Hardened-Refurs

| Was | Becomes | How the risk is held |
|---|---|---|
| only the stock kernel | our own 6.18 LTS kernel from kernel.org, for this machine | the kernel.org signature is verified by Zig code; the build runs in an isolated root without network; Limine always has the signed **stock** UKI |
| no building from source | the kernel, the NVIDIA modules, our components, RefursWM/RefursLine may be built | compilers only in `/var/lib/vh/roots/kbuild` (0700 root) |
| runit | `vh-init` | runit stays as the fallback `init=` until the definition of done |
| sched_ext forbidden | only our own `vh-sched` is allowed | unprivileged BPF off; BPF LSM off; on failure the watchdog returns to EEVDF |
| thor = libxbps | thor 2 in Zig over the Void repositories | the pkgdb stays in the xbps format; thor 1 and `xbps-*` work as the fallback |
| ia32 and Xwayland forbidden | Xwayland only inside the gaming root. IA32 is enabled in the kernel **only when `vh-game` is installed** | vh-init puts the seccomp filter "not the x86_64 ABI -> kill" on every process tree except the gaming one |
| NVIDIA forbidden (DKMS against lockdown) | the open modules are built together with the kernel and signed with a one-time key | lockdown and `modules_disabled=1` after preloading are kept |
| "no `std.Io`" | `Io.Reader`/`Io.Writer` allowed everywhere; an `Io` instance (Threaded) only in thor's network adapter | amendment in `zig/README.md` |
| Russian | English: docs, program output, the installer | — |

**Licence:** GPL-3.0 as before. The BPF part, `sched/bpf/`, is GPL-2.0-only: the kernel
requires a GPL-compatible licence for GPL-only kfuncs.
