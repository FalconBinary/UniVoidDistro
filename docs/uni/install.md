# UniVoidDistro: installation

From UniVoidDistro's live image to a running system on any x86_64 machine with a 64-bit UEFI.
The installer decides for each machine from its own probe and the rules of `hwdb/`, so the steps
are the same everywhere: where a machine differs, its plan says so before anything is written.
[The GF63](#example-the-gf63) at the end is a worked example. ARM64 machines are milestone U5
([ROADMAP](ROADMAP.md)).

## 0. What the machine needs

| | |
|---|---|
| firmware | a 64-bit UEFI. Legacy BIOS, CSM and 32-bit UEFI are refused in every mode |
| memory | at least 1.5 GiB in either mode, the gate's floor; 2 GiB for every protection in `strict` (Argon2id with 1 GiB per guess). From Void's own live image instead of ours, 3 GiB: the installer then builds its programs in RAM |
| disk | a whole disk of at least 20 GiB, wiped by the installation |
| network | Ethernet or Wi-Fi while installing: the packages come from Void's mirror |
| protection | in `strict`, the default: Secure Boot support, TPM 2.0, an IOMMU, AES in the CPU. A machine without one of them is *reduced* and installs only with `VH_SECURITY=tiered`, every missing property confirmed by typing ([principles.md](principles.md)) |
| besides | another computer to download and verify the image, a USB stick of at least 2 GB |

## 1. Download and verify the image

Take the project's address, `FalconBinary/UniVoidDistro`, from a source you trust, not from a
link someone sent. Its images are the assets of its releases,
<https://github.com/FalconBinary/UniVoidDistro/releases>: `univoiddistro-live-x86_64-COMMIT.iso`,
`SHA256SUMS`, `BUILD` (the commit, the CI run, the kernel series) and `live-packages.txt`.
Download the ISO and `SHA256SUMS` of the newest release; TAG below is its tag, for example
`v0.1.0`. None of this needs a GitHub account.

**Is the download whole?** `SHA256SUMS` holds the ISO's sha256, SHA256 below. It shows that the
file arrived whole, not who made it: it comes from the same page as the ISO.

```sh
sha256sum -c SHA256SUMS            # Linux
shasum -a 256 -c SHA256SUMS        # macOS
```

On Windows, `certutil -hashfile ISO SHA256` prints the sum to compare with `SHA256SUMS`.

**Did this project build it?** The ISO carries a build provenance attestation: a Sigstore
signature that GitHub gives this repository's `live-image` workflow, on GitHub's own runners,
for the file it built from the tag ([live-image.md](live-image.md#trust)). It is public:
download it by the ISO's sha256 and check it with the GitHub CLI (a current version: these
commands were checked with 2.102), `curl` and `jq`:

```sh
curl -fsSL https://api.github.com/repos/FalconBinary/UniVoidDistro/attestations/sha256:SHA256 \
  | jq -c '.attestations[].bundle' > bundle.jsonl
gh attestation verify univoiddistro-live-x86_64-COMMIT.iso --bundle bundle.jsonl \
  --repo FalconBinary/UniVoidDistro \
  --signer-workflow FalconBinary/UniVoidDistro/.github/workflows/live-image.yml \
  --source-ref refs/tags/TAG --deny-self-hosted-runners
```

It ends with exit status 0, and in a terminal with "Verification succeeded!". Another file,
another repository, workflow or tag, or a runner outside GitHub makes it fail. To pin the exact
commit as well, add `--source-digest` with the `COMMIT` of `BUILD`. On Windows the same two
commands run in `cmd.exe`, with `curl.exe` and jq (`winget install jqlang.jq`), not in
PowerShell, whose `>` writes UTF-16 [VERIFY].

What the attestation does not prove: that the code is right (it is public at that commit), or
more about Void's packages in the image than Void's own signatures, which xbps checked when the
image was built. A project signing key comes later.

## 2. Write the USB stick

Everything on the stick is lost. Write the ISO to the whole stick, never to a partition:

- Linux: `lsblk` to find it, then `dd if=ISO of=/dev/sdX bs=4M status=progress oflag=sync`;
- macOS: `diskutil list`, `diskutil unmountDisk /dev/diskN`, then
  `sudo dd if=ISO of=/dev/rdiskN bs=4m`;
- Windows: Rufus in DD image mode.

## 3. Firmware settings before the installation

The names differ between makers. For some boards the plan's report shows where the Secure Boot
keys are cleared (`hwdb/board.zon`), and every requirement the machine misses comes with the
setting that fixes it (`hwdb/security.zon`).

| Setting | Value | Why |
|---|---|---|
| boot mode, CSM | UEFI, CSM off | the system boots only through UEFI: Limine and the signed UKI |
| Secure Boot | off while installing | the live image is not signed; the installed system enrols its own keys (step 7) |
| TPM | on: Intel PTT, AMD fTPM or a discrete TPM 2.0 | tpm2-totp, measured boot, the Option ROM check before the keys are enrolled |
| IOMMU | on: Intel VT-d, AMD-Vi (often "IOMMU" or "Kernel DMA Protection") | every device's DMA confined to the memory the kernel gives it |
| Fast Boot | off | the firmware brings USB keyboards up for the passphrase, and the PCRs stay stable |
| virtualization (VT-x, SVM) | off unless `VH_VIRT=yes` | with `VH_VIRT=no` KVM is refused anyway |
| unused devices: camera, card reader, Thunderbolt, network boot, Wake on LAN | off | fewer drivers and fewer devices with DMA |

Update the firmware first if its maker has fixes: holes such as LogoFAIL and PKfail go around
Secure Boot.

## 4. Boot the image and get a network

1. In the firmware's boot menu choose the stick **in UEFI mode**; in GRUB, the first entry,
   "UniVoidDistro COMMIT".
2. Log in as `root`, password `voidlinux`.
3. Ethernet comes up by itself (dhcpcd): `ip a` shows an address. Wi-Fi: the image's
   wpa_supplicant service serves every wireless interface from one file, so add the network
   there (the passphrase stays in the live system's RAM):

   ```sh
   wpa_passphrase 'NETWORK' 'passphrase' >> /etc/wpa_supplicant/wpa_supplicant.conf
   sv restart wpa_supplicant
   ```

4. `ping -c3 repo-default.voidlinux.org`.

The repository at the image's commit is in `/root/vh`, and the programs the installer would
otherwise compile are in `/usr/local/lib/vh/prebuilt`, checked against the image's `SHA256SUMS`
before they are used: nothing to clone and nothing to build.

## 5. The configuration, and the plan before anything is written

```sh
cd /root/vh
cp vh.conf.example vh.conf
vi vh.conf
bash install/plan.sh
less /tmp/vh/plan-report.txt
```

`vh.conf` overrides the defaults of `vh.conf.example`, whose comments explain every setting.
What to look at:

| Setting | |
|---|---|
| `VH_DISK` | the one you must set: the whole disk to wipe, from `lsblk -d -o NAME,SIZE,MODEL` (`/dev/nvme0n1`, `/dev/sda`), never the stick |
| `VH_SECURITY` | `strict` (the default) or `tiered` |
| `VH_HOSTNAME`, `VH_TIMEZONE`, `VH_LOCALE`, `VH_KEYMAP` | the system's |
| `VH_REGDOM` | the Wi-Fi regulatory domain: your country's two letters |
| `VH_ADMIN`, `VH_USER` | the administrator (tty2, `doas`) and the everyday user (tty1, the desktop) |
| `VH_MIRROR` | a Void mirror with HTTPS near you |
| `VH_ETH` | `auto`, `dhcp`, `static` (with `VH_ETH_ADDR`, `VH_ETH_GW`) or `off` |
| `VH_BLUETOOTH` | `off`, `optional` (the bar's menu starts it) or `on` |
| `VH_GPU`, `VH_CAMERA`, `VH_CARDREADER`, `VH_VIRT`, `VH_IPV6` | `VH_GPU=auto` lets the plan choose; the rest are switched off by default |
| `VH_LUKS_ITER_MS`, `VH_LUKS_MEM_KIB` | Argon2id for the disk: leave them, lowering them is a forbidden "speedup" |

`install/plan.sh` probes the machine and plans it; it writes nothing to any disk. Its report
names the machine and its class, the protection tier (`full`, `reduced`, `refused`) in the
chosen mode, every requirement the machine misses with its residual risk and the firmware
setting that fixes it, then the packages, the firmware kept, the kernel classes, the command line,
the services, and every rule of `hwdb/` that applied, each with its reason. In `strict` it exits
with status 3 when a requirement is missing: fix it in the firmware (step 3) and plan again, or
choose `tiered`.

## 6. Install

```sh
bash install/10-install.sh
```

It plans the machine again and asks, in this order: in `tiered` mode, `accept ...` for the
missing requirements; the disk's name, to confirm the wipe; the LUKS passphrase (seven diceware
words, [docs/ru/01-disk.md](../ru/01-disk.md)) twice, and once more to open the volume; the
administrator's and the user's passwords. At every heading it prints the RAM. From our image it
takes a few minutes and the download of the packages (2.5 minutes on the VM rig). It ends with
the next steps:

1. back up the LUKS header to other media (`cryptsetup luksHeaderBackup ...`, as printed);
2. `umount -R /mnt && cryptsetup close cryptroot && reboot`, and take the stick out.

If it stops with an error, fix what it names and run it again: it starts from the wipe.

## 7. The first boot and stage 2: your own Secure Boot keys

The boot is Limine, the signed UKI, the LUKS passphrase, then tty1 (the user: straight into
RefursWM with the RefursLine bar) or tty2 (the administrator).

1. As the administrator on tty2: `doas /root/vh/install/20-firstboot.sh`. It checks the base
   layer and says what comes next.
2. In the firmware: a supervisor (administrator) password, without which anyone can switch
   Secure Boot off; then put Secure Boot in Setup Mode ("Delete all keys", "Clear keys", "Reset
   to Setup Mode").
3. Boot and run `20-firstboot.sh` again: it sees Setup Mode, counts the Option ROMs in the TPM's
   event log and enrols your keys (`sbctl enroll-keys`, with `--tpm-eventlog` when there are
   Option ROMs to keep).
4. In the firmware: Secure Boot on; booting from USB and the network, the boot menu and the UEFI
   shell off; Limine first in the boot order.
5. Boot and run `20-firstboot.sh` a third time: Secure Boot enabled, every file signed.

Details: [docs/ru/03-boot.md](../ru/03-boot.md).

## 8. Stage 3: the module lock

Use every device you will need in this boot first: Wi-Fi, Ethernet, a USB stick, headphones,
Bluetooth unless it is off, a FIDO2 key, an external monitor. Then
`doas /root/vh/install/30-lock.sh`: the modules loaded now are preloaded at every boot, and
loading any other one is blocked until the next boot (`kernel.modules_disabled=1`). Details:
[docs/ru/05-system.md](../ru/05-system.md), "Kernel modules".

## 9. Check

As the administrator:

```sh
doas vh-audit                     # every area; a FAIL line says what to fix
cat /run/vh/check.done            # VH_CHECK machine=same devices=0 firmware=0 lost=0
sv status /var/service/*          # every service: run
less /etc/vh/plan-report.txt      # the plan the system was installed with
```

`vh-kconf check` runs at every boot and compares the machine with the probe it was planned from:
what `lost`, `devices` and `firmware` mean, and what to do about each, is in
[runtime.md](runtime.md#vh-kconf-check).

## 10. Optional: the machine kernel

A kernel for this machine alone: its drivers built in, no loadable modules, the CPU's `-march`
([kernel.md](kernel.md)). The steps are the same on every machine and are written out for the
GF63 in [runbook-gf63.md](../runbook-gf63.md), section 1:

1. copy `/etc/vh/hw.zon` into the repository as `kernel/hw/NAME.zon` and commit it;
2. run the `kernel-custom` workflow with `hw=kernel/hw/NAME.zon` (30 to 60 minutes);
3. download its files, `doas vh-kconf install --dry-run DIR`, read the report, then
   `doas vh-kconf install DIR`;
4. three good trial boots make it Limine's default; the stock kernel always stays in the menu,
   and `doas vh-limine-update --demote` gives it back.

## Example: the GF63

MSI GF63 Thin 10SCXR (MS-16R5): i5-10500H, UHD 630 and a GTX 1650 Max-Q, AX201 Wi-Fi and
Bluetooth, an RTL8111 Ethernet port, a firmware TPM (Intel PTT). Its fixture `kernel/hw/gf63.zon`
is synthesised: the probe of a real installation replaces it (step 10).

The firmware is AMI Aptio in MSI's dress; the menu names change between versions [VERIFY on
yours]:

| What | Where |
|---|---|
| the setup, the boot menu | `Del`, `F11` at power-on |
| the hidden Advanced tab (VT-x, VT-d, PTT) | in the setup: right Ctrl + right Shift + left Alt, then `F2` (on some versions left Ctrl + Alt, right Shift + `F2`) |
| VT-d | Advanced, System Agent (SA) Configuration, VT-d |
| TPM | Advanced, PCH-FW Configuration (or Trusted Computing): TPM Device PTT, Security Device Support Enabled |
| VT-x | Advanced, CPU Configuration, Intel Virtualization Technology: off with `VH_VIRT=no` |
| Fast Boot, UEFI | Boot: Fast Boot Disabled, boot mode UEFI |
| supervisor password | Security, Administrator Password |
| Setup Mode for stage 2 | Secure Boot Mode Custom, Key Management, Delete All Secure Boot Variables: under Security, Secure Boot, or under Settings, Advanced, Windows OS Configuration, Secure Boot (the plan's `board.msi.secure-boot`) |
| the camera | `Fn+F6` switches it off in the embedded controller; `VH_CAMERA=no` also deauthorises it |

What its plan says in `strict` ([the golden plan](../../tests/adapt/golden/gf63/strict/plan-report.txt)):
tier `full`; the kernel's `-march=skylake`; the GTX 1650 without a driver and powered down
(`VH_GPU=auto`, `gpu.nvidia.dgpu-off`), the screen on i915 (whether its HDMI port is wired to
i915 too is [VERIFY]); the firmware it keeps: i915's
DMC, GuC and HuC for Comet Lake, iwlwifi for the AX201, intel/ibt for its Bluetooth, rtl_nic,
`regulatory.db` and the microcode. The firmware's own setup and boot menus, the AX201's name in
the live system (`ip link`) and the machine kernel's first boots are what the real laptop still
has to confirm ([ROADMAP](ROADMAP.md#state-2026-10-20)).
