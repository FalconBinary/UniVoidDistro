# UniVoidDistro: principles

Every rule of the upstream [principles](../principles.md) applies unchanged:

- protection is never traded for speed silently; a measure with a cost comes with a
  measurement and a row "protects / residual risk / speed cost / convenience cost";
- "faster" is claimed only by the bench method of [the upstream ROADMAP](../ROADMAP.md#measurements-bench-an-honest-method);
- [VERIFY] instead of a guess;
- ReleaseSafe, static PIE, full RELRO, no shell spawned by a program; sources pinned by hash;
- documentation, program output and the installer in English;
- the old path stays as the fallback until its replacement has passed its definition of done.

This file adds the rules of a distribution that adapts itself to the machine.

## The rules of adaptivity

1. **Hardware is detected, never assumed.** No vendor or model name, PCI or USB id, firmware
   file name or vendor-specific Kconfig symbol appears outside `hwdb/`,
   `kernel/profiles/class/`, the fixtures (`tests/kernel/`) and the pins (`kernel/pins/`).
   `tests/adapt/lint.sh` enforces it in CI. A runtime rule may name a driver it applies to
   (a udev rule `DRIVERS=="r8169"` is a no-op on every other machine).
2. **Every hardware decision is a rule with an id and a reason.** `vh-plan` records the rule
   id next to every package, firmware pattern, kernel fragment, command-line parameter,
   service, initrd driver and denied module; `vh-plan explain ITEM` prints the chain.
3. **The plan is deterministic.** The same `hw.zon`, `hwdb/` and `vh.conf` give the same plan,
   byte for byte. The golden plans in `tests/adapt/golden/` hold it.
4. **Unknown hardware degrades to the universal path, never to an unbootable system.** The
   stock signed UKI is always in Limine. A machine kernel becomes the default only after it
   has booted (U3). A device no rule knows still gets its stock driver on the stock kernel,
   and `vh-kconf check` reports it.
5. **Runtime rules before generated configuration.** Where a rule that matches attributes at
   runtime costs nothing (a udev rule by `rotational`, by driver), it is installed on every
   machine. Generation per machine is for what measurably pays: the kernel, the firmware
   set, the package set, the initrd.
6. **Security modes.** `VH_SECURITY=strict` is the default: a machine without the full set of
   protective properties of its architecture (the table below) is refused, with the reason
   and the firmware setting that fixes it. `tiered` is chosen explicitly: every missing
   property is shown with its residual risk, confirmed by typing, recorded in `plan.zon` and
   marked by `vh-audit`. A protection is never lowered any other way.
7. **Speed claims per hardware class.** A tuning decision claimed to be faster (an I/O
   scheduler, a zram size, an EPP value, a `-march`) carries a measurement on that class of
   hardware, or the [VERIFY] tag.
8. **`hw.zon` stays private, firmware strings stay out of shell code.** No serial numbers, MAC
   addresses or UUIDs in `hw.zon`: it is committed as a fixture and travels to CI. Strings
   read from the firmware (DMI, the device tree) are data: they never reach `plan.env`, which
   the shell installer sources; `plan.env` carries only values that come from `hwdb/`.
9. **The GF63 oracle.** For the machine void-hardperf-light was written for, the plan
   reproduces its choices: packages, firmware, command line, the kernel configuration. Every
   difference is listed and explained in the report.
10. **Own files in new paths.** Upstream files are edited only where the hardware enters them,
    so that `git merge upstream/main` stays small; new work goes to `adapt/`, `hwdb/`,
    `kernel/profiles/class/`, `tests/adapt/`, `docs/uni/`.

## The protective properties per architecture

`vh-plan` derives them from `hw.zon`; the installer refuses or asks according to the mode.

| Property | x86_64 | ARM64 | Missing, strict | Missing, tiered: the residual risk |
|---|---|---|---|---|
| boot firmware | UEFI 64-bit | UEFI | refused | x86_64: refused (no legacy BIOS, no 32-bit UEFI); Raspberry Pi: the boot chain is not verified (U5) |
| Secure Boot | the `SecureBoot` variable exists | the same | refused | the boot chain is not verified: an "evil maid" can replace the kernel |
| TPM 2.0 | firmware TPM or a discrete one | where present | refused | no tpm2-totp, no measured boot, no Option ROM check for key enrolment |
| IOMMU | the DMAR (Intel) or IVRS (AMD) table | IORT (SMMU) | refused, with the advice to enable VT-d / AMD-Vi | DMA from a malicious device is not contained |
| AES in the CPU | the `aes` flag | `aes` (ARMv8 Crypto Extensions) | refused | the disk is encrypted with Adiantum instead of AES-XTS |
| memory | 2 GiB for Argon2id with 1 GiB per guess (cryptsetup uses at most half of the RAM); 1.5 GiB, the installation's floor from our live image (on Void's own image the installer builds its programs in RAM and needs 3 GiB) | the same | refused | below 1.5 GiB refused (the floor, in both modes); from 1.5 to 2 GiB Argon2id gets a quarter of the RAM (at least 256 MiB), so each guess of the passphrase costs an attacker less |

What does not change with the mode: `lockdown=confidentiality`, the module lock (no modules
on a machine kernel, `modules_disabled=1` on the stock one), `init_on_alloc`/`init_on_free`,
AppArmor, nftables per UID, DoT, NTS, the browser sandbox, CPU mitigations (`auto`).

## What this project changes against void-hardperf-light

| Was | Becomes | How the risk is held |
|---|---|---|
| one machine named in the code | the machine detected, the decisions in `hwdb/` | the GF63 oracle; golden plans of six machines; the lint |
| `vh.conf` names the hardware (`VH_GPU=igpu`, the firmware list) | `auto` by default, the plan decides; `vh.conf` keeps the user's choices | `vh-plan explain`; the report lists every decision |
| UEFI 64-bit + Secure Boot + TPM assumed | checked per machine; `strict` refuses, `tiered` asks | the residual risk named, typed confirmation, `vh-audit` mark |
| the kernel profile names Intel symbols | universal profiles + class fragments chosen by the plan | a lost class symbol is an error, as for `mandatory` |
| one architecture | x86_64 and ARM64 in the data model and the rules; the ARM64 installation is U5 | the installer refuses ARM64 until U5 |
