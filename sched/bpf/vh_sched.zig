// SPDX-License-Identifier: GPL-2.0-only
//! sched/bpf/vh_sched.zig: the spike S1 scheduler. The shape of scx_simple: one shared DSQ,
//! a task goes to the local DSQ of an idle CPU when the default selection finds one,
//! otherwise to the shared DSQ; every CPU dispatches from the shared DSQ. Not a policy, a
//! proof that a sched_ext scheduler written in Zig loads and runs. The counters in `stats`
//! and the exit record in the ring buffer are what the loader reports.
//!
//! Every callback takes the kernel's argument slots (`bpf.Ctx`), one section per callback.
const bpf = @import("bpf.zig");
const types = @import("types");

pub const panic = bpf.panic;

/// `.rodata`: the loader fills it from its command line and freezes it; a `var` so that
/// the compiler cannot fold the defaults into the code
pub export var cfg linksection(".rodata") = types.Cfg{ .slice_ns = bpf.SCX_SLICE_DFL, .shared_dsq = 0, .fail_after = 0, .nr_cpus = 0, ._pad = 0 };
/// `.bss`: counters, read by the loader through the mmap of the map
pub export var stats linksection(".bss") = types.Stats{ .nr_select = 0, .nr_direct = 0, .nr_enqueue = 0, .nr_dispatch = 0, .nr_dispatch_hit = 0, .init_rc = 0, .exit_seq = 0, .exit_kind = 0, .exit_code = 0, .exit_flags = 0 };
pub export var exit_rb linksection(".maps") = bpf.MapDef{ .type = bpf.MapDef.ringbuf, .key_size = 0, .value_size = 0, .max_entries = 4096, .flags = 0 };
pub export const _license linksection("license") = "GPL".*;

/// s32 (*select_cpu)(struct task_struct *p, s32 prev_cpu, u64 wake_flags)
export fn vh_select_cpu(ctx: *const bpf.Ctx) linksection("struct_ops/select_cpu") i32 {
    const p = ctx.ptr(0, *bpf.TaskStruct);
    const prev_cpu = ctx.int(1, i32);
    const wake_flags = ctx.int(2, u64);
    var is_idle = false;
    const cpu = bpf.scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &is_idle);
    bpf.count(&stats.nr_select);
    if (is_idle) {
        bpf.count(&stats.nr_direct);
        bpf.scx_bpf_dsq_insert(p, bpf.SCX_DSQ_LOCAL, cfg.slice_ns, 0);
    }
    return cpu;
}

/// void (*enqueue)(struct task_struct *p, u64 enq_flags)
export fn vh_enqueue(ctx: *const bpf.Ctx) linksection("struct_ops/enqueue") void {
    const p = ctx.ptr(0, *bpf.TaskStruct);
    const enq_flags = ctx.int(1, u64);
    // .seq_cst: a fetch-and-add whose result is used must carry BPF_FETCH, and LLVM emits
    // it only for an ordering above .monotonic (bpf.zig, "atomics")
    const n = @atomicRmw(u64, &stats.nr_enqueue, .Add, 1, .seq_cst) + 1;
    if (cfg.fail_after != 0 and n == cfg.fail_after) {
        bpf.err("vh_sched: fail_after reached");
        return;
    }
    bpf.scx_bpf_dsq_insert(p, cfg.shared_dsq, cfg.slice_ns, enq_flags);
}

/// void (*dispatch)(s32 cpu, struct task_struct *prev)
export fn vh_dispatch(ctx: *const bpf.Ctx) linksection("struct_ops/dispatch") void {
    _ = ctx;
    bpf.count(&stats.nr_dispatch);
    if (bpf.scx_bpf_dsq_move_to_local(cfg.shared_dsq)) bpf.count(&stats.nr_dispatch_hit);
}

/// s32 (*init)(void); sleepable: scx_bpf_create_dsq is KF_SLEEPABLE
export fn vh_init(ctx: *const bpf.Ctx) linksection("struct_ops.s/init") i32 {
    _ = ctx;
    const rc = bpf.scx_bpf_create_dsq(cfg.shared_dsq, -1);
    stats.init_rc = rc;
    return rc;
}

/// void (*exit)(struct scx_exit_info *info)
export fn vh_exit(ctx: *const bpf.Ctx) linksection("struct_ops/exit") void {
    const ei = ctx.ptr(0, *const bpf.ScxExitInfo);
    const rec = types.ExitRec{ .kind = ei.kind, .exit_code = ei.exit_code, .flags = ei.flags };
    stats.exit_kind = rec.kind;
    stats.exit_code = rec.exit_code;
    stats.exit_flags = rec.flags;
    bpf.count(&stats.exit_seq);
    _ = bpf.ringbuf_output(&exit_rb, &rec, @sizeOf(types.ExitRec), 0);
}
