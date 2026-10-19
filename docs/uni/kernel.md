# The machine kernel (U3)

Milestone U3 of the [plan](ROADMAP.md#k-the-kernel-of-any-machine): the kernel of every machine,
not only of the laptop void-hardperf-light was written for. `vh-plan` decides from `hw.zon` and
`hwdb/` which class fragments, how many CPUs and which `-march` a machine gets;
`vh-kconf resolve --plan` turns that into the LSMOD list and the `.config` of the build
([kernel/README.md](../../kernel/README.md)). This file describes what U3 adds around it.

## -march

The plan carries the `-march` of a kernel that is built elsewhere (in CI): `vh-plan` sets the
scalar `march` from `hwdb/`, `resolve --plan` writes `-march=VALUE` into `kcflags`, and the
workflow passes it as `KCFLAGS`, last on the compiler's command line. The kernel's own
`-mno-sse`, `-mno-avx` and the like stay in force: the compiler applies explicit feature flags on
top of the CPU's, so `-march` chooses the integer instructions and the tuning.

- **A model table** in `hwdb/`: `cpu.intel.march.*` (Skylake to Comet Lake: `skylake`; Tiger
  Lake; Alder Lake and Raptor Lake: `alderlake`), `cpu.amd.march.*` (Zen 2 to Zen 5:
  `znver2` .. `znver5`), and on ARM `-mcpu` by core (U5).
- **Else the x86-64 level** of the CPU flags (`x86.march.v2` .. `v4`, a lower priority): the
  instruction set the CPU has for sure, with no tuning for a model.
- **A virtual machine always gets the level** (`armv8-a` on ARM): the model rules carry
  `lacks = vm`. Its CPU is what the hypervisor shows today; the same system boots on another
  host or after a migration, and a kernel built for the host's model would stop at the first
  instruction the next host lacks. (A KVM guest with `-cpu host` on a Zen 4 host would otherwise
  get `znver4`.)

| Machine | CPU (vendor, family, model) | Rule | `-march` |
|---|---|---|---|
| gf63 | Intel, 6, 0xA5: i5-10500H, Comet Lake-H | `cpu.intel.march.skylake` | `skylake` |
| amd-desktop | AMD, 0x19, 0x61: Ryzen 9 7950X3D, Zen 4 | `cpu.amd.march.znver4` | `znver4` |
| intel-hybrid-laptop | Intel, 6, 0x9A: i7-1260P, Alder Lake-P | `cpu.intel.march.alderlake` | `alderlake` |
| qemu-q35 | QEMU's TCG CPU (AMD, 6, 6), a virtual machine | `x86.march.v3` | `x86-64-v3` |

The golden plans pin each value (`VH_PLAN_MARCH` in `tests/adapt/golden/*/strict/plan.env`); the
unit test "-march: the CPU model's on bare metal, the x86-64 level in a virtual machine" in
`adapt/src/tests.zig` runs the real `hwdb/` on these fixtures, then on the same CPUs passed
through to a virtual machine (the `hypervisor` flag added), which get `x86-64-v3`, `x86-64-v4`,
`x86-64-v3`, `x86-64-v3`.

Not claimed: that the model's `-march` is faster than the level. The principles ask for a
measurement per class of hardware ([principles](principles.md#the-rules-of-adaptivity), rule 7);
there is none yet [VERIFY by measurement with bench/ on each class].

### CONFIG_X86_NATIVE_CPU: the local build, later

Linux 6.18 can compile the kernel for the CPU of the build host: `CONFIG_X86_NATIVE_CPU` adds
`-march=native` (the pinned Void config has `CONFIG_CC_HAS_MARCH_NATIVE=y` and
`# CONFIG_X86_NATIVE_CPU is not set`). It applies to the build on the machine itself, in the
kbuild root ([below](#the-local-build-later)): there the build host is the machine, so the
compiler sees the exact CPU, including one no rule of `hwdb/` names. The design: the local build
passes `--native` to `resolve`, which then puts `CONFIG_X86_NATIVE_CPU=y` into the machine
fragment (a lost symbol there fails the build, as for `NR_CPUS`) and writes no `-march` into
`kcflags`; on a virtual machine (`class` vm) it keeps the level, for the reason above. In CI it
would be wrong: `native` would be the runner's CPU, not the machine's.

## The local build, later

Not written yet: it waits for upstream v0.3, which brings the kbuild root and thor's policy
profiles for separate roots ([upstream ROADMAP](../ROADMAP.md), track K "build" and v0.3). Until
then the machine kernel is built in CI from a committed `hw.zon`, as upstream builds the GF63's.
What UniVoidDistro adds to upstream's design, which stays as it is (clang, lld, make, flex,
bison, bc, perl, pahole, elfutils, openssl from Void packages through `thor -r` into
`/var/lib/vh/roots/kbuild`, 0700 root; namespaces, no network, Landlock on the build
directory; `vh-sched` built against the new kernel's BTF in the same step):

1. **The inputs are this machine's**: `/etc/vh/hw.zon` and `/etc/vh/plan.zon` (or the fresh
   plan of `vh-kconf check` after a hardware change), `resolve --plan --native`
   ([above](#config_x86_native_cpu-the-local-build-later)). The tarball is verified against
   `kernel/pins/kernel-org.fingerprints`, as in CI; thor fetches it, the build itself has no
   network.
2. **The same steps as CI**: localyesconfig, olddefconfig, `vh-kconf diff` (a lost symbol of
   `mandatory`, a class or the machine fragment stops the build), the invariants of the
   workflow, bzImage with fixed `KBUILD_BUILD_*`. The workflow's shell moves into one script
   that both run, so that the two cannot drift apart.
3. **The machine stays usable**: the build runs at `SCHED_IDLE` and the idle I/O class, `-j` by
   the cores and the memory, ThinLTO only with enough memory [VERIFY the memory per job on the
   smallest machine of the corpus], and never at boot.
4. **The result goes the way of a CI kernel**: `vh-kconf install` (the UKI, signed;
   [kernel/README.md](../../kernel/README.md), "install"), then `vh-limine-update --new`, and
   it becomes the default only after its boot assessment, as a kernel from CI does.
5. **When**: on request, and after an update of the stock kernel, whose version the machine
   kernel follows (the stock series carries the security fixes and is the fallback).
