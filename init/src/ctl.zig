//! vh-ctl: the control client of vh-init's manager over /run/vh/init.sock, and the `sv` shim:
//! invoked as `sv` it takes sv(8)'s commands and prints sv's status lines, so that the scripts
//! of this system (vh-audit, iwd's conf, ctrlaltdel) work unchanged. Without the socket (runit
//! is PID 1) the shim runs runit's own sv, kept as /usr/bin/sv.runit by vh-init --install.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const proto = @import("proto.zig");
const svc = @import("svc.zig");

pub const version = @import("manager.zig").version;

fn connect() ?linux.fd_t {
    const fd_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(fd_rc);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    const path = vh.getenv("VH_INIT_SOCKET") orelse proto.socket_path;
    if (path.len >= addr.path.len) return null;
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS) {
        vh.close(fd);
        return null;
    }
    return fd;
}

pub const Reply = struct { body: []const u8, ok: bool, err: []const u8 };

/// one request; null when the manager is not reachable
pub fn request(line: []const u8) ?Reply {
    const fd = connect() orelse return null;
    defer vh.close(fd);
    vh.writeAllFd(fd, vh.fmt("{s}\n", .{line})) catch return null;
    const text = vh.readAll(fd) catch return null;
    return splitReply(text);
}

/// the body and the final line
pub fn splitReply(text: []const u8) Reply {
    const t = mem.trimEnd(u8, text, "\n");
    const last_nl = mem.lastIndexOfScalar(u8, t, '\n');
    const last = if (last_nl) |i| t[i + 1 ..] else t;
    const body = if (last_nl) |i| text[0 .. i + 1] else "";
    if (vh.eql(last, "ok")) return .{ .body = body, .ok = true, .err = "" };
    if (vh.startsWith(last, "err ")) return .{ .body = body, .ok = false, .err = last[4..] };
    return .{ .body = text, .ok = false, .err = "the manager closed the connection" };
}

fn usage() noreturn {
    vh.outs(
        \\vh-ctl: control vh-init's services (init/README.md)
        \\  vh-ctl status [NAME]            every service, or one: state, pid, time in the state
        \\  vh-ctl start|stop|restart NAME [-w SECONDS]   -w waits for the state (default 7 s)
        \\  vh-ctl once NAME                start once, no restart when it exits
        \\  vh-ctl signal NAME SIG          send a signal (TERM, HUP, USR1, ...)
        \\  vh-ctl enable|disable NAME      enable a service (/var/service or /etc/vh/services/enabled)
        \\  vh-ctl tree | why NAME | blame  dependencies and what a service waits for; the boot's timing
        \\  vh-ctl reload                   read the service definitions again
        \\  vh-ctl poweroff|reboot|halt     the regular shutdown through PID 1
        \\  vh-ctl ping                     is the manager there
        \\As sv: sv [-w SECONDS] up|down|restart|status|once|check|1|2|i|t|k|p|c|h|a NAME... (sv(8))
        \\
    );
    vh.exit(2);
}

fn secondsArg(s: []const u8) u64 {
    const v = vh.parseLong(s) orelse vh.die("-w: a number of seconds, not {s}", .{s});
    if (v < 0 or v > 86400) vh.die("-w: {d} seconds", .{v});
    return @intCast(v * 1000);
}

fn printStatus(body: []const u8, runit_form: bool) void {
    var lines = mem.tokenizeScalar(u8, body, '\n');
    while (lines.next()) |l| {
        const st = proto.StatusLine.parse(l) orelse {
            vh.out("{s}\n", .{l});
            continue;
        };
        if (runit_form) {
            vh.outs(proto.runitStatus(st));
        } else {
            vh.out("{s: <20} {s: <9} pid {d: <7} {d}s{s}{s}\n", .{ st.name, @tagName(st.state), st.pid, st.since_ms / 1000, if (st.restarts > 0) vh.fmt("  restarts {d}", .{st.restarts}) else "", if (!st.want_up) "  (wanted down)" else "" });
        }
    }
}

fn enable(name: []const u8, on: bool) u8 {
    if (!proto.validName(name)) vh.die("not a service name: {s}", .{name});
    const runit_src = vh.fmt("/etc/sv/{s}", .{name});
    const runit_link = vh.fmt("{s}/{s}", .{ svc.runit_dir, name });
    const svc_file = vh.fmt("{s}/{s}.svc", .{ svc.svc_dir, name });
    const svc_link = vh.fmt("{s}/{s}", .{ svc.enabled_dir, name });
    if (on) {
        if (vh.isDir(runit_src)) {
            if (vh.pathExists(runit_link)) {
                vh.out("{s} is already enabled\n", .{name});
            } else {
                _ = vh.sys(linux.symlink(vh.z(runit_src).ptr, vh.z(runit_link).ptr)) catch vh.die("{s}: {s}", .{ runit_link, vh.serr() });
                vh.out("enabled {s} ({s} -> {s})\n", .{ name, runit_link, runit_src });
            }
        } else if (vh.isRegular(svc_file)) {
            vh.mkdirs(svc.enabled_dir, 0o755);
            if (vh.pathExists(svc_link)) {
                vh.out("{s} is already enabled\n", .{name});
            } else {
                _ = vh.sys(linux.symlink(vh.z(vh.fmt("../{s}.svc", .{name})).ptr, vh.z(svc_link).ptr)) catch vh.die("{s}: {s}", .{ svc_link, vh.serr() });
                vh.out("enabled {s} ({s})\n", .{ name, svc_file });
            }
        } else vh.die("no service {s}: neither {s} nor {s}", .{ name, runit_src, svc_file });
    } else {
        var any = false;
        for ([_][]const u8{ runit_link, svc_link }) |l| if (vh.pathExists(l)) {
            vh.unlink(l) catch vh.die("{s}: {s}", .{ l, vh.serr() });
            any = true;
        };
        if (!any) vh.die("{s} is not enabled", .{name});
        vh.out("disabled {s}\n", .{name});
    }
    if (request("reload")) |r| {
        if (!r.ok) vh.warn("reload: {s}", .{r.err});
    } else vh.out("(the manager is not running: the change applies at the next boot)\n", .{});
    return 0;
}

/// the sv shim: sv [-w SEC] [-v] CMD NAME...
fn svMain(args: []const [:0]const u8) noreturn {
    var wait_ms: u64 = 7000;
    var explicit_wait = false;
    var i: usize = 0;
    while (i < args.len and args[i].len > 0 and args[i][0] == '-') : (i += 1) {
        if (vh.eql(args[i], "-w")) {
            i += 1;
            if (i >= args.len) usage();
            wait_ms = secondsArg(args[i]);
            explicit_wait = true;
        } else if (vh.eql(args[i], "-v")) {
            explicit_wait = true;
        } else usage();
    }
    if (i + 1 >= args.len) usage();
    const cmd = args[i];
    const names = args[i + 1 ..];
    if (connect() == null) {
        // runit is PID 1: runit's sv, in our place. Its argv[0] must be "sv": with any other
        // name runit's sv acts as an LSB init script of a service called by that name (sv.c,
        // lsb), and "sv.runit status X" would report the service sv.runit
        const sv_runit = "/usr/bin/sv.runit";
        if (vh.isRegular(sv_runit)) {
            var argv: std.ArrayList(?[*:0]const u8) = .empty;
            argv.append(vh.gpa, "sv") catch vh.oom();
            for (args) |a| argv.append(vh.gpa, a.ptr) catch vh.oom();
            const cargv = argv.toOwnedSliceSentinel(vh.gpa, null) catch vh.oom();
            vh.flush();
            const rc = linux.execve(sv_runit, cargv.ptr, vh.envp);
            vh.die("{s}: {s}", .{ sv_runit, @tagName(linux.errno(rc)) });
        }
        vh.die("the vh-init manager is not running (no {s}) and there is no {s}", .{ proto.socket_path, sv_runit });
    }
    var rc: u8 = 0;
    for (names) |raw| {
        // sv accepts a path: /var/service/NAME, /etc/sv/NAME
        const name = raw[(mem.lastIndexOfScalar(u8, raw, '/') orelse @as(usize, 0) -% 1) +% 1 ..];
        var line: []const u8 = undefined;
        var show_status = false;
        if (vh.eql(cmd, "status") or vh.eql(cmd, "s")) {
            line = vh.fmt("status {s}", .{name});
            show_status = true;
        } else if (vh.eql(cmd, "up") or vh.eql(cmd, "u")) {
            line = vh.fmt("start {s}", .{name});
        } else if (vh.eql(cmd, "start")) {
            line = vh.fmt("start {s} {d}", .{ name, wait_ms });
            show_status = true;
        } else if (vh.eql(cmd, "down") or vh.eql(cmd, "d")) {
            line = vh.fmt("stop {s}", .{name});
        } else if (vh.eql(cmd, "stop")) {
            line = vh.fmt("stop {s} {d}", .{ name, wait_ms });
            show_status = true;
        } else if (vh.eql(cmd, "restart")) {
            line = vh.fmt("restart {s} {d}", .{ name, wait_ms });
            show_status = true;
        } else if (vh.eql(cmd, "once") or vh.eql(cmd, "o")) {
            line = vh.fmt("once {s}", .{name});
        } else if (vh.eql(cmd, "check") or vh.eql(cmd, "c")) {
            line = vh.fmt("status {s}", .{name});
        } else if (vh.eql(cmd, "exit") or vh.eql(cmd, "x") or vh.eql(cmd, "e")) {
            line = vh.fmt("stop {s}", .{name});
        } else if (cmd.len == 1 and proto.signalOf(cmd) != null) {
            line = vh.fmt("signal {s} {s}", .{ name, cmd });
        } else if (vh.eql(cmd, "reload") or vh.eql(cmd, "r")) {
            line = vh.fmt("signal {s} HUP", .{name});
        } else if (vh.eql(cmd, "term") or vh.eql(cmd, "t")) {
            line = vh.fmt("signal {s} TERM", .{name});
        } else if (vh.eql(cmd, "kill") or vh.eql(cmd, "k")) {
            line = vh.fmt("signal {s} KILL", .{name});
        } else usage();
        const r = request(line) orelse vh.die("the manager went away", .{});
        if (vh.eql(cmd, "check") or vh.eql(cmd, "c")) {
            // sv check: exit 0 when the service is up (runit also runs ./check; the manager did at start)
            const st = proto.StatusLine.parse(r.body) orelse {
                vh.out("fail: {s}: unable to check status\n", .{name});
                rc = 1;
                continue;
            };
            vh.outs(proto.runitStatus(st));
            if (st.state != .up) rc = 1;
            continue;
        }
        if (!r.ok) {
            if (vh.eql(r.err, "timeout")) {
                vh.out("timeout: ", .{});
                printStatus(r.body, true);
            } else vh.out("fail: {s}: {s}\n", .{ name, r.err });
            rc = 1;
            continue;
        }
        if (show_status) printStatus(r.body, true);
    }
    vh.exit(rc);
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "vh-ctl");
    // the shim: the name we were started by
    var it = init.args.iterate();
    const argv0 = it.next() orelse "vh-ctl";
    const base = argv0[(mem.lastIndexOfScalar(u8, argv0, '/') orelse @as(usize, 0) -% 1) +% 1 ..];
    if (vh.eql(base, "sv")) {
        vh.prog = "sv";
        svMain(args);
    }
    if (args.len == 0) usage();
    const cmd = args[0];
    if (vh.eql(cmd, "--version")) {
        vh.out("vh-ctl {s}\n", .{version});
        vh.exit(0);
    }
    if (vh.eql(cmd, "enable") or vh.eql(cmd, "disable")) {
        if (args.len != 2) usage();
        if (linux.geteuid() != 0) vh.die("run as root: doas vh-ctl {s} {s}", .{ cmd, args[1] });
        vh.exit(enable(args[1], vh.eql(cmd, "enable")));
    }
    var wait_ms: u64 = 0;
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (vh.eql(args[i], "-w")) {
            i += 1;
            wait_ms = if (i < args.len) secondsArg(args[i]) else 7000;
        } else rest.append(vh.gpa, args[i]) catch vh.oom();
    }
    var line: std.ArrayList(u8) = .empty;
    line.appendSlice(vh.gpa, cmd) catch vh.oom();
    for (rest.items) |a| line.print(vh.gpa, " {s}", .{a}) catch vh.oom();
    const waits = vh.eql(cmd, "start") or vh.eql(cmd, "stop") or vh.eql(cmd, "restart");
    if (waits and rest.items.len == 1) {
        if (wait_ms == 0) wait_ms = 7000;
        line.print(vh.gpa, " {d}", .{wait_ms}) catch vh.oom();
    }
    _ = proto.parseRequest(line.items) catch usage();
    const r = request(line.items) orelse vh.die("the vh-init manager is not running (no {s})", .{proto.socket_path});
    if (vh.eql(cmd, "status") or waits or vh.eql(cmd, "once")) printStatus(r.body, false) else vh.outs(r.body);
    if (!r.ok) vh.die("{s}", .{r.err});
    vh.exit(0);
}

const testing = std.testing;

test "replies are split at the final line" {
    const r = splitReply("a 1\nb 2\nok\n");
    try testing.expect(r.ok);
    try testing.expectEqualStrings("a 1\nb 2\n", r.body);
    const e = splitReply("err no service x\n");
    try testing.expect(!e.ok);
    try testing.expectEqualStrings("no service x", e.err);
    try testing.expectEqualStrings("", e.body);
    try testing.expect(!splitReply("").ok);
}
