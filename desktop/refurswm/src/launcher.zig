// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! The launcher: a tiny child forked first thing in main, before any wlroots state exists. It
//! starts every program for the compositor, so the compositor can give up exec for good (sandbox)
//! while the terminal, sudo or swaylock it starts stay unrestricted. It receives an index into the
//! comptime command table (never an argv), an activation token and, for programs with a grant,
//! the client end of a Wayland connection the compositor opened for them (WAYLAND_SOCKET).
const std = @import("std");
const linux = std.os.linux;
const wm = @import("wm.zig");
const c = wm.c;
const cfg = wm.cfg;
const T = wm.T;
const policy = @import("policy.zig");
const client = @import("client.zig");
const sandbox = @import("sandbox.zig");

const max_args = 32;

// ------------------------------------------------------------------ command table

fn countCmds() usize {
    var n: usize = cfg.autostart.len + cfg.theme_hooks_dark.len + cfg.theme_hooks_light.len + 1;
    for (cfg.binds) |b| if (b.action == .spawn) {
        n += 1;
    };
    return n;
}

/// Every command the config can run, in a fixed order; messages carry an index into it.
const cmds: [countCmds()]T.Cmd = blk: {
    var out: [countCmds()]T.Cmd = undefined;
    var i: usize = 0;
    for (cfg.binds) |b| switch (b.action) {
        .spawn => |cmd| {
            out[i] = cmd;
            i += 1;
        },
        else => {},
    };
    for (cfg.autostart ++ cfg.theme_hooks_dark ++ cfg.theme_hooks_light ++ [_]T.Cmd{cfg.lock_command}) |cmd| {
        out[i] = cmd;
        i += 1;
    }
    break :blk out;
};

comptime {
    for (cmds) |cmd| if (cmd.len == 0 or cmd.len > max_args) @compileError("config: a command needs 1..32 arguments");
    for (cfg.grants) |g| if (g.path.len < 2 or g.path[0] != '/') @compileError("config: grants need absolute paths");
}

fn indexOf(comptime cmd: T.Cmd) u16 {
    comptime {
        @setEvalBranchQuota(100_000);
        outer: for (cmds, 0..) |x, i| {
            if (x.len != cmd.len) continue;
            for (x, cmd) |a, b| if (!std.mem.eql(u8, std.mem.span(a), std.mem.span(b))) continue :outer;
            return i;
        }
        @compileError("launcher: command not in the table");
    }
}

// ------------------------------------------------------------------ messages

const Kind = enum(u8) { env, spawn, startup, _ };

const Msg = extern struct {
    kind: Kind,
    idx: u16 = 0,
    token_len: u8 = 0,
    token: [64]u8 = @splat(0),
    name_len: u8 = 0,
    name: [32]u8 = @splat(0),

    fn setToken(m: *Msg, t: []const u8) void {
        if (t.len > m.token.len) return;
        @memcpy(m.token[0..t.len], t);
        m.token_len = @intCast(t.len);
    }

    fn getToken(m: *const Msg) []const u8 {
        const t = m.token[0..@min(m.token_len, m.token.len)];
        return if (policy.validToken(t)) t else "";
    }
};

/// One SCM_RIGHTS control message carrying one fd (CMSG_SPACE(sizeof(int)) on 64-bit Linux).
const FdCmsg = extern struct {
    len: usize = @sizeOf(usize) + 2 * @sizeOf(c_int) + @sizeOf(c_int),
    level: c_int = linux.SOL.SOCKET,
    type: c_int = linux.SCM.RIGHTS,
    fd: c_int,
    pad: c_int = 0,
};

fn ok(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

// ------------------------------------------------------------------ compositor side

var sock: linux.fd_t = -1;

/// Forks the launcher. Call first thing in main, while the process holds nothing worth inheriting.
pub fn start() void {
    // fds inherited from whoever started us must not reach any program (and stay out of our way)
    _ = linux.close_range(3, -1, .{ .UNSHARE = false, .CLOEXEC = true });
    var sv: [2]linux.fd_t = undefined;
    if (!ok(linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0, &sv)))
        return wm.log("cannot create the launcher socket", .{});
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(sv[0]);
        _ = c.close(sv[1]);
        return wm.log("cannot fork the launcher", .{});
    }
    if (pid == 0) {
        _ = c.close(sv[0]);
        serve(sv[1]);
    }
    _ = c.close(sv[1]);
    // a stuck launcher must never stall the desktop: then a start is dropped instead
    _ = c.fcntl(sv[0], c.F_SETFL, c.O_NONBLOCK);
    sock = sv[0];
}

/// The session environment for everything started from now on (WAYLAND_DISPLAY etc.).
pub fn setDisplay(name: []const u8) void {
    var m: Msg = .{ .kind = .env };
    if (name.len > m.name.len) return;
    @memcpy(m.name[0..name.len], name);
    m.name_len = @intCast(name.len);
    sendMsg(&m, null);
}

/// Runs a command from the config. `token`: the user asked for it, so the program gets an
/// xdg-activation token and its first window may take the focus even when it is sandboxed.
pub fn spawn(comptime cmd: T.Cmd, token: bool) void {
    var m: Msg = .{ .kind = .spawn, .idx = comptime indexOf(cmd) };
    if (token) if (newToken()) |t| m.setToken(t);
    sendMsg(&m, comptime policy.grantOf(&cfg.grants, std.mem.span(cmd[0])));
}

/// REFURS_STARTUP="prog arg ...": one extra program, split on spaces, no shell (tests).
pub fn startup() void {
    const st = std.mem.span(c.getenv("REFURS_STARTUP") orelse return);
    var m: Msg = .{ .kind = .startup };
    if (newToken()) |t| m.setToken(t);
    sendMsg(&m, policy.grantOf(&cfg.grants, firstWord(st)));
}

fn firstWord(s: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    return it.next() orelse "";
}

var token_mark: u8 = 0;

fn newToken() ?[]const u8 {
    const t = c.wlr_xdg_activation_token_v1_create(wm.s.activation) orelse return null;
    t.*.data = &token_mark;
    return std.mem.span(c.wlr_xdg_activation_token_v1_get_name(t));
}

/// A token RefursWM handed to a program it started.
pub fn ownToken(t: *const c.struct_wlr_xdg_activation_token_v1) bool {
    return t.data == @as(?*anyopaque, &token_mark);
}

fn sendMsg(m: *const Msg, caps: ?T.Caps) void {
    if (sock < 0) return wm.log("no launcher: cannot start programs", .{});
    const conn = if (caps) |cp| privilegedClient(cp) else -1;
    defer if (conn >= 0) {
        _ = c.close(conn);
    };
    const iov = [1]std.posix.iovec_const{.{ .base = @ptrCast(m), .len = @sizeOf(Msg) }};
    var cm: FdCmsg = .{ .fd = conn };
    const mh: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = if (conn >= 0) &cm else null,
        .controllen = if (conn >= 0) @sizeOf(FdCmsg) else 0,
        .flags = 0,
    };
    if (!ok(linux.sendmsg(sock, &mh, linux.MSG.NOSIGNAL))) wm.log("the launcher did not take a command", .{});
}

/// A connection the compositor opens itself for a granted program: the privileged globals are
/// offered on this connection only (client.State.caps), never on a socket anyone can connect to.
fn privilegedClient(caps: T.Caps) linux.fd_t {
    var sv: [2]linux.fd_t = undefined;
    if (!ok(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sv))) return -1;
    const cl = c.wl_client_create(wm.s.display, sv[0]) orelse {
        _ = c.close(sv[0]);
        _ = c.close(sv[1]);
        return -1;
    };
    const st = client.ensure(cl) orelse {
        c.wl_client_destroy(cl);
        _ = c.close(sv[1]);
        return -1;
    };
    st.caps = caps;
    return sv[1];
}

// ------------------------------------------------------------------ the launcher process

extern var environ: [*c][*c]u8;

fn ignore(_: c_int) callconv(.c) void {}

fn serve(fd: linux.fd_t) noreturn {
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr("refurs-launcher"), 0, 0, 0);
    sandbox.noDump();
    sandbox.dropCaps();
    // it ends with the compositor (EOF below), not on a stray signal from the terminal
    var sa = std.mem.zeroes(c.struct_sigaction);
    sa.__sigaction_handler.sa_handler = ignore;
    for ([_]c_int{ c.SIGINT, c.SIGHUP, c.SIGQUIT, c.SIGPIPE }) |sig| _ = c.sigaction(sig, &sa, null);
    sa = std.mem.zeroes(c.struct_sigaction);
    sa.sa_flags = c.SA_NOCLDWAIT;
    _ = c.sigaction(c.SIGCHLD, &sa, null);

    var name: [32:0]u8 = @splat(0);
    while (true) {
        var m: Msg = undefined;
        var cm: FdCmsg = undefined;
        var iov = [1]std.posix.iovec{.{ .base = @ptrCast(&m), .len = @sizeOf(Msg) }};
        var mh: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cm,
            .controllen = @sizeOf(FdCmsg),
            .flags = 0,
        };
        const rc = linux.recvmsg(fd, &mh, linux.MSG.CMSG_CLOEXEC);
        if (linux.errno(rc) == .INTR) continue;
        if (!ok(rc) or rc == 0) break; // the compositor is gone
        const conn: linux.fd_t = if (mh.controllen >= @sizeOf(FdCmsg) - @sizeOf(c_int) and cm.level == linux.SOL.SOCKET and cm.type == linux.SCM.RIGHTS) cm.fd else -1;
        defer if (conn >= 0) {
            _ = c.close(conn);
        };
        if (rc != @sizeOf(Msg)) continue;
        switch (m.kind) {
            .env => setSessionEnv(&m, &name),
            .spawn => if (m.idx < cmds.len) runCmd(m.idx, conn, m.getToken()),
            .startup => runStartup(conn, m.getToken()),
            _ => {},
        }
    }
    cleanup(&name);
    c._exit(0);
}

fn setSessionEnv(m: *const Msg, name: *[32:0]u8) void {
    const n = m.name[0..@min(m.name_len, m.name.len)];
    if (!policy.validDisplayName(n)) return;
    @memcpy(name[0..n.len], n);
    name[n.len] = 0;
    _ = c.setenv("WAYLAND_DISPLAY", name, 1);
    _ = c.setenv("XDG_CURRENT_DESKTOP", "RefursWM", 1);
    _ = c.setenv("XDG_SESSION_TYPE", "wayland", 1);
    _ = c.unsetenv("DISPLAY");
    _ = c.unsetenv("XAUTHORITY");
    var size_buf: [16]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&size_buf, "{d}", .{cfg.cursor_size}, 0)) |sz| {
        _ = c.setenv("XCURSOR_SIZE", sz.ptr, 1);
    } else |_| {}
    if (cfg.cursor_theme) |th| _ = c.setenv("XCURSOR_THEME", th, 1);
    // only Wayland: toolkits must not even try X11 (unless the user said otherwise)
    const hints = [_][2][*:0]const u8{
        .{ "QT_QPA_PLATFORM", "wayland" },
        .{ "GDK_BACKEND", "wayland" },
        .{ "SDL_VIDEODRIVER", "wayland" },
        .{ "CLUTTER_BACKEND", "wayland" },
        .{ "MOZ_ENABLE_WAYLAND", "1" },
        .{ "ELECTRON_OZONE_PLATFORM_HINT", "wayland" },
    };
    for (hints) |kv| _ = c.setenv(kv[0], kv[1], 0);
}

fn runCmd(idx: u16, conn: linux.fd_t, token: []const u8) void {
    var argv: [max_args + 1]?[*:0]const u8 = @splat(null);
    for (cmds[idx], 0..) |a, j| argv[j] = a;
    exec(&argv, conn, token);
}

fn runStartup(conn: linux.fd_t, token: []const u8) void {
    const st = std.mem.span(c.getenv("REFURS_STARTUP") orelse return);
    var buf: [512:0]u8 = @splat(0);
    if (st.len >= buf.len) return;
    @memcpy(buf[0..st.len], st);
    for (buf[0..st.len]) |*ch| if (ch.* == ' ') {
        ch.* = 0;
    };
    var argv: [17]?[*:0]const u8 = @splat(null);
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..st.len], 0);
    while (it.next()) |tok| if (n < argv.len - 1) {
        argv[n] = @ptrCast(tok.ptr);
        n += 1;
    };
    if (n == 0) return;
    exec(&argv, conn, token);
}

/// posix_spawn (vfork-fast), no shell: own session, default signals, empty signal mask, stdin from
/// /dev/null. A granted program (exact absolute path, no $PATH lookup) gets the privileged
/// connection as fd 3 and WAYLAND_SOCKET=3; nobody else ever sees that connection.
fn exec(argv: []?[*:0]const u8, conn_in: linux.fd_t, token: []const u8) void {
    const prog = std.mem.span(argv[0].?);
    const granted = policy.grantOf(&cfg.grants, prog) != null;
    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return;
    defer _ = c.posix_spawnattr_destroy(&attr);
    var def: c.sigset_t = undefined;
    _ = c.sigemptyset(&def);
    for ([_]c_int{ c.SIGCHLD, c.SIGPIPE, c.SIGINT, c.SIGHUP, c.SIGQUIT }) |sig| _ = c.sigaddset(&def, sig);
    var mask: c.sigset_t = undefined;
    _ = c.sigemptyset(&mask);
    _ = c.posix_spawnattr_setsigdefault(&attr, &def);
    _ = c.posix_spawnattr_setsigmask(&attr, &mask);
    _ = c.posix_spawnattr_setflags(&attr, c.POSIX_SPAWN_SETSID | c.POSIX_SPAWN_SETSIGDEF | c.POSIX_SPAWN_SETSIGMASK);
    var fa: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&fa) != 0) return;
    defer _ = c.posix_spawn_file_actions_destroy(&fa);
    _ = c.posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", c.O_RDONLY, 0);

    var conn = conn_in;
    if (granted and conn >= 0) {
        // dup2 onto itself would keep CLOEXEC: move it out of the way first
        if (conn == 3) conn = c.fcntl(conn_in, c.F_DUPFD_CLOEXEC, @as(c_int, 10));
        if (conn >= 0) {
            _ = c.posix_spawn_file_actions_adddup2(&fa, conn, 3);
            _ = c.setenv("WAYLAND_SOCKET", "3", 1);
        }
    }
    defer {
        _ = c.unsetenv("WAYLAND_SOCKET");
        if (conn >= 0 and conn != conn_in) _ = c.close(conn);
    }
    var tbuf: [65]u8 = @splat(0);
    if (token.len > 0 and token.len < tbuf.len) {
        @memcpy(tbuf[0..token.len], token);
        _ = c.setenv("XDG_ACTIVATION_TOKEN", @ptrCast(&tbuf), 1);
        _ = c.setenv("DESKTOP_STARTUP_ID", @ptrCast(&tbuf), 1);
    }
    defer {
        _ = c.unsetenv("XDG_ACTIVATION_TOKEN");
        _ = c.unsetenv("DESKTOP_STARTUP_ID");
    }
    var pid: c.pid_t = 0;
    const rc = if (granted)
        c.posix_spawn(&pid, argv[0].?, &fa, &attr, @ptrCast(argv.ptr), environ)
    else
        c.posix_spawnp(&pid, argv[0].?, &fa, &attr, @ptrCast(argv.ptr), environ);
    if (rc != 0) wm.log("cannot run {s}: error {d}", .{ prog, rc });
}

/// The compositor is gone: remove its sockets (it may not be allowed to itself, see sandbox.zig).
fn cleanup(name: *const [32:0]u8) void {
    const n = std.mem.sliceTo(name, 0);
    if (n.len == 0) return;
    const dir = std.mem.span(c.getenv("XDG_RUNTIME_DIR") orelse return);
    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "", ".lock", "-sandbox" }) |suffix| {
        const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}{s}", .{ dir, n, suffix }, 0) catch continue;
        _ = c.unlink(p.ptr);
    }
}
