//! vh-init: the service model. A service is either a `.svc` file of /etc/vh/services
//! (`key = value`, the native format) or a runit service directory (/etc/sv/NAME with `run`,
//! `log/run`, `check`, `finish`, `down`), enabled by a link in /var/service (both kinds) or in
//! /etc/vh/services/enabled (`.svc` only). A `.svc` of the same name as an enabled runit
//! directory says how that service runs; the runit directory stays the fallback for runit.
//! This file holds the data and the pure logic: parsing, the dependency graph, the start
//! order, durations. Nothing here touches the system; the tests run on any machine.
const std = @import("std");
const mem = std.mem;
const vh = @import("vh");

pub const svc_dir = "/etc/vh/services";
pub const enabled_dir = "/etc/vh/services/enabled";
pub const runit_dir = "/var/service";

pub const Kind = enum { longrun, oneshot };
pub const Restart = enum { always, @"on-failure", no };
pub const Sched = enum { normal, batch, idle };
pub const Log = enum { file, kmsg, none, runit };

/// how the manager learns that a service is up (s6 and dinit have the same four)
pub const Ready = union(enum) {
    /// right after exec succeeded (the runit assumption)
    started,
    /// a oneshot: when it has exited 0
    exit,
    /// the program writes a line to this fd and closes it (s6 notification, dinit pipefd)
    fd: u8,
    /// the path exists (a unix socket, a pid file)
    socket: []const u8,
    /// runit's ./check exits 0
    check: []const u8,
};

pub const Service = struct {
    name: []const u8,
    /// where it comes from, for messages
    source: []const u8 = "",
    /// argv; a runit service runs DIR/run with DIR as its working directory
    exec: []const []const u8 = &.{},
    /// runit: DIR/finish, run after every exit with the exit code and the status
    finish: ?[]const u8 = null,
    /// runit: DIR/log/run reads the service's output on its stdin
    logger: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    kind: Kind = .longrun,
    ready: Ready = .started,
    ready_timeout_ms: u64 = 30_000,
    /// a oneshot that runs again every so often (vh-fstrim); the last run is remembered on disk
    every_ms: ?u64 = null,
    /// the wait before the first start (vh-check: after the drivers have asked for their firmware)
    delay_ms: u64 = 0,
    needs: []const []const u8 = &.{},
    wants: []const []const u8 = &.{},
    after: []const []const u8 = &.{},
    before: []const []const u8 = &.{},
    restart: Restart = .always,
    restart_delay_ms: u64 = 1000,
    restart_max_ms: u64 = 30_000,
    stop_timeout_ms: u64 = 10_000,
    /// runit: a `down` file; the service is not started at boot
    down: bool = false,
    user: ?[]const u8 = null,
    group: ?[]const u8 = null,
    /// the capabilities kept (names without CAP_, lower case); null keeps what the user has
    caps: ?[]const []const u8 = null,
    no_new_privs: bool = true,
    /// the "x86_64 ABI only" seccomp filter: not for the gaming tree
    abi_filter: bool = true,
    umask: u32 = 0o022,
    nice: i8 = 0,
    sched: Sched = .normal,
    oom_score_adj: ?i16 = null,
    env: []const []const u8 = &.{},
    rlimit_nofile: ?u64 = null,
    memory_max: ?u64 = null,
    cpu_weight: ?u32 = null,
    log: Log = .file,
    log_size: u64 = 1 << 20,
    log_keep: u32 = 5,
};

pub const ParseError = error{ BadLine, BadValue, NoExec };

/// a `.svc` text; name is the file's base name without the suffix
pub fn parseSvc(name: []const u8, text: []const u8, source: []const u8) ParseError!Service {
    var s: Service = .{ .name = vh.dupe(name), .source = vh.dupe(source) };
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        if (line.len == 0 or line[0] == '#') continue;
        const eq = mem.indexOfScalar(u8, line, '=') orelse return error.BadLine;
        const key = vh.strip(line[0..eq]);
        const val = vh.strip(line[eq + 1 ..]);
        try setKey(&s, key, val);
    }
    if (s.exec.len == 0) return error.NoExec;
    if (s.kind == .oneshot and s.ready == .started) s.ready = .exit;
    return s;
}

fn setKey(s: *Service, key: []const u8, val: []const u8) ParseError!void {
    if (vh.eql(key, "exec")) {
        s.exec = try splitArgs(val);
    } else if (vh.eql(key, "kind")) {
        s.kind = std.meta.stringToEnum(Kind, val) orelse return error.BadValue;
    } else if (vh.eql(key, "ready")) {
        s.ready = try parseReady(val);
    } else if (vh.eql(key, "ready_timeout")) {
        s.ready_timeout_ms = parseDuration(val) orelse return error.BadValue;
    } else if (vh.eql(key, "every")) {
        s.every_ms = parseDuration(val) orelse return error.BadValue;
    } else if (vh.eql(key, "delay")) {
        s.delay_ms = parseDuration(val) orelse return error.BadValue;
    } else if (vh.eql(key, "needs")) {
        s.needs = words(val);
    } else if (vh.eql(key, "wants")) {
        s.wants = words(val);
    } else if (vh.eql(key, "after")) {
        s.after = words(val);
    } else if (vh.eql(key, "before")) {
        s.before = words(val);
    } else if (vh.eql(key, "restart")) {
        s.restart = std.meta.stringToEnum(Restart, val) orelse return error.BadValue;
    } else if (vh.eql(key, "restart_delay")) {
        s.restart_delay_ms = parseDuration(val) orelse return error.BadValue;
    } else if (vh.eql(key, "restart_max")) {
        s.restart_max_ms = parseDuration(val) orelse return error.BadValue;
    } else if (vh.eql(key, "stop_timeout")) {
        s.stop_timeout_ms = parseDuration(val) orelse return error.BadValue;
    } else if (vh.eql(key, "down")) {
        s.down = try parseBool(val);
    } else if (vh.eql(key, "user")) {
        s.user = if (val.len == 0) null else vh.dupe(val);
    } else if (vh.eql(key, "group")) {
        s.group = if (val.len == 0) null else vh.dupe(val);
    } else if (vh.eql(key, "caps")) {
        s.caps = if (vh.eql(val, "none")) &.{} else words(val);
    } else if (vh.eql(key, "no_new_privs")) {
        s.no_new_privs = try parseBool(val);
    } else if (vh.eql(key, "abi_filter")) {
        s.abi_filter = try parseBool(val);
    } else if (vh.eql(key, "umask")) {
        s.umask = std.fmt.parseInt(u32, val, 8) catch return error.BadValue;
    } else if (vh.eql(key, "nice")) {
        s.nice = std.fmt.parseInt(i8, val, 10) catch return error.BadValue;
        if (s.nice < -20 or s.nice > 19) return error.BadValue;
    } else if (vh.eql(key, "sched")) {
        s.sched = std.meta.stringToEnum(Sched, val) orelse return error.BadValue;
    } else if (vh.eql(key, "oom_score_adj")) {
        s.oom_score_adj = std.fmt.parseInt(i16, val, 10) catch return error.BadValue;
        if (s.oom_score_adj.? < -1000 or s.oom_score_adj.? > 1000) return error.BadValue;
    } else if (vh.eql(key, "env")) {
        const w = words(val);
        for (w) |e| if (mem.indexOfScalar(u8, e, '=') == null) return error.BadValue;
        s.env = w;
    } else if (vh.eql(key, "dir")) {
        s.cwd = if (val.len == 0) null else vh.dupe(val);
    } else if (vh.eql(key, "rlimit_nofile")) {
        s.rlimit_nofile = std.fmt.parseInt(u64, val, 10) catch return error.BadValue;
    } else if (vh.eql(key, "memory_max")) {
        s.memory_max = parseSize(val) orelse return error.BadValue;
    } else if (vh.eql(key, "cpu_weight")) {
        s.cpu_weight = std.fmt.parseInt(u32, val, 10) catch return error.BadValue;
        if (s.cpu_weight.? < 1 or s.cpu_weight.? > 10000) return error.BadValue;
    } else if (vh.eql(key, "log")) {
        s.log = std.meta.stringToEnum(Log, val) orelse return error.BadValue;
        if (s.log == .runit) return error.BadValue; // runit logging comes from a log/ directory only
    } else if (vh.eql(key, "log_size")) {
        s.log_size = parseSize(val) orelse return error.BadValue;
    } else if (vh.eql(key, "log_keep")) {
        s.log_keep = std.fmt.parseInt(u32, val, 10) catch return error.BadValue;
    } else return error.BadLine;
}

fn parseBool(val: []const u8) ParseError!bool {
    if (vh.eql(val, "yes") or vh.eql(val, "true") or vh.eql(val, "1")) return true;
    if (vh.eql(val, "no") or vh.eql(val, "false") or vh.eql(val, "0")) return false;
    return error.BadValue;
}

pub fn parseReady(val: []const u8) ParseError!Ready {
    var it = mem.tokenizeAny(u8, val, " \t");
    const kind = it.next() orelse return error.BadValue;
    const arg = it.next();
    if (it.next() != null) return error.BadValue;
    if (vh.eql(kind, "started")) return if (arg == null) .started else error.BadValue;
    if (vh.eql(kind, "exit")) return if (arg == null) .exit else error.BadValue;
    if (vh.eql(kind, "fd")) {
        const n = std.fmt.parseInt(u8, arg orelse return error.BadValue, 10) catch return error.BadValue;
        if (n < 3) return error.BadValue;
        return .{ .fd = n };
    }
    if (vh.eql(kind, "socket")) {
        const p = arg orelse return error.BadValue;
        if (p.len == 0 or p[0] != '/') return error.BadValue;
        return .{ .socket = vh.dupe(p) };
    }
    return error.BadValue;
}

/// "250ms", "5s", "10m", "2h", "1d", "1w"; a bare number is seconds
pub fn parseDuration(val: []const u8) ?u64 {
    var end: usize = 0;
    while (end < val.len and std.ascii.isDigit(val[end])) end += 1;
    if (end == 0) return null;
    const n = std.fmt.parseInt(u64, val[0..end], 10) catch return null;
    const unit = val[end..];
    const mult: u64 = if (unit.len == 0 or vh.eql(unit, "s")) 1000 else if (vh.eql(unit, "ms")) 1 else if (vh.eql(unit, "m")) 60_000 else if (vh.eql(unit, "h")) 3_600_000 else if (vh.eql(unit, "d")) 86_400_000 else if (vh.eql(unit, "w")) 604_800_000 else return null;
    return std.math.mul(u64, n, mult) catch null;
}

/// "64M", "1G", "4096", "512K"
pub fn parseSize(val: []const u8) ?u64 {
    var end: usize = 0;
    while (end < val.len and std.ascii.isDigit(val[end])) end += 1;
    if (end == 0) return null;
    const n = std.fmt.parseInt(u64, val[0..end], 10) catch return null;
    const unit = val[end..];
    const mult: u64 = if (unit.len == 0) 1 else if (vh.eql(unit, "K")) 1 << 10 else if (vh.eql(unit, "M")) 1 << 20 else if (vh.eql(unit, "G")) 1 << 30 else return null;
    return std.math.mul(u64, n, mult) catch null;
}

fn words(val: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = mem.tokenizeAny(u8, val, " \t");
    while (it.next()) |w| list.append(vh.gpa, vh.dupe(w)) catch vh.oom();
    return list.items;
}

/// argv from a line: words split at spaces; "double quotes" keep spaces, \" and \\ inside them
pub fn splitArgs(val: []const u8) ParseError![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < val.len) {
        while (i < val.len and (val[i] == ' ' or val[i] == '\t')) i += 1;
        if (i >= val.len) break;
        var word: std.ArrayList(u8) = .empty;
        if (val[i] == '"') {
            i += 1;
            var closed = false;
            while (i < val.len) : (i += 1) {
                if (val[i] == '\\' and i + 1 < val.len and (val[i + 1] == '"' or val[i + 1] == '\\')) {
                    i += 1;
                    word.append(vh.gpa, val[i]) catch vh.oom();
                } else if (val[i] == '"') {
                    closed = true;
                    i += 1;
                    break;
                } else word.append(vh.gpa, val[i]) catch vh.oom();
            }
            if (!closed) return error.BadValue;
        } else {
            while (i < val.len and val[i] != ' ' and val[i] != '\t') : (i += 1) word.append(vh.gpa, val[i]) catch vh.oom();
        }
        list.append(vh.gpa, word.items) catch vh.oom();
    }
    if (list.items.len == 0) return error.NoExec;
    if (list.items[0].len == 0 or list.items[0][0] != '/') return error.BadValue; // an absolute path: no PATH lookup for a service
    return list.items;
}

/// a runit service directory: what its files say
pub const RunitDir = struct {
    run: bool,
    finish: bool,
    log_run: bool,
    check: bool,
    down: bool,
};

pub fn fromRunit(name: []const u8, dir: []const u8, files: RunitDir) Service {
    var s: Service = .{ .name = vh.dupe(name), .source = vh.dupe(dir), .cwd = vh.dupe(dir) };
    s.exec = vh.gpa.dupe([]const u8, &.{vh.fmt("{s}/run", .{dir})}) catch vh.oom();
    if (files.finish) s.finish = vh.fmt("{s}/finish", .{dir});
    if (files.log_run) {
        s.logger = vh.fmt("{s}/log/run", .{dir});
        s.log = .runit;
    }
    if (files.check) s.ready = .{ .check = vh.fmt("{s}/check", .{dir}) };
    s.down = files.down;
    // runit's semantics: the run script may be a shell script and may setuid itself; the
    // filter and no_new_privs stay (a runit run script never needs a setuid program here)
    s.no_new_privs = false;
    return s;
}

// ---------------------------------------------------------------- the graph

pub const Graph = struct {
    services: []Service,
    /// index of every name, or null when a dependency names nothing that is enabled
    pub fn find(g: *const Graph, name: []const u8) ?usize {
        for (g.services, 0..) |s, i| if (vh.eql(s.name, name)) return i;
        return null;
    }
};

pub const GraphError = error{ Cycle, MissingNeed };

pub const Problem = struct { service: []const u8, what: []const u8, other: []const u8 };

/// Every `before` becomes the other side's `after`, `needs` and `wants` imply `after`;
/// a `needs` that names nothing enabled is reported (the service never starts); a `wants`
/// or `after` that names nothing is dropped. Returns the problems found (none is good).
pub fn resolve(g: *Graph) []const Problem {
    var problems: std.ArrayList(Problem) = .empty;
    // before -> after of the other
    for (g.services, 0..) |s, i| {
        for (s.before) |b| if (g.find(b)) |j| {
            if (j != i) appendUnique(&g.services[j].after, s.name);
        };
    }
    for (g.services) |*s| {
        var after: std.ArrayList([]const u8) = .empty;
        for (s.after) |a| if (g.find(a) != null) appendUniqueList(&after, a);
        for (s.needs) |n| {
            if (g.find(n) == null) {
                problems.append(vh.gpa, .{ .service = s.name, .what = "needs a service that is not enabled", .other = n }) catch vh.oom();
            } else appendUniqueList(&after, n);
        }
        var wants: std.ArrayList([]const u8) = .empty;
        for (s.wants) |w| if (g.find(w) != null) {
            appendUniqueList(&wants, w);
            appendUniqueList(&after, w);
        };
        s.wants = wants.items;
        s.after = after.items;
    }
    if (findCycle(g)) |c| problems.append(vh.gpa, .{ .service = c[0], .what = "is in a dependency cycle with", .other = c[1] }) catch vh.oom();
    return problems.items;
}

fn appendUnique(list: *[]const []const u8, name: []const u8) void {
    for (list.*) |x| if (vh.eql(x, name)) return;
    var l: std.ArrayList([]const u8) = .empty;
    l.appendSlice(vh.gpa, list.*) catch vh.oom();
    l.append(vh.gpa, name) catch vh.oom();
    list.* = l.items;
}

fn appendUniqueList(list: *std.ArrayList([]const u8), name: []const u8) void {
    for (list.items) |x| if (vh.eql(x, name)) return;
    list.append(vh.gpa, name) catch vh.oom();
}

/// two names of a cycle in the `after` relation, or null
pub fn findCycle(g: *const Graph) ?[2][]const u8 {
    const n = g.services.len;
    const state = vh.gpa.alloc(u8, n) catch vh.oom(); // 0 new, 1 on the path, 2 done
    @memset(state, 0);
    for (0..n) |i| if (state[i] == 0) {
        if (dfs(g, i, state)) |c| return c;
    };
    return null;
}

fn dfs(g: *const Graph, i: usize, state: []u8) ?[2][]const u8 {
    state[i] = 1;
    for (g.services[i].after) |a| {
        const j = g.find(a) orelse continue;
        if (state[j] == 1) return .{ g.services[i].name, g.services[j].name };
        if (state[j] == 0) if (dfs(g, j, state)) |c| return c;
    }
    state[i] = 2;
    return null;
}

/// a start order: every service after the ones it is `after`; ties by name, so the order
/// is the same at every boot (topological sort, Kahn, smallest name first)
pub fn startOrder(g: *const Graph) []usize {
    const n = g.services.len;
    const indeg = vh.gpa.alloc(usize, n) catch vh.oom();
    for (0..n) |i| indeg[i] = g.services[i].after.len;
    var out: std.ArrayList(usize) = .empty;
    const used = vh.gpa.alloc(bool, n) catch vh.oom();
    @memset(used, false);
    while (out.items.len < n) {
        var best: ?usize = null;
        for (0..n) |i| {
            if (used[i] or indeg[i] != 0) continue;
            if (best == null or mem.order(u8, g.services[i].name, g.services[best.?].name) == .lt) best = i;
        }
        const b = best orelse break; // a cycle: the rest stays unordered (resolve reported it)
        used[b] = true;
        out.append(vh.gpa, b) catch vh.oom();
        for (g.services, 0..) |s, j| {
            if (used[j]) continue;
            for (s.after) |a| if (vh.eql(a, g.services[b].name)) {
                indeg[j] -= 1;
            };
        }
    }
    for (0..n) |i| if (!used[i]) out.append(vh.gpa, i) catch vh.oom();
    return out.items;
}

/// the restart delay after `failures` restarts in a row: doubling from the delay to the maximum
pub fn backoffMs(s: *const Service, failures: u32) u64 {
    var d = s.restart_delay_ms;
    var i: u32 = 0;
    while (i < failures and d < s.restart_max_ms) : (i += 1) d = @min(d * 2, s.restart_max_ms);
    return @min(d, s.restart_max_ms);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "svc: a longrun with every key" {
    const text =
        \\# vh-acpid
        \\exec = /usr/local/sbin/vh-acpid --foreground "a b"
        \\needs = dbus udevd
        \\after = nftables
        \\ready = socket /run/vh/acpid.sock
        \\restart = on-failure
        \\restart_delay = 500ms
        \\user = _acpid
        \\caps = net_admin sys_boot
        \\nice = -5
        \\sched = batch
        \\env = FOO=1 BAR=x
        \\memory_max = 64M
        \\log = kmsg
        \\
    ;
    const s = try parseSvc("vh-acpid", text, "test");
    try testing.expectEqual(@as(usize, 3), s.exec.len);
    try testing.expectEqualStrings("a b", s.exec[2]);
    try testing.expectEqual(@as(usize, 2), s.needs.len);
    try testing.expectEqualStrings("/run/vh/acpid.sock", s.ready.socket);
    try testing.expectEqual(Restart.@"on-failure", s.restart);
    try testing.expectEqual(@as(u64, 500), s.restart_delay_ms);
    try testing.expectEqualStrings("_acpid", s.user.?);
    try testing.expectEqual(@as(usize, 2), s.caps.?.len);
    try testing.expectEqual(@as(i8, -5), s.nice);
    try testing.expectEqual(Sched.batch, s.sched);
    try testing.expectEqual(@as(u64, 64 << 20), s.memory_max.?);
    try testing.expectEqual(Log.kmsg, s.log);
    try testing.expect(s.no_new_privs and s.abi_filter);
}

test "svc: a oneshot timer" {
    const s = try parseSvc("vh-fstrim", "exec = /usr/bin/fstrim -v /\nkind = oneshot\nevery = 1w\ndelay = 5m\n", "t");
    try testing.expectEqual(Kind.oneshot, s.kind);
    try testing.expect(s.ready == .exit);
    try testing.expectEqual(@as(u64, 604_800_000), s.every_ms.?);
    try testing.expectEqual(@as(u64, 300_000), s.delay_ms);
}

test "svc: errors" {
    try testing.expectError(error.NoExec, parseSvc("x", "kind = oneshot\n", "t"));
    try testing.expectError(error.BadLine, parseSvc("x", "exec = /bin/a\nnonsense\n", "t"));
    try testing.expectError(error.BadLine, parseSvc("x", "exec = /bin/a\nunknown = 1\n", "t"));
    try testing.expectError(error.BadValue, parseSvc("x", "exec = /bin/a\nready = fd 1\n", "t"));
    try testing.expectError(error.BadValue, parseSvc("x", "exec = /bin/a\nready = socket relative\n", "t"));
    try testing.expectError(error.BadValue, parseSvc("x", "exec = /bin/a\nnice = 30\n", "t"));
    try testing.expectError(error.BadValue, parseSvc("x", "exec = /bin/a\nenv = NOEQUALS\n", "t"));
    try testing.expectError(error.BadValue, parseSvc("x", "exec = /bin/a\nlog = runit\n", "t"));
    try testing.expectError(error.BadValue, parseSvc("x", "exec = relative/path\n", "t"));
    try testing.expectError(error.BadValue, parseSvc("x", "exec = /bin/a \"unclosed\n", "t"));
}

test "svc: durations and sizes" {
    try testing.expectEqual(@as(?u64, 250), parseDuration("250ms"));
    try testing.expectEqual(@as(?u64, 5000), parseDuration("5s"));
    try testing.expectEqual(@as(?u64, 5000), parseDuration("5"));
    try testing.expectEqual(@as(?u64, 7_200_000), parseDuration("2h"));
    try testing.expectEqual(@as(?u64, 86_400_000), parseDuration("1d"));
    try testing.expectEqual(@as(?u64, null), parseDuration("x"));
    try testing.expectEqual(@as(?u64, null), parseDuration("5y"));
    try testing.expectEqual(@as(?u64, 1 << 30), parseSize("1G"));
    try testing.expectEqual(@as(?u64, 4096), parseSize("4096"));
    try testing.expectEqual(@as(?u64, null), parseSize("1T"));
}

test "svc: argv splitting" {
    const a = try splitArgs("/usr/bin/x  -o \"with space\" \"q\\\"uote\" end");
    try testing.expectEqual(@as(usize, 5), a.len);
    try testing.expectEqualStrings("with space", a[2]);
    try testing.expectEqualStrings("q\"uote", a[3]);
    try testing.expectEqualStrings("end", a[4]);
}

test "svc: a runit directory" {
    const s = fromRunit("iwd", "/etc/sv/iwd", .{ .run = true, .finish = false, .log_run = true, .check = true, .down = false });
    try testing.expectEqualStrings("/etc/sv/iwd/run", s.exec[0]);
    try testing.expectEqualStrings("/etc/sv/iwd/log/run", s.logger.?);
    try testing.expectEqual(Log.runit, s.log);
    try testing.expectEqualStrings("/etc/sv/iwd/check", s.ready.check);
    try testing.expect(!s.no_new_privs);
    try testing.expect(s.abi_filter);
}

fn mk(name: []const u8, after: []const []const u8, needs: []const []const u8) Service {
    return .{ .name = name, .exec = &.{"/bin/true"}, .after = after, .needs = needs };
}

test "graph: order, before, missing needs, cycle" {
    var list = [_]Service{
        mk("iwd", &.{}, &.{"dbus"}),
        mk("dbus", &.{}, &.{}),
        mk("agetty", &.{"udevd"}, &.{}),
        mk("udevd", &.{}, &.{}),
        mk("sched", &.{}, &.{}),
        mk("zz", &.{}, &.{"nothing"}),
    };
    list[4].before = &.{"dbus"};
    var g: Graph = .{ .services = &list };
    const problems = resolve(&g);
    try testing.expectEqual(@as(usize, 1), problems.len);
    try testing.expectEqualStrings("zz", problems[0].service);
    try testing.expectEqualStrings("nothing", problems[0].other);
    // sched is before dbus, so dbus is after sched; iwd is after dbus by its needs
    try testing.expectEqual(@as(usize, 1), g.services[1].after.len);
    try testing.expectEqualStrings("sched", g.services[1].after[0]);
    try testing.expectEqualStrings("dbus", g.services[0].after[0]);
    const order = startOrder(&g);
    var pos: [6]usize = undefined;
    for (order, 0..) |idx, p| pos[idx] = p;
    try testing.expect(pos[4] < pos[1]); // sched before dbus
    try testing.expect(pos[1] < pos[0]); // dbus before iwd
    try testing.expect(pos[3] < pos[2]); // udevd before agetty
    try testing.expectEqual(@as(usize, 6), order.len);
}

test "graph: a cycle is found" {
    var list = [_]Service{ mk("a", &.{"b"}, &.{}), mk("b", &.{"c"}, &.{}), mk("c", &.{"a"}, &.{}), mk("d", &.{}, &.{}) };
    var g: Graph = .{ .services = &list };
    const problems = resolve(&g);
    try testing.expectEqual(@as(usize, 1), problems.len);
    try testing.expectEqualStrings("is in a dependency cycle with", problems[0].what);
    try testing.expectEqual(@as(usize, 4), startOrder(&g).len);
}

test "backoff doubles to the maximum" {
    const s: Service = .{ .name = "x", .restart_delay_ms = 1000, .restart_max_ms = 30_000 };
    try testing.expectEqual(@as(u64, 1000), backoffMs(&s, 0));
    try testing.expectEqual(@as(u64, 2000), backoffMs(&s, 1));
    try testing.expectEqual(@as(u64, 16_000), backoffMs(&s, 4));
    try testing.expectEqual(@as(u64, 30_000), backoffMs(&s, 5));
    try testing.expectEqual(@as(u64, 30_000), backoffMs(&s, 50));
}
