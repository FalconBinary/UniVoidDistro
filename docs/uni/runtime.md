# UniVoidDistro: runtime adaptation (U2)

What adapts to the machine while the system runs, without a plan made for it: rules that
match attributes at runtime and cost nothing ([principles](principles.md), rule 5), and the
check at boot that the machine is still the one the system was planned for. The plan of the
installation (`/etc/vh/plan.zon`) decides what is installed; the pieces here act on what the
kernel shows at runtime, so a disk plugged in later or a second GPU is handled the same way
on every machine.

## The I/O scheduler

`rootfs/etc/udev/rules.d/99-vh-iosched.rules` is installed on every machine and chooses by
what a disk is, never by its model:

| Disk | Matched by | Scheduler | Why |
|---|---|---|---|
| NVMe | the kernel name `nvme*` | `none` | the device's own queues order the requests; a scheduler only costs CPU time |
| virtio-blk, the disks of virtio-scsi | a `virtio` device among the parents | `none` | the host schedules |
| an SSD on SATA (or USB, SAS) | `sd*` with `queue/rotational` 0 | `mq-deadline` | one hardware queue: reads before writes, nothing starves |
| a spinning disk | `sd*` with `queue/rotational` 1 | `bfq` | a slow device shared fairly keeps the desktop responsive during a copy |
| eMMC, SD cards | `mmcblk*` | `bfq` | the same for slow flash |

Every choice is **[VERIFY by measurement per class]** (`bench/`: fio latency and the 1 %
lows of the desktop while a large copy runs); principle 7 allows no speed claim without it.
Partitions, device mapper, loop, zram and optical drives keep what the kernel gives them. The
stock kernel builds `mq-deadline` and `bfq` in; `kernel/profiles/perf` names them so that a
machine kernel keeps them for a disk plugged in later (the GF63 oracle lists the two named
symbols as accepted differences: its `.config` does not change). `vh-audit performance`
checks the scheduler of every disk against the same table.

## The power profile: `vh-power`

The profile follows the power source; a machine without a battery (a desktop, a VM) is always
on AC. Three copies do the same: `rootfs/usr/local/sbin/vh-power` (the udev rule at plug
events), the native step of `vh-stage1` at boot (`init/src/vhsteps.zig`) and the checks of
`vh-audit performance`; `tests/init/stage1_test.sh` runs the first two on the same fake
sysfs and compares them.

| | on AC | on battery |
|---|---|---|
| EPP, wherever the CPU's frequency driver offers `energy_performance_preference` (intel_pstate, amd-pstate-epp) and lists the value | `balance_performance` | `balance_power` |
| the ACPI platform profile, where the firmware offers `/sys/firmware/acpi/platform_profile`: the first of these it lists | `balanced` | `low-power`, `quiet`, `balanced` |
| the runtime PM of PCI devices | `on` | `auto` |

The platform profiles follow the pairing power-profiles-daemon uses (balanced with
`balance_performance`, low-power or quiet for saving) and are **[VERIFY by measurement per
class]**: battery life and the 1 % lows. Two kinds of PCI device keep their runtime PM:
bridges (the dGPU sleeps through its root port) and every function in the slot of a display
controller (PCI class `0x03`) that did not bring the console up (`boot_vga`), whatever its
vendor: the dGPU with its audio or USB functions. Whether the dGPU sleeps is the plan's
decision (a rule of `hwdb/gpu.zon` sets the tag `dgpu` and selects its udev rule);
`vh-audit performance` checks that it is suspended only then.

## The watchdog of `optional/deadman`

`optional/deadman/enable` takes the watchdog from the plan (`VH_PLAN_WATCHDOG`, the scalar
`watchdog` of `hwdb/`): the chipset's on Intel (iTCO_wdt) and AMD (sp5100_tco), the SBSA
watchdog of ARM servers, the Raspberry Pi's (bcm2835_wdt), and softdog where no rule knows a
hardware one. It loads that module, preloads it before the module lock and gives it
`nowayout=1` (`/etc/modprobe.d/vh-watchdog.conf`; every watchdog driver has the parameter).
`vh-deadman` asks the driver for a 60 s timeout through the watchdog API and pets it at a
third of what the driver kept (at most every 10 s): a driver with a shorter limit of its own
is petted in time too. A firmware that disabled the hardware watchdog leaves its driver
without a device; `enable` then says so and the daemon runs without one.

| Watchdog | Protects | Residual risk | Speed cost | Convenience cost |
|---|---|---|---|---|
| the board's hardware one, from the plan | a dead or hung `vh-deadman`, and a hung kernel: the hardware resets the machine (with MOR the firmware wipes RAM) | the firmware may disable or lock it (no device appears) | one write every 10 s at most | none |
| softdog, when the plan knows no hardware one | a dead or hung `vh-deadman`: the kernel reboots | a hung kernel (a deadlock, interrupts off) never runs the software timer, so nothing resets the machine | the same | none |

## The backlight: `vh-backlight`

A machine may register several backlight interfaces: a hybrid laptop's two GPUs each a raw
one, the firmware's ACPI one beside a GPU's. `vh-backlight` writes the one that drives the
panel, chosen by what the kernel says of each, never by its name: `firmware` before
`platform` before `raw`, the order the kernel's ABI document (`sysfs-class-backlight`) asks
for, and last a raw interface whose DRM connector is not connected (the GPU the panel is not
wired to). `VH_BACKLIGHT=NAME vh-backlight +5` picks one by hand. `tests/init/stage1_test.sh`
checks the choice on a fake `/sys/class/backlight`.

## Built-in input: `vh-acpid` and `vh-deadman`

The idle watchdog of `vh-acpid` (lock and power off without physical input,
`optional/deadman`) counts only built-in keyboards and touchpads. It knows the PS/2 (i8042)
and I2C ones by their bus; a keyboard on internal USB, SPI or the host bus it cannot tell from
an external one. The probe records each keyboard's place under `/sys/devices` and, on USB,
the kernel's word for its USB device (`removable`: `fixed` means built in). The plan lists
the place of every built-in keyboard vh-acpid cannot tell (`internal_input`, in
`plan.env` `VH_PLAN_INTERNAL_INPUT`), and the installer writes it into
`/etc/vh/acpi.conf` as `INTERNAL_INPUT`. A keyboard whose USB device the kernel calls
`unknown` (no ACPI description of the port) is not counted [VERIFY on hardware with an
internal USB keyboard].

The power button reaches `vh-acpid` in one of two ways (`POWER_KEY` of `/etc/vh/acpi.conf`
decides the action either way). A control-method button (`PNP0C0C`, most laptops and PCs) is an
input device of the `button` driver; `tiny_power_button`, which matches it too and has no input
device, is refused (hwdb rule `acpi.power-button.tiny-off`). A machine with only the fixed
button (`LNXPWRBN`: QEMU's q35, some PCs) has no input device for it on kernel 6.18: between
6.12 and 6.18 `button` became a platform driver, and the kernel makes no platform device for the
fixed button, so `tiny_power_button` alone drives it (rule `acpi.power-button.fixed`, for a
machine without a control-method button and without a lid: it builds `tiny_power_button` into
the machine kernel instead of `button`, since built in the two exclude each other). It signals init, with SIGINT
(`tiny_power_button.power_signal=2`: Void builds it with 38, which runit ignores); runit runs
`/etc/runit/ctrlaltdel`, ours (kept over runit-void's by `/etc/xbps.d/30-vh-noextract.conf`),
which hands it to `vh-acpid` as SIGUSR1 (`sv 1 vh-acpid`), and `vh-acpid` takes that as a
press. A hypervisor's shutdown request (`virsh shutdown`, QEMU's `system_powerdown`) is this
button, and `tests/vm` checks it ends in a regular poweroff. Ctrl+Alt+Del on a text console
sends init the same SIGINT, so on such a machine it is the power button too; elsewhere
`ctrlaltdel` does what Void's does, a reboot.

The alarm combination of `optional/deadman` (Right Ctrl + Right Alt + End, `COMBO=yes` in
`/etc/vh/deadman.conf`) works on the same built-in keyboards, not only on a PS/2 one:
`vh-deadman` applies the same rule (`zig/lib/input.zig`, which `vh-acpid` uses too) and reads
the same `INTERNAL_INPUT`. Of those devices it listens to the ones whose key bitmap
(`capabilities/key`) has a key of the combination, so a touchpad never wakes it; the three
keys count when they are held at once on any of them, since a keyboard may send its modifiers
and its other keys through two input devices. A keyboard plugged in from outside and a
virtual one (uinput) never trigger the alarm. `vh-deadman test` lists the keyboards the
combination listens to. A keyboard that disappears (unplugged, its USB device reset) is
dropped with a line in the log. One that appears while the service runs (a detachable keyboard
attached again, a USB keyboard enumerated anew) is judged by the same rule as soon as the
kernel announces its `/dev/input/eventN` in a uevent, and counts from then on if it passes,
with a line in the log. For this the daemon reads the uevents whenever `COMBO=yes`, with a tag
or without one; without a tag no USB device arms or sets off the alarm [VERIFY on hardware
with a keyboard on internal USB, I2C or SPI].

## `vh-kconf check`

The `vh-check` service runs `vh-kconf check` once a boot, a few seconds after the services
start (a service rather than a step of stage 1: it stays off the boot's critical path and
works with either stage 1). It probes the running system and compares it with
`/etc/vh/hw.zon`, the probe the system was planned from:

| Finding | When | Not a finding |
|---|---|---|
| another machine | the architecture, the CPU model (vendor, family, model; ARM implementer and part) or the board (the DMI baseboard, else the system, else the device tree's model) differ | another stepping or microcode, a BIOS update |
| a device without a driver | one that had a driver at installation has none now; a new one on a bus hardware is plugged into (PCI, USB, HID, SDIO, MMC, SPI, I2C, serio, virtio, Thunderbolt); a new one elsewhere that a module of the running kernel would drive | a device whose module the kernel refuses (`module_blacklist=`), one that had no driver at installation either, a removed one |
| firmware that failed to load | "Direct firmware load for F failed" or "firmware: failed to load F" in this boot's kernel log; the message says whether F is on disk and whether the plan's firmware trim (`/etc/xbps.d/40-vh-firmware.conf`) left it out | |

On another machine the devices are not compared (they all differ). With a finding,
`/run/vh/check` holds the message that the admin sees at login on tty2
(`/etc/profile.d/zz-vh.sh`), and `/run/vh/plan` a fresh plan of the running system
(`hw.zon`, `plan.zon`, `plan.env`, `plan-report.txt`; `vh-plan` with `/root/vh/hwdb`,
`/root/vh/kernel/pins` and the installation's `vh.conf`). `/run/vh/check.done` always holds
`VH_CHECK machine=same|different devices=N firmware=N lost=N`, which `vh-audit plan` reads;
`lost` counts the devices that had a driver at installation and have none now, the verdict the
boot assessment of a machine kernel reads ([kernel.md](kernel.md#what-a-good-boot-is)). On a
machine kernel (release `*-vh`) the modules its build left out on purpose count as refused:
`kernel/profiles/modules.deny`, the plan's deny list, the modules of the features the plan does
not select. On the stock kernel, when the machine is the same, the check also writes the
running system's probe to `/var/lib/vh/check/stock.zon`; a machine kernel's devices are judged
against that, the stock kernel of the same installation, and its lines say "had the driver X
on the stock kernel (V)". The installation's probe was made by the live image's kernel, another
version, and a driver that moved between versions is no loss of the machine kernel's: the q35's
fixed power button, driven by `button` on the live image's 6.12 and by `tiny_power_button` on
6.18, is one.

What to do: another machine means the plan (packages, firmware, the kernel's classes, the
command line) was made for the other one: compare `/run/vh/plan/plan-report.txt` with
`/etc/vh/plan-report.txt` and reinstall, or keep the stock UKI. A module that would drive a
new device but is not bound was refused by the module lock: run
`doas /root/vh/install/30-lock.sh` with the device present, then reboot. A firmware file the
trim left out: keep it in `/etc/xbps.d/40-vh-firmware.conf` (or `VH_FIRMWARE_KEEP`) and
reinstall its package with `xbps-install -f`. A file the plan keeps that is not on disk is
usually the target of a link: linux-firmware keeps the names drivers ask for as links into
vendor directories (`iwlwifi-*.ucode` into `intel/iwlwifi/` since 2025), some under another
name. The trim keeps every pattern below any directory too, and at installation the targets
of the links it keeps under another name, read from the packages' file lists
(`install/lib.sh`, `vh_firmware_link_keep`); a target a later linux-firmware renames is kept
the same way, by its path in the file. Until then the GF63's Wi-Fi went without its firmware
on linux-firmware 20260810. The heuristics are **[VERIFY on hardware]**:
the probe at installation runs in the live system, whose devices and drivers may differ a
little from the installed system's.

Without a wireless interface the plan keeps no `regulatory.db` (`net.wifi` of
`hwdb/net.zon`), so cfg80211, which asks for the file as soon as it loads, must not load
there. Its one alias is the generic netlink family nl80211, and dhcpcd asks for that family at
every start, for every interface; until `rootfs/etc/modprobe.d/vh-cfg80211.conf` the check
reported `regulatory.db` at every boot of the rig, which has no Wi-Fi. The file blacklists
cfg80211: modprobe then ignores its alias, while a Wi-Fi driver still loads it as a dependency,
so a USB adapter plugged in later works and the next check sees its interface. A machine
kernel has the 802.11 stack only with the feature `wifi`, which the same rule selects. A
`regulatory.db` failure therefore means a wireless interface the plan did not see: compare
the fresh plan.

## Kernel modules at boot

Stage 1 loads every module of the kernel's `modules.devname` at every boot, so that its device
node exists before udev starts: runit-void's `01-static-devnodes.sh` runs `modprobe -bq` for
each, vh-stage1's step `static-devnodes` one `modprobe -abq` ([init](../../init/README.md)).
eudev creates no static nodes, so without the module there is no node, and no process can load
the module by opening one. The stock 6.18 kernel lists 18 modules there. On the rig (no
Bluetooth, no sound, `VH_VIRT=no`) 15 of them loaded, 27 modules with their dependencies: the
Bluetooth stack through `hci_vhci` (a virtual controller for testing), tun, vhost-net,
vhost-vsock and the VFIO container, whose nodes eudev's rules make world-writable (0666), and
more. `install/30-lock.sh` then preloaded all of them before the module lock. Under KVM the
step took 328 ms of a 1211 ms stage 1 (kvm-smoke run 39411670080).

`modprobe -b` skips a module that modprobe.d blacklists, named or found through an alias,
while a driver that needs it still loads it as a dependency (kmod 34.2, `tools/modprobe.c`
and `libkmod/libkmod-module.c`; eudev's module loading checks the blacklist the same way).
Two files use that:

| File | Modules | Who still loads them |
|---|---|---|
| `rootfs/etc/modprobe.d/vh-devnodes.conf` | hci_vhci, bluetooth, userio, uinput, ppp_generic, nvram, snd_seq, snd_timer | btusb and hci_uart (bluetooth), thinkpad_acpi (nvram), every sound driver (snd_timer); the rest only `doas modprobe NAME` |
| `rootfs/etc/modprobe.d/vh-novirt.conf` | tun, vhost_net, vhost_vsock, vfio | `doas modprobe NAME`; with `VH_VIRT=yes` the installer removes the file (`install/chroot.sh`), since qemu needs the nodes at boot |

The blacklist of bluetooth also keeps `socket(AF_BLUETOOTH)` from loading the stack on a
machine without a controller. The ALSA sequencer serves MIDI only: WirePlumber makes its
Midi-Bridge when `/dev/snd/seq` exists, PipeWire's audio does not use it, and a MIDI device
does not load it (the sequencer itself unblocks the loading of its drivers). For MIDI:
`doas modprobe snd_seq` before `30-lock.sh`, so that the lock keeps it. loop, dm_mod, btrfs and
rfkill still load at boot: blacklisted, btrfs would no longer load for `mount -t btrfs` either,
and with btrfs-progs installed runit-void's `btrfs device scan || emergency_shell` fails on a
btrfs disk without `/dev/btrfs-control`; `rfkill(8)` fails without `/dev/rfkill`, and `vh-keys`
(`optional/sb-offline-keys`) and `install/00-probe.sh` run it under `set -e` on machines with no
radio as well (the node is root's only, `99-vh-devices.rules`). The live image carries the
same files ([live-image.md](live-image.md#what-the-image-holds)), so the probe of the
installation lists the modules the machine uses, not these. A system locked before keeps its
old `/etc/vh/modules.preload` until `30-lock.sh` runs again.

## `vh-audit plan`

The audit area `rootfs/usr/local/libexec/vh/vh-audit.d/15-plan.sh` reads the plan of the
installation, `/etc/vh/plan.zon`, through `vh-plan env` (the plan in the form of
`plan.env`; without `vh-plan`, the installer's copy `/root/vh/plan.env`). Every area may ask
it with `plan KEY`, the value of `VH_PLAN_KEY`.

| Check | ok | FAIL | ?? |
|---|---|---|---|
| the protection tier | full | a missing requirement nobody acknowledged; refused | each requirement acknowledged at installation (tiered), with its residual risk from `plan-report.txt` |
| the plan's services (iwd, dhcpcd-eth0, vh-acpid, vh-fstrim, bluetoothd) | enabled and running | not enabled, or not running | |
| the refused modules | all in `module_blacklist=` of the command line, none loaded | missing from it, or loaded | |
| the plan's command line (`intel_iommu=on`, `efi=disable_early_pci_dma`, `ia32_emulation=0` ...) | all present | missing | |
| the firmware on disk | every pattern of the plan kept in `/etc/xbps.d/40-vh-firmware.conf` (each also below any directory, and the targets of its links), every file under `/usr/lib/firmware` kept by one | a pattern missing; a file the plan does not keep | no trim (`VH_FIRMWARE_TRIM=no`) |
| `vh-kconf check` at this boot | the same machine, no finding | another machine; the fresh plan's tier differs from the installation's | devices or firmware found; the check did not run |

The checks that depend on the hardware left the other areas for this one: `intel_iommu=on`
(the boot area checked it on every machine), iwd and vh-acpid (the services area expected them
everywhere); the services area checks `vh-check` instead, and the performance area asks the
plan for the tag `dgpu`. `tests/adapt/audit_test.sh` runs the area on the golden plans of the
GF63 (full) and the Raspberry Pi 5 (reduced, tiered and strict) in a mocked installed system.

## runit's state of the services: `/run/runit`

Every service directory UniVoidDistro ships (`rootfs/etc/sv/*`, `optional/*/sv/*`) has
`supervise -> /run/runit/supervise.NAME`, and its `log/` has `supervise ->
/run/runit/supervise.NAME-log`, as Void's own packages have. runsv makes the link's target in
`/run/runit` (a tmpfs, made by stage 1) when it starts and keeps there what it writes at every
start, stop and restart of a service (`status`, `stat`, `pid`, its control fifos and lock): no
write to the disk, and nothing of it outlives the boot. The installer puts the links in as links
(`install/lib.sh` `install_tree`), in place of a `supervise/` directory already there.

An installation from before 2026-10-21 has `supervise/` directories on the disk for `vh-acpid`,
`vh-check`, `vh-boot-assess`, `vh-fstrim`, `vh-eth-static` and `vh-deadman`. `doas vh-update`
first runs `/usr/local/libexec/vh/vh-sv-runstate`, which gives each of them the link: an enabled
service leaves `/var/service` while runsvdir stops its runsv, and comes back, so it restarts
once and is down for 2 to 10 s (runsvdir looks every 5 s; 2 to 7 s measured). That is harmless
for each of ours: vh-boot-assess counts a boot once by its `boot_id`, vh-check checks again,
vh-fstrim keeps its weekly stamp, vh-eth-static sets the same address, and the watchdog of
vh-deadman (`WATCHDOG=yes`) is asked a timeout of 60 s. A directory a runsv works in otherwise
(one started by hand) is left as it is, with a line on stderr. `vh-audit` (Services) FAILs on a
`supervise/` directory under `/etc/sv`. `tests/install/services_test.sh` checks the links,
`install_tree` and the tool under runit's own runsv and runsvdir; `tests/vm` checks on the
installed system that no state is on the disk and that the tool moves a running vh-acpid's.
