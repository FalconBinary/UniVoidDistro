# sched/ — track S: `vh-sched`

A sched_ext scheduler with both halves in Zig 0.17.0: the BPF programs (`bpf/`, built for
`bpfel-freestanding` by the same Zig, GPL-2.0-only) and the loader (`src/`, pure Zig over
our own 6.18 bpf uapi structures: ELF, BTF_LOAD, maps, programs, the `sched_ext_ops`
struct_ops value, a `BPF_F_LINK` link). No libbpf, no clang, no C. Owned files: this
directory and the new `zig/lib/{bpf_uapi,btf,elf}.zig`.

Spike S1 ([docs/spikes/S1.md](../docs/spikes/S1.md)) is a **go**: the scheduler in
`bpf/vh_sched.zig` loads and runs on Linux 6.18.57 under `lockdown=confidentiality` on
arm64 (QEMU hvf) and x86_64 (QEMU TCG).

```
sched/
  build.zig            zig build -Dtarget=x86_64-linux --prefix DIR -> DIR/bin/vh-sched, DIR/bpf/*.o
  bpf/
    bpf.zig            kfuncs as extern symbols, helpers, MapDef, the callback context, constants
    vh_sched.zig       the spike scheduler: select_cpu, enqueue, dispatch, init, exit
    tcp_ca_probe.zig   a tcp_congestion_ops struct_ops: the loader mechanics on a kernel without sched_ext
    lockdown_probe.zig a program that needs bpf_probe_read_kernel: must be refused under lockdown
  src/
    main.zig           vh-sched load | lint | btf | state
    loader.zig         the generic struct_ops loader (any struct_ops type, by the kernel's BTF)
    lint.zig           the lint of the .o file
    types.zig          the .rodata/.bss layouts shared by the BPF programs and the loader
```

```sh
cd sched && zig build -Dtarget=x86_64-linux --prefix out
out/bin/vh-sched lint out/bpf/vh_sched.o                      # no kernel needed
out/bin/vh-sched load out/bpf/vh_sched.o --hold 10 --stats    # as root, on a kernel with CONFIG_SCHED_CLASS_EXT
out/bin/vh-sched load out/bpf/tcp_ca_probe.o --ops tcp_congestion_ops --hold 3   # any 6.x kernel with BTF
```

## How the BPF side is written

- One `export fn` per callback, in the section `struct_ops/MEMBER`; `struct_ops.s/MEMBER`
  loads it sleepable (`init` must be: `scx_bpf_create_dsq` is `KF_SLEEPABLE`).
- A callback takes `*const bpf.Ctx`: the kernel passes the arguments as 8-byte slots, and
  the verifier allows only 8-byte loads at slot offsets (what the `BPF_PROG` macro hides in
  C). `ctx.ptr(0, *bpf.TaskStruct)`, `ctx.int(1, i32)`.
- kfuncs are `extern fn` with the 6.13+ names; the loader resolves them against
  `/sys/kernel/btf/vmlinux`. Helpers are function pointers at the helper number.
- Globals: a `var` in `.rodata` becomes a frozen read-only map that the loader fills first
  (`--set cfg.FIELD=N`); `.bss` is an mmapped array map; a `MapDef` in `.maps` is a map.
  `const` values are folded by the compiler and never reach a map.
- Never `@panic` or `unreachable`: LLVM lowers them to `__bpf_trap`, which the 6.18 verifier
  rejects when reachable. An error is `bpf.err("...")` and a normal return.
- Atomics: `.monotonic` only when the result is discarded; `.seq_cst` for a fetch-and-op
  whose result is used (`bpf/bpf.zig`, the lint checks it). No `@atomicLoad` on BPF.
- Helpers are `inline fn`; the lint rejects bpf-to-bpf calls, compiler-rt and libc calls
  (u128, memcpy), signed division, legacy packet loads, a stack above 512 bytes.

## The loader

Nothing kernel-side is hard-coded: the struct's BTF id, the member indexes and offsets,
the `bpf_struct_ops_<type>` value layout, the kfunc ids and the `scx_exit_kind` names all
come from the running kernel's BTF. The BTF the kernel wants for the struct_ops map
(`btf_fd`) and for the data maps is generated at compile time from the Zig types in
`src/types.zig` with C names (`btf.Builder`), not taken from LLVM.

The link fd is held by the loader (later by the vh-init manager): closing it unregisters
the scheduler. `BPF_LINK_DETACH` makes the fd report `POLLHUP`; a kernel-side exit (an
error, sysrq-S) does not touch the link, so the exit is read from the ring buffer the
`exit` callback writes into (pollable), see the spike report.
