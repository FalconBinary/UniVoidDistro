# session/ — track G: `vh-root`, `vh-game`

`vh-root` creates, lists and removes roots under `/var/lib/vh/roots/<name>`, installing
packages with thor `-r` under a per-root policy profile (base, kbuild, game). `vh-game install`
builds the gaming session: the `game` UID on tty3, a root with glibc multilib, Steam,
Mesa/Vulkan 32/64, gamescope, Xwayland and the NVIDIA libraries of the same version as the
kernel modules, `features/game` in the kernel profile and a kernel rebuild. `vh-game remove`
takes all of it away and the system is byte-for-byte what it was (`find / -xdev`, `hw.zon`,
the nft ruleset, passwd/group compared before and after). Owned files: this directory.

Planned layout (see [docs/ROADMAP.md](../docs/ROADMAP.md#g-vh-root-vh-game)):

```
session/
  build.zig
  src/root.zig         vh-root
  src/game.zig         vh-game install / remove
  src/enter.zig        vh-game-enter: the login shell of game (unprivileged userns + mount/pid/ipc/uts)
  profiles/            thor policy profiles per root
```

Nothing here is built yet; milestone v0.3.
