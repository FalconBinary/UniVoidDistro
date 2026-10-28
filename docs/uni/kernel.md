# The machine kernel (U3)

Milestone U3 of the [plan](ROADMAP.md#k-the-kernel-of-any-machine): the kernel of every machine,
not only of the laptop void-hardperf-light was written for. `vh-plan` decides from `hw.zon` and
`hwdb/` which class fragments, how many CPUs and which `-march` a machine gets;
`vh-kconf resolve --plan` turns that into the LSMOD list and the `.config` of the build
([kernel/README.md](../../kernel/README.md)). This file describes what U3 adds around it.

## The CI matrix

Every machine of `kernel/hw` (gf63, amd-desktop, intel-hybrid-laptop, qemu-q35 on x86_64;
aarch64-virt, rpi5 and qemu-virt, the aarch64 rig, on aarch64 since U5) gets its kernel resolved on every push and built on
request, against the pins of its architecture (`kernel/pins/README.md`: Void's `.config` and
module tables for x86_64 and for aarch64) and with the fragment of its architecture
(`kernel/profiles/arch/x86_64`, `arch/aarch64`: what only one of them has, the RTC driver, the
32-bit ABI, the compressed image; the universal fragments name nothing of one architecture).

**On every push** (the `adapt` workflow, `sh tests/kernel/matrix.sh`, a few seconds; it runs on
the Mac as well): each machine is planned in tiered mode (a kernel can be built for a machine
the strict gate would refuse to install on) and resolved with its plan, twice. The checks need
no kernel source:

| Check | What it catches before a build |
|---|---|
| the two runs give the same bytes (plan and resolve) | a nondeterministic plan or `.config` |
| every symbol a class of the plan sets is known to the pinned config | a class symbol olddefconfig would drop: the build would fail on it |
| no fragment conflict involves a class or the machine fragment | two classes that disagree, a later fragment overriding a driver |
| the invariants of the build hold in the requested `.config` | a profile that lost `MODULES=n`, sched_ext, BTF, lockdown or the io_uring ban |
| `NR_CPUS` is the plan's and within the range of its architecture (x86_64: the pinned config's 2..512; arm64: 2..4096 of `arch/arm64/Kconfig`) | a machine with more CPUs than the config allows |
| `kcflags` is the plan's `-march` (aarch64: `-mcpu` for a core), and clang accepts it for that target | a CPU the compiler does not know: `znver5` needs clang 19 or newer [VERIFY], and the build takes the clang of `ubuntu-latest` |

Before this, `tests/kernel/run.sh` resolved the GF63 only and `tests/adapt/run.sh` planned every
machine without resolving.

**On request** (the `kernel-custom` workflow with `hw=all`): one job per machine, in parallel,
each the whole build of [kernel/README.md](../../kernel/README.md): the PGP-verified tarball, the
plan, resolve, localyesconfig, olddefconfig, `vh-kconf diff`, the invariants, the image with the
plan's `-march` (a bzImage on x86_64; on aarch64 `ARCH=arm64` and the uncompressed `Image`,
cross-built by the same clang and lld, which need no other toolchain for it). A symbol of
`mandatory`, of a class the plan names or of the machine fragment
that olddefconfig did not keep makes `diff` exit 2 and fails that machine's job; the others go on
(`fail-fast: false`), and a failed job keeps its plan, its resolve output and its diff report
as the artifact `kernel-custom-NAME-KVER-failed`. A run for all machines makes no release (a
release is for one machine, the runbook's). The steps are kernel-custom's own: the matrix is an
input of that workflow rather than a copy of its shell or a reusable workflow, so that a merge of
upstream's changes to the file stays small. Each job takes the 30 to 60 minutes of a kernel
build, so it runs on request:

```sh
gh workflow run kernel-custom -R FalconBinary/UniVoidDistro -f hw=all
```

## -march

The plan carries the `-march` of a kernel that is built elsewhere (in CI): `vh-plan` sets the
scalar `march` from `hwdb/`, `resolve --plan` writes `-march=VALUE` into `kcflags`, and the
workflow passes it as `KCFLAGS`, last on the compiler's command line. The kernel's own
`-mno-sse`, `-mno-avx` and the like stay in force: the compiler applies explicit feature flags on
top of the CPU's, so `-march` chooses the integer instructions and the tuning.

- **A model table** in `hwdb/`: `cpu.intel.march.*` (Skylake to Comet Lake: `skylake`; Tiger
  Lake; Alder Lake and Raptor Lake: `alderlake`), `cpu.amd.march.*` (Zen 2 to Zen 5:
  `znver2` .. `znver5`), and on ARM the core (`arm.mcpu.*`: Cortex-A72, Cortex-A76, Neoverse
  N1). The scalar is `march` on both; on aarch64 clang's `-march` takes only architecture
  names, so `resolve` writes a core as `-mcpu=cortex-a76` and the `armv8-a` of a virtual
  machine as `-march=armv8-a` (`kcflags()` in `kernel/src/resolve.zig`).
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
| aarch64-virt | Apple's cores under the Virtualization framework (implementer 0x61), a virtual machine | `arm.mcpu.generic` | `-march=armv8-a` |
| qemu-virt | the aarch64 rig: Apple's cores under hvf (implementer 0x61, part 0x000), a virtual machine | `arm.mcpu.generic` | `-march=armv8-a` |
| rpi5 | Cortex-A76 (0x41, 0xd0b) | `arm.mcpu.cortex-a76` | `-mcpu=cortex-a76` |

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

## The boot assessment

`vh-limine-update` knows three series of UKIs on the ESP: the stock one, `linux-A.B.C_D.efi`
(Void's signed kernel package through dracut-uefi), the machine one, `linux-A.B.C-vh_N.efi`
([`vh-kconf install`](#the-machine-uki-vh-kconf-install); `uname -r` is `A.B.C-vh`), and the
init twin of a stock UKI, `linux-A.B.C_D-vh-init.efi`: the stock UKI with
`init=/usr/local/sbin/vh-init` appended to its command line, made and kept by vh-limine-update
while `/etc/vh/init-boot` exists ([`vh-init --install`](../../init/README.md#the-uki-with-vh-init-the-install-through-the-boot-assessment)).
A new machine UKI or init twin becomes Limine's default only after it has booted successfully
`MACHINE_BOOTS` times (3 by default, `/etc/vh/boot.conf`). Until then the default stays what it
was: the newest stock UKI, or a UKI that has passed. A trial that hangs or fails never
becomes the only way to boot: the boot after it reaches that default with no choice in the menu.
What follows says "machine UKI"; the init twin is assessed the same way, named "Void Linux
A.B.C_D (vh-init)" in the menu after the machine entries, and `--status`, `--retry NAME` and
`--demote` take it alike. The twin series keeps the newest stock UKI's twin plus the default,
the trial and the running one; a stock kernel update makes the new kernel's twin and puts it on
trial, unless a machine kernel is the default, which then keeps its place (the twin waits in the
menu for `--retry NAME`; a machine UKI built while the marker exists carries `init=` itself).
Without the marker every twin goes.

### What Limine 12.9.3 offers

The project pins no Limine version: the installer and thor take Void's `limine` package, 12.9.3
on 2026-10-19 (`srcpkgs/limine/template` of void-packages). Read in that version's source
(`common/menu.c`, `common/lib/bli.c`), its `CONFIG.md` and its ChangeLog:

- **No boot counting**: no tries counter on an entry, no boot-once-then-fall-back of its own.
- **systemd's Boot Loader Interface**, variables of the vendor GUID
  `4a67b082-0a4c-41cf-b6c7-440b29bb8c4f` (first support in 9.2.0, entry and timeout control in
  11.4.0, systemd-style entry identifiers in 12.7.0):
  - `LoaderEntryOneShot`: the menu code reads it before anything else and erases it as soon as
    it has read it, before any entry boots. It takes precedence over `remember_last_entry`,
    `default_entry` and `LoaderEntryDefault`; a value that names no entry falls through to the
    normal default.
  - `LoaderEntryDefault`: read and never erased; consulted only when the config sets neither
    `remember_last_entry` nor `default_entry` (`default_entry` wins over it since 12.9.0). A value
    that names no entry leaves the first entry the default.
  - `LoaderEntrySelected`: the identifier of the entry this boot started. `LoaderEntries`: the
    identifiers of the menu. `LoaderFeatures`: bit 3 says one-shot entries work. `LoaderInfo`:
    `Limine 12.9.3`. All four are volatile: a boot without Limine has none of them.
  - An entry's identifier is its name mapped onto `[A-Za-z0-9+_.@-]`: `/` (a parent directory)
    becomes `.`, every other byte `-`; a later duplicate gains `-2`, `-3`, ... The entry
    `Void Linux 6.18.57-vh_2 (machine kernel)` is `Void-Linux-6.18.57-vh_2--machine-kernel-`.
  - None of it depends on Secure Boot or the enrolled config hash. The variables only choose
    among the entries of the hashed config, each pinned by its BLAKE2B; the editor stays off.

### The mechanism

- **A trial is a one-shot entry.** `vh-limine-update --new A.B.C-vh_N` writes the menu with the
  new entry (after the stock entries) and sets `LoaderEntryOneShot` to its identifier. The next
  boot goes through the same Limine, the same hashed config and the same BLAKE2B check of the UKI
  as any boot, and Limine erases the variable before the kernel starts. If the kernel hangs,
  panics (`panic=10` reboots), fails in the initramfs (`rd.emergency=poweroff`) or never
  reaches the end of the boot, nothing sets the variable again, so the next boot is the default.
  After each good boot of the trial, the late-boot service sets it again for the next one.
- **Promotion is the persistent default entry.** After `MACHINE_BOOTS` good boots in a row the
  service sets `LoaderEntryDefault` to the UKI's identifier. limine.conf does not change: no
  signing at boot (so it works with `KEYS_OFFLINE=yes`), no write to the ESP at boot, and PCR 4
  stays what the trial boots measured. The menu is unchanged as well: the stock entries stay at
  its head, so when the variable is lost (an NVRAM reset), deleted (`--demote`) or names an
  entry the config no longer has, Limine boots the newest stock UKI.
- **The stock series is never removed or demoted.** It keeps upstream's rotation (`KEEP`, plus
  the running kernel), its names and its place at the head of the menu, and it takes no part in
  trials. The machine series is rotated on its own (`KEEP_MACHINE`, 2 by default, plus the
  default, the trial and the running one; newest first after the stock entries) and never
  deletes a stock UKI. With stock UKIs only, limine.conf is byte for byte upstream's.

### What a good boot is

The runit service `vh-boot-assess` runs `vh-limine-update --booted` once a boot, with the other
services, after the root file system is read-write (it works with either stage 1). For a boot of
the trial, or of the default machine kernel, it waits up to 120 s for the verdict of
`vh-kconf check` (the vh-check service, 5 s after the services start). The boot is good when
`/run/vh/check.done` says `machine=same lost=0`: the same machine, and no device that the stock
kernel of this installation drives (its view, `/var/lib/vh/check/stock.zon`, which `vh-kconf
check` writes at each stock boot; the installation's probe while there is none) is without a
driver now. Neither the firmware failures (iwlwifi logs a failed
load for every newer firmware API it tries first, on any kernel) nor new devices without a
driver (a phone on USB has none on any kernel) decide it.

On a machine kernel (release `*-vh`) `vh-kconf check` counts as refused the modules its build
left out on purpose: `kernel/profiles/modules.deny`, the plan's deny list and the modules of the
features the plan does not select, as `module_blacklist=` says on the stock kernel. Otherwise
the GF63's camera and card reader, bound by their drivers when the installer probed and refused
by its plan, would look lost.

### The state machine

The state is `/var/lib/vh/boot-assess` (root, 0600): the default machine UKI and its BLAKE2B
(none: the stock UKI); the UKI on trial, its BLAKE2B, its state (trying or failed), its good
boots so far, the boot that set the one-shot entry, the last boot judged
(`/proc/sys/kernel/random/boot_id`) and the reason of a failure. At every boot `--booted` decides:

| This boot | Then |
|---|---|
| started the trial's entry, and the verdict is good | one more good boot; at `MACHINE_BOOTS` the trial becomes the default (`LoaderEntryDefault`), else the one-shot entry is set again |
| started the trial's entry, and the verdict is bad, or there is none | failed, with the verdict as the reason |
| started another entry, after a one-shot entry set in an earlier boot that Limine consumed | failed: the trial did not reach the end of the boot (it failed, was interrupted, or another entry was chosen in the menu: the three look the same) |
| as above, but this boot's `LoaderEntries` lacks the trial's identifier | failed: Limine did not know the entry, so the trial was never attempted |
| a boot through Limine, and the one-shot entry is still set | failed: this Limine did not erase the variable, so trials are not safe with it |
| no Limine (no `LoaderInfo`) | nothing: the trial waits |
| no one-shot entry set yet (the boot loader of the install's boot could not take one) | set now, if this Limine supports one-shot entries and lists the trial |
| already judged (the service ran twice) | nothing |

A good boot of the trial's entry chosen by hand in the menu counts as well. A boot of the
default machine kernel with a bad verdict is reported, not acted on; so is a boot of another
entry while a machine UKI is the default. `LoaderEntryDefault` belongs to the tool: when it names
another entry than the state's default, `--booted` sets it back. Every run that writes
limine.conf compares the state with the ESP: a default or a trial whose UKI is gone is forgotten
and its variable deleted; one whose BLAKE2B changed is another kernel and starts its assessment
anew. The BLAKE2B is the one limine.conf pins, taken after signing: this relies on `sbctl sign`
leaving a file it has signed as it is ("already signed"), as the hash pins of every kernel update
already do [VERIFY with the system's sbctl]. A new trial passing makes the previous default
machine UKI an ordinary entry, which the rotation removes in time.

### Commands and settings

```sh
vh-limine-update --new 6.18.57-vh_1   # (the hook of vh-kconf install) the menu, then the trial
vh-limine-update --booted             # the vh-boot-assess service, once a boot
vh-limine-update --status             # the default, the trial, and this boot as Limine reports it
vh-limine-update --retry [NAME]       # assess the failed trial again, or the machine UKI or init twin NAME
vh-limine-update --demote             # the stock UKI is the default again (no key needed)
```

`/etc/vh/boot.conf`: `MACHINE_BOOTS=3` (1-10), `KEEP_MACHINE=2` (1-5). The admin's login on
tty2 shows `/run/vh/boot-assess` when the service has news: a trial in progress, a failure and
its reason, a promotion, a default machine kernel that lost drivers or was not the one booted.

### tpm2-totp

Every change of limine.conf changes `BOOTX64.EFI` (the enrolled hash is inside it) and with it
PCR 4, and a UKI is measured into PCR 4 too: the code matches only the boot path it was sealed
on. The install of a machine UKI asks for one reseal at the next boot, which is the first trial
(the initramfs shows `/proc/version`: the machine kernel's). The promotion measures nothing new:
no second reseal. A failed trial leaves the code sealed on the trial's path: the boot after it
shows one mismatch, which its admin login then explains, and the service asks for a reseal at
the boot after that. `--demote` asks for one as well.

### What it protects, and what it does not

| Protects | Residual risk | Speed cost | Convenience cost |
|---|---|---|---|
| a machine kernel that does not boot, or boots without a driver of the machine, never becomes the default; the boot after a failed trial reaches the default by itself | a default machine kernel that fails later (after a firmware update, with new hardware) is booted again until the stock entry is chosen in the menu and `--demote` is run; the boot after a failed trial shows one TOTP mismatch that cannot be told from tampering on that boot; an interrupted trial counts as failed; a Limine that stopped erasing `LoaderEntryOneShot` before it boots would retry a hanging trial at every boot, and the first trial with such a Limine is not protected [VERIFY with each Limine update: the tests/vm step `assess`] | none at boot: the service runs beside the others | `MACHINE_BOOTS` boots before the default changes; `--retry` after an interrupted trial |

A hang without a panic needs a power cycle (or the deadman's watchdog, once that service runs);
a panic reboots by itself; a failure in the initramfs powers the machine off.

### Rejected

- UEFI `BootNext` with a `Boot####` entry per UKI: the firmware deletes `BootNext` before it
  boots the option, but the trial would bypass Limine (no BLAKE2B pin, no menu), PCR 4 would
  differ from the Limine path, and `BootNext` and `BootCurrent` are as good as each firmware.
- A second signed Limine in `\EFI\vh-trial\` with its own config (Limine reads the config next to
  its executable first since 10.3.0): two loaders to sign and enroll, and `BootNext` to reach it.
- `remember_last_entry`, or `LoaderEntryDefault` for the trial: not one-shot, so a kernel that
  hangs would be booted again and again.
- Rewriting limine.conf for the trial or the promotion: each rewrite needs the db key (offline
  keys), a new enrollment, an ESP write at boot and a new PCR 4.
- systemd-boot's boot counting: another boot loader; the project chose Limine
  ([upstream docs/ru/03-boot.md](../ru/03-boot.md)).

## The machine UKI: vh-kconf install

`doas vh-kconf install DIR` ([kernel/README.md](../../kernel/README.md#install)) turns the kernel
of a `kernel-custom` run into `linux-A.B.C-vh_N.efi` on trial: its files checked against the
run's SHA256SUMS and the machine's `/etc/vh/hw.zon`, the final `.config` against what a UKI
needs, dracut `--no-kernel` with the plan's firmware in the initrd and the stock UKI's command
line without the parameters of modules the kernel does not have (and with `init=` appended
while vh-init is wanted, `/etc/vh/init-boot`), then `vh-limine-update --new`
and the boot assessment above. The procedure on the laptop is
[docs/runbook-gf63.md](../runbook-gf63.md), 1.6.

| Protects | Residual risk | Speed cost | Convenience cost |
|---|---|---|---|
| a kernel built for another machine, or from another probe of this one, is not installed, nor a damaged download; no UKI is built whose initrd its kernel could not unpack, whose firmware it could not load (the compression of either) or whose command line names modules it lacks; the stock UKI, its command line and its dracut configuration stay the reference of the machine one | SHA256SUMS is not a signature: a release replaced on GitHub, or the download replaced on the machine, passes as long as the two agree (with offline keys the kernel's SHA-256 is confirmed against the release page on another device); firmware a driver picks at run time that no hwdb rule names is not in the initrd (reported when the pins name it); a later change of modprobe.d or of the stock command line reaches the machine UKI only with the next install | none at boot; an install takes one dracut run | a probe that changed since the build needs a new build; with offline keys, three confirmations at the first install |

### Offline keys and vh-audit

The two follow-ups the machine series needed:

- **vh-uki-verify** (`optional/sb-offline-keys`) keeps references of the machine series beside
  the stock ones on the key media, `cmdline-machine` and `initrd-machine.sha256`. The first
  machine UKI shows its command line against the stock reference (the parameters removed and
  added) and records it once confirmed; the next ones must match it byte for byte. Its kernel
  is no package's file, so the SHA-256 of `.linux` is shown, to be compared with
  `bzImage-vh-KVER` in the release's SHA256SUMS on another device (dracut keeps the bzImage's
  exact size, so the two are equal: `tests/kernel/dracut_test.sh`). `/usr/local/sbin/vh-kconf`
  is one of the build inputs now. `vh-uki-verify --init` with a machine UKI records the machine
  references; `optional/sb-offline-keys/enable` records the newest stock UKI's and, when there
  is one, the newest machine UKI's.
- **vh-audit** on a kernel without loadable modules (no `/proc/modules`): the boot area says that
  `module.sig_enforce` has nothing to check and that no module lock is needed (there is no
  `kernel.modules_disabled`), and looks for fuse and overlay in `/proc/filesystems`; the plan
  area says the refused modules cannot be loaded instead of asking for `module_blacklist=`.
  `99-zz-vh-modlock.sh` skips the preload and the lock there. A machine kernel with modules (the
  game feature) keeps every check of the stock kernel.

### Not yet

- A real run: no `kernel-custom` run of this fork has built a kernel with the `BUILD` line and
  the `modules.builtin*` files install reads (scripts/Makefile.vmlinux of 6.18 writes both with
  every vmlinux, `CONFIG_MODULES=n` included); no machine UKI has booted, on the GF63 (runbook
  1.6) or on the VM rig (the step `machine`, kvm-smoke with `kernel_run`). [VERIFY]
- The local build ([below](#the-local-build-later)) will install its kernel the same way.

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
   [kernel/README.md](../../kernel/README.md#install)), then `vh-limine-update --new`, and
   it becomes the default only after its [boot assessment](#the-boot-assessment), as a kernel
   from CI does.
5. **When**: on request, and after an update of the stock kernel, whose version the machine
   kernel follows (the stock series carries the security fixes and is the fallback).
