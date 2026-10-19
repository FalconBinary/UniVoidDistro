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

## Built-in input for `vh-acpid`

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
