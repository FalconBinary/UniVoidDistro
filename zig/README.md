# zig: the system tools written in Zig

```sh
cd zig && zig build -Dtarget=x86_64-linux --prefix DIR   # the programs land in DIR/bin
install/build-tools.sh /mnt                               # [LIVE] build in RAM and install
sh tests/zig/run.sh                                       # tests in a Void container (docker)
```

The Zig version is pinned: `ZIG_VERSION` (currently 0.17.0). Zig breaks compatibility
between releases, so building with another version is not supported.

| File | What |
|---|---|
| `lib/vh.zig` | shared code: messages, system calls, files, `KEY=VALUE` configs, running programs without a shell |
| `lib/hash.zig` | SHA-256 and BLAKE2b-512 (`std.crypto`) |
| `lib/seccomp.zig` | classic BPF assembler, the sandbox filters and an interpreter for the self-test |
| `lib/input.zig` | the input devices built into the machine: vh-acpid's idle watchdog and vh-deadman's alarm combination listen to these only |
| `lib/assess.zig` | the boot assessment of a machine UKI for vh-limine-update: Limine's Boot Loader Interface variables in efivarfs, its entry identifiers, the verdict of vh-kconf check, the state and the decisions ([docs/uni/kernel.md](../docs/uni/kernel.md#the-boot-assessment)) |
| `lib/twin.zig` | the gaming boot's twin of a stock UKI for vh-limine-update: the same PE image with `ia32_emulation=1`, the signature cut off, and the comparison with a twin on the ESP ([docs/uni/game.md](../docs/uni/game.md#g3a-the-gaming-boot)) |

Code rules (the full list, with the reasons, is in `docs/principles.md`):

- Linux system calls only (`std.os.linux`). `std.Io.Reader`/`std.Io.Writer` may be used
  everywhere; an `Io` instance (`Io.Threaded`) only inside the network adapter of thor,
  because the rest of `std.Io` is still experimental and changes between releases.
- libc (glibc) only where there is no other way (OpenSSL, libxcrypt, libxbps); every other
  program is a static PIE that does not depend on the system's glibc.
- ReleaseSafe builds: bounds, overflow and null checks stay in the program.
- Never spawn programs through a shell.
- Messages and comments are in English.

History: these tools were ported from C one to one in the predecessor project
(Void-Hardened-Refurs, commit `39cf905` holds the last C sources); the ports were verified
against the C programs byte for byte there. The differential test scripts in `tests/zig/`
remain and now compare two builds of the Zig tools (for example a release and a refactor).
