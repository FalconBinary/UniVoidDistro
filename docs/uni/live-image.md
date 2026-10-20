# UniVoidDistro: our own live image (U6)

The installation starts from a live image. Until now that is Void's official one (20250202),
and the rig showed what it costs ([ROADMAP](ROADMAP.md#state-2026-10-20)):

- **another kernel**: the image runs 6.12, the installed system 6.18. The probe of the
  installation is made by 6.12, and a driver that moved between the two looks lost to
  `vh-kconf check` (the fixed ACPI power button did; the check now judges a machine kernel against
  the stock kernel to get round it). New hardware that 6.12 does not know cannot be probed at all.
- **an old xbps**: it refuses every package until it has updated itself (`install/fetch-zig.sh`
  now updates it first).
- **everything compiled in RAM**: the installer downloads Zig and builds `vh-kconf` and `vh-plan`,
  thor, the Zig tools, RefursWM and RefursLine in the live system's RAM. That is about 20 minutes
  of every installation and its memory peak of 2.1 GiB (the RefursWM build), the reason the
  gate's floor was 3 GiB (`hwdb/security.zon`, memory-floor; 1.5 GiB since U6, and the
  installer itself refuses to build in RAM below 3 GiB).

U6 builds an image from this repository at a commit: the same kernel series as the installed
system, a current xbps, the installer's tools, and every program already built, so that the
installer compiles nothing.

## What the image holds

`void-mklive`'s `mklive.sh` at a pinned commit (`live/mklive.pins`: git checks the tree against
it), with:

| Option | Value |
|---|---|
| `-v` | `linux6.18`: the series the installed system runs (`VH_KERNEL`) |
| `-p` | the official base image's packages (cryptsetup, lvm2, the GRUB of the ISO, the accessibility tools) and the installer's live tools (xfsprogs, dosfstools, minisign, xz); the firmware comes with them as in the official image, so that the network works while installing |
| `-S` | the official base image's services (sshd, chronyd, dhcpcd, wpa_supplicant, acpid) |
| `-I` | the tree below |
| `-T` | `UniVoidDistro` and the commit |

The first image (live-image run 39379089134) is 1.3 GB, the official 20250202 one 1.08 GB: the
difference is the firmware of 2026-08 (`linux-firmware-network` alone is 464 MB installed) and
the newer kernel; the prebuilt programs are 23 MB.

The tree, beside Void's root file system:

| Path | What |
|---|---|
| `/root/vh` | the repository at the commit (the installer reads it from there, as from the copy a user makes today) |
| `/usr/local/lib/vh/prebuilt/bin` | `vh-kconf`, `vh-plan` and the Zig tools (`-Dcpu=baseline`, as the installer builds them) |
| `/usr/local/lib/vh/prebuilt/thor` | the thor package and its repository index (`thor/package.sh`) |
| `/usr/local/lib/vh/prebuilt/desktop/LEVEL-BT` | RefursWM and RefursLine for each x86-64 level and Bluetooth variant (see the first decision) |
| `/usr/local/lib/vh/prebuilt/SHA256SUMS` | every file above; `BUILD` names the commit and the CI run |
| `/etc/vh-live` | the marker: the commit, the run, the image's kernel |

## The installer on our image

`install/lib.sh` reads `/etc/vh-live`; on our image:

- `plan.sh` takes the prebuilt `vh-kconf` and `vh-plan`: no Zig, no compile;
- the live environment's tools are there: the installer's `xbps-install` lines find them
  installed (a repository sync, no download);
- `build-thor.sh --prebuilt`, `build-tools.sh --prebuilt` (it exists), `build-desktop.sh
  --prebuilt` (it exists) with the variant the plan and `vh.conf` ask for;
- every prebuilt file is checked against `SHA256SUMS` before it is copied.

On Void's official image nothing changes: the installer builds as it does now.

## Building it: `.github/workflows/live-image.yml`

On demand and on `v*` tags, on `ubuntu-latest`. `live/prebuilt.sh` builds the programs: the
static ones with Zig on the runner, those linked with the C library in the vh-dev image (Void,
the Zig of `zig/ZIG_VERSION`). `live/build-image.sh` then runs as root in a privileged Void
container (mklive needs `chroot` and loop devices): it fetches `void-mklive` at its commit, runs
`mklive.sh`, and writes the ISO's sha256, the image's package list (`xbps-query -l`) and `BUILD`.
The workflow adds a GitHub build provenance attestation; the ISO is the run's artifact. The
packages come from Void's repositories at build time: the image is not bit-reproducible, and its
package list says what it holds. The first image took 23 minutes for the programs and 5 for
mklive.

mklive also runs tools of the build host, and does not stop when they are missing: without
`mkfs.vfat` and `mkfs.ext3` it made an unformatted EFI boot image and root image (run
39375727335), and the `mksquashfs` and `xorriso` it installs into its `void-host` directory run
with the host's libraries. `LIVE_HOST_PKGS` in `live/mklive.pins` names what the container
needs. `build-image.sh` checks for those tools before mklive, and after it that the ISO has a
UEFI El Torito image, a FAT holding `EFI/BOOT/BOOTX64.EFI`: the rig boots the image's kernel
directly and would not see a broken UEFI boot.

## Trust

- The ISO: its sha256 and the attestation (`gh attestation verify ISO --repo
  FalconBinary/UniVoidDistro` ties it to this repository, the workflow and the commit).
- The prebuilt programs: built by that workflow from that commit, checked by the installer
  against the image's `SHA256SUMS`.
- Secure Boot stays off while installing, as with Void's image (it is unsigned too); the
  installed system enrols its own keys at the first boot (`install/20-firstboot.sh`).

## Verification

- `kvm-smoke` takes a `live_run` input: the ISO of a live-image run instead of Void's (its sha256
  and attestation checked instead of minisign); the steps `base` and `machine` on it. On the
  first image both pass: `base` 19 of 19 (run 39381993073), `machine` 23 of 23 (run 39382001559).
- The installer prints its RAM at every step: the peak on our image decides how far the memory
  floor of `hwdb/security.zon` comes down (the protection alone asks for 2 GiB: Argon2id with
  1 GiB per guess), and the installation's time is measured against the official image's. On the
  rig (3 GiB, MemTotal 2872 MiB):

  | | Void's image (run 39369155168) | our image (run 39381993073) |
  |---|---|---|
  | the installation | 16.4 minutes | 2.6 minutes |
  | the lowest MemAvailable sampled | 756 MiB (building the Zig tools) | 1902 MiB (LUKS2: Argon2id, 1 GiB) |
  | tmpfs at most | 1091 MiB | 30 MiB |

  The sampler reads MemAvailable every 2 seconds and sees part of the Argon2id peak: the live
  system's own 325 MiB and the 1 GiB of Argon2id put the real peak near 1.4 GiB. Without
  Argon2id, the largest step is the UKI (dracut: about 280 MiB).
- The install-time probe is made by the installed kernel's series: `vh-kconf check` on the stock
  kernel finds nothing lost on the rig (`lost=0`); its one firmware load failure, `regulatory.db`,
  is the same on Void's image.

## aarch64

With U5: the same workflow with `-a aarch64` once the arm64 pins exist.

## Decisions (2026-10-20)

1. **RefursWM and RefursLine**: built in CI for x86-64-v1 and x86-64-v3 and for both Bluetooth
   variants of RefursLine; the installer takes the build the plan's x86-64 level (its tag
   `x86-64-v3`) and `VH_BLUETOOTH` ask for. Today they are built for the machine's own CPU (`zig
   build` with no `-Dcpu`): what that costs is measured, not assumed.
2. **The ISO**: the run's artifact, and a release on `v*` tags.
3. **Trust**: the sha256 and GitHub's build provenance attestation now; a project minisign key
   later (it needs a CI secret).
4. **Firmware**: what the official base image carries.
5. **aarch64**: with U5.
