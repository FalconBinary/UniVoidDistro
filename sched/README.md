# sched/ — track S: `vh-sched`

A sched_ext scheduler with both halves in Zig: the BPF program (`bpf/`, built for
`bpfel-freestanding`, GPL-2.0-only) and the loader (`src/`, pure Zig over our own 6.18 bpf
uapi structures: ELF, BTF_LOAD, maps, programs, the `sched_ext_ops` struct_ops value, a
`BPF_F_LINK` link held by the vh-init manager). Owned files: this directory and the new
`zig/lib/{btf,elf,bpf_uapi}.zig`.

Planned layout (see [docs/ROADMAP.md](../docs/ROADMAP.md#s-vh-sched-sched_ext-all-in-zig)):

```
sched/
  build.zig
  bpf/                 the BPF program (GPL-2.0-only, see bpf/README.md)
  src/                 the loader, the BTF generator, the lint of the .o file
  policy/              v1: fairness per session cgroup, nice weights, vtime with a sleep bonus
```

Spike S1 (KVM + the `kernel-fat` CI kernel, under lockdown) decides whether Zig can reach
sched_ext at all; the fallback paths are in the roadmap. Nothing here is built yet.
