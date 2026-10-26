# sched/ — track S: `vh-sched`

A sched_ext scheduler with both halves in Zig 0.17.0: the BPF programs (`bpf/`, built for
`bpfel-freestanding` by the same Zig, GPL-2.0-only) and the loader (`src/`, pure Zig over
our own 6.18 bpf uapi structures: ELF, BTF_LOAD, maps, programs, the `sched_ext_ops`
struct_ops value, a `BPF_F_LINK` link). No libbpf, no clang, no C. Owned files: this
directory and the new `zig/lib/{bpf_uapi,btf,elf}.zig`.

Spike S1 ([docs/spikes/S1.md](../docs/spikes/S1.md)) is a **go**: a scheduler written this
way loads and runs on Linux 6.18.57 under `lockdown=confidentiality` on arm64 (QEMU hvf) and
x86_64 (QEMU TCG). **v1 (2026-10-26) is the scheduler of any topology** (U4): the loader reads
the machine from sysfs and writes it into the object's `.rodata` before the load; one object
serves every machine.

## v1: the policy

```
select_cpu   the kernel's own idle search first (the previous CPU, a whole idle core, the LLC,
             anywhere: scx_bpf_select_cpu_dfl); found -> straight to that CPU's local queue.
             On a hybrid CPU an interactive task that found nothing takes an idle big core.
enqueue      one dispatch queue per LLC, ordered by virtual time weighted by nice. A task may
             fall behind the LLC's clock by one slice, an interactive one (its runs are shorter
             than a quarter of the slice) by 1 + lat_bonus_max slices: it goes first when it
             wakes. While more tasks wait in the LLC than it has CPUs, the slice shrinks
             (slice * cpus / waiting, at least slice_min).
dispatch     the CPU's own LLC queue; when empty, another LLC's queue, only with steal_min or
             more tasks waiting there (one task is better off near its own cache).
running      the task's start time; the LLC's clock moves forward with the tasks that run.
stopping     the run's length into an exponential average (the interactive test); the task's
             virtual time advances by the CPU time used, inversely to its weight.
enable       a task that enters: its clock is the LLC's.
cpu_release  RT or deadline took the CPU: what waited in its local queue goes back to the LLC.
```

The machine, in `.rodata` (`src/types.zig` `Cfg`, filled by `src/topo.zig`): the LLC of every
CPU (the highest unified cache level shared beyond the core's SMT siblings; without cache nodes
the cluster, then the package), the number of CPUs per LLC and the NUMA node of each, the big
cores of a hybrid part (arm64 `cpu_capacity`, else the maximum frequency: cores more than 5 %
apart make the part hybrid), the `task_struct` offsets the programs read (`scx.weight`,
`scx.dsq_vtime`, `scx.slice`, `cpus_ptr`) taken from the running kernel's BTF, and the knobs:
`slice_ns` (20 ms), `slice_min_ns` (1 ms), `lat_bonus_max` (4), `steal_min` (2), `flags`
(prefer big cores, steal). `--set cfg.KEY=N` changes any of them at the load. Per-task state
(the run average, the last start) lives in a `BPF_MAP_TYPE_TASK_STORAGE` map typed by the
generated BTF.

```sh
cd sched && zig build -Dtarget=x86_64-linux --prefix out
out/bin/vh-sched topology                                     # the machine as the scheduler sees it
out/bin/vh-sched lint out/bpf/vh_sched.o                      # no kernel needed
out/bin/vh-sched load out/bpf/vh_sched.o --hold 10 --stats    # as root, on a kernel with CONFIG_SCHED_CLASS_EXT
out/bin/vh-sched run                                          # the service: /usr/local/lib/vh/vh_sched.o, until
                                                              # SIGTERM (exit 0) or the kernel ends it (exit 1)
doas vh-ctl enable vh-sched                                   # under vh-init: rootfs/etc/vh/services/vh-sched.svc
VHL_SMP="sockets=2,cores=2,threads=1" sched/test/run-vm.sh arm64   # the QEMU rig (sched/test/README.md)
```

**Verified** (2026-10-26, the S1 rig: the small 6.18.57 kernels of `sched/test`, QEMU): on arm64
(hvf, 4 CPUs) every program of v1 passes the verifier (584 instructions, 10 programs, the task
storage map), the scheduler runs the whole system (`switch_all=1`), with two `yes` loops every task
goes through our queues (`nr_local` = `nr_enqueue`); with eight runners and a sleeping loop on four
CPUs 2933 of 3187 enqueues got a shortened slice and the sleeping loop was counted interactive 1241
times; the error path, `run` exiting 1 when the kernel ends the scheduler, sysrq-S,
`BPF_LINK_DETACH`, 30 load cycles. Topology: six fixtures in `src/topo.zig` (one LLC, two CCDs,
Intel hybrid, a VM without cache nodes, arm64 big.LITTLE, an offline CPU). On x86_64 with two
sockets (`VHL_SMP=sockets=2,cores=2,threads=1`: two LLCs, the steal path compiled in) the same seven
loads pass under single-threaded TCG (`VH_TEST_EXIT 0`, 30 load/unload cycles, 0 failures): the
loader found the two LLCs by cache, load 2 kept 2368 of 2368 dispatches local with 1902 short slices
and 803 interactive enqueues, and `nr_steal` stayed 0 because both LLCs always had work (the steal
fires only for an empty LLC next to one with `steal_min` or more waiting: [VERIFY] with a load that
empties one LLC). Under multi-threaded TCG (`VHL_TCG_THREAD=multi`, the former default) the second
load crashed the guest with `Oops: int3` in `update_rq_clock` while `scx_root_enable_workfn` was
patching the `scx_enabled` static key, before any program of ours had run for that load: a stale
translated block of QEMU's MTTCG at a text-patching site, not a fault of the scheduler (the same
enable path passed 30 times on arm64 under hvf and on x86_64 under single-threaded TCG); the panic
log is kept as `~/.cache/vhl-s1/serial-x86_64-mttcg-panic.log` and the script now defaults to one
thread. [VERIFY on real x86_64 hardware] the two-LLC run under KVM. **Not verified:** any claim of
speed (docs/ROADMAP.md: faster only by the bench method); the big-core path on a real hybrid CPU;
the fat kernel of `kernel-fat` with the loader; the service under vh-init on the rig. **Not done**
(v2): fairness per session cgroup, a battery mode, frequencies through `cpuperf`.


```
sched/
  build.zig            zig build -Dtarget=x86_64-linux --prefix DIR -> DIR/bin/vh-sched, DIR/bpf/*.o
  bpf/
    bpf.zig            kfuncs as extern symbols, helpers, MapDef, the callback context, constants
    vh_sched.zig       v1: select_cpu, enqueue, dispatch, running, stopping, enable, init_task,
                       cpu_release, init, exit
    tcp_ca_probe.zig   a tcp_congestion_ops struct_ops: the loader mechanics on a kernel without sched_ext
    lockdown_probe.zig a program that needs bpf_probe_read_kernel: must be refused under lockdown
  src/
    main.zig           vh-sched run | load | topology | lint | btf | state
    loader.zig         the generic struct_ops loader (any struct_ops type, by the kernel's BTF)
    topo.zig           the topology from sysfs into Cfg (tested on fixtures)
    lint.zig           the lint of the .o file
    types.zig          the .rodata/.bss/task storage layouts shared by the BPF programs and the loader
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
