# UniVoidDistro: the rolling release

Void's packages have always rolled. Our own layer now does too: thor, the Zig tools, vh-init,
vh-sched, the desktop, the SELinux policy, `hwdb/`, the kernel's profiles and pins, the installer
and the programs of `rootfs/` reach an installed system as signed xbps packages through the same
`doas vh-update`, in one transaction of thor with Void's; only a new thor goes first and alone, since
libxbps holds everything else back until it is in. Nothing is published before it has passed
the rig. The rebuild from the live USB ([09](../ru/09-updates.md), section 7) stays as the fallback
until a publication has reached real systems: the gate is green (below), the keys and the first
publication are still to come.

## The packages: `pkg/build.sh`

From the tree `live/prebuilt.sh` lays out (the installer's build in RAM lays out the same one):

| Package | What | Notes |
|---|---|---|
| `thor` | xbps with the policy | `thor/package.sh`; its version is xbps's and the patch revision |
| `vh-tools` | the tools of `pkg/tools.map`, `vh-kconf`, `vh-plan` | its INSTALL replaces the copies of enabled `optional/` modules |
| `vh-init` | `vh-stage1`, `vh-init`, `vh-ctl` | |
| `vh-sched` | `vh-sched`, `vh_sched.o` | |
| `vh-session` | `vh-root`, `vh-game`, `vh-game-enter` | |
| `vh-desktop-VARIANT` | RefursWM, RefursLine, their quirks, `desktop.sha256` | one per build (`x86-64-v1\|v3`, `aarch64`; `plain\|btmenu`); each `provides` `vh-desktop` and `replaces` the others |
| `vh-selinux-policy` | `/etc/vh/selinux`: the policy, file contexts | with `VH_MAC=selinux` only |
| `vh-data` | `/root/vh`: `hwdb/`, `adapt/`, `kernel/` (pins, profiles, sources), `zig/`, `thor/` | |
| `vh-installer` | `/root/vh`: `install/`, `tools/`, `rootfs/`, `optional/`, `pkg/` | |
| `vh-base` | `rootfs/usr`: `vh-update`, `vh-audit`, the migrations | |
| `vh-etc` | `rootfs/etc`, our own files | what is not a program is `conf_files` |
| `vh-keyring` | the channels' public keys | |
| `univoid` | depends on all of the above that every installation has | a new package reaches old systems through it |

Paths do not change (the UKI's `init=/usr/local/sbin/vh-init` names one). thor's policy applies to
these packages as to Void's. An installation installs them through thor from the local repository,
which afterwards keeps thor alone: the other packages, four desktop builds among them, would be
dead weight.

**The version** is `git describe`'s (`v0.2.0-15-gHASH` is `0.2.0.r15`), the revision CI's run number:
it only grows along `main` and over the tags, so both channels compare. `univoid`'s also carries the
time of the build. A package whose files, modes and metadata are the published ones is not published
again (`pkg/merge.sh`, the `ARCH-contents` asset): **an update replaces exactly what changed**, a
change to a hwdb rule downloads a few hundred kilobytes. Two builds of one tree are byte for byte
the same (`tests/pkg`); that two runners agree is [VERIFY] by the first publications, and a program
that differs is only downloaded once more than it had to be.

### What no package owns

xbps overwrites what it unpacks, so these stay out of every package (`pkg/installer-owned`, and the
test `tests/pkg` fails on a file of `rootfs/` that is neither a package's nor listed here):

- **The templates, `*.in` and `*.cin`:** rendered per installation from `vh.conf`.
- **Files a Void package owns:** `/etc/pam.d/{doas,swaylock,system-login}`, `/etc/dhcpcd.conf`,
  `/etc/security/faillock.conf`, `/etc/runit/ctrlaltdel`. xbps refuses two owners (`tests/pkg` reads
  the file lists of Void's packages).
- **Files the installer edits or deletes per machine:** `/etc/vh/acpi.conf`,
  `99-vh-dgpu-off.rules`, `vh-novirt.conf`. A package would bring a deleted file back.

A fix to one of these reaches installations in one of two ways, without a trade-off (the signed
packages already run INSTALL as root):

1. **A thin file.** What can be a program goes to `vh-base`, and the installer's file only calls it.
   `/etc/runit/ctrlaltdel` is that now: `/usr/local/libexec/vh/vh-ctrlaltdel` does the work.
2. **A migration.** `vh-base` ships `/usr/local/libexec/vh/migrate.d/NNNN-name`; `vh-update` runs
   each once, in order, and records it in `/var/lib/vh/migrated`; a failure stops the update and is
   retried by the next one. An installation records the ones it was born with. A migration must be
   idempotent and must not overwrite an admin's change: it leaves `FILE.new-migration` next to it.
   `0001-ctrlaltdel` makes the old file thin on existing installations.

**Not delivered yet:** a module of `optional/` keeps what it installed; `vh-tools` replaces the copies
of the programs, but the module's scripts change only when it is enabled again ([VERIFY]: list them
in a migration when one changes).

### The entry points

thor's policy does not extract kernel hooks and login scripts from any package. `vh-etc` has seven
(`pkg/thor-keep`): the six `/etc/kernel.d/*/NN-vh-*` and `/etc/bash/bashrc.d/vh.sh`. The installer and
`vh-update --adopt` name exactly those paths in `/etc/thor/keep.conf`, where `thor policy` shows
them. Without the list the policy holds them back (`tests/pkg`).

## The channels

```sh
doas vh-update --channel rolling    # or stable; then it updates
```

| | stable | rolling |
|---|---|---|
| What | the repository of the newest `v*` tag | the repository of `main` |
| Where | `releases/latest/download`, which GitHub sends to the newest non-pre-release | the pre-release `rolling` |
| Published | by hand: `pkg/sign-stable.sh` | by CI, after the gates, on every merge and weekly |
| Signed by | the offline key | CI's key |
| The default | yes (`VH_CHANNEL`) | |

The channel is `/etc/xbps.d/00-vh-channel.conf`, sorted ahead of `01-thor.conf`, because xbps takes a
package from the first repository that has it. The URLs are in `/etc/vh/channels.conf`.

**rolling to stable:** xbps does not downgrade, so the system stays on its newer packages until the
next tag catches up (the versions compare across channels). `--downgrade` installs stable's now.

Assets of a release follow a redirect that xbps's fetch handles (checked against v0.2.0's assets).
The index of a release is replaced last, after its packages, and the packages an index named stay
one publication longer. Replacing an asset leaves a gap of seconds: a `vh-update` in it stops with
xbps's error, and the next one works.

### The keys

**Two keys, because the two channels have different exposures.** CI's signs rolling and lives in
the secret `VH_REPO_KEY_ROLLING` of the environment `rolling`, which only `main` may use; the offline
key signs stable. A system trusts only the key of its channel: `vh-update --channel` puts that one
in `/var/db/xbps/keys` and takes the other out. **So taking over CI or this repository does not reach
systems on stable.**

| Protects from | Residual risk | Speed cost | Convenience cost |
|---|---|---|---|
| A package changed at the host or on the way (each is signed); a stolen CI key on stable systems; a repository of a new key (below) | A stolen CI key signs for rolling systems until the key is replaced; the freeze below | RSA verification per package, as for Void's | The offline signature, a manual step of minutes per tag |

**xbps asks `[Y/n]` before trusting a new key, and `-y` does not answer it** (probed on 0.60.7). A
stray Enter would import an attacker's key, so `vh-update` synchronises with stdin closed: xbps then
refuses the repository, and `vh-update` stops and says so instead of updating without it.

**A frozen index.** A signature has no expiry. rolling is published at least weekly, so `vh-update`
reports a rolling index older than nine days (`univoid`'s version carries the time). Stable can
rightly be old, so a frozen stable is not detected: [09](../ru/09-updates.md), section 4 applies.

Making them, once, in this order: the secret needs its environment, and the rule "only `main`" must
hold before there is a secret to guard. A key's directory must not lie in `~/Documents`, which syncs
to iCloud.

```sh
echo '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' | gh api -X PUT repos/FalconBinary/UniVoidDistro/environments/rolling --input -
```

```sh
gh api -X POST repos/FalconBinary/UniVoidDistro/environments/rolling/deployment-branch-policies -f name=main -f type=branch
```

```sh
sh pkg/keygen.sh rolling /tmp/vh-rolling-key
```

```sh
gh secret set VH_REPO_KEY_ROLLING --env rolling < /tmp/vh-rolling-key/rolling.pem
```

```sh
mkdir -p pkg/keys/rolling && cp /tmp/vh-rolling-key/*.plist pkg/keys/rolling/ && rm -rf /tmp/vh-rolling-key
```

```sh
sh pkg/keygen.sh stable /Volumes/KEY    # asks for a passphrase; the media stays offline
```

```sh
mkdir -p pkg/keys/stable && cp /Volumes/KEY/*.plist pkg/keys/stable/
```

The two `FINGERPRINT.plist` files are committed, and the stable key's fingerprint and sha256 go into
the command below. Until then CI builds and gates but publishes nothing, and new installations have
no channel.

Neither script leaves a secret behind in Docker. A private key is made or read in a tmpfs (colima's
VM has no swap), and it reaches or leaves the container only on a stream, so its disk never holds the
key. The passphrase comes on stdin, so neither `ps` nor `docker inspect` shows it. A stream also means
the media need not be shared with the VM: colima does not share `/Volumes`.

### From v0.2.0

An installation of v0.2.0 has neither the key nor the repository. One command, run by the admin; the
key is pinned by its sha256, so nothing is trusted on first use:

<!-- the command of an installation of v0.2.0 -->
```sh
doas sh -c 'xbps-fetch -o /tmp/vh-key https://raw.githubusercontent.com/FalconBinary/UniVoidDistro/main/pkg/keys/stable/FINGERPRINT.plist && echo "KEY_SHA256  /tmp/vh-key" | sha256sum -c - && install -m 0644 /tmp/vh-key /var/db/xbps/keys/FINGERPRINT.plist && printf "repository=https://github.com/FalconBinary/UniVoidDistro/releases/latest/download\n" > /etc/xbps.d/00-vh-channel.conf && xbps-install -S </dev/null && if xbps-install -un </dev/null | grep -q "^thor-"; then xbps-install -yu xbps </dev/null; fi && xbps-install -y vh-base </dev/null && /usr/local/sbin/vh-update --adopt'
```

`FINGERPRINT` and `KEY_SHA256` are filled in with the first stable key. thor goes first: libxbps lets
nothing else through while the package that provides xbps has an update, and it takes that update
only under the name `xbps`. Only then: on a current thor, `xbps-install -u xbps` asks for Void's xbps,
and the transaction aborts over `libxbps.so.6`. thor stays (`tests/thor/package_test.sh`), but the
command would stop there. `vh-base` brings the new `vh-update`; `--adopt` names the entry points for thor, installs `univoid` with the desktop's build
and policy the plan and `vh.conf` ask for (the installer's own `vh_desktop_variant`), removes the
identical `.new-*` copies, runs the migrations and goes on to a normal update. The files keep their
places; only their owner changes. Then reboot. The rig gate runs this very text.

**A desktop with your own `config.zig`:** a build made on the machine is copied to
`/root/vh-desktop-before-adopt`. Install it again by the rebuild from the USB stick, then
`doas xbps-pkgdb -m hold vh-desktop-VARIANT` keeps updates off it (`-m unhold` gives them back).

## The gates: `.github/workflows/packages.yml`

Build natively for both architectures, merge, sign, then:

- **x86_64: the rig.** `kvm-smoke` (called with `from_release: latest`, `update_run`, `step: update,base`)
  takes the newest release's ISO with its attestation, installs with **the installer the image
  brings** (`vhvm.py install --own-installer`), serves this build's repository from the runner, runs
  the command above and `vh-update`, checks the owners and hashes of every package (`xbps-pkgdb`) and
  the migration, reboots and passes `base`. A failure publishes nothing.
- **aarch64: a container.** GitHub's arm64 runners have no `/dev/kvm`, and TCG would take hours per
  merge. `tests/pkg/gate.sh`, on an arm64 runner: the new thor replaces xbps, our packages and
  Void's dependencies install in enforce with every signature checked, the programs start, the
  libraries resolve. **[VERIFY] that aarch64 boots after the update:** only by hand, under hvf
  ([hardware.md](hardware.md)), before each stable tag.

`concurrency` keeps the newest commit. The weekly run rebuilds against the current Void, so a
library's new name reaches the desktop; xbps refuses an update that would break a library another
package needs.

## A stable release

1. `git tag v0.3.0 && git push origin v0.3.0`. `packages`, `live-image` and `zig-test` run, and their
   gates pass; the assets collect on a **draft**, which is not `latest`, so no system sees it.
2. `sh pkg/sign-stable.sh v0.3.0 /Volumes/KEY/stable.pem`: every package is checked against its
   attestation, signed by the offline key, and the release is published. The `.xbps` files stay
   the bytes CI built.
3. By hand before step 2: the aarch64 rig under hvf, the [VERIFY] above.

## Images

Each week `live-image` builds `main`, takes the published package wherever it is the same, so a new
installation does not download it again, and after the x86_64 image has passed the rig the ISOs
replace last week's among the assets of the pre-release `rolling`. Tags stay the stable releases.

## How it is verified

- `tests/pkg/run.sh` (the `adapt` workflow), in a container: every package, the split of `rootfs/`,
  reproducibility, an installation over a v0.2.0-like tree, an update, an edited conf file, a module's
  copy, the desktop's switch, a second publication replacing only what changed, signatures over HTTP
  (an unknown key, a changed package, the other channel's key), a real thor in enforce, and `vh-update
  --channel` with this container as the system.
- The rig: the gate above, on every pull request of these paths and before every publication. Run
  41748466629 (2026-11-04): v0.2.0's ISO installed, the command above, every package replaced,
  `vh-update`, a reboot, `base` with no failure, including `vh-kconf check` with `lost=0` and the power
  button's regular poweroff; `gate-aarch64` green in the same run.
- `pkg/keygen.sh` and `pkg/sign-stable.sh` by hand on a Mac with colima, with throwaway keys and a
  stand-in for `gh`: the keys in a tmpfs, the signed index and packages install with the public key,
  a wrong passphrase uploads nothing.

**Not run yet:** the job `publish` and a real `gh release`, `sign-stable.sh` against a real draft and
its attestations, the weekly `live-image` path, the installer's path that builds in RAM and packages
through `pkg/build.sh`, and the `gh api` commands above (they would create the environment).
