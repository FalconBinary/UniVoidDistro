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
  of every installation and its memory peak of 2.1 GiB (the RefursWM build), the reason for the
  gate's 3 GiB floor (`hwdb/security.zon`, memory-floor).

U6 builds an image from this repository at a commit: the same kernel series as the installed
system, a current xbps, the installer's tools, and every program already built, so that the
installer compiles nothing.

## What the image holds

`void-mklive`'s `mklive.sh` (a pinned commit, its tarball checked against a sha256), with:

| Option | Value |
|---|---|
| `-v` | `linux6.18`: the series the installed system runs (`VH_KERNEL`) |
| `-p` | the installer's live tools (cryptsetup, xfsprogs, dosfstools, minisign, xz), and the firmware of the official image, so that the network works while installing [VERIFY the size] |
| `-I` | the tree below |
| `-T` | `UniVoidDistro` and the commit |

The tree, beside Void's root file system:

| Path | What |
|---|---|
| `/root/vh` | the repository at the commit (the installer reads it from there, as from the copy a user makes today) |
| `/usr/local/lib/vh/prebuilt/bin` | `vh-kconf`, `vh-plan`, the Zig tools, `vh-stage1` (`-Dcpu=baseline`, as the installer builds them now) |
| `/usr/local/lib/vh/prebuilt/thor` | the thor package and its repository index (`thor/package.sh`) |
| `/usr/local/lib/vh/prebuilt/desktop/LEVEL-BT` | RefursWM and RefursLine for each x86-64 level and Bluetooth variant (see the first decision) |
| `/usr/local/lib/vh/prebuilt/SHA256SUMS` | every file above; `BUILD` names the commit and the CI run |
| `/etc/vh-live` | the marker: the commit, the run, the image's kernel |

## The installer on our image

`install/lib.sh` reads `/etc/vh-live`; on our image:

- `plan.sh` takes the prebuilt `vh-kconf` and `vh-plan`: no Zig, no compile;
- the live environment's tools are there: no `xbps-install -Syu xbps`, no tool installs;
- `build-thor.sh --prebuilt`, `build-tools.sh --prebuilt` (it exists), `build-desktop.sh
  --prebuilt` (it exists) with the variant the plan and `vh.conf` ask for;
- every prebuilt file is checked against `SHA256SUMS` before it is copied.

On Void's official image nothing changes: the installer builds as it does now.

## Building it: `.github/workflows/live-image.yml`

On demand and on `v*` tags, on `ubuntu-latest`, in a privileged Void container (mklive needs
`chroot` and loop devices): build the prebuilt files (Zig 0.17, the pins of `install/fetch-zig.sh`),
fetch and check `void-mklive`, run `mklive.sh`, write the ISO's sha256, the package list of the
image (`xbps-query -l`) and a GitHub build provenance attestation; the ISO is the run's artifact.
The packages come from Void's repositories at build time: the image is not bit-reproducible, and
its package list says what it holds.

## Trust

- The ISO: its sha256 and the attestation (`gh attestation verify ISO --repo
  FalconBinary/UniVoidDistro` ties it to this repository, the workflow and the commit).
- The prebuilt programs: built by that workflow from that commit, checked by the installer
  against the image's `SHA256SUMS`.
- Secure Boot stays off while installing, as with Void's image (it is unsigned too); the
  installed system enrols its own keys at the first boot (`install/20-firstboot.sh`).

## Verification

- `kvm-smoke` takes a `live_run` input: the ISO of a live-image run instead of Void's (its sha256
  and attestation checked instead of minisign); the steps `base` and `machine` on it.
- The installer prints its RAM at every step: the peak on our image decides how far the memory
  floor of `hwdb/security.zon` comes down (the protection alone asks for 2 GiB: Argon2id with
  1 GiB per guess), and the installation's time is measured against the official image's.
- The install-time probe is made by the installed kernel's series: `vh-kconf check` on the stock
  kernel should find nothing on the rig.

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
