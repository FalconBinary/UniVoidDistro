# kernel/ — track K: `vh-kconf`

A kernel built for this machine only: drivers built in, `CONFIG_MODULES=n` unless the gaming
session needs the NVIDIA modules. Owned files: this directory, the Limine hooks, the dracut
configuration and the `kernel.d` hooks in `rootfs/`. The plan is
[docs/ROADMAP.md](../docs/ROADMAP.md#k-vh-kconf-the-kernel-of-this-machine); what the user
does with it is [docs/runbook-gf63.md](../docs/runbook-gf63.md).

```
kernel/
  build.zig            vh-kconf (static PIE, ReleaseSafe; shares ../zig/lib/vh.zig in place)
  src/                 main (the commands), probe, resolve, diff, hw (hw.zon), alias
                       (modules.alias, fnmatch), kconfig (.config, the Kconfig tree, Kbuild)
  profiles/            Kconfig fragments, every option with its reason: base, mandatory,
                       hardening, perf (what every machine gets), class/ (what a hardware
                       class needs: cpu-intel, gpu-amdgpu, storage-nvme, ...; the machine's plan
                       names them), features/{usb-common,bluetooth,camera,virt,game}
                       (+ NAME.modules: the stock modules a feature stands for), modules.deny
  pins/                the Void linux6.18 .config and its modules.alias / modules.builtin* /
                       modules.firmware, with the void-packages commit and hashes; kernel.org
                       PGP fingerprints
  hw/                  hw.zon files of the known machines, which CI builds from (gf63,
                       amd-desktop, intel-hybrid-laptop, qemu-q35, aarch64-virt, rpi5)
tests/kernel/          the GF63 sysfs/procfs fixture (mkfixture.py writes it), run.sh
.github/workflows/kernel-custom.yml   the build
```

## v0.1: what exists

```sh
vh-kconf probe [--from DIR] [--save DIR] [-o FILE|--stdout]
vh-kconf resolve --hw FILE --plan FILE --out DIR --repo DIR [--features LIST|auto|none] [--alias F ...]
vh-kconf diff --config .config --requested fragment.config [--lsmod FILE] [--kernel DIR]
vh-kconf check [--hw FILE] [--out DIR] [--repo DIR] [--vh-plan PATH|none] [--kmsg FILE] [--from DIR] [--root DIR]
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
  holds the summary line `VH_CHECK machine=same|different devices=N firmware=N` for
  `vh-audit plan` ([docs/uni/runtime.md](../docs/uni/runtime.md#vh-kconf-check)).

The workflow does the rest in this order: PGP-verify the tarball, `vh-plan plan`, resolve,
copy `.config`, `yes "" | make LLVM=1 localyesconfig LSMOD=lsmod`, `make LLVM=1 olddefconfig`,
diff, check the invariants, `make LLVM=1 KCFLAGS=<the plan's -march> bzImage` with fixed
`KBUILD_BUILD_*`, upload. The GF63 oracle (`sh tests/kernel/oracle.sh`) holds the result to
upstream's for that laptop: the classes reassemble exactly the symbols the universal profiles
had for it.

Tests: `sh tests/kernel/run.sh` builds the unit tests for Linux and runs them in a container
(Zig cannot run Linux binaries on the Mac); `zig build test` does the same on a Linux host.
The tests read `tests/kernel/fixtures/gf63` and `kernel/pins`. The fixture is synthesised from
the hardware list of README.md and the pinned alias tables; `vh-kconf probe --save` on the
laptop produces the real one [VERIFY].

## install: the design (the next piece)

`vh-kconf install bzImage SHA256SUMS` on the laptop, after the runbook's download step.

1. **Verify.** `sha256sum -c` against the release's `SHA256SUMS`; the `BUILD` file names the
   commit and the `hw.zon`; refuse an image whose `hw.zon` is not the laptop's current
   `/etc/vh/hw.zon` (a different machine, or hardware exercised since the probe).
2. **Firmware list.** The modules of the LSMOD list (and the built-in drivers the resolve
   report names) are looked up in the stock kernel's module files on the laptop:
   `modinfo -F firmware MODULE` for the kernel of `hw.zon`'s `probe.kernel`. The custom kernel
   has the same drivers built in, so it needs the same files. Plus `regulatory.db` and
   `regulatory.db.p7s` (a built-in cfg80211 without them is stuck in the world domain), plus
   the microcode as dracut's early cpio. The files are the zstd-compressed ones Void ships
   (`FW_LOADER_COMPRESS_ZSTD`). [VERIFY: the firmware loader of 6.18 waits for the initramfs
   for built-in drivers probed before the initrd is unpacked; if not, `i915` and `iwlwifi`
   must be deferred or the files go into `EXTRA_FIRMWARE` after all.]
3. **The UKI.** dracut with `--no-kernel --kver 6.18.57-vh --kernel-image bzImage --uefi`, the
   existing `rootfs/etc/dracut.conf.d/10-vh.conf.in` (crypt, early microcode, reproducible),
   `install_items+=` the firmware list, and the cmdline of the stock UKI with these changes:
   `module_blacklist=` and `module.sig_enforce=1` removed (nothing to load), the `modprobe.d`
   options moved onto the cmdline because there are no modules to carry them
   (`iwlwifi.power_save=0 iwlwifi.uapsd_disable=3 iwlmvm.power_scheme=1`, the iTCO
   `nowayout`/`heartbeat`), everything else identical, so that the sysctl loader and
   `vh-audit` see one system. Parameters of modules that do not exist would reach PID 1 as
   environment: the cmdline is checked against the final `.config` before dracut runs.
   Output: `/boot/efi/EFI/void/linux-6.18.57-vh_1.efi` (the `_N` counts installs of the same
   version).
4. **Signing and Limine.** `sbctl sign` as today (the key media must be attached in the
   offline-keys module). `vh-limine-update` learns two UKI series: `linux-A.B.C_D.efi` (the
   stock one, pinned: never deleted, never demoted) and `linux-A.B.C-vh_N.efi` (custom,
   `KEEP=2`). Today its `parseUki` accepts only the stock pattern and would delete the
   fallback; the `kernel.d` hooks and the `vh-audit` check "UKI: 1-3" change with it. The
   default entry stays the stock UKI until the runbook's flip step: boot the custom entry
   once from the menu, check `uname -r`, Wi-Fi, sound, the touchpad, `vh-audit`, then make it
   the default; the way back is the menu.
5. **check** (a service at start, done in U2: see above): a modalias without a driver in
   sysfs -> a message at the admin login on tty2, with the `vh-kconf probe` + CI steps of the
   runbook as the answer.

Not in v0.1: `fetch` and `build` on the laptop (the kbuild root arrives in v0.3 with the thor
policy for separate roots); `resolve` v2 (`allnoconfig` + fragments, v1 as the oracle).
