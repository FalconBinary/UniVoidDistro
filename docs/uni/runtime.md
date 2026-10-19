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
