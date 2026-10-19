// SPDX-License-Identifier: GPL-2.0-only
//! sched/bpf/lockdown_probe.zig: not a scheduler. One `exit` callback that calls
//! bpf_probe_read_kernel, the helper that lockdown=confidentiality withholds. It must be
//! refused by the verifier on the test kernel: that is the proof that the environment of the
//! spike is really locked down and that vh_sched.o needs nothing the lockdown forbids.
const bpf = @import("bpf.zig");

pub const panic = bpf.panic;

const probe_read_kernel: *align(1) const fn (dst: *anyopaque, size: u32, src: *const anyopaque) callconv(.c) i64 = @ptrFromInt(113);

pub export var sink linksection(".bss") = [_]u64{0};
pub export const _license linksection("license") = "GPL".*;

/// void (*exit)(struct scx_exit_info *info)
export fn vh_exit_probe(ctx: *const bpf.Ctx) linksection("struct_ops/exit") void {
    const ei = ctx.ptr(0, *const bpf.ScxExitInfo);
    var buf: [8]u8 = undefined;
    _ = probe_read_kernel(&buf, 8, ei);
    sink[0] = @as(*align(1) const u64, @ptrCast(&buf)).*;
}
