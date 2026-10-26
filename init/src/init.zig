//! vh-init: PID 1 and the service manager in one binary (init/README.md, v0.2).
//!   vh-init                       as PID 1 (init=/usr/local/sbin/vh-init): stage 1, the manager, stage 3
//!   vh-init --manager [-v]        the manager (PID 1 starts it; by hand for a container test)
//!   vh-init --install             init= on the kernel command line of the next UKI and the sv shim
//!   vh-init --rollback            the command line without init=, runit's sv back
//!   vh-init --status              which init is PID 1, the markers of this boot
//!   vh-init --check               the service definitions: parse, the graph, what would start
//!   vh-init --test-pid1 [--dir D] [--no-stage1] [-v]   tests: PID 1 of a container's namespace
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");
const pid1 = @import("pid1.zig");
const manager = @import("manager.zig");
const svc = @import("svc.zig");
const setup = @import("initsetup.zig");

comptime {
    _ = @import("proto.zig");
    _ = @import("spawn.zig");
    _ = @import("log.zig");
    _ = @import("cgroup.zig");
    _ = @import("shutdown.zig");
    _ = @import("stage1.zig");
    _ = @import("ctl.zig");
}

fn usage() noreturn {
    vh.outs(
        \\vh-init: PID 1 and the service manager (UniVoidDistro, init/)
        \\  vh-init --manager [-v] [--dir DIR]   the manager (started by PID 1 as its child)
        \\  vh-init --install | --rollback | --status | --check
        \\  vh-init --test-pid1 [--no-stage1] [--dir DIR] [-v]
        \\
    );
    vh.exit(2);
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "vh-init");
    if (linux.getpid() == 1 and args.len == 0) pid1.main(.{});
    var mode: enum { none, manager, pid1_test, install, rollback, status, check } = .none;
    var o: pid1.Options = .{ .force = true };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (vh.eql(a, "--manager")) {
            mode = .manager;
        } else if (vh.eql(a, "--test-pid1")) {
            mode = .pid1_test;
        } else if (vh.eql(a, "--install")) {
            mode = .install;
        } else if (vh.eql(a, "--rollback")) {
            mode = .rollback;
        } else if (vh.eql(a, "--status")) {
            mode = .status;
        } else if (vh.eql(a, "--check")) {
            mode = .check;
        } else if (vh.eql(a, "--no-stage1")) {
            o.skip_stage1 = true;
        } else if (vh.eql(a, "--dir")) {
            i += 1;
            if (i >= args.len) usage();
            o.extra_dir = args[i];
        } else if (vh.eql(a, "-v")) {
            o.verbose = true;
        } else if (vh.eql(a, "--version")) {
            vh.out("vh-init {s}\n", .{pid1.version});
            vh.exit(0);
        } else usage();
    }
    switch (mode) {
        .none => {
            if (linux.getpid() == 1) pid1.main(o);
            usage();
        },
        .manager => {
            vh.prog = "vh-init manager";
            var m: manager.Manager = .{};
            m.verbose = o.verbose;
            m.extra_dir = o.extra_dir;
            // fd 3 is the channel from PID 1 (a socketpair) when it started us
            if (isSocket(3)) m.pid1_fd = 3;
            m.run();
        },
        .pid1_test => pid1.main(o),
        .install => vh.exit(setup.install()),
        .rollback => vh.exit(setup.rollback()),
        .status => vh.exit(setup.status()),
        .check => vh.exit(check(o.extra_dir)),
    }
}

fn isSocket(fd: linux.fd_t) bool {
    const st = vh.fstat(fd) catch return false;
    return st.mode & vh.S.IFMT == vh.S.IFSOCK;
}

/// the definitions as the manager would read them, and the start order
fn check(extra: ?[]const u8) u8 {
    var m: manager.Manager = .{};
    m.extra_dir = extra;
    const defs = m.loadDefinitions();
    var g: svc.Graph = .{ .services = defs };
    const problems = svc.resolve(&g);
    for (problems) |p| vh.out("problem: {s} {s} {s}\n", .{ p.service, p.what, p.other });
    const order = svc.startOrder(&g);
    vh.out("{d} services, start order:\n", .{defs.len});
    for (order) |idx| {
        const s = g.services[idx];
        vh.out("  {s: <20} {s: <8} ready={s: <8} restart={s: <10} {s}{s}{s}\n", .{ s.name, @tagName(s.kind), @tagName(s.ready), @tagName(s.restart), if (s.down) "down " else "", if (s.log == .runit) "runit-log " else "", s.source });
        if (s.needs.len > 0 or s.after.len > 0) {
            vh.out("      ", .{});
            if (s.needs.len > 0) {
                vh.out("needs:", .{});
                for (s.needs) |n| vh.out(" {s}", .{n});
            }
            if (s.after.len > 0) {
                vh.out(" after:", .{});
                for (s.after) |a| vh.out(" {s}", .{a});
            }
            vh.out("\n", .{});
        }
    }
    return if (problems.len > 0) 1 else 0;
}
