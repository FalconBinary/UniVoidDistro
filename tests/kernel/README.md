# tests/kernel: vh-kconf

```sh
sh tests/kernel/run.sh        # the unit tests of kernel/ in an Alpine container, plus a smoke run
python3 tests/kernel/mkfixture.py   # rewrites fixtures/gf63 from the table in the script
```

`run.sh` cross-builds the test binary for Linux (the host's architecture) and runs it in a
container, because Zig cannot run Linux binaries on the Mac; on a Linux host `zig build test`
in `kernel/` does the same. The files the tests read are streamed into the container with
tar: Docker Desktop on macOS refuses to read bind-mounted files that carry the
`com.apple.provenance` attribute ("Resource deadlock would occur"), which files written from
the Claude app carry.

`fixtures/gf63` is a sysfs/procfs snapshot with the shape `vh-kconf probe --save DIR`
produces: `sys/bus/BUS/devices/NAME` symlinks to the real device directories under
`sys/devices/`, each with its `modalias` and a `driver` symlink into `sys/bus/BUS/drivers/`,
where a `module` symlink names the module; `sys/class/dmi/id`, `sys/firmware/efi`,
`sys/class/tpm/tpm0`, `sys/devices/system/cpu`; `proc/{cpuinfo,modules,mounts,sys/kernel/osrelease}`.

It is **synthesised** by `mkfixture.py` for the MSI GF63 Thin 10SCXR of README.md under the
stock Void `6.18.57_1`, with the devices, IDs and bound drivers a Void-Hardened-Refurs
installation has (the dGPU without a driver, mei blacklisted, kvm off, the module lock's
preload list). The PCI and USB IDs are public ones of this hardware; the ACPI and platform
objects are the usual ones of a Comet Lake-H laptop; the firmware strings are plausible.
**[VERIFY]** against the laptop: `doas vh-kconf probe --save /root/hw-snapshot` on the GF63
gives the real snapshot (docs/runbook-gf63.md); it replaces this directory, `mkfixture.py`
is deleted, and `kernel/hw/gf63.zon` is regenerated with `vh-kconf probe --from`.

What the tests assert on it (kernel/src/*.zig, `test` blocks): the probe reads every bus,
driver and module link, the CPU, DMI, EFI, TPM and file systems, writes no serial number,
and survives a `--save` round trip; resolve maps the Wi-Fi, Ethernet, Bluetooth, touchpad,
audio and TPM devices to the right stock modules against the pinned `modules.alias`, keeps
the loaded modules, leaves out the built-in drivers, refuses nouveau, mei, the tiny power
button and the modules of unselected features, prefers the module the running system
bound over other matches, and reports the conflicts between hardening and the game feature.
