# kernel/ — track K: `vh-kconf`

A kernel built for this machine only: drivers built in, `CONFIG_MODULES=n` unless the gaming
session needs the NVIDIA modules. Owned files: this directory, the Limine hooks, the dracut
configuration and the `kernel.d` hooks in `rootfs/`. The plan is
[docs/ROADMAP.md](../docs/ROADMAP.md#k-vh-kconf-the-kernel-of-this-machine); what the user
does with it is [docs/runbook-gf63.md](../docs/runbook-gf63.md).

```
kernel/
  build.zig            vh-kconf (static PIE, ReleaseSafe; shares ../zig/lib/vh.zig in place)
  src/                 main (the commands), probe, resolve, diff, check, install (the machine
                       UKI), hw (hw.zon), alias (modules.alias, fnmatch), kconfig (.config, the
                       Kconfig tree, Kbuild), uki (a bzImage's header, PE sections, cpio names)
  profiles/            Kconfig fragments, every option with its reason: base, mandatory,
                       hardening, perf (what every machine gets), class/ (what a hardware
                       class needs: cpu-intel, gpu-amdgpu, storage-nvme, ...; the machine's plan
                       names them), features/{usb-common,bluetooth,wifi,camera,virt,game}
                       (+ NAME.modules: the stock modules a feature stands for), modules.deny
  pins/                the Void linux6.18 .config and its modules.alias / modules.builtin* /
                       modules.firmware, with the void-packages commit and hashes; kernel.org
                       PGP fingerprints
  hw/                  hw.zon files of the known machines, which CI builds from (gf63,
                       amd-desktop, intel-hybrid-laptop, qemu-q35, aarch64-virt, rpi5)
tests/kernel/          the fixtures (mkfixture.py writes them), run.sh, matrix.sh, oracle.sh,
                       dracut_test.sh (install against Void's dracut)
.github/workflows/kernel-custom.yml   the build
```

## v0.1: what exists

```sh
vh-kconf probe [--from DIR] [--save DIR] [-o FILE|--stdout]
vh-kconf resolve --hw FILE --plan FILE --out DIR --repo DIR [--features LIST|auto|none] [--alias F ...]
vh-kconf diff --config .config --requested fragment.config [--lsmod FILE] [--kernel DIR]
vh-kconf check [--hw FILE] [--out DIR] [--repo DIR] [--vh-plan PATH|none] [--kmsg FILE] [--from DIR] [--root DIR]
vh-kconf install DIR [--dry-run] [--hw FILE] [--plan FILE] [--repo DIR] [--root DIR]
```

- **probe** reads sysfs and procfs (nothing else) and writes `/etc/vh/hw.zon`: the modalias
  of every device on every bus with its bound driver and module, `/proc/modules`, the CPU
  (vendor, family, model, stepping, caches, SMT, flags), the DMI strings, EFI and TPM, the
  mounted file system types. No serial numbers, no UUIDs, no MAC addresses: the file is
  committed and travels to CI. `--save DIR` copies what it read into a snapshot with the
  shape of sysfs; `--from DIR` replays one (the fixture, or a snapshot from the laptop).
- **resolve** (v1, not a Kconfig solver): every modalias goes through the stock kernel's
  `modules.alias` and `modules.builtin.modinfo`; the module the running system bound wins
  over other matches; `modules.deny`, the plan's deny list and the modules of unselected
  features are refused; what `/proc/modules` had is kept; the selected features (by default
  the plan's) add their modules. The fragments are applied in order: base, mandatory,
  hardening, perf, the plan's classes (`class/NAME`), the features, and the machine
  (`NR_CPUS` = the plan's possible CPUs). The result is the LSMOD list for
  `make localyesconfig`, the merged fragment (with the origin of every symbol and the
  conflicts), the pinned `.config` with the fragment applied, `kcflags` (the plan's `-march`),
  and `resolve-report.txt` with every decision. The plan is required: without it the kernel
  would have no driver for the machine's disk, GPU or CPU.
- **diff** reads the `.config` the kernel produced after `localyesconfig olddefconfig` and
  says, for every requested symbol, whether it survived and if not why: the unmet
  dependency (from the Kconfig tree, evaluated against the final config), a missing prompt,
  a choice, a symbol this version does not have; and for every LSMOD module whether its
  `obj-$(CONFIG_*)` symbol is `=y`. A lost symbol from `mandatory`, from a class or from the
  machine fragment is exit code 2.
- **check** (U2, the `vh-check` service at boot) probes the running system and compares it
  with `/etc/vh/hw.zon`: another CPU model or board, devices without a driver (one that had
  a driver at installation, or a new one, unless the kernel refuses its module), firmware the
  kernel log says failed to load, and whether the plan's firmware trim left it out. A finding
  goes to `/run/vh/check`, which the admin sees at login on tty2, with a fresh plan of the
  running system in `/run/vh/plan` (`vh-plan` run by argv); `/run/vh/check.done` always
  holds the summary line `VH_CHECK machine=same|different devices=N firmware=N lost=N` for
  `vh-audit plan` and the boot assessment ([docs/uni/runtime.md](../docs/uni/runtime.md#vh-kconf-check)).
  On a machine kernel the modules its build left out (`resolve`'s deny list of the plan) count
  as refused, as `module_blacklist=` does on the stock kernel.
- **install** (U3) turns the kernel of a `kernel-custom` run into a signed machine UKI on trial:
  [below](#install).

The workflow does the rest in this order: PGP-verify the tarball, `vh-plan plan`, resolve,
copy `.config`, `yes "" | make LLVM=1 localyesconfig LSMOD=lsmod`, `make LLVM=1 olddefconfig`,
diff, check the invariants, `make LLVM=1 KCFLAGS=<the plan's -march> bzImage` with fixed
`KBUILD_BUILD_*`, upload (with `BUILD`, which names the commit and the hw.zon, and the
kernel's `modules.builtin` and `modules.builtin.modinfo`, which `install` reads). The GF63
oracle (`sh tests/kernel/oracle.sh`) holds the result to upstream's for that laptop: the
classes reassemble exactly the symbols the universal profiles had for it.

Tests: `sh tests/kernel/run.sh` builds the unit tests for Linux and runs them in a container
(Zig cannot run Linux binaries on the Mac); `zig build test` does the same on a Linux host.
The tests read `tests/kernel/fixtures/gf63` and `kernel/pins`. The fixture is synthesised from
the hardware list of README.md and the pinned alias tables; `vh-kconf probe --save` on the
laptop produces the real one [VERIFY].

## install

`doas vh-kconf install DIR` on the machine, after the runbook's download step
([docs/runbook-gf63.md](../docs/runbook-gf63.md), 1.6). DIR holds the files of one machine of a
`kernel-custom` run (its release or its artifact). `--dry-run` goes as far as dracut and prints
the command it would run; nothing is written. What happens to the result at boot is
[docs/uni/kernel.md](../docs/uni/kernel.md#the-boot-assessment).

1. **Verify.** Every file used (`BUILD`, `bzImage-vh-KVER`, `config-vh-KVER`,
   `modules.builtin-vh-KVER`, `modules.builtin.modinfo-vh-KVER`, `lsmod`, `resolve-report.txt`,
   `plan.zon`, the hw.zon) must be in `DIR/SHA256SUMS` and match it. `BUILD` names the machine,
   the version, the commit and, on the line `hw.zon: kernel/hw/NAME.zon sha256 HEX`, the hw.zon
   the kernel was resolved from, which must be this machine's `/etc/vh/hw.zon` byte for byte.
   Another machine is refused with what differs (the CPU model, the board: `vh-kconf check`'s
   comparison); another probe of this machine with the advice to commit it and build again.
   `--hw FILE` names another probe as this machine's (the VM rig does, see below). The bzImage's
   setup header must report `KVER-vh` (`CONFIG_LOCALVERSION="-vh"`). SHA256SUMS is not a
   signature: it catches a damaged or incomplete download; the release itself is trusted as
   GitHub serves it.
2. **The final `.config`.** With `--no-kernel` dracut skips its own kernel checks
   (`check_kernel_config` returns true), so install checks `config-vh-KVER` itself: `EFI_STUB`,
   `BLK_DEV_INITRD`, the `RD_*` of dracut's compressor (`compress=` of the dracut configuration,
   or a compression option in the hook's `DRACUT_OPTIONS`), `FW_LOADER` and
   `FW_LOADER_COMPRESS_ZSTD`/`_XZ` for the firmware's compression. A missing one stops the
   install before dracut runs; `MICROCODE` unset is a note (the early cpio would be ignored).
3. **The firmware of the initrd.** Every file under `/usr/lib/firmware` that a firmware pattern
   of the image's plan or of the installation's (`/etc/vh/plan.zon`) keeps. vh-plan made those
   patterns from the same `kernel/pins/modules.firmware` (what each module names, narrowed to
   the device where a hwdb rule knows it) and added the files drivers pick at run time (Intel
   Bluetooth's `intel/ibt-*`), so on a trimmed system (`VH_FIRMWARE_TRIM=yes`) they are the files
   on disk. Plus `regulatory.db` and `regulatory.db.p7s` when cfg80211 is built in (the feature
   `wifi`; without them it stays in the world domain). The patterns of the `*.microcode` rules
   are left out ([hwdb/README.md](../hwdb/README.md)): dracut's `early_microcode` puts this CPU's file into
   the early cpio, as for the stock UKI. The drivers of the LSMOD list and the stock built-ins
   whose firmware (`/root/vh/kernel/pins/modules.firmware`) gets no file in the initrd are
   reported. The files go in as Void ships them (zstd). A built-in driver probed at boot finds
   them: the firmware loader waits for the initramfs (`fw_get_filesystem_firmware()` calls
   `wait_for_initramfs()`, `drivers/base/firmware_loader/main.c` of 6.18), and after
   `switch_root` it reads the root's `/lib/firmware`, for a device plugged in later.
   [VERIFY on the GF63: i915's DMC and iwlwifi load from the initrd at the first trial boot,
   `dmesg | grep -i firmware`.]
4. **The command line.** The `.cmdline` of the newest stock UKI (`linux-A.B.C_D.efi` on the ESP),
   so that the sysctl loader, `vh-kconf check` and `vh-audit` see one system, with three changes:
   - without loadable modules (`# CONFIG_MODULES is not set`), `module_blacklist=` and
     `module.*` (`module.sig_enforce=1`) are removed; with the game feature's modules they stay;
   - `MOD.param` is removed when MOD is a module of the stock kernel (`modules.dep` and
     `modules.builtin` in `/usr/lib/modules`) that the machine kernel lacks (its own
     `modules.builtin*`, which the build writes from the final `.config`): for example
     `efi_pstore.pstore_disable=1`, since `hardening` turns `EFI_VARS_PSTORE` off. Dotted
     parameters of the core and the initrd (`rd.*`, `iommu.*`, `page_alloc.*`) name no module
     and stay. Linux 6.18 drops an unknown dotted parameter, but hands an unknown one without a
     dot to PID 1 as an environment variable (`init/main.c`, `unknown_bootoption()`), as
     `module_blacklist=` would be on a kernel without modules: the machine UKI's command line
     holds only what its kernel takes;
   - the `options` lines of modprobe.d (`/etc`, `/usr/local/lib`, `/usr/lib`, `/lib`: kmod's
     order and precedence) for modules that are built in become `MOD.param=value` after the
     stock parameters, as kmod applies them after the command line's: today
     `iwlwifi.power_save=0 iwlwifi.uapsd_disable=3 iwlmvm.power_scheme=1`
     (`rootfs/etc/modprobe.d/vh-iwlwifi.conf`) and, with `optional/deadman`, the watchdog's
     `nowayout=1`. The options of a module the kernel does not have stay in modprobe.d (reported).

   The result must be printable ASCII within the kernel's 2047 bytes.
5. **The UKI.** `dracut --force [DRACUT_OPTIONS] --no-kernel --kver KVER-vh --kernel-image
   bzImage --uefi --kernel-cmdline=LINE --include FILE FILE ...` (one `--include` per firmware
   file, so that names with spaces stay whole), with the system's dracut configuration, the
   stock UKI's (`rootfs/etc/dracut.conf.d/10-vh.conf.in`: crypt, early microcode, reproducible;
   the optional modules' `20-vh-totp.conf`, `21-vh-deadman.conf`), into `/var/tmp`. Then
   checked: `.linux` is the verified bzImage byte for byte, `.cmdline` the line of step 4 (a
   `kernel_cmdline=` in dracut's configuration would add to it), and an early cpio holds the
   microcode where there is one. Written to `/boot/efi/EFI/void/linux-KVER-vh_N.efi` beside its
   name, synced and renamed into place: N counts the installs of `KVER-vh` and never comes back
   for another kernel (the ESP, the records and the boot assessment's state are counted).
   Verified with Void's dracut 112 in a container (`sh tests/kernel/dracut_test.sh`):
   `--no-kernel` with `--kernel-image` and `--uefi` works, the firmware lands in
   `usr/lib/firmware` of the initrd, its `lib` is a link to `usr/lib`, no module is in it, and
   `.linux` keeps the bzImage's exact size.
6. **Signing and Limine.** `vh-limine-update --new KVER-vh_N` signs it as it signs every UKI of
   the menu (`sbctl sign`, after `vh-uki-verify` with offline keys; the machine series has its
   own references: [docs/uni/kernel.md](../docs/uni/kernel.md#offline-keys-and-vh-audit)), adds
   it after the stock entries and puts it on trial: Limine's one-shot entry, then its default
   after `MACHINE_BOOTS` good boots. What `sign()` would refuse (offline keys not attached,
   Secure Boot on without the db key) is refused before dracut runs; a failure of `--new` before
   `limine.conf` names the UKI removes it again. `/var/lib/vh/kernels/KVER-vh_N/` keeps the
   record: the report, the command line, the firmware list, `BUILD` and `SHA256SUMS`.

The ESP is mounted for the run when it is not (`noauto`, as the `kernel.d` hooks do) and
unmounted after; one install runs at a time (`/var/lib/vh/kconf-install.lock`). Tests: the unit
tests of `install.zig` and `uki.zig`, with an install end to end under `--root` (stand-ins for
dracut and vh-limine-update) and what is refused; `tests/kernel/dracut_test.sh` with Void's
dracut; the VM rig's step `machine` (`python3 tests/vm/check.py machine --repo` with a run's
qemu-q35 files in `build/kernel-custom`, the kvm-smoke input `kernel_run`). That kernel is
built from the synthesised `kernel/hw/qemu-q35.zon`, not from the rig's probe, so the step
passes `--hw` that file, and the boot assessment judges the kernel against the rig's own probe.

What install does not do: build the kernel (CI does it, from a committed hw.zon); carry a later
change of modprobe.d or of the stock command line into a machine UKI already installed (install
again); follow an update of the stock kernel (the machine kernel keeps its version until the
next run).

Not in v0.1: `fetch` and `build` on the laptop (the kbuild root arrives in v0.3 with the thor
policy for separate roots); `resolve` v2 (`allnoconfig` + fragments, v1 as the oracle).
