//! sched/src/topo.zig: the topology of the running machine for vh-sched, from sysfs
//! (docs/uni/ROADMAP.md, U4): which CPUs share a last-level cache, which are the big cores
//! of a hybrid part, the NUMA node of each cache. The loader writes the result into the
//! scheduler's `.rodata` (types.Cfg); one BPF object serves every machine. Everything is read
//! through a `Source`, so the tests run on text fixtures without a /sys.
const std = @import("std");
const mem = std.mem;
const vh = @import("vh");
const types = @import("types.zig");

pub const Source = struct {
    ctx: *const anyopaque,
    /// the trimmed first line of a sysfs file, null when it does not exist
    readFn: *const fn (ctx: *const anyopaque, path: []const u8) ?[]const u8,

    pub fn read(s: Source, path: []const u8) ?[]const u8 {
        return s.readFn(s.ctx, path);
    }

    /// the real /sys
    pub const sysfs: Source = .{ .ctx = undefined, .readFn = readSysfs };
    fn readSysfs(_: *const anyopaque, path: []const u8) ?[]const u8 {
        const v = vh.rd(path);
        if (v.len == 0 and !vh.pathExists(path)) return null;
        return v;
    }
};

pub const Cpu = struct {
    id: u32,
    llc: u32 = 0,
    node: i32 = 0,
    /// 1024 is the biggest core; a homogeneous machine has 1024 everywhere
    capacity: u32 = 1024,
    big: bool = false,
    /// how the LLC was found: a cache level, a cluster, the package
    by: enum { cache, cluster, package } = .package,
};

pub const Topology = struct {
    cpus: []Cpu,
    /// the possible CPUs: the highest online id + 1 (the scheduler indexes by CPU id)
    nr_cpu_ids: u32,
    nr_llcs: u32,
    llc_cpus: [types.max_llcs]u16 = @splat(0),
    llc_node: [types.max_llcs]i32 = @splat(0),
    nr_big: u32 = 0,
    hybrid: bool = false,
    how: []const u8 = "",
};

/// "0-3,8,10-11" -> the ids
pub fn parseList(text: []const u8) []u32 {
    var out: std.ArrayList(u32) = .empty;
    var it = mem.tokenizeAny(u8, text, ", \n\t");
    while (it.next()) |part| {
        if (mem.indexOfScalar(u8, part, '-')) |d| {
            const a = std.fmt.parseInt(u32, part[0..d], 10) catch continue;
            const b = std.fmt.parseInt(u32, part[d + 1 ..], 10) catch continue;
            if (b < a or b - a > types.max_cpus) continue;
            var x = a;
            while (x <= b) : (x += 1) out.append(vh.gpa, x) catch vh.oom();
        } else out.append(vh.gpa, std.fmt.parseInt(u32, part, 10) catch continue) catch vh.oom();
    }
    return out.items;
}

const cpu_root = "/sys/devices/system/cpu";

fn cpuFile(id: u32, name: []const u8) []u8 {
    return vh.fmt("{s}/cpu{d}/{s}", .{ cpu_root, id, name });
}

/// the shared_cpu_list of the highest unified cache level of a CPU (index3 before index2),
/// only when it spans more than the CPU's own SMT siblings; null without cache information
fn llcList(src: Source, id: u32) ?[]const u8 {
    const siblings = src.read(cpuFile(id, "topology/core_cpus_list")) orelse src.read(cpuFile(id, "topology/thread_siblings_list")) orelse "";
    var idx: u32 = 4;
    while (idx > 0) {
        idx -= 1;
        const dir = vh.fmt("cache/index{d}", .{idx});
        const t = src.read(cpuFile(id, vh.fmt("{s}/type", .{dir}))) orelse continue;
        if (!vh.eql(t, "Unified")) continue;
        const list = src.read(cpuFile(id, vh.fmt("{s}/shared_cpu_list", .{dir}))) orelse continue;
        // an L2 private to the core is not a last-level cache shared by anything
        if (parseList(list).len <= parseList(siblings).len) continue;
        return list;
    }
    return null;
}

pub fn detect(src: Source) Topology {
    const online = parseList(src.read(cpu_root ++ "/online") orelse "0");
    var cpus: std.ArrayList(Cpu) = .empty;
    var max_id: u32 = 0;
    for (online) |id| {
        if (id >= types.max_cpus) continue;
        if (id > max_id) max_id = id;
        cpus.append(vh.gpa, .{ .id = id }) catch vh.oom();
    }
    var t: Topology = .{ .cpus = cpus.items, .nr_cpu_ids = max_id + 1, .nr_llcs = 0 };
    // the LLC of each CPU: the key is the list of the CPUs that share it
    var keys: std.ArrayList([]const u8) = .empty;
    var how: @TypeOf(t.cpus[0].by) = .package;
    for (t.cpus) |*c| {
        var key: []const u8 = undefined;
        if (llcList(src, c.id)) |l| {
            key = l;
            c.by = .cache;
        } else if (src.read(cpuFile(c.id, "topology/cluster_cpus_list"))) |cl| {
            // arm64 big.LITTLE without cache nodes: the cluster; x86 reports the cluster as the
            // L2 group, which is the core itself on most parts: then the package below
            key = if (parseList(cl).len > 1) cl else (src.read(cpuFile(c.id, "topology/package_cpus_list")) orelse "all");
            c.by = if (parseList(cl).len > 1) .cluster else .package;
        } else {
            key = src.read(cpuFile(c.id, "topology/package_cpus_list")) orelse "all";
            c.by = .package;
        }
        how = c.by;
        var found: ?u32 = null;
        for (keys.items, 0..) |k, i| if (vh.eql(k, key)) {
            found = @intCast(i);
        };
        if (found == null) {
            if (keys.items.len >= types.max_llcs) {
                found = types.max_llcs - 1;
            } else {
                keys.append(vh.gpa, vh.dupe(key)) catch vh.oom();
                found = @intCast(keys.items.len - 1);
            }
        }
        c.llc = found.?;
        t.llc_cpus[c.llc] += 1;
    }
    t.nr_llcs = @intCast(@max(keys.items.len, 1));
    t.how = @tagName(how);
    // NUMA: the node of each CPU, the node of each LLC (its first CPU's)
    const nodes = parseList(src.read("/sys/devices/system/node/online") orelse "0");
    for (nodes) |n| {
        const list = src.read(vh.fmt("/sys/devices/system/node/node{d}/cpulist", .{n})) orelse continue;
        for (parseList(list)) |id| for (t.cpus) |*c| if (c.id == id) {
            c.node = @intCast(n);
        };
    }
    var seen: [types.max_llcs]bool = @splat(false);
    for (t.cpus) |c| if (!seen[c.llc]) {
        seen[c.llc] = true;
        t.llc_node[c.llc] = c.node;
    };
    // capacity: arm64's cpu_capacity, else the maximum frequency (Intel hybrid: P-cores clock higher)
    var max_cap: u64 = 0;
    var min_cap: u64 = std.math.maxInt(u64);
    var caps = vh.gpa.alloc(u64, t.cpus.len) catch vh.oom();
    var any = false;
    for (t.cpus, 0..) |c, i| {
        var v: u64 = 0;
        if (src.read(cpuFile(c.id, "cpu_capacity"))) |s| {
            v = std.fmt.parseInt(u64, s, 10) catch 0;
        } else if (src.read(cpuFile(c.id, "cpufreq/cpuinfo_max_freq"))) |s| {
            v = std.fmt.parseInt(u64, s, 10) catch 0;
        }
        caps[i] = v;
        if (v != 0) {
            any = true;
            if (v > max_cap) max_cap = v;
            if (v < min_cap) min_cap = v;
        }
    }
    if (any and max_cap > 0) {
        for (t.cpus, 0..) |*c, i| c.capacity = if (caps[i] == 0) 1024 else @intCast(caps[i] * 1024 / max_cap);
        // a difference of more than 5 % between the cores makes the part hybrid: the biggest ones are the big cores
        if (min_cap != std.math.maxInt(u64) and min_cap * 100 < max_cap * 95) {
            t.hybrid = true;
            for (t.cpus) |*c| if (c.capacity >= 1024 * 95 / 100) {
                c.big = true;
                t.nr_big += 1;
            };
        }
    }
    return t;
}

/// the scheduler's view of it
pub fn fill(t: *const Topology, c: *types.Cfg) void {
    c.nr_cpus = t.nr_cpu_ids;
    c.nr_llcs = t.nr_llcs;
    c.cpu_llc = @splat(0);
    c.cpu_big = @splat(0);
    c.big_list = @splat(0);
    c.llc_cpus = t.llc_cpus;
    c.llc_node = t.llc_node;
    var nb: u32 = 0;
    for (t.cpus) |cpu| {
        c.cpu_llc[cpu.id] = @intCast(cpu.llc);
        if (cpu.big) {
            c.cpu_big[cpu.id] = 1;
            c.big_list[nb] = @intCast(cpu.id);
            nb += 1;
        }
    }
    c.nr_big = nb;
    if (!t.hybrid) c.flags &= ~types.FLAG_PREFER_BIG;
}

/// for `vh-sched topology` and the log
pub fn describe(t: *const Topology) []u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(vh.gpa, "{d} CPUs online (ids up to {d}), {d} LLC{s} by {s}{s}\n", .{ t.cpus.len, t.nr_cpu_ids - 1, t.nr_llcs, if (t.nr_llcs == 1) "" else "s", t.how, if (t.hybrid) vh.fmt(", hybrid: {d} big cores", .{t.nr_big}) else "" }) catch vh.oom();
    var l: u32 = 0;
    while (l < t.nr_llcs) : (l += 1) {
        out.print(vh.gpa, "  LLC {d} (node {d}, {d} CPUs):", .{ l, t.llc_node[l], t.llc_cpus[l] }) catch vh.oom();
        for (t.cpus) |c| if (c.llc == l) out.print(vh.gpa, " {d}{s}", .{ c.id, if (t.hybrid and c.big) "B" else if (t.hybrid) "s" else "" }) catch vh.oom();
        out.append(vh.gpa, '\n') catch vh.oom();
    }
    return out.items;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// a sysfs made of (path, content) pairs
const Fake = struct {
    files: []const [2][]const u8,
    fn read(ctx: *const anyopaque, path: []const u8) ?[]const u8 {
        const f: *const Fake = @ptrCast(@alignCast(ctx));
        for (f.files) |kv| if (vh.eql(kv[0], path)) return kv[1];
        return null;
    }
    fn source(f: *const Fake) Source {
        return .{ .ctx = f, .readFn = read };
    }
};

fn cpuEntry(comptime id: u32, comptime name: []const u8, comptime v: []const u8) [2][]const u8 {
    return .{ std.fmt.comptimePrint("/sys/devices/system/cpu/cpu{d}/{s}", .{ id, name }), v };
}

test "cpu lists" {
    const l = parseList("0-3,8,10-11\n");
    try testing.expectEqual(@as(usize, 7), l.len);
    try testing.expectEqual(@as(u32, 11), l[6]);
    try testing.expectEqual(@as(usize, 1), parseList("5").len);
    try testing.expectEqual(@as(usize, 0), parseList("").len);
}

test "6C/12T, one L3: one LLC, no big cores (a laptop with one die)" {
    comptime var files: []const [2][]const u8 = &.{.{ "/sys/devices/system/cpu/online", "0-11" }};
    comptime {
        @setEvalBranchQuota(200_000);
        var i: u32 = 0;
        while (i < 12) : (i += 1) {
            files = files ++ &[_][2][]const u8{
                cpuEntry(i, "topology/core_cpus_list", std.fmt.comptimePrint("{d},{d}", .{ i % 6, i % 6 + 6 })),
                cpuEntry(i, "topology/package_cpus_list", "0-11"),
                cpuEntry(i, "cache/index3/type", "Unified"),
                cpuEntry(i, "cache/index3/shared_cpu_list", "0-11"),
                cpuEntry(i, "cache/index2/type", "Unified"),
                cpuEntry(i, "cache/index2/shared_cpu_list", std.fmt.comptimePrint("{d},{d}", .{ i % 6, i % 6 + 6 })),
                cpuEntry(i, "cpufreq/cpuinfo_max_freq", "4500000"),
            };
        }
    }
    const f: Fake = .{ .files = files };
    const t = detect(f.source());
    try testing.expectEqual(@as(usize, 12), t.cpus.len);
    try testing.expectEqual(@as(u32, 1), t.nr_llcs);
    try testing.expectEqual(@as(u16, 12), t.llc_cpus[0]);
    try testing.expect(!t.hybrid);
    try testing.expectEqualStrings("cache", t.how);
    var c = mem.zeroes(types.Cfg);
    c.flags = types.FLAG_PREFER_BIG | types.FLAG_STEAL;
    fill(&t, &c);
    try testing.expectEqual(@as(u32, 12), c.nr_cpus);
    try testing.expectEqual(@as(u32, 0), c.nr_big);
    try testing.expectEqual(types.FLAG_STEAL, c.flags);
    try testing.expectEqual(@as(u8, 0), c.cpu_llc[11]);
}

test "an AMD part with two CCDs: two LLCs by the L3, nodes" {
    comptime var files: []const [2][]const u8 = &.{ .{ "/sys/devices/system/cpu/online", "0-15" }, .{ "/sys/devices/system/node/online", "0" }, .{ "/sys/devices/system/node/node0/cpulist", "0-15" } };
    comptime {
        @setEvalBranchQuota(200_000);
        var i: u32 = 0;
        while (i < 16) : (i += 1) {
            const ccd = if (i % 8 < 4) "0-3,8-11" else "4-7,12-15";
            files = files ++ &[_][2][]const u8{
                cpuEntry(i, "topology/core_cpus_list", std.fmt.comptimePrint("{d},{d}", .{ i % 8, i % 8 + 8 })),
                cpuEntry(i, "topology/package_cpus_list", "0-15"),
                cpuEntry(i, "cache/index3/type", "Unified"),
                cpuEntry(i, "cache/index3/shared_cpu_list", ccd),
                cpuEntry(i, "cpufreq/cpuinfo_max_freq", "5000000"),
            };
        }
    }
    const f: Fake = .{ .files = files };
    const t = detect(f.source());
    try testing.expectEqual(@as(u32, 2), t.nr_llcs);
    try testing.expectEqual(@as(u16, 8), t.llc_cpus[0]);
    try testing.expectEqual(@as(u16, 8), t.llc_cpus[1]);
    try testing.expectEqual(@as(u32, 0), t.cpus[0].llc);
    try testing.expectEqual(@as(u32, 1), t.cpus[4].llc);
    try testing.expectEqual(@as(u32, 0), t.cpus[9].llc);
    try testing.expect(!t.hybrid);
    const d = describe(&t);
    try testing.expect(mem.indexOf(u8, d, "2 LLCs by cache") != null);
}

test "an Intel hybrid part: the P-cores clock higher and are the big cores" {
    comptime var files: []const [2][]const u8 = &.{.{ "/sys/devices/system/cpu/online", "0-11" }};
    comptime {
        @setEvalBranchQuota(200_000);
        var i: u32 = 0;
        while (i < 12) : (i += 1) {
            // 0-7: four P-cores with SMT (0,1 2,3 ...); 8-11: four E-cores
            const p = i < 8;
            files = files ++ &[_][2][]const u8{
                cpuEntry(i, "topology/core_cpus_list", if (p) std.fmt.comptimePrint("{d}-{d}", .{ i / 2 * 2, i / 2 * 2 + 1 }) else std.fmt.comptimePrint("{d}", .{i})),
                cpuEntry(i, "topology/package_cpus_list", "0-11"),
                cpuEntry(i, "cache/index3/type", "Unified"),
                cpuEntry(i, "cache/index3/shared_cpu_list", "0-11"),
                cpuEntry(i, "cpufreq/cpuinfo_max_freq", if (p) "5000000" else "3800000"),
            };
        }
    }
    const f: Fake = .{ .files = files };
    const t = detect(f.source());
    try testing.expectEqual(@as(u32, 1), t.nr_llcs);
    try testing.expect(t.hybrid);
    try testing.expectEqual(@as(u32, 8), t.nr_big);
    try testing.expect(t.cpus[0].big and !t.cpus[9].big);
    try testing.expectEqual(@as(u32, 3800000 * 1024 / 5000000), t.cpus[9].capacity);
    var c = mem.zeroes(types.Cfg);
    c.flags = types.FLAG_PREFER_BIG;
    fill(&t, &c);
    try testing.expectEqual(@as(u32, 8), c.nr_big);
    try testing.expectEqual(types.FLAG_PREFER_BIG, c.flags);
    try testing.expectEqual(@as(u16, 7), c.big_list[7]);
    try testing.expectEqual(@as(u8, 1), c.cpu_big[3]);
    try testing.expectEqual(@as(u8, 0), c.cpu_big[8]);
}

test "a 4-vCPU VM without cache nodes or cpufreq: one LLC by the package" {
    comptime var files: []const [2][]const u8 = &.{.{ "/sys/devices/system/cpu/online", "0-3" }};
    comptime {
        @setEvalBranchQuota(200_000);
        var i: u32 = 0;
        while (i < 4) : (i += 1) files = files ++ &[_][2][]const u8{ cpuEntry(i, "topology/core_cpus_list", std.fmt.comptimePrint("{d}", .{i})), cpuEntry(i, "topology/package_cpus_list", "0-3") };
    }
    const f: Fake = .{ .files = files };
    const t = detect(f.source());
    try testing.expectEqual(@as(u32, 1), t.nr_llcs);
    try testing.expectEqualStrings("package", t.how);
    try testing.expectEqual(@as(u32, 4), t.nr_cpu_ids);
    try testing.expect(!t.hybrid);
}

test "arm64 big.LITTLE without cache nodes: LLCs by cluster, big cores by cpu_capacity" {
    comptime var files: []const [2][]const u8 = &.{.{ "/sys/devices/system/cpu/online", "0-7" }};
    comptime {
        @setEvalBranchQuota(200_000);
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            const little = i < 4;
            files = files ++ &[_][2][]const u8{
                cpuEntry(i, "topology/core_cpus_list", std.fmt.comptimePrint("{d}", .{i})),
                cpuEntry(i, "topology/cluster_cpus_list", if (little) "0-3" else "4-7"),
                cpuEntry(i, "topology/package_cpus_list", "0-7"),
                cpuEntry(i, "cpu_capacity", if (little) "381" else "1024"),
            };
        }
    }
    const f: Fake = .{ .files = files };
    const t = detect(f.source());
    try testing.expectEqual(@as(u32, 2), t.nr_llcs);
    try testing.expectEqualStrings("cluster", t.how);
    try testing.expect(t.hybrid);
    try testing.expectEqual(@as(u32, 4), t.nr_big);
    try testing.expect(t.cpus[7].big and !t.cpus[0].big);
}

test "a CPU that is offline is not a CPU: ids with a hole" {
    const files = [_][2][]const u8{
        .{ "/sys/devices/system/cpu/online", "0,2" },
        cpuEntry(0, "topology/package_cpus_list", "0-3"),
        cpuEntry(2, "topology/package_cpus_list", "0-3"),
    };
    const f: Fake = .{ .files = &files };
    const t = detect(f.source());
    try testing.expectEqual(@as(usize, 2), t.cpus.len);
    try testing.expectEqual(@as(u32, 3), t.nr_cpu_ids);
    var c = mem.zeroes(types.Cfg);
    fill(&t, &c);
    try testing.expectEqual(@as(u32, 3), c.nr_cpus);
}
