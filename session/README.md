# session/ — track G: `vh-root`, `vh-game`, `vh-game-enter`

The gaming session on tty3: the user `game`, a Void userland of its own under
`/var/lib/vh/roots/game`, namespaces, nothing of the everyday user's within reach, and a removal
that gives the system back byte for byte. The design, the phases, the user's decisions and the
cost: [docs/uni/game.md](../docs/uni/game.md); upstream's plan:
[docs/ROADMAP.md](../docs/ROADMAP.md#g-vh-root-vh-game). Owned files: this directory,
`tests/session/`, `tests/vm/steps/session.py`, `rootfs/usr/local/libexec/vh/vh-audit.d/55-game.sh`,
`.github/workflows/session.yml`.

```
session/
  build.zig            vh-root, vh-game, vh-game-enter (static PIEs, ReleaseSafe; ../zig/lib/vh.zig in place)
  profiles/            the root profiles, compiled in: game.zon (packages, thor's deny-list
                       exceptions of the root, noextract, repositories, mode)
  src/root.zig         vh-root: create, install, update, list, remove a root (roots.zig)
  src/game.zig         vh-game: install, tty on|off, remove, status
  src/enter.zig        vh-game-enter: the login shell of game, the session's namespaces and mounts
  src/accounts.zig     passwd, shadow, group, gshadow: the lines added and taken away exactly
  src/lines.zig        access.conf, /etc/shells, fstab: the same
  src/rmtree.zig       a tree removed without following a symlink or entering a mount
  src/sys.zig          mounts, namespaces, capabilities, the hostname, lo
```

```sh
doas vh-game install     # the user game, its home, the gaming root (the plan's Vulkan driver), tty3
doas vh-game tty on      # the login of game on tty3 until the next boot
doas vh-game status
doas vh-game remove      # everything back, the home with it
doas vh-root list | update NAME | install NAME PKG...

sh tests/session/run.sh  # the unit tests, then the session end to end in a privileged container
python3 tests/vm/check.py game --repo   # on the VM rig (kvm-smoke: step=game)
```

The programs are built and installed with the system's other Zig tools
(`install/build-tools.sh`, `live/prebuilt.sh`); nothing of the session runs before
`vh-game install`. G1 is built: the root, the account, the login, the session (Mesa: Vulkan of
the GPU's driver, no network, no sound, no 32-bit, no kernel change). G2 (sound), G3 (the
gaming boot and the NVIDIA module built on the machine), G4 (Steam) follow
([docs/uni/game.md](../docs/uni/game.md#phases)).
