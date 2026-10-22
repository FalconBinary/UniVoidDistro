# session/ — track G: `vh-root`, `vh-game`, `vh-game-enter`

The gaming session on tty3: the user `game`, a Void userland of its own under
`/var/lib/vh/roots/game`, namespaces, nothing of the everyday user's within reach, and a removal
that gives the system back byte for byte. The design, the phases, the user's decisions and the
cost: [docs/uni/game.md](../docs/uni/game.md); upstream's plan:
[docs/ROADMAP.md](../docs/ROADMAP.md#g-vh-root-vh-game). Owned files: this directory,
`tests/session/`, `tests/vm/steps/session.py`, `rootfs/usr/local/libexec/vh/vh-audit.d/55-game.sh`,
`.github/workflows/session.yml`, `.github/workflows/game-kernel.yml`.

```
session/
  build.zig            vh-root, vh-game, vh-game-enter (static PIEs, ReleaseSafe; ../zig/lib/vh.zig in place)
  profiles/            the root profiles, compiled in: game.zon (packages, thor's deny-list
                       exceptions of the root, noextract, repositories, mode); kbuild.zon (the
                       gaming kernel's build root, removed after each build); keys.zon (OpenSSL
                       for the module key, removed after it)
  src/root.zig         vh-root: create, install, update, list, remove a root (roots.zig)
  src/game.zig         vh-game: install, tty on|off, boot on|off, play, remove, status; the root's
                       sound configuration, the udev rule and the ACL entries of the sound cards'
                       playback nodes
  src/boot.zig         the gaming boot (G3a): its marker and stage-1 script, ia32 on the command
                       line, the x86_64 filter, tty3's getty, vh-game stage1 and stage2
  src/key.zig          the module key (G3b): RSA-4096 under a passphrase beside the Secure Boot
                       keys, its certificate the gaming kernel's only module key
  src/kbuild.zig       the gaming kernel's build (G3b): the pinned tarball, the build root, the
                       machine kernel's pipeline with features/game in a sandbox, its invariants
  src/enter.zig        vh-game-enter: the login shell of game, the session's namespaces and mounts,
                       its /dev/snd and its own sound server
  src/accounts.zig     passwd, shadow, group, gshadow: the lines added and taken away exactly
  src/lines.zig        access.conf, /etc/shells, fstab: the same
  src/rmtree.zig       a tree removed without following a symlink or entering a mount
  src/sys.zig          mounts, namespaces, capabilities, the hostname, lo
  src/acl.zig          POSIX access ACLs: a named user's entry added and taken away exactly
```

```sh
doas vh-game install     # the user game, its home, the gaming root (the plan's Vulkan driver, a sound
                         # server of its own), tty3, the sound cards' playback nodes for game
doas vh-game tty on      # the login of game on tty3 until the next boot
doas vh-game boot on     # the gaming boot: the stock UKI's twin with ia32 on, the last entry of the menu
doas vh-game play        # reboot into it once (ia32 for the gaming session alone, tty3 by itself)
doas vh-game key new     # the module key, under a passphrase (G3b)
doas vh-game kernel build # the gaming kernel, built on the machine; with the gaming boot on, its entry
doas vh-game status
doas vh-game remove      # everything back, the home with it
doas vh-root list | update NAME | install NAME PKG...

sh tests/session/run.sh  # the unit tests, then the session end to end in a privileged container
python3 tests/vm/check.py game --repo   # on the VM rig (kvm-smoke: step=game; the gaming boot: step=gameboot;
                                        # the gaming kernel of CI's game-kernel: step=gamekernel)
```

The programs are built and installed with the system's other Zig tools
(`install/build-tools.sh`, `live/prebuilt.sh`); nothing of the session runs before
`vh-game install`. G1 is built: the root, the account, the login, the session (Mesa: Vulkan of
the GPU's driver, no network, no 32-bit, no kernel change). G2 is built: the session's own
sound server (the root's PipeWire, with WirePlumber and its pulse server) on the sound cards'
playback and control nodes, which `game` gets by an ACL entry of a udev rule
(`/etc/udev/rules.d/99-vh-game.rules`); no microphone or camera in the session. G3a is built: the
gaming boot, the stock UKI's twin with `ia32_emulation=1` (vh-limine-update's `game` series,
`zig/lib/twin.zig`), in which every process tree but the gaming session's runs under a filter that
kills a 32-bit system call. G3b is built: the gaming kernel, built on the machine by the machine
kernel's pipeline with `features/game` in a build root and a sandbox removed after it, trusting
the user's module key alone, the gaming entry before the twin. G3c-G3d (the NVIDIA module built
on the machine), G4 (Steam) follow ([docs/uni/game.md](../docs/uni/game.md#phases)).
