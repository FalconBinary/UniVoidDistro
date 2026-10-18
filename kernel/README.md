# kernel/ — track K: `vh-kconf`

A kernel built for this machine only: drivers built in, `CONFIG_MODULES=n` unless the gaming
session needs the NVIDIA modules. Owned files: this directory, the Limine hooks, the dracut
configuration and the `kernel.d` hooks in `rootfs/`.

Planned layout (see [docs/ROADMAP.md](../docs/ROADMAP.md#k-vh-kconf-the-kernel-of-this-machine)):

```
kernel/
  build.zig            vh-kconf: probe, resolve, fetch, build, install, check
  src/                 Zig sources
  profiles/            Kconfig fragments: base, hardening, perf, features/{usb-common,
                       bluetooth,camera,virt,game}
  pins/                pinned Void linux6.18 .config, kernel.org PGP fingerprints
```

Milestone v0.1 builds the custom UKI in CI (`kernel-fat` first, then the hardware config from
`/etc/vh/hw.zon`) and installs it on the laptop as an additional Limine entry; the stock UKI
stays. Nothing here is built yet.
