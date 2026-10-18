//! vh-sched: the loader of the sched_ext scheduler written in Zig (sched/README.md).
//!
//!   vh-sched load FILE.o [options]    load a struct_ops object, hold the link, report
//!       --ops TYPE          the kernel struct (sched_ext_ops; tcp_congestion_ops for the probe)
//!       --name NAME         the struct_ops name (vh_sched)
//!       --set SYM.FIELD=N   a value in .rodata before it is frozen (cfg.fail_after=100)
//!       --flags N           sched_ext_ops.flags
//!       --hold SECONDS      how long the link is held (5)
//!       --stats             print the .bss counters every second
//!       --detach-after S    BPF_LINK_DETACH after S seconds (the link fd poll test)
//!       --sysrq-after S     write S to /proc/sysrq-trigger after S seconds (the reset test)
//!       --vmlinux PATH      the kernel BTF (/sys/kernel/btf/vmlinux)
//!       --log-level N       verifier log level (1)
//!       --verbose           every step
//!   vh-sched lint FILE.o              the lint of the object (no kernel needed)
//!   vh-sched btf > own.btf            the generated BTF, for bpftool
//!   vh-sched state                    /sys/kernel/sched_ext
const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;
const vh = @import("vh");
const uapi = @import("bpf_uapi");
const btf = @import("btf");
const elf = @import("elf");
const loader = @import("loader.zig");
const lint = @import("lint.zig");
const types = @import("types.zig");

/// the BTF of the maps' values, generated at compile time from the Zig types with C names
const own_btf_blob = blk: {
    @setEvalBranchQuota(1_000_000);
    var b: btf.Builder = .{};
    _ = b.add(u32);
    _ = b.add(types.Cfg);
    _ = b.add(types.Stats);
    _ = b.add(types.ExitRec);
    _ = b.add(types.ProbeStats);
    break :blk b.finish();
};
const own_btf: []const u8 = &own_btf_blob;

const scx_sections = [_]loader.SectionType{ .{ .section = ".rodata", .type_name = "vh_cfg" }, .{ .section = ".bss", .type_name = "vh_stats" } };
const probe_sections = [_]loader.SectionType{.{ .section = ".bss", .type_name = "vh_probe_stats" }};

var terminated = false;

fn onTerm(_: linux.SIG) callconv(.c) void {
    terminated = true;
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "vh-sched");
    if (args.len == 0) usage();
    const cmd = args[0];
    if (vh.eql(cmd, "lint")) {
        if (args.len < 2) usage();
        const data = vh.readFile(args[1]) catch vh.die("{s}: {s}", .{ args[1], vh.serr() });
        const o = elf.Object.parse(data) catch |e| vh.die("{s}: {s}", .{ args[1], @errorName(e) });
        const rep = lint.run(o);
        vh.exit(if (rep.errors > 0) 1 else 0);
    } else if (vh.eql(cmd, "load")) {
        loadCmd(args[1..]);
    } else if (vh.eql(cmd, "btf")) {
        vh.writeAllFd(1, own_btf) catch {};
    } else if (vh.eql(cmd, "state")) {
        printState();
    } else usage();
    vh.exit(0);
}

fn usage() noreturn {
    vh.writeAllFd(2, "vh-sched load FILE.o [--ops TYPE] [--name NAME] [--set SYM.FIELD=N] [--flags N] [--hold S] [--stats] [--detach-after S] [--sysrq-after S] [--vmlinux PATH] [--log-level N] [--verbose]\nvh-sched lint FILE.o | btf | state\n") catch {};
    vh.exit(2);
}

fn sysfs(path: []const u8) []const u8 {
    const s = vh.readFile(path) catch return "(absent)";
    return vh.strip(s);
}

fn printState() void {
    vh.log("sched_ext: state={s} switch_all={s} enable_seq={s} nr_rejected={s} root/ops={s}", .{
        sysfs("/sys/kernel/sched_ext/state"),
        sysfs("/sys/kernel/sched_ext/switch_all"),
        sysfs("/sys/kernel/sched_ext/enable_seq"),
        sysfs("/sys/kernel/sched_ext/nr_rejected"),
        sysfs("/sys/kernel/sched_ext/root/ops"),
    });
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn arg(args: []const [:0]const u8, i: *usize) []const u8 {
    i.* += 1;
    if (i.* >= args.len) usage();
    return args[i.*];
}

fn num(s: []const u8) u64 {
    const v = vh.parseLong(s) orelse vh.die("not a number: {s}", .{s});
    if (v < 0) vh.die("not a number: {s}", .{s});
    return @intCast(v);
}

/// Prints the fields of an extern struct from the bytes of its map.
fn printStruct(comptime T: type, bytes: []const u8, prefix: []const u8) void {
    if (bytes.len < @sizeOf(T)) return;
    vh.out("{s}", .{prefix});
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, FT| {
        const off = @offsetOf(T, fname);
        const v = mem.readInt(FT, bytes[off..][0..@sizeOf(FT)], .little);
        if (fname[0] != '_') vh.out(" {s}={d}", .{ fname, v });
    }
    vh.out("\n", .{});
    vh.flush();
}

fn loadCmd(args: []const [:0]const u8) void {
    var file: []const u8 = "";
    var opts: loader.Options = .{ .own_btf = own_btf };
    var patches: std.ArrayList(loader.Patch) = .empty;
    var hold_s: u64 = 5;
    var stats = false;
    var detach_after: ?u64 = null;
    var sysrq_after: ?u64 = null;
    var vmlinux_path: []const u8 = "/sys/kernel/btf/vmlinux";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (vh.eql(a, "--ops")) {
            opts.ops_type = arg(args, &i);
        } else if (vh.eql(a, "--name")) {
            opts.name = arg(args, &i);
        } else if (vh.eql(a, "--set")) {
            const spec = arg(args, &i);
            const dot = mem.indexOfScalar(u8, spec, '.') orelse usage();
            const eq = mem.indexOfScalarPos(u8, spec, dot, '=') orelse usage();
            patches.append(vh.gpa, .{ .symbol = spec[0..dot], .field = spec[dot + 1 .. eq], .value = num(spec[eq + 1 ..]) }) catch vh.oom();
        } else if (vh.eql(a, "--flags")) {
            opts.ops_flags = num(arg(args, &i));
        } else if (vh.eql(a, "--hold")) {
            hold_s = num(arg(args, &i));
        } else if (vh.eql(a, "--stats")) {
            stats = true;
        } else if (vh.eql(a, "--detach-after")) {
            detach_after = num(arg(args, &i));
        } else if (vh.eql(a, "--sysrq-after")) {
            sysrq_after = num(arg(args, &i));
        } else if (vh.eql(a, "--vmlinux")) {
            vmlinux_path = arg(args, &i);
        } else if (vh.eql(a, "--log-level")) {
            opts.log_level = @intCast(num(arg(args, &i)));
        } else if (vh.eql(a, "--verbose")) {
            opts.verbose = true;
        } else if (a.len > 0 and a[0] == '-') {
            usage();
        } else file = a;
    }
    if (file.len == 0) usage();
    opts.patches = patches.items;
    const is_scx = vh.eql(opts.ops_type, "sched_ext_ops");
    opts.section_types = if (is_scx) &scx_sections else if (vh.eql(opts.ops_type, "tcp_congestion_ops")) &probe_sections else &.{};
    if (!is_scx and vh.eql(opts.name, "vh_sched")) opts.name = "vh_probe";

    var sa = mem.zeroes(linux.Sigaction);
    sa.handler = .{ .handler = onTerm };
    _ = linux.sigaction(.TERM, &sa, null);
    _ = linux.sigaction(.INT, &sa, null);

    const obj = vh.readFile(file) catch vh.die("{s}: {s}", .{ file, vh.serr() });
    const vmlinux = vh.readFile(vmlinux_path) catch vh.die("{s}: {s}", .{ vmlinux_path, vh.serr() });
    vh.log("object {s}: {d} bytes; kernel BTF {s}: {d} bytes; generated BTF: {d} bytes", .{ file, obj.len, vmlinux_path, vmlinux.len, own_btf.len });
    const t_load = nowMs();
    var l = loader.load(obj, vmlinux, opts) catch vh.exit(1);
    const t_loaded = nowMs();

    // the report of the load
    var total_processed: u32 = 0;
    for (l.progs) |p| {
        total_processed += p.insn_processed;
        vh.log("program {s} -> {s}.{s} (member {d}{s}): fd {d}, {d} insns, insn_processed {d}", .{ p.func, opts.ops_type, p.member, p.member_index, if (p.sleepable) ", sleepable" else "", p.fd, p.insn_cnt, p.insn_processed });
        if (opts.verbose) {
            vh.outs(p.log);
            vh.outs("\n");
        }
    }
    vh.log("loaded in {d} ms: {d} programs, insn_processed {d} in all, link fd {d}", .{ t_loaded - t_load, l.progs.len, total_processed, l.link_fd });
    if (loader.linkInfo(l.link_fd)) |info| {
        vh.log("link: type {d} (struct_ops = {d}), id {d}, map id {d}", .{ info.type, uapi.link_type_struct_ops, info.id, info.u.struct_ops.map_id });
    } else |_| vh.warn("BPF_OBJ_GET_INFO_BY_FD on the link: {s}", .{@tagName(uapi.errno)});
    if (is_scx) printState();

    // the ring buffer of exit records and the counters
    var rb: ?loader.Ringbuf = null;
    if (l.map("exit_rb")) |m| rb = loader.Ringbuf.open(m.fd, m.size) catch null;
    const bss: []const u8 = if (l.map(".bss")) |m| m.mem else &.{};
    const exit_kind_enum = l.vmlinux.find(.@"enum", "scx_exit_kind");

    var pfds = [_]linux.pollfd{
        .{ .fd = l.link_fd, .events = linux.POLL.IN | linux.POLL.PRI },
        .{ .fd = if (rb) |r| r.fd else -1, .events = linux.POLL.IN },
    };
    const t0 = nowMs();
    var last_stats: i64 = t0;
    var link_revents: i16 = 0;
    var detached = false;
    var sysrq_done = false;
    var exit_seen = false;
    var rec_buf: [256]u8 = undefined;
    while (!terminated) {
        const el: u64 = @intCast(@divTrunc(nowMs() - t0, 1000));
        if (el >= hold_s) break;
        pfds[0].revents = 0;
        pfds[1].revents = 0;
        const rc = linux.poll(&pfds, pfds.len, 1000);
        if (linux.errno(rc) != .SUCCESS and linux.errno(rc) != .INTR) vh.die("poll: {s}", .{@tagName(linux.errno(rc))});
        if (pfds[0].revents != 0 and pfds[0].revents != link_revents) {
            link_revents = pfds[0].revents;
            vh.log("link fd: poll revents 0x{x}{s}{s}{s} at {d} ms", .{ @as(u16, @bitCast(link_revents)), if (link_revents & linux.POLL.HUP != 0) " HUP" else "", if (link_revents & linux.POLL.ERR != 0) " ERR" else "", if (link_revents & linux.POLL.IN != 0) " IN" else "", nowMs() - t0 });
            // a level-triggered HUP would spin: stop polling the link once it reports
            pfds[0].fd = -1;
        }
        if (rb) |*r| {
            while (r.next(&rec_buf)) |rec| {
                if (rec.len >= @sizeOf(types.ExitRec)) {
                    const e = mem.bytesToValue(types.ExitRec, rec[0..@sizeOf(types.ExitRec)]);
                    const kname = if (exit_kind_enum) |id| (l.vmlinux.enumName(id, e.kind) orelse "?") else "?";
                    vh.log("exit record from the ring buffer at {d} ms: kind {d} ({s}), exit_code {d}, flags 0x{x}", .{ nowMs() - t0, e.kind, kname, e.exit_code, e.flags });
                    exit_seen = true;
                } else vh.log("ring buffer record of {d} bytes", .{rec.len});
            }
        }
        if (stats and nowMs() - last_stats >= 1000) {
            last_stats = nowMs();
            if (is_scx) printStruct(types.Stats, bss, "stats:") else printStruct(types.ProbeStats, bss, "stats:");
        }
        if (sysrq_after) |s| if (!sysrq_done and el >= s) {
            sysrq_done = true;
            const ok = vh.writeStr("/proc/sysrq-trigger", "S");
            vh.log("sysrq S written: {s} (kernel.sysrq = {s})", .{ if (ok) "yes" else "no", sysfs("/proc/sys/kernel/sysrq") });
        };
        if (detach_after) |s| if (!detached and el >= s) {
            detached = true;
            if (loader.linkDetach(l.link_fd)) |_| {
                vh.log("BPF_LINK_DETACH at {d} ms: ok", .{nowMs() - t0});
            } else |_| vh.log("BPF_LINK_DETACH: {s}", .{@tagName(uapi.errno)});
        };
    }
    if (is_scx) {
        printStruct(types.Stats, bss, "stats:");
        printState();
    } else printStruct(types.ProbeStats, bss, "stats:");
    if (!exit_seen) vh.log("no exit record while the link was held; link fd poll revents 0x{x}", .{@as(u16, @bitCast(link_revents))});

    // closing the link unregisters the scheduler: the exit callback runs once more
    vh.close(l.link_fd);
    vh.log("link closed", .{});
    const t_close = nowMs();
    while (rb != null and nowMs() - t_close < 2000) {
        var rpfd = [_]linux.pollfd{.{ .fd = rb.?.fd, .events = linux.POLL.IN }};
        _ = linux.poll(&rpfd, 1, 200);
        var got = false;
        while (rb.?.next(&rec_buf)) |rec| {
            got = true;
            if (rec.len >= @sizeOf(types.ExitRec)) {
                const e = mem.bytesToValue(types.ExitRec, rec[0..@sizeOf(types.ExitRec)]);
                const kname = if (exit_kind_enum) |id| (l.vmlinux.enumName(id, e.kind) orelse "?") else "?";
                vh.log("exit record after close: kind {d} ({s}), exit_code {d}, flags 0x{x}", .{ e.kind, kname, e.exit_code, e.flags });
            }
        }
        if (got) break;
    }
    if (is_scx) printState();
}

test {
    _ = loader;
}
