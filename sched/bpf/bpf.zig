// SPDX-License-Identifier: GPL-2.0-only
//! sched/bpf/bpf.zig: what every BPF program of vh-sched shares. The kfuncs of sched_ext
//! (the 6.13+ names) are extern symbols: LLVM emits `call -1` with a relocation that the
//! loader turns into a kfunc call (src_reg = 2, imm = the BTF id from the running kernel).
//! Helpers are function pointers whose address is the helper number. Maps are `MapDef`
//! values in the `.maps` section, read by the loader.
//!
//! Rules (docs/ROADMAP.md, S): bpfel-freestanding, ReleaseFast (memory safety comes from the
//! verifier); helpers are `inline fn`; never @panic and never reach `unreachable`: LLVM lowers
//! them to a call of `__bpf_trap`, and the 6.18 verifier rejects a program in which that call
//! is reachable. An error is reported with `err()` and the callback returns normally, which is
//! what scx_bpf_error() does in C: the kernel then exits the scheduler with SCX_EXIT_ERROR_BPF.
const std = @import("std");

/// `struct task_struct`: only passed through to kfuncs here
pub const TaskStruct = opaque {};

/// The context of a struct_ops callback: the kernel passes the arguments as an array of
/// 8-byte slots (one per argument, `u64 args[]`), not as the typed arguments; the verifier
/// only allows 8-byte loads at slot offsets and gives each slot the type of the member's
/// prototype (a pointer slot becomes a trusted `task_struct` pointer). This is what the
/// `BPF_PROG` macro hides in C. Read only the slots the callback has arguments for.
pub const Ctx = extern struct {
    a: [6]u64,

    pub inline fn ptr(c: *const Ctx, comptime i: usize, comptime T: type) T {
        return @ptrFromInt(c.a[i]);
    }

    pub inline fn int(c: *const Ctx, comptime i: usize, comptime T: type) T {
        const v = c.a[i];
        return switch (@typeInfo(T).int.bits) {
            64 => @bitCast(v),
            32 => @bitCast(@as(u32, @truncate(v))),
            16 => @bitCast(@as(u16, @truncate(v))),
            else => @bitCast(@as(u8, @truncate(v))),
        };
    }

    pub inline fn boolean(c: *const Ctx, comptime i: usize) bool {
        return c.a[i] != 0;
    }
};

/// the head of `struct scx_exit_info` (kernel/sched/ext_internal.h, 6.18): kind at 0,
/// exit_code at 8, flags at 16; the strings behind it need bpf_probe_read_kernel, which
/// lockdown=confidentiality forbids, so they are not read
pub const ScxExitInfo = extern struct {
    kind: i32,
    _pad: i32,
    exit_code: i64,
    flags: u64,
};

// ---------------------------------------------------------------- kfuncs (kernel/sched/ext.c, ext_idle.c)

pub extern fn scx_bpf_dsq_insert(p: *TaskStruct, dsq_id: u64, slice: u64, enq_flags: u64) void;
pub extern fn scx_bpf_dsq_insert_vtime(p: *TaskStruct, dsq_id: u64, slice: u64, vtime: u64, enq_flags: u64) void;
pub extern fn scx_bpf_dsq_move_to_local(dsq_id: u64) bool;
/// KF_SLEEPABLE: only from a program loaded sleepable (section `struct_ops.s/init`)
pub extern fn scx_bpf_create_dsq(dsq_id: u64, node: i32) i32;
pub extern fn scx_bpf_destroy_dsq(dsq_id: u64) void;
pub extern fn scx_bpf_dsq_nr_queued(dsq_id: u64) i32;
pub extern fn scx_bpf_select_cpu_dfl(p: *TaskStruct, prev_cpu: i32, wake_flags: u64, is_idle: *bool) i32;
pub extern fn scx_bpf_error_bstr(fmt: [*:0]const u8, data: [*]u64, data_sz: u32) void;
pub extern fn scx_bpf_exit_bstr(exit_code: i64, fmt: [*:0]const u8, data: [*]u64, data_sz: u32) void;

/// Report an error to the kernel (SCX_EXIT_ERROR_BPF follows); the caller returns normally.
/// The kfunc takes a non-const `char *fmt`, so the verifier wants writable map memory: the
/// message lives in `.data` (one buffer per message, as the C macro's `static char ___fmt[]`),
/// not in the frozen `.rodata` where a string literal would go.
pub inline fn err(comptime msg: [:0]const u8) void {
    const S = struct {
        var fmt linksection(".data") = msg[0..msg.len :0].*;
    };
    var param: [1]u64 = .{0};
    scx_bpf_error_bstr(&S.fmt, &param, @sizeOf(@TypeOf(param)));
}

// ---------------------------------------------------------------- helpers (enum bpf_func_id)

pub const ringbuf_output: *align(1) const fn (map: *const anyopaque, data: *const anyopaque, size: u64, flags: u64) callconv(.c) i64 = @ptrFromInt(130);
pub const ktime_get_ns: *align(1) const fn () callconv(.c) u64 = @ptrFromInt(5);
pub const get_smp_processor_id: *align(1) const fn () callconv(.c) u32 = @ptrFromInt(8);

// ---------------------------------------------------------------- maps

/// A map definition in the `.maps` section; the loader creates the map and relocates every
/// `ld_imm64` that points at the definition to the map's fd.
pub const MapDef = extern struct {
    type: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
    flags: u32,

    pub const array = 2;
    pub const ringbuf = 27;
};

// ---------------------------------------------------------------- sched_ext constants (include/linux/sched/ext.h)

pub const SCX_SLICE_DFL: u64 = 20 * 1000 * 1000;
pub const SCX_DSQ_FLAG_BUILTIN: u64 = 1 << 63;
pub const SCX_DSQ_INVALID: u64 = SCX_DSQ_FLAG_BUILTIN | 0;
pub const SCX_DSQ_GLOBAL: u64 = SCX_DSQ_FLAG_BUILTIN | 1;
pub const SCX_DSQ_LOCAL: u64 = SCX_DSQ_FLAG_BUILTIN | 2;
pub const SCX_ENQ_WAKEUP: u64 = 1;
pub const SCX_ENQ_PREEMPT: u64 = 1 << 32;

/// Every program root declares `pub const panic = bpf.panic`: the handlers are never
/// referenced in ReleaseFast without an explicit @panic, so nothing of them is emitted.
pub const panic = std.debug.no_panic;

/// Atomic add on a counter in the .bss map (BPF_ATOMIC, -mcpu=v3).
///
/// Atomics on the BPF target (Zig 0.17.0, LLVM 22): an `@atomicRmw` with `.monotonic`
/// ordering is lowered to the plain `lock *(u64 *)(r +off) += r2` without BPF_FETCH, and
/// when its result is used the code goes on with the operand register as if it held the old
/// value, which it does not (measured in spike S1: the counter test never fired). Use
/// `.monotonic` only when the result is discarded, as here; use `.seq_cst` (or `.acq_rel`)
/// for a fetch-and-op whose result is used: those are lowered to the BPF_FETCH forms.
/// `@atomicLoad` does not exist on BPF ("Cannot select AtomicLoad"): read through a
/// `*volatile` pointer instead. The lint flags a non-fetch atomic whose operand register is
/// read afterwards.
pub inline fn count(p: *u64) void {
    _ = @atomicRmw(u64, p, .Add, 1, .monotonic);
}
