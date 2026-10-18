// SPDX-License-Identifier: GPL-2.0-only
//! sched/bpf/tcp_ca_probe.zig: not a scheduler. The smallest valid `tcp_congestion_ops`
//! struct_ops (the kernel needs ssthresh, undo_cwnd and cong_avoid), so that the loader's
//! mechanics (ELF, BTF, maps, struct_ops value, BPF_F_LINK) can be exercised on a kernel
//! without sched_ext: colima's 6.8 on the Mac (docs/ROADMAP.md, "the fast loop on the Mac").
//! It only registers; nothing switches a socket to it.
const bpf = @import("bpf.zig");
const types = @import("types");

pub const panic = bpf.panic;

pub export var stats linksection(".bss") = types.ProbeStats{ .nr_ssthresh = 0, .nr_undo_cwnd = 0, .nr_cong_avoid = 0 };
pub export const _license linksection("license") = "GPL".*;

/// u32 (*ssthresh)(struct sock *sk)
export fn vh_ssthresh(ctx: *const bpf.Ctx) linksection("struct_ops/ssthresh") u32 {
    _ = ctx;
    bpf.count(&stats.nr_ssthresh);
    return 2;
}

/// u32 (*undo_cwnd)(struct sock *sk)
export fn vh_undo_cwnd(ctx: *const bpf.Ctx) linksection("struct_ops/undo_cwnd") u32 {
    _ = ctx;
    bpf.count(&stats.nr_undo_cwnd);
    return 2;
}

/// void (*cong_avoid)(struct sock *sk, u32 ack, u32 acked)
export fn vh_cong_avoid(ctx: *const bpf.Ctx) linksection("struct_ops/cong_avoid") void {
    _ = ctx;
    bpf.count(&stats.nr_cong_avoid);
}
