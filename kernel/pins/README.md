# kernel/pins: the inputs of the custom kernel, pinned

Every input of `vh-kconf resolve` and of the `kernel-custom` workflow is a file here or is
verified against a value here, so that two runs with the same `hw.zon` produce the same
`.config`. The pins are per architecture: the x86_64 ones under their plain names, the
aarch64 ones (milestone U5) under names that say so; `resolve` and `vh-plan` pick them by
the machine's `.arch` (`kernel/src/alias.zig`, `pinNames`).

| File | What | Source |
|---|---|---|
| `kernel-org.fingerprints` | the PGP keys that may sign `linux-6.18.y.tar.sign` | https://www.kernel.org/signature.html |
| `x86_64-dotconfig` | the `.config` of Void `linux6.18-6.18.57_1` | void-packages `srcpkgs/linux6.18/files/x86_64-dotconfig` at commit `1808133be7d656d11390fb9a87fe6f44d738e2a2` ("linux6.18: update to 6.18.57.", 2026-10-15) |
| `modules.alias` | modalias pattern -> module, as `depmod` wrote it for the stock kernel | `linux6.18-6.18.57_1.x86_64.xbps`, `/usr/lib/modules/6.18.57_1/modules.alias` |
| `modules.builtin.modinfo` | the aliases of the drivers that are already built into the stock kernel | the same package, `modules.builtin.modinfo` |
| `modules.builtin` | the list of built-in modules of the stock kernel | the same package, `modules.builtin` |
| `modules.firmware` | module -> the firmware files it names (`MODULE_FIRMWARE`), what vh-plan keeps for a machine's modules | the same package: the `.modinfo` section of every `.ko.zst` and the firmware records of `modules.builtin.modinfo`, read by `mkfirmware.py` (nothing is loaded or run) |
| `aarch64-dotconfig` | the `.config` of Void `linux6.18-6.18.59_1` for aarch64 | `/boot/config-6.18.59_1` of `linux6.18-6.18.59_1.aarch64.xbps`; void-packages `srcpkgs/linux6.18/files/arm64-dotconfig` at commit `e01c83f3418e92d3d1e1a3c567e019daaba93ce8` ("linux6.18: update to 6.18.59.", 2026-10-27) differs from it in one line only, `CONFIG_CC_VERSION_TEXT` (the file in void-packages was last written by a musl build) |
| `aarch64-modules.alias`, `aarch64-modules.builtin.modinfo`, `aarch64-modules.builtin`, `aarch64-modules.firmware` | the same four tables for aarch64 | `linux6.18-6.18.59_1.aarch64.xbps`, `/usr/lib/modules/6.18.59_1/`; `modules.firmware` by `mkfirmware.py` from that package |

SHA-256 of the pinned files and of the package they were taken from (2026-10-19,
`https://repo-default.voidlinux.org/current/linux6.18-6.18.57_1.x86_64.xbps`, 182479259 bytes):

```
5d4f1e5a600be214472b6ab80736d45078dd9cf0e31dd71f4be0ebf7d4ee22a5  linux6.18-6.18.57_1.x86_64.xbps
3cb263c473f3673434e8669861fb91db6630b7f2724e525538c2f662bdabc68d  x86_64-dotconfig
b956aaf438f041267aa6d327f5ae8427c542d6bc69e465f58b4a856ef5d74925  modules.alias
0bc2e66986e720b6ee7e929d4459c2b26d546c5631b3a36daf521b60dadc0344  modules.builtin.modinfo
3e6aaf55fd4973a5de9be0b2c4aa55bcbf0dc37d89bc0255444b2544676ac4f8  modules.builtin
6a00177cc06fdd4e544a386607385bf41d818ac0e8c0a6db398a79e836ee6f23  modules.firmware
5bd9acdc82ec5efc3790ae840e5aaa40dfde7efff261cf6dde902dc570acf98c  linux-6.18.57.tar.xz (kernel.org)
```

The aarch64 pins (2026-10-27, `https://repo-default.voidlinux.org/current/aarch64/linux6.18-6.18.59_1.aarch64.xbps`,
169 MB): Void's aarch64 repository had moved to 6.18.59 by then and keeps one version, so the
two architectures pin two patch releases of the 6.18 series; the next x86_64 update aligns
them. The x86_64 files above are unchanged.

```
384f24feca187ed28af4f02b9807a3f7c6a42a7cd7f701dd40e0e0dbf51955b5  linux6.18-6.18.59_1.aarch64.xbps
c76fe44b3c8a4ec1983bff2cd9e603006a33b1b6fc84d0602591633b5a5493a3  aarch64-dotconfig
9ee9dda097e5459148d84ec2e96ba2061bab7eaa0b8eab00413af3eb8f518c7f  aarch64-modules.alias
5d71eef4398fc89f5224e12e65eb182c7a93ff73eea71ee61fd7b73fe23191f7  aarch64-modules.builtin.modinfo
863caf405141c2d9012f40c7a5c192a2f8970ae26ad705ec08e8e3b7809e8608  aarch64-modules.builtin
7853c5f270ae048f15cad6fb9f9b435c17ef3eca522933235afe802b2309c6a7  aarch64-modules.firmware
53a55ac9863a5547e292b8e381d4e4c2240dd1127d5428a7c44dbc550be23963  linux-6.18.59.tar.xz (kernel.org, informative as above)
```

`aarch64-dotconfig` is `/boot/config-6.18.59_1` of the package byte for byte. The kernel
source is the same tarball for both architectures (one `linux-KVER.tar.xz` per release); the
arm64 build needs no other pin, only `ARCH=arm64`.

`x86_64-dotconfig` is byte-identical to `/boot/config-6.18.57_1` of the package (checked
2026-10-19). The tarball hash is informative: the workflow trusts the PGP signature against
`kernel-org.fingerprints`, as `kernel-fat.yml` does.

Updating the pins (a new Void kernel, for one architecture or both): download the package,
extract the three `modules.*` files and `/boot/config-*`, replace the files here, record the
void-packages commit of the dotconfig and the hashes above, regenerate `modules.firmware` with
`python3 -I kernel/pins/mkfirmware.py PACKAGE.xbps kernel/pins/modules.builtin.modinfo > kernel/pins/modules.firmware`
(aarch64: the `aarch64-` files; after updating the package's entry in its `PINNED` table), and
run `vh-kconf resolve` on `kernel/hw/gf63.zon`, `sh tests/adapt/run.sh` and
`sh tests/kernel/matrix.sh` to see what changed.

Some drivers name their firmware only at run time and list nothing here: the SOF audio DSP
(`intel/sof*`), Intel Bluetooth (`intel/ibt-*`). Their files come from rules in `hwdb/`.
