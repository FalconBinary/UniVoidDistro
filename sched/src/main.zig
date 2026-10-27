//! vh-sched: the loader of the sched_ext scheduler written in Zig (sched/README.md).
//!
//!   vh-sched run [options]            the service: load vh_sched.o for this machine's topology,
//!                                     hold the link; exit 1 when the kernel ends the scheduler
//!                                     (vh-init starts it again), 0 on SIGTERM
//!   vh-sched load FILE.o [options]    load any struct_ops object, hold the link, report (tests)
//!       --ops TYPE          the kernel struct (sched_ext_ops; tcp_congestion_ops for the probe)
//!       --name NAME         the struct_ops name (vh_sched)
//!       --set SYM.FIELD=N   a value in .rodata before it is frozen (cfg.fail_after=100)
//!       --flags N           sched_ext_ops.flags
//!       --hold SECONDS      how long the link is held (5; run: until the end)
//!       --stats [S]         print the .bss counters every S seconds (1; run: 600)
//!       --detach-after S    BPF_LINK_DETACH after S seconds (the link fd poll test)
//!       --sysrq-after S     write S to /proc/sysrq-trigger after S seconds (the reset test)
//!       --vmlinux PATH      the kernel BTF (/sys/kernel/btf/vmlinux)
//!       --object PATH       run: the object (/usr/local/lib/vh/vh_sched.o)
//!       --ready-fd N        run: a line to fd N and close it once the scheduler runs (vh-init's
//!                           ready = fd N; s6 and dinit do the same)
//!       --topology DIR      a sysfs root for the topology (tests)
//!       --log-level N       verifier log level (1)
//!       --verbose           every step
//!   vh-sched topology                 the topology as the scheduler will see it
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
const topo = @import("topo.zig");

pub const version = "1.0.0";
pub const default_object = "/usr/local/lib/vh/vh_sched.o";

/// the BTF of the maps' values, generated at compile time from the Zig types with C names
const own_btf_blob = blk: {
    @setEvalBranchQuota(2_000_000);
    var b: btf.Builder = .{};
    _ = b.add(u32);
    _ = b.add(i32);
    _ = b.add(types.Cfg);
    _ = b.add(types.Stats);
    _ = b.add(types.TaskCtx);
    _ = b.add(types.ExitRec);
    _ = b.add(types.ProbeStats);
    break :blk b.finish();
};
const own_btf: []const u8 = &own_btf_blob;

const scx_sections = [_]loader.SectionType{ .{ .section = ".rodata", .type_name = "vh_cfg" }, .{ .section = ".bss", .type_name = "vh_stats" } };
const scx_maps = [_]loader.MapTypeDef{.{ .map = "task_ctx", .key = "int", .value = "vh_task_ctx" }};
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
        loadCmd(args[1..], false);
    } else if (vh.eql(cmd, "run")) {
        loadCmd(args[1..], true);
    } else if (vh.eql(cmd, "topology")) {
        var dir: []const u8 = "";
        if (args.len >= 3 and vh.eql(args[1], "--topology")) dir = args[2];
        const t = topo.detect(sourceFor(dir));
        vh.outs(topo.describe(&t));
        vh.flush();
    } else if (vh.eql(cmd, "btf")) {
        vh.writeAllFd(1, own_btf) catch {};
    } else if (vh.eql(cmd, "state")) {
        printState();
    } else if (vh.eql(cmd, "--version")) {
        vh.out("vh-sched {s}\n", .{version});
    } else usage();
    vh.exit(0);
}

fn usage() noreturn {
    vh.writeAllFd(2, "vh-sched run [--object PATH] [--ready-fd N] [--set SYM.FIELD=N] [--stats [S]] [--vmlinux PATH] [--topology DIR] [--verbose]\nvh-sched load FILE.o [--ops TYPE] [--name NAME] [--set SYM.FIELD=N] [--flags N] [--hold S] [--stats [S]] [--detach-after S] [--sysrq-after S] [--vmlinux PATH] [--topology DIR] [--log-level N] [--verbose]\nvh-sched topology [--topology DIR] | lint FILE.o | btf | state\n") catch {};
    vh.exit(2);
}

/// the topology source: /sys, or a directory laid out like it (tests)
const DirSource = struct {
    root: []const u8,
    fn read(ctx: *const anyopaque, path: []const u8) ?[]const u8 {
        const d: *const DirSource = @ptrCast(@alignCast(ctx));
        const full = vh.fmt("{s}{s}", .{ d.root, path });
        if (!vh.pathExists(full)) return null;
        return vh.rd(full);
    }
};

fn sourceFor(dir: []const u8) topo.Source {
    if (dir.len == 0) return topo.Source.sysfs;
    const d = vh.gpa.create(DirSource) catch vh.oom();
    d.* = .{ .root = vh.dupe(dir) };
    return .{ .ctx = d, .readFn = DirSource.read };
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

/// Prints the integer fields of an extern struct from the bytes of its map (arrays are skipped).
fn printStruct(comptime T: type, bytes: []const u8, prefix: []const u8) void {
    if (bytes.len < @sizeOf(T)) return;
    vh.out("{s}", .{prefix});
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, FT| {
        if (@typeInfo(FT) == .int) {
            const off = @offsetOf(T, fname);
            const v = mem.readInt(FT, bytes[off..][0..@sizeOf(FT)], .little);
            if (fname[0] != '_') vh.out(" {s}={d}", .{ fname, v });
        }
    }
    vh.out("\n", .{});
    vh.flush();
}

/// the initial bytes of a `.rodata` symbol of the object (the defaults compiled into it)
fn rodataSymbol(o: elf.Object, symbol: []const u8) ?[]const u8 {
    const idx = o.findSection(".rodata") orelse return null;
    const data = o.sectionData(idx);
    for (o.symtab) |s| {
        if (s.shndx != idx or s.kind() != elf.STT_OBJECT or !vh.eql(o.symName(s), symbol)) continue;
        if (s.value + s.size > data.len) return null;
        return data[s.value .. s.value + s.size];
    }
    return null;
}

/// the `task_struct` offsets the scheduler reads, from the running kernel's BTF
const Offsets = struct { weight: u32, dsq_vtime: u32, slice: u32, cpus_ptr: u32 };

fn taskOffsets(vm: btf.Btf) ?Offsets {
    const ts = vm.find(.@"struct", "task_struct") orelse return null;
    const scx = vm.member(ts, "scx") orelse return null;
    const sxe = vm.resolve(scx.type);
    const w = vm.member(sxe, "weight") orelse return null;
    const vt = vm.member(sxe, "dsq_vtime") orelse return null;
    const sl = vm.member(sxe, "slice") orelse return null;
    const cp = vm.member(ts, "cpus_ptr") orelse return null;
    return .{
        .weight = scx.bit_offset / 8 + w.bit_offset / 8,
        .dsq_vtime = scx.bit_offset / 8 + vt.bit_offset / 8,
        .slice = scx.bit_offset / 8 + sl.bit_offset / 8,
        .cpus_ptr = cp.bit_offset / 8,
    };
}

/// the scheduler's configuration for this machine: the object's defaults, the topology, the offsets
fn machineCfg(o: elf.Object, vm: btf.Btf, t: *const topo.Topology) types.Cfg {
    const raw = rodataSymbol(o, "cfg") orelse vh.die("the object has no .rodata symbol cfg", .{});
    if (raw.len != @sizeOf(types.Cfg)) vh.die("the object's cfg has {d} bytes, this loader's vh_cfg {d}: the object and the loader are not of the same build", .{ raw.len, @sizeOf(types.Cfg) });
    var c = mem.bytesToValue(types.Cfg, raw[0..@sizeOf(types.Cfg)]);
    topo.fill(t, &c);
    const off = taskOffsets(vm) orelse vh.die("the kernel's BTF has no task_struct.scx with weight, dsq_vtime and slice, or no cpus_ptr: no sched_ext in this kernel", .{});
    c.off_scx_weight = off.weight;
    c.off_scx_dsq_vtime = off.dsq_vtime;
    c.off_scx_slice = off.slice;
    c.off_cpus_ptr = off.cpus_ptr;
    return c;
}

fn loadCmd(args: []const [:0]const u8, service: bool) void {
    var file: []const u8 = if (service) default_object else "";
    var opts: loader.Options = .{ .own_btf = own_btf };
    var patches: std.ArrayList(loader.Patch) = .empty;
    var hold_s: u64 = if (service) std.math.maxInt(u64) else 5;
    var stats = service;
    var stats_every: i64 = if (service) 600 else 1;
    var detach_after: ?u64 = null;
    var sysrq_after: ?u64 = null;
    var vmlinux_path: []const u8 = "/sys/kernel/btf/vmlinux";
    var topo_dir: []const u8 = "";
    var ready_fd: ?linux.fd_t = null;
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
            if (i + 1 < args.len and args[i + 1].len > 0 and std.ascii.isDigit(args[i + 1][0])) stats_every = @intCast(num(arg(args, &i)));
        } else if (vh.eql(a, "--detach-after")) {
            detach_after = num(arg(args, &i));
        } else if (vh.eql(a, "--sysrq-after")) {
            sysrq_after = num(arg(args, &i));
        } else if (vh.eql(a, "--vmlinux")) {
            vmlinux_path = arg(args, &i);
        } else if (vh.eql(a, "--object")) {
            file = arg(args, &i);
        } else if (vh.eql(a, "--topology")) {
            topo_dir = arg(args, &i);
        } else if (vh.eql(a, "--ready-fd")) {
            ready_fd = @intCast(num(arg(args, &i)));
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
    if (is_scx) opts.map_types = &scx_maps;
    if (!is_scx and vh.eql(opts.name, "vh_sched")) opts.name = "vh_probe";

    var sa = mem.zeroes(linux.Sigaction);
    sa.handler = .{ .handler = onTerm };
    _ = linux.sigaction(.TERM, &sa, null);
    _ = linux.sigaction(.INT, &sa, null);

    const obj = vh.readFile(file) catch vh.die("{s}: {s}", .{ file, vh.serr() });
    const vmlinux = vh.readFile(vmlinux_path) catch vh.die("{s}: {s}", .{ vmlinux_path, vh.serr() });
    vh.log("object {s}: {d} bytes; kernel BTF {s}: {d} bytes; generated BTF: {d} bytes", .{ file, obj.len, vmlinux_path, vmlinux.len, own_btf.len });

    // the machine: the topology into cfg, the task_struct offsets from the kernel's BTF
    var cfg_bytes: [@sizeOf(types.Cfg)]u8 = undefined;
    if (is_scx) {
        const o = elf.Object.parse(obj) catch |e| vh.die("{s}: {s}", .{ file, @errorName(e) });
        const vm = btf.Btf.parse(vh.gpa, vmlinux) catch |e| vh.die("{s}: {s}", .{ vmlinux_path, @errorName(e) });
        // an object without the scheduler's cfg (the lockdown probe) loads as it is
        if (rodataSymbol(o, "cfg") != null) {
            const t = topo.detect(sourceFor(topo_dir));
            const c = machineCfg(o, vm, &t);
            vh.log("topology: {s}", .{mem.trimEnd(u8, topo.describe(&t), "\n")});
            vh.log("task_struct offsets: scx.weight {d}, scx.dsq_vtime {d}, scx.slice {d}, cpus_ptr {d}; slice {d} us, min {d} us, lag bonus {d}, steal from {d}, flags {d}", .{ c.off_scx_weight, c.off_scx_dsq_vtime, c.off_scx_slice, c.off_cpus_ptr, c.slice_ns / 1000, c.slice_min_ns / 1000, c.lat_bonus_max, c.steal_min, c.flags });
            cfg_bytes = mem.toBytes(c);
            opts.rodata_init = .{ .symbol = "cfg", .bytes = &cfg_bytes };
        }
    }

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
    if (ready_fd) |fd| {
        // the service manager's readiness pipe (vh-sched.svc: ready = fd 3, --ready-fd 3): a line
        // once the scheduler runs. The kernel enables it after the link is attached, in a work item
        // (scx_root_enable_workfn); /sys/kernel/sched_ext/state says enabling until then
        if (is_scx) {
            var waited_ms: u32 = 0;
            while (waited_ms < 5000 and !vh.eql(sysfs("/sys/kernel/sched_ext/state"), "enabled")) : (waited_ms += 50) {
                const ts: linux.timespec = .{ .sec = 0, .nsec = 50_000_000 };
                _ = linux.nanosleep(&ts, null);
            }
            if (waited_ms > 0) printState();
        }
        _ = linux.write(fd, "\n", 1);
        _ = linux.close(fd);
    }

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
    while (!terminated and !(service and exit_seen)) {
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
        if (stats and nowMs() - last_stats >= stats_every * 1000) {
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
    if (service and exit_seen) {
        // the kernel ended the scheduler (an error, sysrq-S): its own scheduler runs now; vh-init
        // starts us again with a backoff
        vh.close(l.link_fd);
        vh.warn("the kernel ended the scheduler: exiting 1 so that the service is started again", .{});
        vh.exit(1);
    }
    if (!exit_seen) vh.log("no exit record while the link was held; link fd poll revents 0x{x}", .{@as(u16, @bitCast(link_revents))});

    // closing the link unregisters the scheduler: the exit callback runs once more
    vh.close(l.link_fd);
    vh.log("link closed{s}", .{if (terminated) " (signal)" else ""});
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
    _ = topo;
}

test "the cfg of the object and of the loader are the same type" {
    try std.testing.expect(@sizeOf(types.Cfg) % 8 == 0);
    try std.testing.expect(@sizeOf(types.TaskCtx) == 32);
}
