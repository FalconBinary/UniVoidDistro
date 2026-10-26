// SPDX-License-Identifier: GPL-2.0-only
//! sched/bpf/vh_sched.zig: vh-sched v1, the scheduler of any topology (docs/uni/ROADMAP.md, U4;
//! docs/ROADMAP.md, S "Policy v1"). One dispatch queue per last-level cache: a task that wakes
//! stays near its cache, a CPU that runs dry takes work from its own LLC first and from another
//! LLC only when enough waits there. Inside an LLC the queue is ordered by virtual time weighted
//! by nice; a task that runs briefly between sleeps (interactive: a compositor, a shell, a game's
//! input thread) may fall behind the LLC's clock by more slices than a CPU hog, so it goes first
//! when it wakes, and the slice of every task shrinks while the LLC is crowded, so nobody waits a
//! whole slice behind a long queue. On a hybrid CPU an interactive task that finds no idle CPU
//! near it takes an idle big core before a crowded small one. Every number about the machine
//! comes from `.rodata`, which the loader fills from sysfs (sched/src/topo.zig); nothing here is
//! a compile-time constant of one machine.
//!
//! Every callback takes the kernel's argument slots (`bpf.Ctx`), one section per callback.
const std = @import("std");
const bpf = @import("bpf.zig");
const types = @import("types");

pub const panic = bpf.panic;

/// `.rodata`: the loader fills it from the topology and `--set`, then freezes it; a `var` so
/// that the compiler cannot fold the defaults into the code
pub export var cfg linksection(".rodata") = blk: {
    var c = std.mem.zeroes(types.Cfg);
    c.slice_ns = bpf.SCX_SLICE_DFL;
    c.slice_min_ns = 1_000_000;
    c.lat_bonus_max = 4;
    c.steal_min = 2;
    c.flags = types.FLAG_PREFER_BIG | types.FLAG_STEAL;
    break :blk c;
};
/// `.bss`: counters and the LLC clocks, read by the loader through the mmap of the map
pub export var stats linksection(".bss") = std.mem.zeroes(types.Stats);
pub export var exit_rb linksection(".maps") = bpf.MapDef{ .type = bpf.MapDef.ringbuf, .key_size = 0, .value_size = 0, .max_entries = 4096, .flags = 0 };
/// the per-task storage: `vh_task_ctx` in the generated BTF (the loader names it for the kernel)
pub export var task_ctx linksection(".maps") = bpf.MapDef{ .type = bpf.MapDef.task_storage, .key_size = 4, .value_size = @sizeOf(types.TaskCtx), .max_entries = 0, .flags = bpf.MapDef.F_NO_PREALLOC };
pub export const _license linksection("license") = "GPL".*;

const llc_mask: u32 = types.max_llcs - 1;
const cpu_mask: u32 = types.max_cpus - 1;

inline fn ctxOf(p: *bpf.TaskStruct) ?*types.TaskCtx {
    const raw = bpf.task_storage_get(&task_ctx, p, null, bpf.LOCAL_STORAGE_GET_F_CREATE) orelse return null;
    return @ptrCast(@alignCast(raw));
}

inline fn llcOf(cpu: i32) u32 {
    const idx: u32 = @as(u32, @bitCast(cpu)) & cpu_mask;
    return @as(u32, cfg.cpu_llc[idx]) & llc_mask;
}

inline fn weightOf(p: *bpf.TaskStruct) u64 {
    const w = bpf.field(u32, p, cfg.off_scx_weight);
    return if (w == 0) 100 else w;
}

/// a task whose runs are short against the slice: it gives the CPU up on its own
inline fn interactive(tc: *const types.TaskCtx) bool {
    return tc.nr_runs >= 2 and tc.avg_run_ns * 4 < cfg.slice_ns;
}

/// s32 (*select_cpu)(struct task_struct *p, s32 prev_cpu, u64 wake_flags)
export fn vh_select_cpu(ctx: *const bpf.Ctx) linksection("struct_ops/select_cpu") i32 {
    const p = ctx.ptr(0, *bpf.TaskStruct);
    const prev_cpu = ctx.int(1, i32);
    const wake_flags = ctx.int(2, u64);
    bpf.count(&stats.nr_select);
    // the kernel's own choice first: the previous CPU if idle, a whole idle core, an idle CPU
    // in the same LLC, then anywhere (kernel/sched/ext_idle.c)
    var is_idle = false;
    const cpu = bpf.scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &is_idle);
    if (is_idle) {
        bpf.count(&stats.nr_direct);
        bpf.scx_bpf_dsq_insert(p, bpf.SCX_DSQ_LOCAL, cfg.slice_ns, 0);
        return cpu;
    }
    // a hybrid CPU: an interactive task that found nothing idle takes an idle big core
    if (cfg.flags & types.FLAG_PREFER_BIG != 0 and cfg.nr_big != 0) {
        if (ctxOf(p)) |tc| {
            if (interactive(tc)) {
                const allowed = bpf.field(*const bpf.Cpumask, p, cfg.off_cpus_ptr);
                var i: u32 = 0;
                while (i < cfg.nr_big and i < types.max_cpus) : (i += 1) {
                    const c: u32 = cfg.big_list[i & cpu_mask];
                    if (!bpf.bpf_cpumask_test_cpu(c, allowed)) continue;
                    if (bpf.scx_bpf_test_and_clear_cpu_idle(@intCast(c))) {
                        bpf.count(&stats.nr_big);
                        bpf.scx_bpf_dsq_insert(p, bpf.SCX_DSQ_LOCAL, cfg.slice_ns, 0);
                        return @intCast(c);
                    }
                }
            }
        }
    }
    return cpu;
}

/// void (*enqueue)(struct task_struct *p, u64 enq_flags)
export fn vh_enqueue(ctx: *const bpf.Ctx) linksection("struct_ops/enqueue") void {
    const p = ctx.ptr(0, *bpf.TaskStruct);
    const enq_flags = ctx.int(1, u64);
    // .seq_cst: a fetch-and-add whose result is used must carry BPF_FETCH (bpf.zig, "atomics")
    const n = @atomicRmw(u64, &stats.nr_enqueue, .Add, 1, .seq_cst) + 1;
    if (cfg.fail_after != 0 and n == cfg.fail_after) {
        bpf.err("vh_sched: fail_after reached");
        return;
    }
    const llc = llcOf(bpf.scx_bpf_task_cpu(p));
    const vnow = bpf.load(&stats.vtime[llc]);
    var vtime = bpf.field(u64, p, cfg.off_scx_dsq_vtime);
    // how far behind the LLC's clock a task may be: one slice, more for an interactive one
    var lag_slices: u64 = 1;
    if (ctxOf(p)) |tc| {
        tc.llc = llc;
        if (interactive(tc)) {
            lag_slices += cfg.lat_bonus_max;
            bpf.count(&stats.nr_interactive);
        }
    }
    const lag_max = cfg.slice_ns * lag_slices;
    if (vnow > lag_max and vtime < vnow - lag_max) vtime = vnow - lag_max;
    // the slice shrinks while more tasks wait in the LLC than it has CPUs
    const queued = bpf.scx_bpf_dsq_nr_queued(llc);
    const nq: u64 = if (queued < 0) 0 else @intCast(queued);
    var ncpus: u64 = cfg.llc_cpus[llc];
    if (ncpus == 0) ncpus = 1;
    var slice = cfg.slice_ns;
    if (nq + 1 > ncpus) {
        slice = cfg.slice_ns * ncpus / (nq + 1);
        if (slice < cfg.slice_min_ns) slice = cfg.slice_min_ns;
        bpf.count(&stats.nr_short_slice);
    }
    bpf.scx_bpf_dsq_insert_vtime(p, llc, slice, vtime, enq_flags);
}

/// void (*dispatch)(s32 cpu, struct task_struct *prev)
export fn vh_dispatch(ctx: *const bpf.Ctx) linksection("struct_ops/dispatch") void {
    const cpu = ctx.int(0, i32);
    bpf.count(&stats.nr_dispatch);
    const llc = llcOf(cpu);
    if (bpf.scx_bpf_dsq_move_to_local(llc)) {
        bpf.count(&stats.nr_local);
        return;
    }
    // the own LLC is empty: another LLC's queue, the next ones in order, only when enough
    // tasks wait there (a single waiting task is better off near its own cache)
    if (cfg.flags & types.FLAG_STEAL != 0 and cfg.nr_llcs > 1) {
        var k: u32 = 1;
        while (k < cfg.nr_llcs and k < types.max_llcs) : (k += 1) {
            const other = (llc + k) % cfg.nr_llcs;
            const queued = bpf.scx_bpf_dsq_nr_queued(other & llc_mask);
            if (queued >= 0 and @as(u32, @intCast(queued)) >= cfg.steal_min) {
                if (bpf.scx_bpf_dsq_move_to_local(other & llc_mask)) {
                    bpf.count(&stats.nr_steal);
                    return;
                }
            }
        }
    }
}

/// void (*running)(struct task_struct *p)
export fn vh_running(ctx: *const bpf.Ctx) linksection("struct_ops/running") void {
    const p = ctx.ptr(0, *bpf.TaskStruct);
    if (ctxOf(p)) |tc| tc.run_start_ns = bpf.ktime_get_ns();
    // the LLC's clock moves forward with the tasks that run on it (never backwards)
    const llc = llcOf(bpf.scx_bpf_task_cpu(p));
    const vt = bpf.field(u64, p, cfg.off_scx_dsq_vtime);
    if (bpf.load(&stats.vtime[llc]) < vt) stats.vtime[llc] = vt;
}

/// void (*stopping)(struct task_struct *p, bool runnable)
export fn vh_stopping(ctx: *const bpf.Ctx) linksection("struct_ops/stopping") void {
    const p = ctx.ptr(0, *bpf.TaskStruct);
    const tc = ctxOf(p) orelse return;
    const t = bpf.ktime_get_ns();
    var used: u64 = 0;
    if (tc.run_start_ns != 0 and t > tc.run_start_ns) used = t - tc.run_start_ns;
    tc.avg_run_ns = (tc.avg_run_ns * 3 + used) / 4;
    tc.nr_runs += 1;
    // the virtual time advances by the CPU time used, inversely to the weight (nice)
    const vt = bpf.field(u64, p, cfg.off_scx_dsq_vtime) + used * 100 / weightOf(p);
    bpf.setField(u64, p, cfg.off_scx_dsq_vtime, vt);
}

/// void (*enable)(struct task_struct *p): the task starts being scheduled by us
export fn vh_enable(ctx: *const bpf.Ctx) linksection("struct_ops/enable") void {
    const p = ctx.ptr(0, *bpf.TaskStruct);
    const llc = llcOf(bpf.scx_bpf_task_cpu(p));
    bpf.setField(u64, p, cfg.off_scx_dsq_vtime, bpf.load(&stats.vtime[llc]));
    if (ctxOf(p)) |tc| {
        tc.avg_run_ns = cfg.slice_ns / 2;
        tc.run_start_ns = 0;
        tc.nr_runs = 0;
        tc.llc = llc;
    }
}

/// s32 (*init_task)(struct task_struct *p, struct scx_init_task_args *args); sleepable
export fn vh_init_task(ctx: *const bpf.Ctx) linksection("struct_ops.s/init_task") i32 {
    const p = ctx.ptr(0, *bpf.TaskStruct);
    if (ctxOf(p) == null) return -12; // -ENOMEM
    return 0;
}

/// void (*cpu_release)(s32 cpu, struct scx_cpu_release_args *args): a higher class (RT,
/// deadline) took the CPU; what waited in its local DSQ goes back to the LLC's queue
export fn vh_cpu_release(ctx: *const bpf.Ctx) linksection("struct_ops/cpu_release") void {
    _ = ctx;
    _ = bpf.scx_bpf_reenqueue_local();
    bpf.count(&stats.nr_reenqueue);
}

/// s32 (*init)(void); sleepable: scx_bpf_create_dsq is KF_SLEEPABLE
export fn vh_init(ctx: *const bpf.Ctx) linksection("struct_ops.s/init") i32 {
    _ = ctx;
    var i: u32 = 0;
    while (i < cfg.nr_llcs and i < types.max_llcs) : (i += 1) {
        const rc = bpf.scx_bpf_create_dsq(i, cfg.llc_node[i & llc_mask]);
        if (rc != 0) {
            stats.init_rc = rc;
            return rc;
        }
    }
    stats.init_rc = 0;
    return 0;
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
