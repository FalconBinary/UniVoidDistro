//! vh-game-enter: the login shell of the game user (track G, docs/uni/game.md). login(1) starts
//! it on tty3 after PAM has let game in (pam_access: game on tty3 only; pam_shells: it is in
//! /etc/shells). It needs no privilege and no helper running as root: with the user namespaces
//! every user has (the browser's sandbox uses them too) it builds the session and starts a
//! login shell of the gaming root in it.
//!
//!   - namespaces of user, mount, PID, IPC, UTS, network and cgroup. game stays game inside (its
//!     uid and gid map to themselves), its groups _seatd and render stay with it (setgroups is
//!     denied, so it cannot drop or gain one);
//!   - the gaming root /var/lib/vh/roots/game read-only as /; the home /home/game; a /dev of its
//!     own: null, zero, full, random, urandom, tty, the login's terminal, a new instance of pts,
//!     shm and the GPU's /dev/dri, nothing else (no input device: seatd hands gamescope those of
//!     the active session, and takes them back at a VT switch); a /proc of the session's PID
//!     namespace; sysfs read-only; /run with seatd's socket and udev's database (read-only);
//!     /tmp and /var/tmp in memory;
//!   - no network: the loopback interface only (the network namespace hides the abstract
//!     sockets of the session's Xwayland from every other process too); the host name "game";
//!   - no new privileges and no capability for the programs of the session.
//!
//! The session's first process is PID 1 of its PID namespace: when the login shell ends, every
//! process of the session ends with it.
//!
//!   vh-game-enter              an interactive login shell in the root (login runs it as "-vh-game-enter")
//!   vh-game-enter -c CMD       CMD by bash in the root
//!   vh-game-enter --check      the session made, checked from inside: VH_GAME_ENTER ok=N fail=N
//!
//! Static PIE, ReleaseSafe, std.os.linux only (zig/README.md).
const std = @import("std");
const vh = @import("vh");
const common = @import("common.zig");
const accounts = @import("accounts.zig");
const sys = @import("sys.zig");
const linux = std.os.linux;
const mem = std.mem;
const MS = sys.MS;

const root_dir = common.roots_dir ++ "/" ++ common.game.root;
const hostname = "game";

const Mode = enum { shell, command, check };

const Session = struct {
    uid: u32,
    gid: u32,
    name: []const u8,
    home: []const u8,
    /// the login's terminal, "/dev/tty3"; null without one
    tty: ?[]const u8,
    term: []const u8,
    mode: Mode,
    command: []const u8 = "",
};

pub fn main(init: std.process.Init.Minimal) void {
    var it = init.args.iterate();
    const argv0 = it.next() orelse "vh-game-enter";
    const args = vh.init(init, "vh-game-enter");
    var mode: Mode = .shell;
    var command: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (vh.eql(a, "-c")) {
            if (i + 1 >= args.len) vh.die("-c needs a command", .{});
            i += 1;
            mode = .command;
            command = args[i];
        } else if (vh.eql(a, "--check")) {
            mode = .check;
        } else if (vh.eql(a, "-l") or vh.eql(a, "--login")) {
            mode = .shell;
        } else vh.die("usage: vh-game-enter [-c COMMAND | --check]", .{});
    }
    _ = argv0;
    vh.exit(run(mode, command));
}

fn run(mode: Mode, command: []const u8) u8 {
    const uid = linux.getuid();
    const gid = linux.getgid();
    if (uid == 0) vh.die("the gaming session is not for root", .{});
    if (!vh.isDir(root_dir)) vh.die("{s}: no gaming root (doas vh-game install)", .{root_dir});
    const passwd = vh.readFile("/etc/passwd") catch vh.die("/etc/passwd: {s}", .{vh.serr()});
    const me = ownLine(passwd, uid) orelse vh.die("uid {d} is not in /etc/passwd", .{uid});
    const tty: ?[]const u8 = if (vh.readlink("/proc/self/fd/0")) |l| (if (vh.startsWith(l, "/dev/")) l else null) else |_| null;
    const s: Session = .{
        .uid = uid,
        .gid = gid,
        .name = accounts.field(me, 0).?,
        .home = accounts.field(me, 5) orelse vh.die("/etc/passwd: no home for uid {d}", .{uid}),
        .tty = tty,
        .term = vh.getenv("TERM") orelse "linux",
        .mode = mode,
        .command = command,
    };
    if (!vh.isDir(s.home)) vh.die("{s}: no home", .{s.home});

    sys.unshare(linux.CLONE.NEWUSER | linux.CLONE.NEWNS | linux.CLONE.NEWPID | linux.CLONE.NEWIPC |
        linux.CLONE.NEWUTS | linux.CLONE.NEWNET | linux.CLONE.NEWCGROUP) catch vh.die("unshare: {s} (user namespaces are needed)", .{vh.serr()});
    sys.writeOnce("/proc/self/setgroups", "deny") catch vh.die("setgroups: {s}", .{vh.serr()});
    sys.writeOnce("/proc/self/uid_map", vh.fmt("{d} {d} 1\n", .{ uid, uid })) catch vh.die("uid_map: {s}", .{vh.serr()});
    sys.writeOnce("/proc/self/gid_map", vh.fmt("{d} {d} 1\n", .{ gid, gid })) catch vh.die("gid_map: {s}", .{vh.serr()});

    // the first child is PID 1 of the session's PID namespace
    vh.flush();
    const pid_rc = vh.sys(linux.fork()) catch vh.die("fork: {s}", .{vh.serr()});
    if (pid_rc == 0) init1(s);
    session_pid = @intCast(pid_rc);
    // a hangup of the terminal or a TERM ends the whole session: SIGKILL to its PID 1 (the init
    // of a PID namespace takes from an ancestor only the signals it handles, and SIGKILL)
    handle(linux.SIG.HUP, onEnd);
    handle(linux.SIG.TERM, onEnd);
    ignore(linux.SIG.INT);
    ignore(linux.SIG.QUIT);
    return waitFor(session_pid);
}

/// the line of /etc/passwd with uid UID
fn ownLine(passwd: []const u8, uid: u32) ?[]const u8 {
    var it = mem.splitScalar(u8, passwd, '\n');
    while (it.next()) |l| {
        const f = accounts.field(l, 2) orelse continue;
        if ((std.fmt.parseInt(u32, f, 10) catch continue) == uid) return l;
    }
    return null;
}

var session_pid: linux.pid_t = 0;

fn onEnd(_: linux.SIG) callconv(.c) void {
    if (session_pid > 0) _ = linux.kill(session_pid, .KILL);
}

fn handle(sig: linux.SIG, f: *const fn (linux.SIG) callconv(.c) void) void {
    var sa = mem.zeroes(linux.Sigaction);
    sa.handler = .{ .handler = f };
    _ = linux.sigaction(sig, &sa, null);
}

fn ignore(sig: linux.SIG) void {
    var sa = mem.zeroes(linux.Sigaction);
    sa.handler = .{ .handler = linux.SIG.IGN };
    _ = linux.sigaction(sig, &sa, null);
}

/// the exit code of PID: its own, or 128 + the signal that ended it
fn waitFor(pid: linux.pid_t) u8 {
    var st: i32 = 0;
    while (true) {
        const rc = linux.wait4(pid, &st, 0, null);
        const e = linux.errno(rc);
        if (e == .SUCCESS) break;
        if (e != .INTR) return 1;
    }
    const u: u32 = @bitCast(st);
    if (linux.W.IFEXITED(u)) return linux.W.EXITSTATUS(u);
    return @truncate(128 + @intFromEnum(linux.W.TERMSIG(u)));
}

// ---------------------------------------------------------------- PID 1 of the session

fn init1(s: Session) noreturn {
    build(s) catch {
        vh.warn("the session could not be made: {s}: {s}", .{ step, vh.serr() });
        linux.exit_group(1);
    };
    // PID 2 is the session's program; PID 1 reaps every process until it ends
    vh.flush();
    const rc = vh.sys(linux.fork()) catch vh.die("fork: {s}", .{vh.serr()});
    if (rc == 0) program(s);
    const main_pid: linux.pid_t = @intCast(rc);
    var code: u8 = 1;
    while (true) {
        var st: i32 = 0;
        const r = linux.wait4(-1, &st, 0, null);
        const e = linux.errno(r);
        if (e == .INTR) continue;
        if (e != .SUCCESS) break;
        if (@as(linux.pid_t, @intCast(r)) != main_pid) continue;
        const u: u32 = @bitCast(st);
        code = if (linux.W.IFEXITED(u)) linux.W.EXITSTATUS(u) else @truncate(128 + @intFromEnum(linux.W.TERMSIG(u)));
        break;
    }
    // the init of a PID namespace ending takes every other process of it along
    linux.exit_group(code);
}

/// the step of build() that failed, for the message
var step: []const u8 = "";

fn at(comptime what: []const u8) void {
    step = what;
}

fn inRoot(p: []const u8) []const u8 {
    return vh.fmt("{s}{s}", .{ root_dir, p });
}

/// The session's file system, then the root it pivots into. Every mount is made in the
/// session's own mount namespace: the system's mounts do not change.
fn build(s: Session) vh.Error!void {
    at("mount propagation");
    try sys.mount(null, "/", null, MS.REC | MS.PRIVATE, null);
    // the root: read-only, without SUID bits or device nodes
    at("the gaming root");
    try sys.bindKeep(root_dir, root_dir, false, MS.RDONLY | MS.NOSUID | MS.NODEV);
    at("/proc");
    try sys.mount("proc", inRoot("/proc"), "proc", MS.NOSUID | MS.NODEV | MS.NOEXEC, null);
    at("/sys");
    // a sysfs of the session's network namespace (only lo in /sys/class/net), read-only; the
    // system's /sys bound read-only where a new one is refused
    sys.mount("sysfs", inRoot("/sys"), "sysfs", MS.RDONLY | MS.NOSUID | MS.NODEV | MS.NOEXEC, null) catch
        try sys.bindKeep("/sys", inRoot("/sys"), true, MS.RDONLY);
    at("/dev");
    try sys.mount("tmpfs", inRoot("/dev"), "tmpfs", MS.NOSUID | MS.NOEXEC, "mode=0755,size=1m");
    for ([_][]const u8{ "null", "zero", "full", "random", "urandom", "tty" }) |d| try bindNode(vh.fmt("/dev/{s}", .{d}));
    if (s.tty) |t| if (!vh.eql(t, "/dev/tty")) try bindNode(t);
    if (vh.isDir("/dev/dri")) {
        try sys.mkdir(inRoot("/dev/dri"), 0o755);
        try sys.bindKeep("/dev/dri", inRoot("/dev/dri"), false, 0);
    }
    at("/dev/pts");
    try sys.mkdir(inRoot("/dev/pts"), 0o755);
    try sys.mount("devpts", inRoot("/dev/pts"), "devpts", MS.NOSUID | MS.NOEXEC, "newinstance,ptmxmode=0666,mode=0620");
    try sys.symlink("pts/ptmx", inRoot("/dev/ptmx"));
    try sys.mkdir(inRoot("/dev/shm"), 0o755);
    try sys.mount("tmpfs", inRoot("/dev/shm"), "tmpfs", MS.NOSUID | MS.NODEV, "mode=1777");
    for ([_][2][]const u8{ .{ "/proc/self/fd", "fd" }, .{ "/proc/self/fd/0", "stdin" }, .{ "/proc/self/fd/1", "stdout" }, .{ "/proc/self/fd/2", "stderr" } }) |l|
        try sys.symlink(l[0], inRoot(vh.fmt("/dev/{s}", .{l[1]})));
    at("/run");
    try sys.mount("tmpfs", inRoot("/run"), "tmpfs", MS.NOSUID | MS.NODEV | MS.NOEXEC, "mode=0755");
    try sys.mkdir(inRoot("/run/user"), 0o755);
    try sys.mkdir(inRoot(vh.fmt("/run/user/{d}", .{s.uid})), 0o700);
    if (vh.pathExists("/run/seatd.sock")) {
        try sys.touch(inRoot("/run/seatd.sock"), 0o600);
        try sys.bindKeep("/run/seatd.sock", inRoot("/run/seatd.sock"), false, 0);
    }
    if (vh.isDir("/run/udev")) {
        try sys.mkdir(inRoot("/run/udev"), 0o755);
        try sys.bindKeep("/run/udev", inRoot("/run/udev"), true, MS.RDONLY);
    }
    at("/tmp");
    try sys.mount("tmpfs", inRoot("/tmp"), "tmpfs", MS.NOSUID | MS.NODEV, "mode=1777");
    if (vh.isDir(inRoot("/var/tmp"))) try sys.mount("tmpfs", inRoot("/var/tmp"), "tmpfs", MS.NOSUID | MS.NODEV, "mode=1777");
    at("the home");
    try sys.bindKeep(s.home, inRoot(s.home), false, 0);
    at("pivot_root");
    try sys.pivotHere(root_dir);
    at("the host name");
    try sys.sethostname(hostname);
    at("the loopback interface");
    try sys.loopbackUp();
}

/// a device node of the system, bound onto an empty file of the session's /dev
fn bindNode(dev: []const u8) vh.Error!void {
    if (!vh.pathExists(dev)) return;
    try sys.touch(inRoot(dev), 0o600);
    try sys.bindKeep(dev, inRoot(dev), false, 0);
}

// ---------------------------------------------------------------- the session's program

fn program(s: Session) noreturn {
    sys.noNewPrivs() catch vh.die("no_new_privs: {s}", .{vh.serr()});
    sys.dropCaps() catch vh.die("capabilities: {s}", .{vh.serr()});
    sys.umask(0o077);
    _ = linux.chdir(vh.z(s.home).ptr);
    const runtime = vh.fmt("/run/user/{d}", .{s.uid});
    const env = [_][]const u8{
        vh.fmt("HOME={s}", .{s.home}),
        vh.fmt("USER={s}", .{s.name}),
        vh.fmt("LOGNAME={s}", .{s.name}),
        "SHELL=/bin/bash",
        "PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin",
        vh.fmt("TERM={s}", .{s.term}),
        "LANG=C.UTF-8",
        vh.fmt("XDG_RUNTIME_DIR={s}", .{runtime}),
    };
    const envp = vh.gpa.allocSentinel(?[*:0]const u8, env.len, null) catch vh.oom();
    for (env, 0..) |e, i| envp[i] = vh.z(e).ptr;
    vh.envp = envp.ptr;
    if (s.mode == .check) linux.exit_group(check(s));
    const argv: []const []const u8 = switch (s.mode) {
        .shell => &.{"-bash"},
        .command => &.{ "bash", "-c", s.command },
        .check => unreachable,
    };
    const cargv = vh.gpa.allocSentinel(?[*:0]const u8, argv.len, null) catch vh.oom();
    for (argv, 0..) |a, i| cargv[i] = vh.z(a).ptr;
    vh.flush();
    const rc = linux.execve("/bin/bash", cargv.ptr, envp.ptr);
    vh.errno = linux.errno(rc);
    vh.die("/bin/bash of the gaming root: {s}", .{vh.serr()});
}

// ---------------------------------------------------------------- --check

var oks: usize = 0;
var fails: usize = 0;

fn expect(ok: bool, comptime what: []const u8, detail: []const u8) void {
    if (ok) oks += 1 else fails += 1;
    vh.out("{s} {s}{s}{s}\n", .{ if (ok) "ok" else "FAIL", what, if (detail.len > 0) ": " else "", detail });
}

fn statusField(status: []const u8, key: []const u8) []const u8 {
    var it = mem.splitScalar(u8, status, '\n');
    while (it.next()) |l| if (vh.startsWith(l, key) and l.len > key.len and l[key.len] == ':') return vh.strip(l[key.len + 1 ..]);
    return "";
}

/// the session as its programs see it
fn check(s: Session) u8 {
    const status = vh.readFile("/proc/self/status") catch "";
    expect(linux.getuid() == s.uid and linux.getgid() == s.gid, "the same user inside", vh.fmt("uid {d} gid {d}", .{ linux.getuid(), linux.getgid() }));
    const map = vh.strip(vh.readFile("/proc/self/uid_map") catch "");
    var mf = mem.tokenizeAny(u8, map, " \t\n");
    const m0 = mf.next() orelse "";
    const m1 = mf.next() orelse "";
    const m2 = mf.next() orelse "";
    expect(vh.eql(m0, vh.fmt("{d}", .{s.uid})) and vh.eql(m1, m0) and vh.eql(m2, "1") and mf.next() == null, "the user namespace maps game alone, onto itself", map);
    expect(linux.getpid() == 2 and linux.getppid() == 1, "PID 2 of a PID namespace of its own", vh.fmt("pid {d}, parent {d}", .{ linux.getpid(), linux.getppid() }));
    expect(vh.eql(statusField(status, "NoNewPrivs"), "1"), "no new privileges", statusField(status, "NoNewPrivs"));
    expect(vh.eql(statusField(status, "CapEff"), "0000000000000000") and vh.eql(statusField(status, "CapPrm"), "0000000000000000") and vh.eql(statusField(status, "CapBnd"), "0000000000000000"), "no capability", statusField(status, "CapBnd"));
    // the gaming tree is the one without the "x86_64 ABI only" filter (docs/uni/game.md)
    expect(vh.eql(statusField(status, "Seccomp"), "0"), "no seccomp filter", statusField(status, "Seccomp"));
    const groups = statusField(status, "Groups");
    expect(groups.len > 0, "the supplementary groups kept (seatd, render)", groups);
    // the root: read-only, the system's files out of sight
    const w = vh.openFd("/usr/.vh-game-check", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600);
    expect(if (w) |_| false else |_| vh.errno == .ROFS or vh.errno == .ACCES, "the root is read-only", if (w) |_| "written" else |_| vh.serr());
    expect(!vh.pathExists("/etc/vh") and !vh.pathExists("/root/vh") and !vh.pathExists("/var/lib/vh"), "the system's files are not there (the root is /)", "");
    var others: usize = 0;
    for (vh.listDir("/home") catch &.{}) |n| if (!vh.eql(vh.fmt("/home/{s}", .{n}), s.home)) {
        others += 1;
    };
    expect(others == 0, "no other home", vh.fmt("{d}", .{others}));
    // the home: writable, executable (games run from it)
    const probe = vh.fmt("{s}/.vh-game-check", .{s.home});
    const pw = vh.openFd(probe, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o700);
    if (pw) |fd| vh.close(fd) else |_| {}
    expect(if (pw) |_| true else |_| false, "the home is writable", s.home);
    if (pw) |_| vh.unlink(probe) catch {} else |_| {}
    const hflags = sys.mountFlags(s.home) catch 0;
    expect(hflags & MS.NOEXEC == 0 and hflags & MS.NOSUID != 0 and hflags & MS.NODEV != 0, "the home: exec, nosuid, nodev", vh.fmt("flags 0x{x}", .{hflags}));
    const tflags = sys.mountFlags("/tmp") catch 0;
    expect(tflags & MS.NOSUID != 0 and tflags & MS.NODEV != 0, "/tmp in memory: nosuid, nodev", vh.fmt("flags 0x{x}", .{tflags}));
    // its own PID namespace: the system's processes are not there
    var procs: usize = 0;
    for (vh.listDir("/proc") catch &.{}) |n| if (std.fmt.parseInt(u32, n, 10)) |_| {
        procs += 1;
    } else |_| {};
    expect(procs <= 4, "only the session's processes in /proc", vh.fmt("{d}", .{procs}));
    const comm1 = vh.strip(vh.readFile("/proc/1/comm") catch "");
    expect(vh.eql(comm1, "vh-game-enter"), "PID 1 is vh-game-enter", comm1);
    // no network: lo alone, and up
    var nets: vh.Strv = .{};
    for (vh.listDir("/sys/class/net") catch &.{}) |n| nets.add(n);
    expect(nets.len() == 1 and vh.eql(nets.slice()[0], "lo"), "the network: lo alone", nets.join(" "));
    expect(vh.eql(vh.strip(vh.readFile("/sys/class/net/lo/operstate") catch ""), "unknown") or vh.strip(vh.readFile("/sys/class/net/lo/flags") catch "").len > 0, "lo is there", "");
    expect(connectInet(.{ 1, 1, 1, 1 }, 443) == .NETUNREACH, "no route out", @tagName(connectInet(.{ 1, 1, 1, 1 }, 443)));
    var uts: linux.utsname = undefined;
    _ = linux.uname(&uts);
    const node = mem.sliceTo(&uts.nodename, 0);
    expect(vh.eql(node, hostname), "the host name", node);
    // a /dev of its own: the device nodes of a session and nothing more
    var devs: vh.Strv = .{};
    for (vh.listDir("/dev") catch &.{}) |n| devs.add(n);
    devs.sort();
    expect(!vh.pathExists("/dev/input") and !vh.pathExists("/dev/mem") and !vh.pathExists("/dev/kmsg") and !vh.pathExists("/dev/snd"), "no input, memory, kernel log or sound device", devs.join(" "));
    if (vh.isDir("/dev/dri")) {
        var dri: vh.Strv = .{};
        for (vh.listDir("/dev/dri") catch &.{}) |n| dri.add(n);
        expect(dri.len() > 0, "the GPU's /dev/dri", dri.join(" "));
    }
    const urandom = vh.openFd("/dev/urandom", .{ .ACCMODE = .RDONLY }, 0);
    if (urandom) |fd| vh.close(fd) else |_| {}
    expect(if (urandom) |_| true else |_| false, "/dev/urandom opens", "");
    // seatd's socket: gamescope reaches the seat through it
    if (vh.pathExists("/run/seatd.sock")) {
        const e = connectUnix("/run/seatd.sock");
        expect(e == .SUCCESS, "seatd's socket connects", @tagName(e));
    } else expect(false, "seatd's socket is there", "no /run/seatd.sock (is seatd running?)");
    expect(vh.isDir(vh.fmt("/run/user/{d}", .{s.uid})), "XDG_RUNTIME_DIR", vh.fmt("/run/user/{d}", .{s.uid}));
    vh.out("VH_GAME_ENTER ok={d} fail={d}\n", .{ oks, fails });
    vh.flush();
    return if (fails == 0) 0 else 1;
}

fn connectInet(addr: [4]u8, port: u16) linux.E {
    const fd: vh.fd_t = @intCast(vh.sys(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) catch return vh.errno);
    defer vh.close(fd);
    var sa: linux.sockaddr.in = .{ .port = mem.nativeToBig(u16, port), .addr = @bitCast(addr) };
    return linux.errno(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
}

fn connectUnix(p: []const u8) linux.E {
    const fd: vh.fd_t = @intCast(vh.sys(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)) catch return vh.errno);
    defer vh.close(fd);
    var sa: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(sa.path[0..p.len], p);
    return linux.errno(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.un)));
}

test "the passwd line of a uid" {
    const p = "root:x:0:0:root:/root:/bin/bash\ngame:x:1003:1003:gaming session (vh-game):/home/game:/usr/local/bin/vh-game-enter\n";
    try std.testing.expectEqualStrings("/home/game", accounts.field(ownLine(p, 1003).?, 5).?);
    try std.testing.expect(ownLine(p, 1004) == null);
}
