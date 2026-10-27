# The Raspberry Pi (U5): a runbook, not a path the installer takes

Milestone U5 ([ROADMAP](ROADMAP.md)) brings the ARM64 installation to machines with UEFI:
Limine, the UKI on the aarch64 EFI stub, Secure Boot with the system's own keys, as on
x86_64 ([hardware.md](hardware.md#arm64)). A Raspberry Pi 4 or 5 is an ARM64 machine without
any of that: its boot ROM loads the firmware from the EEPROM (the Pi 4 and 5) or the SD card,
the firmware (`start*.elf` on the Pi 4, the `boot.img` of the Pi 5) reads `config.txt`, loads
the kernel and the device tree and starts the kernel. No UEFI, no Secure Boot variables, no
TPM, no SMMU. Everything below is **[VERIFY]**: no board is at hand, and nothing of it has run.
`kernel/hw/rpi5.zon` is a synthesised fixture ([tests/kernel/README.md](../../tests/kernel/README.md)).

## What the plan says of a Pi

`vh-plan` on `rpi5.zon` ([tests/adapt/golden/rpi5](../../tests/adapt/golden/rpi5)):

- the class `sbc` (a device tree, no ACPI), `-mcpu=cortex-a76`, the Crypto Extensions (AES-XTS
  on the disk, `class/cpu-arm64-aes`), VideoCore (`class/gpu-vc4`), the SD card through SDHCI
  (`class/storage-mmc`), the Pi's firmware drivers (`class/platform-rpi`, rule `board.rpi`), the
  `bcm2835_wdt` watchdog for `optional/deadman`, brcmfmac's firmware and NVRAM, Bluetooth on the
  UART;
- **`strict` refuses it**: the requirement `uefi` (`hwdb/security.zon`, ARM64 only) is not met,
  and with it `secure-boot`, `tpm2` and `iommu`. The report names each with its residual risk
  and the fix; the rule `board.rpi` adds the note that the installer never writes the OTP key.
  `VH_SECURITY=tiered` installs it after the typed confirmation of the four risks, as for any
  reduced machine ([principles.md](principles.md#the-protective-properties-per-architecture)).

The gate decides from the probe, not from the board's name: a Pi behind a UEFI firmware port
(the EDK2 ports for the Pi 4 and the Pi 5 exist [VERIFY which boots Void's kernel]) would show
`efi` and be judged on what that firmware offers (Secure Boot variables, no TPM, no SMMU:
reduced in any case).

## What the installer does not do on a Pi

The installer (`install/10-install.sh`) requires UEFI (`/sys/firmware/efi/efivars`): it stops
before the gate on a Pi booted by its own firmware. The boot path it writes, Limine on the ESP
and a UKI in `EFI/void`, has no reader there. An installation on a Pi needs, beyond this
runbook's scope:

1. the firmware partition (FAT, the first partition) with Void's `rpi-firmware` and its
   `config.txt` and `cmdline.txt`, the kernel as `kernel8.img` (or the `boot.img` ramdisk of
   the Pi 5's firmware) and the device tree blobs;
2. the kernel: Void's `rpi-kernel` and `rpi5-kernel` are the Raspberry Pi Foundation's
   downstream 6.12; mainline `linux6.18` (the series this system runs, the pins) drives the Pi 5's
   RP1 southbridge only in part on 6.18 [VERIFY: Ethernet, USB and the SD card behind RP1];
3. the initramfs with the LUKS prompt on the HDMI console or the UART, loaded by the firmware
   through `initramfs` in `config.txt` (dracut's plain initramfs, no UKI);
4. nothing verifies 1 to 3 at boot: the stock Void image for the Pi does not either.

## The Pi's own secure boot: why it is a decision, never a step

The Pi 4 (from EEPROM 2020-09) and the Pi 5 can verify `boot.img`, the signed boot ramdisk,
with an RSA-2048 public key whose hash is burnt into the board's one-time programmable (OTP)
memory, and lock the board to signed images (`rpi-eeprom-config`: `SIGNED_BOOT=1`, the key
programmed by `rpi-eeprom-config --apply` with the customer key; the tools `rpi-eeprom-digest`
and `rpi-sign-bootcode` of `rpi-eeprom`). Once the key hash is in OTP:

- it cannot be changed or removed: a lost private key is a board that boots nothing else, a
  stolen one a board that trusts the thief, for the board's whole life;
- `boot.img` holds the firmware's ramdisk, the kernel and the initramfs: every kernel update
  rebuilds and re-signs it on a machine that holds the private key;
- what it verifies ends at the initramfs; the LUKS passphrase and the root file system's
  integrity are the same as on any machine (`lockdown`, the module lock), and there is no TPM
  to measure any of it.

That is why the plan refuses `strict` on a Pi with the reason and the installer takes no step
towards the OTP: enabling it is the owner's decision, made outside this system with the
Foundation's documentation ("Raspberry Pi 4 and 5 secure boot", `rpi-eeprom` README), on a
board the owner is prepared to lock. If it is enabled, the Pi still has no UEFI and no TPM:
the plan stays `reduced` (`secure-boot`, `tpm2`, `iommu` not met), `tiered` with three risks
instead of four, and the `uefi` requirement would need a probe fact for "the firmware verifies
what it boots" that no sysfs file provides today [VERIFY: the EEPROM config is readable through
`vcgencmd bootloader_config` on the running board].

## What would make it a path

In the order the roadmap would take, each with its test and its document: a real probe of a
Pi 5 under mainline 6.18 as the fixture (replacing `machines/rpi5.py`); the kernel-custom
build of `rpi5.zon` (now possible: `ARCH=arm64`) booted by the firmware with Void's
`rpi-firmware`; the installer's firmware-partition path behind a `VH_BOOT=rpi` decision of
the plan; the plain initramfs with the LUKS prompt; `vh-kconf check` on the board. None of it
is started.
