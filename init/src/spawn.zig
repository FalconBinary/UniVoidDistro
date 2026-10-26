//! vh-init: starting a service process. Everything the child needs is prepared before fork
//! (no allocation after it): argv and the environment as NUL-terminated arrays, the user's
//! ids and groups, the cgroup path. The child: a new session, its stdio (stdin /dev/null or
//! the logger's pipe, stdout and stderr the log pipe), the readiness fd, the working
//! directory, umask, the cgroup, oom_score_adj, nice and the scheduling class, rlimits, the
//! user and the capabilities, no_new_privs, the "x86_64 ABI only" seccomp filter, execve.
//! An exec failure comes back through a CLOEXEC pipe as the errno.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const svc = @import("svc.zig");
const sys = @import("sys.zig");
const cgroup = @import("cgroup.zig");

pub const Io = struct {
    /// the service's stdin; -1 is /dev/null
    stdin: linux.fd_t = -1,
    /// stdout and stderr; -1 keeps the manager's (the console)
    stdout: linux.fd_t = -1,
    /// the readiness pipe's write end and the fd number the program expects it at
    ready: linux.fd_t = -1,
    ready_at: u8 = 0,
};

pub const Result = union(enum) {
    pid: linux.pid_t,
    /// the child could not exec: the errno
    exec_failed: linux.E,
    /// fork failed
    fork_failed: linux.E,
};

/// the user's supplementary groups from /etc/group (initgroups)
pub fn userGroups(user: []const u8, primary: u32) []const u32 {
    var list: std.ArrayList(u32) = .empty;
    list.append(vh.gpa, primary) catch vh.oom();
    const text = vh.readFile(sys.p("/etc/group")) catch return list.items;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = mem.splitScalar(u8, line, ':');
        _ = f.next() orelse continue;
        _ = f.next() orelse continue;
        const gid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const members = f.next() orelse continue;
        var m = mem.tokenizeScalar(u8, members, ',');
        while (m.next()) |name| if (vh.eql(name, user) and gid != primary) {
            list.append(vh.gpa, gid) catch vh.oom();
            break;
        };
    }
    return list.items;
}

/// capability numbers by name (without CAP_, any case); null for an unknown name
pub fn capNumber(name: []const u8) ?u8 {
    const names = [_][]const u8{
        "chown",            "dac_override",     "dac_read_search", "fowner",          "fsetid",          "kill",            "setgid",      "setuid",
        "setpcap",          "linux_immutable",  "net_bind_service", "net_broadcast",  "net_admin",       "net_raw",         "ipc_lock",    "ipc_owner",
        "sys_module",       "sys_rawio",        "sys_chroot",      "sys_ptrace",      "sys_pacct",       "sys_admin",       "sys_boot",    "sys_nice",
        "sys_resource",     "sys_time",         "sys_tty_config",  "mknod",           "lease",           "audit_write",     "audit_control", "setfcap",
        "mac_override",     "mac_admin",        "syslog",          "wake_alarm",      "block_suspend",   "audit_read",      "perfmon",     "bpf",
        "checkpoint_restore",
    };
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, name);
    const n = if (vh.startsWith(lower, "cap_")) lower[4..] else lower;
    for (names, 0..) |c, i| if (vh.eql(c, n)) return @intCast(i);
    return null;
}

pub const cap_last = 40;

/// the seccomp filter "only the native ABI": a foreign architecture or the x32 bit kills the
/// process (docs/principles.md: every process tree but the gaming one). Six instructions,
/// no argument is read, so the kernel caches the verdict per system call.
/// struct sock_filter and struct sock_fprog of classic BPF (linux/filter.h)
pub const SockFilter = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
pub const SockFprog = extern struct { len: u16, filter: [*]const SockFilter };

pub fn abiFilter() [6]SockFilter {
    // classic BPF: ld arch; jeq native,+1,kill; ld nr; jge X32,kill,allow; ret allow; ret kill
    const AUDIT_ARCH: u32 = switch (builtin.cpu.arch) {
        .x86_64 => 0xC000003E,
        .aarch64 => 0xC00000B7,
        else => @compileError("abiFilter: architecture"),
    };
    const X32_BIT: u32 = 0x40000000;
    const LD: u16 = 0x20;
    const JEQ: u16 = 0x15;
    const JGE: u16 = 0x35;
    const RET: u16 = 0x06;
    const ALLOW: u32 = 0x7FFF0000;
    const KILL_PROCESS: u32 = 0x80000000;
    // insn 3: on x86_64 a system call number with the x32 bit kills (jt -> insn 5); on
    // aarch64 there is no x32 ABI and the slot is a plain allow
    const insn3: SockFilter = if (builtin.cpu.arch == .x86_64) .{ .code = JGE, .jt = 1, .jf = 0, .k = X32_BIT } else .{ .code = RET, .jt = 0, .jf = 0, .k = ALLOW };
    return .{
        .{ .code = LD, .jt = 0, .jf = 0, .k = 4 }, // arch
        .{ .code = JEQ, .jt = 0, .jf = 3, .k = AUDIT_ARCH }, // foreign -> insn 5: kill
        .{ .code = LD, .jt = 0, .jf = 0, .k = 0 }, // nr
        insn3,
        .{ .code = RET, .jt = 0, .jf = 0, .k = ALLOW },
        .{ .code = RET, .jt = 0, .jf = 0, .k = KILL_PROCESS },
    };
}

const Prepared = struct {
    argv: [:null]?[*:0]const u8,
    envp: [:null]?[*:0]const u8,
    exe: [*:0]const u8,
    cwd: ?[*:0]const u8,
    cgroup_procs: ?[*:0]const u8,
    uid: ?u32,
    gid: ?u32,
    groups: []const u32,
    caps: ?u64,
    oom: ?[]const u8,
};

fn prepare(s: *const svc.Service) ?Prepared {
    const argv = vh.gpa.allocSentinel(?[*:0]const u8, s.exec.len, null) catch vh.oom();
    for (s.exec, 0..) |a, i| argv[i] = vh.z(a).ptr;
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    env.append(vh.gpa, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin") catch vh.oom();
    for (s.env) |e| env.append(vh.gpa, vh.z(e).ptr) catch vh.oom();
    const envp = env.toOwnedSliceSentinel(vh.gpa, null) catch vh.oom();
    var p: Prepared = .{
        .argv = argv,
        .envp = envp,
        .exe = argv[0].?,
        .cwd = if (s.cwd) |c| vh.z(c).ptr else null,
        .cgroup_procs = if (cgroup.available) vh.z(vh.fmt("{s}/cgroup.procs", .{cgroup.path(s.name)})).ptr else null,
        .uid = null,
        .gid = null,
        .groups = &.{},
        .caps = null,
        .oom = if (s.oom_score_adj) |o| vh.fmt("{d}", .{o}) else null,
    };
    if (s.user) |u| {
        const id = sys.userId(u) orelse {
            vh.warn("{s}: no user {s}", .{ s.name, u });
            return null;
        };
        p.uid = id.uid;
        p.gid = id.gid;
        p.groups = userGroups(u, id.gid);
    }
    if (s.group) |g| {
        p.gid = sys.groupId(g) orelse {
            vh.warn("{s}: no group {s}", .{ s.name, g });
            return null;
        };
        if (s.user == null) p.groups = vh.gpa.dupe(u32, &.{p.gid.?}) catch vh.oom();
    }
    if (s.caps) |names| {
        var mask: u64 = 0;
        for (names) |n| {
            const c = capNumber(n) orelse {
                vh.warn("{s}: unknown capability {s}", .{ s.name, n });
                return null;
            };
            mask |= @as(u64, 1) << @intCast(c);
        }
        p.caps = mask;
    }
    return p;
}

/// start the service; the parent closes nothing of `io` (the caller owns those fds)
pub fn spawn(s: *const svc.Service, io: Io) Result {
    const p = prepare(s) orelse return .{ .exec_failed = .INVAL };
    var errpipe: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&errpipe, .{ .CLOEXEC = true })) != .SUCCESS) return .{ .fork_failed = linux.errno(linux.pipe2(&errpipe, .{ .CLOEXEC = true })) };
    const filter = abiFilter();
    const prog: SockFprog = .{ .len = filter.len, .filter = &filter };
    vh.flush();
    const rc = linux.fork();
    const e = linux.errno(rc);
    if (e != .SUCCESS) {
        vh.close(errpipe[0]);
        vh.close(errpipe[1]);
        return .{ .fork_failed = e };
    }
    if (rc == 0) child(s, &p, io, errpipe[1], &prog);
    vh.close(errpipe[1]);
    var code: [4]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        const n = vh.readFd(errpipe[0], code[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    vh.close(errpipe[0]);
    const pid: linux.pid_t = @intCast(rc);
    if (got == 4) {
        // the exec failed: the child has exited with 127; reap it here
        var st: i32 = 0;
        _ = linux.wait4(pid, &st, 0, null);
        return .{ .exec_failed = @enumFromInt(mem.readInt(u32, &code, .little)) };
    }
    return .{ .pid = pid };
}

fn fail(errpipe: linux.fd_t, e: linux.E) noreturn {
    var code: [4]u8 = undefined;
    mem.writeInt(u32, &code, @intFromEnum(e), .little);
    _ = linux.write(errpipe, &code, 4);
    linux.exit_group(127);
}

fn check(errpipe: linux.fd_t, rc: usize) void {
    const e = linux.errno(rc);
    if (e != .SUCCESS) fail(errpipe, e);
}

/// the child: system calls only, nothing allocated
fn child(s: *const svc.Service, p: *const Prepared, io: Io, errpipe: linux.fd_t, prog: *const SockFprog) noreturn {
    // every signal unblocked; the manager keeps them blocked for its signalfd
    const empty = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
    _ = linux.setsid();
    // stdio
    if (io.stdin >= 0) {
        check(errpipe, linux.dup2(io.stdin, 0));
    } else {
        const nul = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(nul) == .SUCCESS) {
            _ = linux.dup2(@intCast(nul), 0);
            if (nul != 0) _ = linux.close(@intCast(nul));
        }
    }
    if (io.stdout >= 0) {
        check(errpipe, linux.dup2(io.stdout, 1));
        check(errpipe, linux.dup2(io.stdout, 2));
    }
    if (io.ready >= 0) {
        // dup2 clears CLOEXEC on the copy; the original is CLOEXEC and goes at exec. The pipe
        // may already sit at the wanted number: then its CLOEXEC flag goes instead.
        if (io.ready != io.ready_at) check(errpipe, linux.dup2(io.ready, io.ready_at)) else _ = linux.fcntl(io.ready, linux.F.SETFD, 0);
    }
    if (p.cwd) |d| check(errpipe, linux.chdir(d));
    _ = linux.syscall1(.umask, s.umask);
    if (p.cgroup_procs) |cg| {
        const fd = linux.open(cg, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) == .SUCCESS) {
            _ = linux.write(@intCast(fd), "0", 1);
            _ = linux.close(@intCast(fd));
        }
    }
    if (p.oom) |o| {
        const fd = linux.open("/proc/self/oom_score_adj", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) == .SUCCESS) {
            _ = linux.write(@intCast(fd), o.ptr, o.len);
            _ = linux.close(@intCast(fd));
        }
    }
    if (s.nice != 0) _ = linux.syscall3(.setpriority, 0, 0, @as(usize, @bitCast(@as(isize, s.nice))));
    switch (s.sched) {
        .normal => {},
        .batch, .idle => {
            const param: linux.sched_param = .{ .priority = 0 };
            const policy: linux.SCHED = .{ .mode = if (s.sched == .batch) .BATCH else .IDLE };
            _ = linux.sched_setscheduler(0, policy, &param);
        },
    }
    if (s.rlimit_nofile) |n| {
        const lim: linux.rlimit = .{ .cur = n, .max = n };
        _ = linux.setrlimit(.NOFILE, &lim);
    }
    // the user and the capabilities
    if (p.caps) |mask| {
        // the bounding set first, while CAP_SETPCAP is still effective: every capability not wanted goes
        var c: u8 = 0;
        while (c <= cap_last) : (c += 1) {
            if (mask & (@as(u64, 1) << @intCast(c)) == 0) _ = linux.prctl(@intFromEnum(linux.PR.CAPBSET_DROP), c, 0, 0, 0);
        }
        // keep the permitted set across the uid change, then make it exactly the wanted set
        if (p.uid != null) check(errpipe, linux.prctl(@intFromEnum(linux.PR.SET_KEEPCAPS), 1, 0, 0, 0));
    }
    if (p.gid) |g| {
        check(errpipe, linux.setgroups(p.groups.len, p.groups.ptr));
        check(errpipe, linux.setresgid(g, g, g));
    }
    if (p.uid) |u| check(errpipe, linux.setresuid(u, u, u));
    if (p.caps) |mask| {
        // effective, permitted, inheritable = mask (v3: two 32-bit words)
        var hdr: linux.cap_user_header_t = .{ .version = 0x20080522, .pid = 0 };
        const data = [2]linux.cap_user_data_t{
            .{ .effective = @truncate(mask), .permitted = @truncate(mask), .inheritable = @truncate(mask) },
            .{ .effective = @truncate(mask >> 32), .permitted = @truncate(mask >> 32), .inheritable = @truncate(mask >> 32) },
        };
        check(errpipe, linux.capset(&hdr, &data[0]));
        // ambient: the capabilities survive the exec of a program without file capabilities
        var c: u8 = 0;
        while (c <= cap_last) : (c += 1) {
            if (mask & (@as(u64, 1) << @intCast(c)) != 0) _ = linux.prctl(@intFromEnum(linux.PR.CAP_AMBIENT), 2, c, 0, 0); // PR_CAP_AMBIENT_RAISE
        }
    }
    if (s.no_new_privs) check(errpipe, linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0));
    if (s.abi_filter) {
        // needs no_new_privs or CAP_SYS_ADMIN; a runit script running as root has the latter
        const rc = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, prog);
        if (linux.errno(rc) != .SUCCESS and s.no_new_privs) fail(errpipe, linux.errno(rc));
    }
    const rc = linux.execve(p.exe, p.argv.ptr, p.envp.ptr);
    fail(errpipe, linux.errno(rc));
}

const testing = std.testing;

test "capability names" {
    try testing.expectEqual(@as(?u8, 0), capNumber("chown"));
    try testing.expectEqual(@as(?u8, 10), capNumber("NET_BIND_SERVICE"));
    try testing.expectEqual(@as(?u8, 12), capNumber("cap_net_admin"));
    try testing.expectEqual(@as(?u8, 39), capNumber("bpf"));
    try testing.expectEqual(@as(?u8, 40), capNumber("checkpoint_restore"));
    try testing.expect(capNumber("nope") == null);
}

test "the ABI filter kills a foreign architecture and allows the native one" {
    const f = abiFilter();
    try testing.expectEqual(@as(usize, 6), f.len);
    // interpret: arch load, compare
    try testing.expectEqual(@as(u32, 0x7FFF0000), f[4].k);
    try testing.expectEqual(@as(u32, 0x80000000), f[5].k);
    try testing.expectEqual(@as(u8, 3), f[1].jf); // a foreign arch jumps to the kill
}

test "supplementary groups" {
    // the real /etc/group of the test machine: root is in root (gid 0) at least
    const g = userGroups("root", 0);
    try testing.expect(g.len >= 1);
    try testing.expectEqual(@as(u32, 0), g[0]);
}
