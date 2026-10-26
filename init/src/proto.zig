//! vh-init: the control protocol between vh-ctl and the manager over /run/vh/init.sock
//! (a unix stream socket, root only), and between PID 1 and the manager over their
//! socketpair. Text, one request line, reply lines, then a final line `ok` or `err TEXT`.
//! Pure parsing and formatting: tested without a socket.
const std = @import("std");
const mem = std.mem;
const vh = @import("vh");

pub const socket_path = "/run/vh/init.sock";
pub const socket_dir = "/run/vh";

pub const Verb = enum {
    ping,
    list,
    status,
    start,
    stop,
    restart,
    once,
    signal,
    tree,
    why,
    blame,
    reload,
    poweroff,
    reboot,
    halt,
};

pub const Request = struct {
    verb: Verb,
    name: []const u8 = "",
    /// a second argument: the signal of `signal`, the wait of start/stop/restart in ms
    arg: []const u8 = "",
};

pub const Error = error{ BadRequest, UnknownVerb };

/// "status dbus", "start iwd 5000", "signal vh-acpid USR1"
pub fn parseRequest(line: []const u8) Error!Request {
    var it = mem.tokenizeAny(u8, mem.trimEnd(u8, line, "\r\n"), " \t");
    const v = it.next() orelse return error.BadRequest;
    const verb = std.meta.stringToEnum(Verb, v) orelse return error.UnknownVerb;
    var r: Request = .{ .verb = verb };
    if (it.next()) |n| r.name = n;
    if (it.next()) |a| r.arg = a;
    if (it.next() != null) return error.BadRequest;
    switch (verb) {
        .status, .list, .tree, .blame, .reload, .poweroff, .reboot, .halt, .ping => {},
        .start, .stop, .restart, .once, .why, .signal => if (r.name.len == 0) return error.BadRequest,
    }
    if (!validName(r.name)) return error.BadRequest;
    return r;
}

/// a service name: what a directory or file name of a service may be
pub fn validName(name: []const u8) bool {
    if (name.len > 64) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '@')) return false;
    return mem.indexOf(u8, name, "..") == null;
}

/// the states a service is reported in (the manager's, by name)
pub const State = enum { waiting, delayed, starting, up, stopping, finishing, down, failed, done };

/// one line of `status`: machine-readable, space separated
pub const StatusLine = struct {
    name: []const u8,
    state: State,
    pid: i32,
    /// milliseconds in the state
    since_ms: u64,
    restarts: u32,
    want_up: bool,
    logger_pid: i32,
    exit_code: i32,

    pub fn format(l: StatusLine) []u8 {
        return vh.fmt("{s} {s} {d} {d} {d} {s} {d} {d}\n", .{ l.name, @tagName(l.state), l.pid, l.since_ms, l.restarts, if (l.want_up) "want-up" else "want-down", l.logger_pid, l.exit_code });
    }

    pub fn parse(line: []const u8) ?StatusLine {
        var it = mem.tokenizeAny(u8, mem.trimEnd(u8, line, "\r\n"), " ");
        const name = it.next() orelse return null;
        const state = std.meta.stringToEnum(State, it.next() orelse return null) orelse return null;
        const pid = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
        const since = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        const restarts = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const want = it.next() orelse return null;
        const lpid = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
        const code = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
        return .{ .name = name, .state = state, .pid = pid, .since_ms = since, .restarts = restarts, .want_up = vh.eql(want, "want-up"), .logger_pid = lpid, .exit_code = code };
    }
};

/// the runit `sv status` line: "run: NAME: (pid 123) 45s" / "down: NAME: 3s, normally up"
pub fn runitStatus(l: StatusLine) []u8 {
    const secs = l.since_ms / 1000;
    const running = l.state == .up or l.state == .starting or l.state == .stopping or l.state == .finishing;
    var out: std.ArrayList(u8) = .empty;
    if (running) {
        out.print(vh.gpa, "run: {s}: (pid {d}) {d}s", .{ l.name, l.pid, secs }) catch vh.oom();
        if (!l.want_up) out.appendSlice(vh.gpa, ", want down") catch vh.oom();
        if (l.state == .stopping or l.state == .finishing) out.appendSlice(vh.gpa, ", got TERM") catch vh.oom();
    } else if (l.state == .failed) {
        out.print(vh.gpa, "fail: {s}: {d}s", .{ l.name, secs }) catch vh.oom();
    } else {
        out.print(vh.gpa, "down: {s}: {d}s", .{ l.name, secs }) catch vh.oom();
        if (l.want_up and l.state != .done) out.appendSlice(vh.gpa, ", want up") catch vh.oom() else if (l.state != .done) out.appendSlice(vh.gpa, ", normally up") catch vh.oom();
    }
    if (l.logger_pid > 0) out.print(vh.gpa, "; run: log: (pid {d}) {d}s", .{ l.logger_pid, secs }) catch vh.oom();
    out.append(vh.gpa, '\n') catch vh.oom();
    return out.items;
}

/// the signal letters of sv(8) and the names of vh-ctl signal
pub fn signalOf(s: []const u8) ?std.os.linux.SIG {
    const L = std.os.linux.SIG;
    if (s.len == 1) return switch (s[0]) {
        '1' => L.USR1,
        '2' => L.USR2,
        'i' => L.INT,
        't' => L.TERM,
        'k' => L.KILL,
        'p' => L.STOP,
        'c' => L.CONT,
        'h' => L.HUP,
        'a' => L.ALRM,
        'q' => L.QUIT,
        else => null,
    };
    const name = if (vh.startsWith(s, "SIG")) s[3..] else s;
    const table = [_]struct { n: []const u8, s: L }{
        .{ .n = "HUP", .s = L.HUP },   .{ .n = "INT", .s = L.INT },   .{ .n = "QUIT", .s = L.QUIT }, .{ .n = "KILL", .s = L.KILL },
        .{ .n = "USR1", .s = L.USR1 }, .{ .n = "USR2", .s = L.USR2 }, .{ .n = "TERM", .s = L.TERM }, .{ .n = "CONT", .s = L.CONT },
        .{ .n = "STOP", .s = L.STOP }, .{ .n = "ALRM", .s = L.ALRM }, .{ .n = "WINCH", .s = L.WINCH },
    };
    for (table) |t| if (vh.eql(t.n, name)) return t.s;
    return null;
}

const testing = std.testing;

test "requests" {
    const r = try parseRequest("start iwd 5000\n");
    try testing.expectEqual(Verb.start, r.verb);
    try testing.expectEqualStrings("iwd", r.name);
    try testing.expectEqualStrings("5000", r.arg);
    try testing.expectEqual(Verb.status, (try parseRequest("status")).verb);
    try testing.expectError(error.BadRequest, parseRequest("start"));
    try testing.expectError(error.BadRequest, parseRequest("status a b c"));
    try testing.expectError(error.BadRequest, parseRequest("stop ../etc"));
    try testing.expectError(error.UnknownVerb, parseRequest("frobnicate x"));
    try testing.expectError(error.BadRequest, parseRequest(""));
}

test "status lines round trip and the runit form" {
    const l: StatusLine = .{ .name = "dbus", .state = .up, .pid = 123, .since_ms = 45_600, .restarts = 2, .want_up = true, .logger_pid = 124, .exit_code = 0 };
    const text = l.format();
    const back = StatusLine.parse(text).?;
    try testing.expectEqualStrings("dbus", back.name);
    try testing.expectEqual(State.up, back.state);
    try testing.expectEqual(@as(i32, 123), back.pid);
    try testing.expectEqual(@as(u32, 2), back.restarts);
    try testing.expect(back.want_up);
    try testing.expectEqualStrings("run: dbus: (pid 123) 45s; run: log: (pid 124) 45s\n", runitStatus(back));
    const d: StatusLine = .{ .name = "iwd", .state = .down, .pid = 0, .since_ms = 3000, .restarts = 0, .want_up = false, .logger_pid = 0, .exit_code = 1 };
    try testing.expectEqualStrings("down: iwd: 3s, normally up\n", runitStatus(d));
    const f: StatusLine = .{ .name = "x", .state = .failed, .pid = 0, .since_ms = 1000, .restarts = 0, .want_up = true, .logger_pid = 0, .exit_code = 1 };
    try testing.expectEqualStrings("fail: x: 1s\n", runitStatus(f));
    try testing.expect(StatusLine.parse("garbage") == null);
}

test "signals" {
    try testing.expectEqual(std.os.linux.SIG.USR1, signalOf("1").?);
    try testing.expectEqual(std.os.linux.SIG.TERM, signalOf("t").?);
    try testing.expectEqual(std.os.linux.SIG.HUP, signalOf("SIGHUP").?);
    try testing.expectEqual(std.os.linux.SIG.CONT, signalOf("CONT").?);
    try testing.expect(signalOf("nope") == null);
}
