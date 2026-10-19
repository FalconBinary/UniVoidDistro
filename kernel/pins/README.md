# kernel/pins: the inputs of the custom kernel, pinned

Every input of `vh-kconf resolve` and of the `kernel-custom` workflow is a file here or is
verified against a value here, so that two runs with the same `hw.zon` produce the same
`.config`.

| File | What | Source |
|---|---|---|
| `kernel-org.fingerprints` | the PGP keys that may sign `linux-6.18.y.tar.sign` | https://www.kernel.org/signature.html |
| `x86_64-dotconfig` | the `.config` of Void `linux6.18-6.18.57_1` | void-packages `srcpkgs/linux6.18/files/x86_64-dotconfig` at commit `1808133be7d656d11390fb9a87fe6f44d738e2a2` ("linux6.18: update to 6.18.57.", 2026-10-15) |
| `modules.alias` | modalias pattern -> module, as `depmod` wrote it for the stock kernel | `linux6.18-6.18.57_1.x86_64.xbps`, `/usr/lib/modules/6.18.57_1/modules.alias` |
| `modules.builtin.modinfo` | the aliases of the drivers that are already built into the stock kernel | the same package, `modules.builtin.modinfo` |
| `modules.builtin` | the list of built-in modules of the stock kernel | the same package, `modules.builtin` |

SHA-256 of the pinned files and of the package they were taken from (2026-10-19,
`https://repo-default.voidlinux.org/current/linux6.18-6.18.57_1.x86_64.xbps`, 182479259 bytes):

```
5d4f1e5a600be214472b6ab80736d45078dd9cf0e31dd71f4be0ebf7d4ee22a5  linux6.18-6.18.57_1.x86_64.xbps
3cb263c473f3673434e8669861fb91db6630b7f2724e525538c2f662bdabc68d  x86_64-dotconfig
b956aaf438f041267aa6d327f5ae8427c542d6bc69e465f58b4a856ef5d74925  modules.alias
0bc2e66986e720b6ee7e929d4459c2b26d546c5631b3a36daf521b60dadc0344  modules.builtin.modinfo
3e6aaf55fd4973a5de9be0b2c4aa55bcbf0dc37d89bc0255444b2544676ac4f8  modules.builtin
5bd9acdc82ec5efc3790ae840e5aaa40dfde7efff261cf6dde902dc570acf98c  linux-6.18.57.tar.xz (kernel.org)
```

`x86_64-dotconfig` is byte-identical to `/boot/config-6.18.57_1` of the package (checked
2026-10-19). The tarball hash is informative: the workflow trusts the PGP signature against
`kernel-org.fingerprints`, as `kernel-fat.yml` does.

Updating the pins (a new Void kernel): download the package, extract the three `modules.*`
files and `/boot/config-*`, replace the files here, record the void-packages commit of the
dotconfig and the hashes above, and run `vh-kconf resolve` on `kernel/hw/gf63.zon` to see
what changed in the report.
