# installer/ — track N: `vh-install`

An English TUI installer in Zig (termios + ANSI) with a `--config` mode for the test rig. The
steps and the protection follow `install/10-install.sh` and `install/chroot.sh`, which remain
the specification: the disk confirmed by name, LUKS2, XFS, users, the system installed by thor,
RefursWM/RefursLine built for the CPU, Limine + sbctl. It does not build the kernel: the first
boot runs on the stock UKI, then `vh-firstboot` (Secure Boot as `20-firstboot.sh`, then
`vh-kconf`). Owned files: this directory.

Planned layout (see [docs/ROADMAP.md](../docs/ROADMAP.md#n-vh-install)):

```
installer/
  build.zig
  src/                 vh-install, vh-firstboot
  zig/lib/tui.zig      (new shared file) the terminal UI
```

Runs from the official Void live image. Nothing here is built yet; milestone v0.3.
