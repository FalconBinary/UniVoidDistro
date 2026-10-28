# UniVoidDistro: hardware

What hardware the distribution supports, how `vh-kconf probe` detects each piece, what the
plan does with it and what happens when it is missing. The rules themselves are in
[`hwdb/`](../../hwdb/README.md); the machines they are tested on are the fixtures in
`tests/kernel/fixtures/` (the golden plans: `tests/adapt/golden/`).

Facts come from sysfs, procfs and the device tree only; `hw.zon` never holds a serial
number, a MAC address or a UUID. [VERIFY] marks what has not yet been checked on a real
machine of that class.

## Support levels

| Level | What | State |
|---|---|---|
| **full** | x86_64 with UEFI 64-bit, Secure Boot, TPM 2.0, an IOMMU, AES-NI, at least 2 GiB: every protection of void-hardperf-light | installs in `strict` (the default) |
| **reduced** | one or more of these properties missing ([the table](principles.md#the-protective-properties-per-architecture)) | installs only with `VH_SECURITY=tiered` and a typed confirmation of every residual risk |
| **refused** | x86_64 without UEFI 64-bit (legacy BIOS, CSM, 32-bit UEFI), less than 1.5 GiB of memory (3 GiB from Void's own live image, on which the installer builds in RAM) | never |
| **ARM64** | UEFI machines (servers, laptops): the same path as x86_64 (Limine for aa64, the UKI on `linuxaa64.efi.stub`, Secure Boot with our keys, the TPM and the SMMU where present); the Raspberry Pi 4/5 is *reduced* (no UEFI: [rpi.md](rpi.md)) | U5: installs from the aarch64 live image; verified on QEMU's virt machine only ([below](#arm64)) |

## Machine classes

`vh-plan` derives one class; rules use it for power, services and the desktop.

| Class | Detected by | Effect |
|---|---|---|
| laptop | DMI chassis type 8, 9, 10, 14, 30, 31, 32, or a battery, or a lid switch (ACPI `PNP0C0D`) | the power profile follows AC/battery (EPP), `vh-acpid` for the lid and the power button, backlight control |
| desktop | chassis 3-7, 13, 15, 16, 35, 36 without a battery | EPP `balance_performance` or `performance`, no lid logic |
| server | chassis 17, 23, 25, 28, 29 | no desktop stack unless asked for |
| vm | the CPU flag `hypervisor`, DMI (QEMU, KVM, VMware, Hyper-V, VirtualBox, Xen), `/sys/hypervisor/type`, the device tree `linux,dummy-virt` | no microcode, no power management, virtio drivers |
| sbc | a device tree without ACPI (Raspberry Pi and others) | the board rules of `hwdb/platform.zon` |

## CPU

| What | Detected by | Effect |
|---|---|---|
| Intel | `vendor_id GenuineIntel` | `intel-ucode` (early microcode in the initrd), `intel_iommu=on`, kernel class `cpu-intel` (intel_pstate, intel_idle, RAPL, coretemp, the iTCO watchdog), the ME interface (`mei*`) denied |
| AMD | `vendor_id AuthenticAMD` | microcode from `linux-firmware-amd`, kernel class `cpu-amd` (amd-pstate in EPP mode, k10temp, AMD IOMMU, the sp5100_tco watchdog) |
| hybrid Intel (P and E cores) | `/sys/devices/cpu_core/cpus` and `cpu_atom/cpus` | the scheduler places by core type (U4); `SCHED_CLUSTER` |
| AMD with several CCDs, X3D | per-CPU L3 domains of different sizes | the scheduler is LLC-aware; the V-Cache CCD for latency-sensitive work (U4) [VERIFY] |
| x86-64 level | v2: `cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3`; v3: + `avx avx2 bmi1 bmi2 f16c fma abm movbe xsave`; v4: + `avx512f avx512bw avx512cd avx512dq avx512vl` | `-march` of the kernel built in CI when the model has no entry in the table |
| AES | the `aes` flag (ARM: `aes` in `Features`) | LUKS2 AES-XTS; without it Adiantum (`tiered` only) |
| CET | `user_shstk`, `ibt` | the kernel enables shadow stacks and IBT where the CPU has them (built into every kernel) |
| SMT vulnerabilities | `/sys/devices/system/cpu/vulnerabilities/*` | `mitigations=auto` as upstream; `nosmt` only as an explicit option with its cost |
| ARM cores | `CPU implementer`, `CPU part` (Cortex-A72 in the Pi 4, A76 in the Pi 5, Neoverse in servers) | `-mcpu` of the kernel built in CI (`arm.mcpu.*`; `-march=armv8-a` in a virtual machine), the ARM64 class (`cpu-arm64`: the generic timer, PSCI, CPPC and SCMI frequency control), the Crypto Extensions class with `aes` |

## Graphics

The primary GPU is the one with `boot_vga = 1` (on ARM: the one that drives the console).
A second GPU without a connected display is a dGPU: it is powered down through runtime PM
unless the gaming session needs it.

| GPU | Detected by (PCI class 0x03) | Effect |
|---|---|---|
| Intel Gen9-Gen12 (Skylake to Raptor Lake) | vendor 8086, the i915 alias | class `gpu-i915`, firmware of that platform only (DMC/GuC/HuC), `intel-media-driver`, `mesa-vulkan-intel` |
| Intel Xe2 and newer (Lunar Lake, Battlemage) | vendor 8086, the xe alias | class `gpu-xe` [VERIFY] |
| AMD GCN 1.2 and newer | vendor 1002, the amdgpu alias | class `gpu-amdgpu`, the firmware of that ASIC, `mesa-vaapi`, `mesa-vulkan-radeon` |
| NVIDIA Turing and newer | vendor 10de, device id of TU1xx or later | as a dGPU: powered down; with the gaming session: the open NVIDIA modules (upstream track G); for the desktop: nouveau with GSP firmware |
| NVIDIA before Turing | vendor 10de | nouveau without reclocking: slow, named in the report; the open modules do not support it |
| virtual: virtio-gpu, bochs, QXL, VMware, Hyper-V | vendor 1af4, 1234, 1b36, 15ad, 1414 | the matching DRM driver; RefursWM with the pixman renderer where there is no GL |
| no GPU (server, serial console) | no PCI class 0x03 | no desktop stack |
| Raspberry Pi VideoCore VI/VII | device tree `brcm,bcm2711-v3d` / `brcm,2712-v3d` | class `gpu-vc4`: v3d + vc4 built in [VERIFY on a board] |

The gaming session ([game.md](game.md)) gets the Vulkan driver of the machine's GPU in its own
root, never in the system: ANV for Intel, RADV for AMD, NVK where nouveau drives an NVIDIA GPU,
lavapipe (the CPU) where no GPU has one (a virtual machine without 3D). The rule is the GPU's own,
its effect `game_packages` (`hwdb/gpu.zon`).

## Network

| Hardware | Driver | Effect |
|---|---|---|
| Intel Wi-Fi (AX200/201/210/211, BE200) | iwlwifi | firmware of that device family only; power saving off on the command line (lower latency, as upstream) |
| MediaTek Wi-Fi (MT7921, MT7922, MT7925) | mt7921e, mt7925e | firmware of that chip |
| Qualcomm Wi-Fi (QCA6174, WCN6855, WCN7850) | ath10k, ath11k, ath12k | firmware of that chip [VERIFY] |
| Realtek Wi-Fi (RTL8822CE, RTL8852 family) | rtw88, rtw89 | firmware of that chip |
| Broadcom Wi-Fi | brcmfmac: supported; the proprietary `wl`: **not supported** (a DKMS module cannot load under lockdown) | the report names the card and suggests a supported one or a USB adapter |
| Realtek Ethernet (RTL8111/8168, RTL8125) | r8169 | `rtl_nic` firmware of that chip; EEE off (a runtime udev rule, no-op elsewhere) |
| Intel Ethernet (I219, I225, I226) | e1000e, igc | no firmware |
| virtio-net, e1000e in a VM | virtio_net, e1000e | — |
| Wi-Fi of any vendor | `/sys/class/net/*/wireless` | `iwd`, `wireless-regdb` (`regulatory.db` into the initrd of a machine kernel), the feature `wifi` (cfg80211 and mac80211 built into a machine kernel); without a wireless interface cfg80211 loads only as a Wi-Fi driver's dependency ([runtime](runtime.md#vh-kconf-check)) |
| wired interfaces | `/sys/class/net/*` with a device and no wireless | `dhcpcd` on each of them (`VH_ETH=auto`), or the static address of `vh.conf` |
| Bluetooth | a `btusb` (or UART) controller | `bluez` only when present and `VH_BLUETOOTH` is not `off`; the vendor helper module (btintel, btrtl, btmtk, btbcm) by the controller's id |

## Audio

| Hardware | Driver | Effect |
|---|---|---|
| HD Audio codecs | snd_hda_intel | no firmware |
| Intel SOF (most laptops from Ice Lake on, digital microphones) | snd_sof_pci_intel_* | `sof-firmware`, `alsa-ucm-conf` |
| AMD ACP (Ryzen laptops) | snd_acp*, snd_sof_amd_* | `sof-firmware` where the SOF path is used [VERIFY] |
| USB audio | snd_usb_audio | built into every machine kernel (feature `usb-common`) |

Sound runs through PipeWire everywhere, as upstream. The gaming session has a PipeWire of its own
in its root, on the cards' playback and control nodes alone ([game.md](game.md#g2-sound)).

## Storage and the root disk

| Controller | Detected by | Effect |
|---|---|---|
| NVMe | the nvme driver | class `storage-nvme`; I/O scheduler `none` (a runtime udev rule, [runtime](runtime.md#the-io-scheduler)) |
| SATA (AHCI) | ahci | class `storage-ahci`; SSD: `mq-deadline`, HDD: `bfq` (the same rule) [VERIFY by measurement] |
| Intel VMD ("RAID"/RST mode) | the vmd driver on a PCI device of class 0x0104 | class `storage-vmd`, `vmd` in the initrd; the report suggests AHCI mode in the firmware setup |
| eMMC, SD | sdhci, mmc_block | class `storage-mmc`; I/O scheduler `bfq` (the same rule) [VERIFY by measurement] |
| virtio-blk, virtio-scsi | virtio_blk, virtio_scsi | class `storage-virtio`; I/O scheduler `none` (the same rule) |
| USB disks | usb-storage, uas | built in (feature `usb-common`) |

The installer formats the chosen disk as GPT (ESP + LUKS2 + XFS with 4096-byte sectors)
whatever the controller. TRIM is enabled when the disk reports discard support and
`VH_TRIM` allows it; `vh-fstrim` runs only then.

## Input, and the LUKS passphrase

The passphrase is typed in the initrd, so every driver on the way from the keyboard to its
bus must be there. The probe records each keyboard and the chain of drivers above it; the
plan puts that chain into dracut's `add_drivers`:

| Keyboard | Chain |
|---|---|
| PS/2 (most laptops) | i8042, atkbd |
| USB (desktops, some laptops' internal keyboards) | xhci_pci (or ehci/ohci on old machines), usbhid, hid_generic |
| I2C-HID (some laptops) | the platform's I2C and GPIO drivers (intel_lpss_pci, the pinctrl driver of the chipset, i2c_designware), i2c_hid_acpi |

The probe also records where each keyboard sits and, on USB, whether the kernel calls its
USB device built in (`fixed`): a built-in keyboard on USB or SPI becomes the physical input of
`vh-acpid`'s idle watchdog and a keyboard of `optional/deadman`'s alarm combination
([runtime](runtime.md#built-in-input-vh-acpid-and-vh-deadman)).

## Motherboards and chipsets

| What | Detected by | Effect |
|---|---|---|
| chipset (Intel PCH, AMD FCH) | PCI ids of the SMBus, LPC and thermal functions | SMBus (i2c_i801 / i2c_piix4), the pin controller of that chipset generation (the i2c-hid touchpad hangs off it) |
| watchdog for `optional/deadman` | Intel: iTCO (via LPC/SMBus); AMD: sp5100_tco (via SMBus); ARM servers: sbsa_gwdt; Raspberry Pi: bcm2835_wdt | the plan's `watchdog`, which `optional/deadman` loads with `nowayout`; softdog is the weaker fallback ([the cost table](runtime.md#the-watchdog-of-optionaldeadman)) |
| Super I/O sensors (Nuvoton, ITE) | not visible to a probe (ISA ports); DMI board vendor and name | the hwmon driver of `hwdb/board.zon` where the board is known [VERIFY] |
| WMI and EC platform drivers (ASUS, MSI, Lenovo, Dell, HP, Gigabyte) | the WMI GUID and DMI aliases | the vendor's driver (fan and power modes) |
| TPM | `/sys/class/tpm/tpm0`: firmware TPM through CRB, discrete through TIS/SPI | class `tpm-crb` or `tpm-tis`; a firmware TPM gets a note naming the firmware it trusts (Intel PTT in the ME, the AMD fTPM in the PSP) |
| IOMMU | the ACPI tables DMAR (Intel) and IVRS (AMD); IORT on ARM | `intel_iommu=on`, `iommu.strict=1`, `iommu.passthrough=0` everywhere; on ARM the class `iommu-smmu` (the SMMU v2 and v3 drivers built in) |
| Thunderbolt / USB4 | the thunderbolt alias | the driver stays denied (DMA); USB and DisplayPort over these ports work without it |
| Option ROMs (a discrete GPU, a network card) | the TPM event log (`EV_EFI_BOOT_SERVICES_DRIVER`) | Secure Boot key enrolment keeps their hashes (`sbctl enroll-keys --tpm-eventlog`, `install/20-firstboot.sh`) so the display and the disks still initialise |
| Secure Boot setup menus | DMI vendor | `hwdb/board.zon` names the menu items ("Key Management", "Secure Boot Mode: Custom", "Reset to Setup Mode") in the report |

## Virtual machines

| Hypervisor | Effect |
|---|---|
| QEMU/KVM (q35, OVMF with Secure Boot, swtpm, `intel-iommu` or `virtio-iommu`) | **full** level possible; the test rig `tests/vm/` is such a machine |
| QEMU's `virt` machine on aarch64 (AAVMF, swtpm on the MMIO TIS interface, `iommu=smmuv3`, under KVM or Apple's hvf) | the aarch64 rig, `VH_ARCH=aarch64 tests/vm/vhvm.py` ([below](#arm64)). **full** level possible with a Secure Boot build of AAVMF (Debian's and Ubuntu's `qemu-efi-aarch64`) [VERIFY under KVM: under hvf that build stops after its banner]; with QEMU's own `edk2-aarch64-code.fd`, which has no Secure Boot, **reduced**: `tiered` with one risk acknowledged, which is what ran on the Mac |
| QEMU without a vTPM or an IOMMU, VirtualBox, VMware, Hyper-V | **reduced**: `tiered` only; the host can read the guest's memory anyway (a residual risk named in the report) |

## Known not supported

| What | Why | What to do |
|---|---|---|
| legacy BIOS and CSM | no Secure Boot chain; out of scope | enable UEFI, disable CSM |
| 32-bit UEFI on a 64-bit CPU (some Atom tablets) | no 64-bit EFI stub path | — |
| Broadcom `wl` Wi-Fi | proprietary module, cannot load under lockdown | a supported card or a USB adapter |
| NVIDIA before Turing with the proprietary driver | the open modules need Turing+; the closed ones cannot be signed into this chain | nouveau (slow) or a newer card |
| Apple T2 Macs, Microsoft Surface | need out-of-tree kernel patches | — |

## ARM64

What U5 built, and how far it is verified ([ROADMAP](ROADMAP.md#u5-arm64-installation) has the
state with its numbers):

- **The machine kernel**: Void's aarch64 `linux6.18` pinned beside the x86_64 one
  (`kernel/pins/aarch64-*`), the universal profiles split into what every architecture has and
  `kernel/profiles/arch/{x86_64,aarch64}` (the RTC driver, the 32-bit ABI off, the compressed
  image, pointer authentication and BTI), the ARM64 classes (`cpu-arm64`, `cpu-arm64-aes`,
  `iommu-smmu`, `gpu-vc4`, `platform-rpi`), `-mcpu` of the core; `tests/kernel/matrix.sh` and
  `tests/kernel/run.sh` cover `aarch64-virt` and `rpi5`, and `kernel-custom` cross-builds them
  (`ARCH=arm64`, the uncompressed `Image`). Not done: `vh-kconf install` of such an image (it
  reads a bzImage's setup header for the release; the arm64 `Image` has none) and the boot
  assessment of a machine UKI on ARM64 [VERIFY: the stock UKI path is what the rig boots].
- **The live image**: `univoiddistro-live-aarch64-COMMIT.iso`, built natively on GitHub's
  arm64 runner ([live-image.md](live-image.md#aarch64)).
- **The boot path**: the same scripts, the architecture read where it enters: the EFI stub
  `linuxaa64.efi.stub` in dracut's configuration (`@VH_EFI_ARCH@`), Limine's `BOOTAA64.EFI`
  from Void's `limine` package and on the ESP (`vh-limine-update`, by the build's
  architecture), the NVRAM entry, `XBPS_ARCH`, the serial console `ttyAMA0` of the rig. Void
  ships `systemd-boot-efistub` with `linuxaa64.efi.stub` (256.6_2), `limine` with
  `BOOTAA64.EFI` (12.9.4_1), `sbctl` (0.18_2) and `dracut-uefi` (112_1) for aarch64: no
  substitute was needed. The x86_64 path is byte for byte what it was (`tests/install/run.sh`,
  the GF63 golden files, `limine_diff.sh`).
- **The rig**: `VH_ARCH=aarch64` turns `tests/vm/vhvm.py` into QEMU's `virt` machine
  (GICv3, `iommu=smmuv3`, AAVMF, swtpm on `tpm-tis-device`, NVMe, virtio network and display, a
  USB keyboard, the CDs on virtio-scsi, the live kernel as `/boot/vmlinux`), under KVM where a
  host has it, under Apple's hvf on a Mac. GitHub's arm64 runner (`ubuntu-24.04-arm`): see
  the ROADMAP's U5 state for whether it exposes `/dev/kvm`; `kvm-smoke` takes `arch=aarch64`
  and stops before the installation without it unless `accel=tcg`.
- **Not done**: the seccomp filters of the browser and viewer sandboxes (`zig/lib/seccomp.zig`,
  `vh-seccomp`) are written with x86_64's system call numbers and architecture check: on an
  ARM64 system the sandbox would kill its program at the first call. Firefox and `vh-open` do
  not run there until the filters are built per architecture (the gaming session is x86_64's by
  design). The base system, the installer, the desktop compositor and bar are not affected.
- **Not verified on any real ARM64 machine**: the installation, Secure Boot key enrolment on a
  vendor's firmware, the TPM event log, the SMMU with `iommu.strict=1` on real devices, the
  Raspberry Pi altogether ([rpi.md](rpi.md)).

## Adding a machine

1. On the machine (a live USB is enough): `vh-kconf probe --save DIR -o hw.zon`. Nothing
   private is saved: no serial numbers, MAC addresses or UUIDs.
2. Commit `DIR` as `tests/kernel/fixtures/NAME` and run `vh-plan plan` on it.
3. Every device the report lists as "no rule" gets a rule in `hwdb/` with its reason; the
   golden plan goes to `tests/adapt/golden/NAME`.
