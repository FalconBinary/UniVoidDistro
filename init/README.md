# init/ — track I: `vh-init`, `vh-ctl`, `vh-logd`

A tiny PID 1 (zombies, signals, shutdown, restarting the manager) and a separate service
manager process from the same binary: stage 1 natively without a shell, a service graph
started in parallel by readiness, runit-compatible service directories, `vh-ctl` (also as the
`sv` shim) and `vh-logd` for `/dev/log`, `/dev/kmsg` and service stdout. Owned files: this
directory, `rootfs/etc/runit`, `rootfs/etc/sv`, the `sv` shim.

Planned layout (see [docs/ROADMAP.md](../docs/ROADMAP.md#i-vh-init-vh-ctl-vh-logd)):

```
init/
  build.zig
  src/pid1.zig         PID 1
  src/manager.zig      the service graph and the control socket
  src/stage1.zig       mounts, sysctl, hostname, seedrng, zram, eudev, nft, apparmor
  src/ctl.zig          vh-ctl
  logd/                vh-logd
  services/            /etc/vh/services/*.svc of the base system
```

Milestone v0.1 ships `vh-stage1` (a Zig replacement of `/etc/runit/1` and the core services,
runit stays PID 1); spike S2 tries vh-init as PID 1 in a container and a VM; v0.2 makes it
PID 1 through a separate UKI with `init=`. Nothing here is built yet.
