# live/: UniVoidDistro's own live image (U6)

The design and the decisions: [docs/uni/live-image.md](../docs/uni/live-image.md).

| File | What |
|---|---|
| `mklive.pins` | void-mklive's commit, the image's kernel series, the official base image's packages and services, the installer's tools |
| `prebuilt.sh OUT` | the programs the installer would compile in the live system's RAM, built: `vh-kconf`, `vh-plan` and the Zig tools, thor (`install/build-thor.sh --out`), RefursWM and RefursLine for x86-64-v1 and -v3 with and without the Bluetooth menu (`install/build-desktop.sh --out`); `BUILD` and `SHA256SUMS` |
| `build-image.sh PREBUILT OUT` | the ISO: void-mklive with the repository at that commit in `/root/vh` (`.vh-commit`), the programs in `/usr/local/lib/vh/prebuilt`, `/etc/vh-live`; its `SHA256SUMS`, `BUILD` and package list |

Both run in the `live-image` workflow (on demand and on `v*` tags): `prebuilt.sh` on the x86_64
runner (zig, and the vh-dev image of `tests/docker/build.sh`), `build-image.sh` as root in a
privileged Void container. The ISO is the run's artifact, with a GitHub build provenance
attestation, and a release asset on a tag:

    sha256sum -c SHA256SUMS
    gh attestation verify univoiddistro-live-x86_64-COMMIT.iso --repo FalconBinary/UniVoidDistro

On the image the installer (`install/lib.sh` `vh_prebuilt`) takes the programs when the image is
of the repository's commit and every file matches `SHA256SUMS` (a file that does not stops the
installation); on Void's own image it builds them as before. `kvm-smoke` installs from the image
with `live_run=RUN` (a live-image run of the same commit).
