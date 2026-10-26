//! vh-init: the service manager, a separate process from PID 1 (docs/ROADMAP.md, I: "Process
//! split"). One event loop (epoll): a signalfd for SIGCHLD, the control socket of vh-ctl, the
//! channel to PID 1, the services' log and readiness pipes; the restart delays and the timers
//! of periodic oneshots are the loop's timeout. Services start in parallel as soon as what they
//! need is ready. A new manager after a crash finds the services a previous one left running
//! in their cgroups and watches them through pidfds.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const svc = @import("svc.zig");
const sys = @import("sys.zig");
const proto = @import("proto.zig");
const spawn = @import("spawn.zig");
const log = @import("log.zig");
const cgroup = @import("cgroup.zig");

pub const version = "0.2.0";

const State = proto.State;

const Inst = struct {
    s: svc.Service,
    state: State = .waiting,
    want_up: bool = true,
    /// `once`: not restarted after it exits
    once: bool = false,
    pid: linux.pid_t = 0,
    /// a process a previous manager started, watched through a pidfd
    pidfd: linux.fd_t = -1,
    logger_pid: linux.pid_t = 0,
    finish_pid: linux.pid_t = 0,
    check_pid: linux.pid_t = 0,
    /// the service's stdout pipe (read end) and its writer
    log_r: linux.fd_t = -1,
    /// the pipe between the service and its runit logger: kept so a restarted logger gets it again
    logger_pipe: [2]linux.fd_t = .{ -1, -1 },
    logw: log.Writer,
    ready_r: linux.fd_t = -1,
    /// when the state began (monotonic ms)
    since_ms: u64 = 0,
    /// when the process was started: the run time decides whether a restart counts as a failure
    started_ms: u64 = 0,
    /// when a readiness check is due, when the start delay ends, when a restart is due
    next_ms: ?u64 = null,
    ready_deadline_ms: u64 = 0,
    stop_deadline_ms: u64 = 0,
    restarts: u32 = 0,
    failures: u32 = 0,
    exit_code: i32 = 0,
    exit_status: i32 = 0,
    /// vh-ctl waiting for the state to settle: connection fds and their deadlines
    waiters: std.ArrayList(Waiter) = .empty,
    /// a request to start again after the stop
    restart_pending: bool = false,
    /// the time stamp file of a periodic oneshot
    stamp: ?[]const u8 = null,
};

const Waiter = struct { fd: linux.fd_t, deadline_ms: u64, want: enum { up, down } };

const Conn = struct { fd: linux.fd_t, buf: std.ArrayList(u8) = .empty };

pub const Manager = struct {
    insts: std.ArrayList(Inst) = .empty,
    order: []usize = &.{},
    epfd: linux.fd_t = -1,
    sigfd: linux.fd_t = -1,
    listen_fd: linux.fd_t = -1,
    /// the channel to PID 1 (fd 3 when started by it), -1 when run by hand (tests)
    pid1_fd: linux.fd_t = -1,
    conns: std.ArrayList(Conn) = .empty,
    shutting_down: bool = false,
    shutdown_ms: u64 = 0,
    /// the last time the shutdown's stragglers were named in the log
    straggler_ms: u64 = 0,
    /// told PID 1 once that every boot service has settled
    reported_ready: bool = false,
    boot_ms: u64 = 0,
    /// --root DIR of the tests: definitions and logs under DIR
    root: []const u8 = "",
    /// --dir: an extra directory of .svc files that are all enabled (tests)
    extra_dir: ?[]const u8 = null,
    verbose: bool = false,
    state_dir: []const u8 = "/var/lib/vh/init",

    fn now(_: *Manager) u64 {
        return sys.monoUs() / 1000;
    }

    fn find(m: *Manager, name: []const u8) ?*Inst {
        for (m.insts.items) |*i| if (vh.eql(i.s.name, name)) return i;
        return null;
    }

    fn setState(m: *Manager, i: *Inst, st: State) void {
        if (i.state == st) return;
        if (m.verbose) vh.log("{s}: {s} -> {s}", .{ i.s.name, @tagName(i.state), @tagName(st) });
        i.state = st;
        i.since_ms = m.now();
        m.wakeWaiters(i);
    }

    // ---------------------------------------------------------------- definitions

    /// What runit-void's stage 2 (/etc/runit/2) does before runsvdir, so that /var/service
    /// resolves: /var/service -> /run/runit/runsvdir/current -> /etc/runit/runsvdir/current
    /// (runsvchdir: -> default). The link in /run is gone after every boot and nothing but
    /// stage 2 made it; without it the manager, sv and vh-ctl enable would see no service at all
    /// (the rig's first boot under vh-init, kvm-smoke run 40323258202). The runlevel of the
    /// command line (/etc/runit/runsvdir/NAME) and /etc/rc.local are not taken over.
    fn runitServiceDir(m: *Manager) void {
        if (m.root.len > 0 or vh.isDir(svc.runit_dir)) return;
        const run_link = "/run/runit/runsvdir/current";
        const etc_current = "/etc/runit/runsvdir/current";
        if (!vh.pathExists(etc_current)) {
            if (!vh.isDir("/etc/runit/runsvdir/default")) return;
            _ = linux.symlink("default", etc_current);
        }
        vh.mkdirs("/run/runit/runsvdir", 0o755);
        if (vh.pathExists(run_link)) return;
        if (linux.errno(linux.symlink(etc_current, run_link)) == .SUCCESS) {
            vh.log("{s} -> {s} (runit's stage 2 does not run under vh-init)", .{ run_link, etc_current });
        } else vh.warn("{s}: {s}", .{ run_link, vh.serr() });
    }

    /// /var/service/* (runit directories, a .svc of the same name taking over how it runs) and
    /// /etc/vh/services/enabled/* (.svc only)
    pub fn loadDefinitions(m: *Manager) []svc.Service {
        var list: std.ArrayList(svc.Service) = .empty;
        const rdir = vh.fmt("{s}{s}", .{ m.root, svc.runit_dir });
        for (sys.sortedDir(rdir)) |name| {
            if (!proto.validName(name) or name[0] == '.') continue;
            const dir = vh.fmt("{s}/{s}", .{ rdir, name });
            if (!vh.isDir(dir)) continue;
            if (m.loadSvcFile(name)) |s| {
                list.append(vh.gpa, s) catch vh.oom();
                continue;
            }
            const run_path = vh.fmt("{s}/run", .{dir});
            if (!vh.isRegular(run_path)) {
                vh.warn("{s}: no run file and no {s}/{s}.svc: skipped", .{ dir, svc.svc_dir, name });
                continue;
            }
            // the real directory: /var/service/NAME is a link to /etc/sv/NAME
            const real = vh.realpath(dir) catch dir;
            list.append(vh.gpa, svc.fromRunit(name, real, .{
                .run = true,
                .finish = vh.isRegular(vh.fmt("{s}/finish", .{real})),
                .log_run = vh.isRegular(vh.fmt("{s}/log/run", .{real})),
                .check = vh.isRegular(vh.fmt("{s}/check", .{real})),
                .down = vh.pathExists(vh.fmt("{s}/down", .{real})),
            })) catch vh.oom();
        }
        const edir = vh.fmt("{s}{s}", .{ m.root, svc.enabled_dir });
        for (sys.sortedDir(edir)) |raw| {
            const name = if (vh.endsWith(raw, ".svc")) raw[0 .. raw.len - 4] else raw;
            if (!proto.validName(name)) continue;
            var dup = false;
            for (list.items) |s| if (vh.eql(s.name, name)) {
                dup = true;
            };
            if (dup) continue;
            if (m.loadSvcFile(name)) |s| list.append(vh.gpa, s) catch vh.oom() else vh.warn("{s}/{s}: no {s}/{s}.svc", .{ edir, raw, svc.svc_dir, name });
        }
        if (m.extra_dir) |d| {
            for (sys.sortedDir(d)) |raw| {
                if (!vh.endsWith(raw, ".svc")) continue;
                const name = raw[0 .. raw.len - 4];
                const path = vh.fmt("{s}/{s}", .{ d, raw });
                const text = vh.readFile(path) catch continue;
                const s = svc.parseSvc(name, text, path) catch |e| {
                    vh.warn("{s}: {s}", .{ path, @errorName(e) });
                    continue;
                };
                list.append(vh.gpa, s) catch vh.oom();
            }
        }
        return list.items;
    }

    fn loadSvcFile(m: *Manager, name: []const u8) ?svc.Service {
        const path = vh.fmt("{s}{s}/{s}.svc", .{ m.root, svc.svc_dir, name });
        const text = vh.readFile(path) catch return null;
        return svc.parseSvc(name, text, path) catch |e| {
            vh.warn("{s}: {s}: the service is not started", .{ path, @errorName(e) });
            return null;
        };
    }

    /// (re)build the instances from the definitions: new ones are added, gone ones stopped
    pub fn reload(m: *Manager) void {
        const defs = m.loadDefinitions();
        var g: svc.Graph = .{ .services = defs };
        for (svc.resolve(&g)) |p| vh.warn("{s} {s} {s}", .{ p.service, p.what, p.other });
        // keep the state of the ones that are still there
        var fresh: std.ArrayList(Inst) = .empty;
        for (g.services) |s| {
            if (m.find(s.name)) |old| {
                var i = old.*;
                i.s = s;
                fresh.append(vh.gpa, i) catch vh.oom();
            } else {
                var i: Inst = .{ .s = s, .logw = log.Writer.init(s.name, if (s.log == .kmsg) .kmsg else .file, s.log_size, s.log_keep) };
                i.logw.root = m.root;
                i.want_up = !s.down;
                i.since_ms = m.now();
                if (s.every_ms != null) i.stamp = vh.fmt("{s}{s}/{s}.last", .{ m.root, m.state_dir, s.name });
                fresh.append(vh.gpa, i) catch vh.oom();
            }
        }
        // the ones that are gone: stopped, then dropped when down
        for (m.insts.items) |*old| {
            var still = false;
            for (fresh.items) |f| if (vh.eql(f.s.name, old.s.name)) {
                still = true;
            };
            if (!still and (old.state != .down and old.state != .failed and old.state != .done)) {
                vh.log("{s}: no longer enabled: stopping", .{old.s.name});
                old.want_up = false;
                fresh.append(vh.gpa, old.*) catch vh.oom();
            }
        }
        m.insts = fresh;
        var sl: std.ArrayList(svc.Service) = .empty;
        for (m.insts.items) |i| sl.append(vh.gpa, i.s) catch vh.oom();
        var g2: svc.Graph = .{ .services = sl.items };
        m.order = svc.startOrder(&g2);
    }

    // ---------------------------------------------------------------- the loop

    pub fn run(m: *Manager) void {
        m.boot_ms = m.now();
        var mask = linux.sigfillset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &mask, null);
        var chld = linux.sigemptyset();
        linux.sigaddset(&chld, .CHLD);
        linux.sigaddset(&chld, .TERM);
        linux.sigaddset(&chld, .INT);
        linux.sigaddset(&chld, .HUP);
        m.sigfd = @intCast(vh.sys(linux.signalfd(-1, &chld, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK)) catch vh.die("signalfd: {s}", .{vh.serr()}));
        m.epfd = @intCast(vh.sys(linux.epoll_create1(linux.EPOLL.CLOEXEC)) catch vh.die("epoll_create1: {s}", .{vh.serr()}));
        m.watch(m.sigfd, .signal, 0);
        _ = linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
        _ = linux.prctl(@intFromEnum(linux.PR.SET_NAME), @intFromPtr("vh-manager"), 0, 0, 0);
        if (m.pid1_fd >= 0) m.watch(m.pid1_fd, .pid1, 0);
        if (m.root.len == 0) {
            if (!cgroup.setup()) vh.log("cgroup2 is not writable: services run without cgroups", .{});
        }
        vh.mkdirs(vh.fmt("{s}{s}", .{ m.root, m.state_dir }), 0o700);
        m.listenSocket();
        m.runitServiceDir();
        m.reload();
        m.adopt();
        vh.log("vh-init manager {s}: {d} services", .{ version, m.insts.items.len });
        var events: [64]linux.epoll_event = undefined;
        while (true) {
            m.tick();
            if (m.shutting_down and m.allDown()) {
                vh.log("every service is down", .{});
                m.tellPid1("stopped\n");
                vh.exit(0);
            }
            const timeout = m.nextTimeoutMs();
            const n = linux.epoll_wait(m.epfd, &events, events.len, timeout);
            if (linux.errno(n) != .SUCCESS) {
                if (linux.errno(n) == .INTR) continue;
                vh.die("epoll_wait: {s}", .{@tagName(linux.errno(n))});
            }
            for (events[0..n]) |ev| m.handle(ev);
        }
    }

    const Tag = enum(u8) { signal, listen, conn, pid1, log, ready, pidfd };

    fn key(tag: Tag, fd: linux.fd_t) u64 {
        return (@as(u64, @intFromEnum(tag)) << 32) | @as(u32, @bitCast(fd));
    }

    fn watch(m: *Manager, fd: linux.fd_t, tag: Tag, idx: u32) void {
        _ = idx;
        var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = key(tag, fd) } };
        _ = linux.epoll_ctl(m.epfd, linux.EPOLL.CTL_ADD, fd, &ev);
    }

    fn unwatch(m: *Manager, fd: linux.fd_t) void {
        _ = linux.epoll_ctl(m.epfd, linux.EPOLL.CTL_DEL, fd, null);
    }

    fn handle(m: *Manager, ev: linux.epoll_event) void {
        const tag: Tag = @enumFromInt(@as(u8, @truncate(ev.data.u64 >> 32)));
        const fd: linux.fd_t = @bitCast(@as(u32, @truncate(ev.data.u64)));
        switch (tag) {
            .signal => m.drainSignals(),
            .listen => m.acceptConn(),
            .conn => m.readConn(fd),
            .pid1 => m.readPid1(),
            .log => m.readLog(fd),
            .ready => m.readReady(fd),
            .pidfd => m.adoptedExit(fd),
        }
    }

    fn nextTimeoutMs(m: *Manager) i32 {
        const t = m.now();
        var best: ?u64 = null;
        for (m.insts.items) |i| {
            if (i.next_ms) |n| best = if (best) |b| @min(b, n) else n;
            if (i.state == .starting and i.ready_deadline_ms != 0) best = if (best) |b| @min(b, i.ready_deadline_ms) else i.ready_deadline_ms;
            if ((i.state == .stopping or i.state == .finishing) and i.stop_deadline_ms != 0) best = if (best) |b| @min(b, i.stop_deadline_ms) else i.stop_deadline_ms;
            for (i.waiters.items) |w| best = if (best) |b| @min(b, w.deadline_ms) else w.deadline_ms;
        }
        const b = best orelse return -1;
        if (b <= t) return 0;
        return @intCast(@min(b - t, std.math.maxInt(i32)));
    }

    // ---------------------------------------------------------------- starting and readiness

    fn depsReady(m: *Manager, i: *const Inst) bool {
        for (i.s.needs) |n| {
            const d = m.find(n) orelse return false;
            if (!(d.state == .up or d.state == .done)) return false;
        }
        for (i.s.after) |a| {
            const d = m.find(a) orelse continue;
            if (!m.settled(d)) return false;
        }
        return true;
    }

    /// a dependency that will not change on its own any more: up, done, failed, or down for good
    fn settled(_: *Manager, d: *const Inst) bool {
        return switch (d.state) {
            .up, .done, .failed => true,
            .down => !d.want_up or d.next_ms == null,
            else => false,
        };
    }

    fn tick(m: *Manager) void {
        const t = m.now();
        for (m.order) |idx| {
            const i = &m.insts.items[idx];
            // a runit logger outlives its service (runit keeps it for the next start); at the
            // shutdown its pipe is closed, and one that does not end on EOF is signalled
            if (m.shutting_down and i.pid == 0 and i.logger_pid != 0) {
                if (i.logger_pipe[1] >= 0) {
                    vh.close(i.logger_pipe[1]);
                    vh.close(i.logger_pipe[0]);
                    i.logger_pipe = .{ -1, -1 };
                } else if (t - m.shutdown_ms > 10_000) {
                    _ = linux.kill(i.logger_pid, .KILL);
                } else if (t - m.shutdown_ms > 5000) _ = linux.kill(i.logger_pid, .TERM);
            }
            switch (i.state) {
                .waiting, .down, .delayed => {
                    if (m.shutting_down or !i.want_up) continue;
                    if (i.next_ms) |n| if (n > t) continue;
                    if (!m.depsReady(i)) {
                        if (i.state != .waiting) m.setState(i, .waiting);
                        continue;
                    }
                    if (i.state == .waiting and i.s.delay_ms > 0 and i.restarts == 0 and i.next_ms == null) {
                        i.next_ms = t + i.s.delay_ms;
                        m.setState(i, .delayed);
                        continue;
                    }
                    if (i.s.every_ms != null and i.next_ms == null) {
                        if (m.periodicDue(i)) |due| if (due > t) {
                            i.next_ms = due;
                            m.setState(i, .delayed);
                            continue;
                        };
                    }
                    i.next_ms = null;
                    m.start(i);
                },
                .starting => if (m.shutting_down or !i.want_up) m.maybeStop(i) else m.checkReady(i, t),
                .stopping => if (i.stop_deadline_ms != 0 and t >= i.stop_deadline_ms) m.killHard(i),
                .finishing => if (i.stop_deadline_ms != 0 and t >= i.stop_deadline_ms) {
                    if (i.finish_pid > 0) _ = linux.kill(i.finish_pid, .KILL);
                },
                .up => if (m.shutting_down or !i.want_up) m.maybeStop(i),
                .failed, .done => {},
            }
        }
        // waiters whose deadline passed
        for (m.insts.items) |*i| m.expireWaiters(i, t);
        // a shutdown that drags: every 5 s the log names what still runs
        if (m.shutting_down and t - m.shutdown_ms > 5000 and t - m.straggler_ms > 5000) {
            m.straggler_ms = t;
            for (m.insts.items) |*i| {
                if (i.pid != 0 or i.logger_pid != 0 or i.finish_pid != 0 or i.state == .stopping or i.state == .finishing)
                    vh.log("still running: {s} ({s}, pid {d}, logger {d}, finish {d}, want {s})", .{ i.s.name, @tagName(i.state), i.pid, i.logger_pid, i.finish_pid, if (i.want_up) "up" else "down" });
            }
        }
        if (!m.reported_ready and !m.shutting_down and m.allSettled()) {
            m.reported_ready = true;
            const ms = t - m.boot_ms;
            vh.log("every service has settled in {d} ms", .{ms});
            m.tellPid1(vh.fmt("ready {d}\n", .{ms}));
        }
    }

    fn allSettled(m: *Manager) bool {
        for (m.insts.items) |*i| {
            if (!i.want_up) continue;
            if (i.state == .delayed and i.s.every_ms != null) continue; // a periodic oneshot waits for its time
            if (!m.settled(i)) return false;
        }
        return true;
    }

    fn allDown(m: *Manager) bool {
        for (m.insts.items) |i| if (i.pid != 0 or i.logger_pid != 0 or i.finish_pid != 0 or i.state == .stopping or i.state == .finishing) return false;
        return true;
    }

    /// a periodic oneshot: the next run from the time stamp of the last; null when it never ran
    fn periodicDue(m: *Manager, i: *Inst) ?u64 {
        const stamp = i.stamp orelse return null;
        const text = vh.readFile(stamp) catch return null;
        const last = std.fmt.parseInt(i64, vh.strip(text), 10) catch return null;
        const every_s: i64 = @intCast(i.s.every_ms.? / 1000);
        const due_wall = last + every_s;
        const now_wall = vh.now();
        if (due_wall <= now_wall) return null;
        return m.now() + @as(u64, @intCast(due_wall - now_wall)) * 1000;
    }

    fn start(m: *Manager, i: *Inst) void {
        if (m.root.len == 0) _ = cgroup.create(i.s.name, i.s.memory_max, i.s.cpu_weight);
        var io: spawn.Io = .{};
        // the log pipe
        var logp: [2]linux.fd_t = .{ -1, -1 };
        switch (i.s.log) {
            .none => {},
            .file, .kmsg => {
                if (linux.errno(linux.pipe2(&logp, .{ .CLOEXEC = true, .NONBLOCK = true })) == .SUCCESS) {
                    io.stdout = logp[1];
                    i.log_r = logp[0];
                    // the write end is CLOEXEC: the child's dup2 copies are not
                    m.watch(logp[0], .log, 0);
                }
            },
            .runit => {
                if (i.logger_pipe[0] < 0) {
                    if (linux.errno(linux.pipe2(&i.logger_pipe, .{ .CLOEXEC = true })) != .SUCCESS) i.logger_pipe = .{ -1, -1 };
                }
                io.stdout = i.logger_pipe[1];
                if (i.logger_pid == 0) m.startLogger(i);
            },
        }
        var readyp: [2]linux.fd_t = .{ -1, -1 };
        if (i.s.ready == .fd) {
            if (linux.errno(linux.pipe2(&readyp, .{ .CLOEXEC = true, .NONBLOCK = true })) == .SUCCESS) {
                io.ready = readyp[1];
                io.ready_at = i.s.ready.fd;
                i.ready_r = readyp[0];
                m.watch(readyp[0], .ready, 0);
            }
        }
        const t = m.now();
        i.started_ms = t;
        const r = spawn.spawn(&i.s, io);
        if (logp[1] >= 0) vh.close(logp[1]);
        if (readyp[1] >= 0) vh.close(readyp[1]);
        switch (r) {
            .pid => |pid| {
                i.pid = pid;
                i.started_ms = t;
                i.exit_code = 0;
                i.ready_deadline_ms = t + i.s.ready_timeout_ms;
                m.setState(i, .starting);
                if (m.verbose) vh.log("{s}: started, pid {d}", .{ i.s.name, pid });
                switch (i.s.ready) {
                    .started => m.markUp(i),
                    .exit, .fd => {},
                    .socket, .check => i.next_ms = t + 100,
                }
            },
            .exec_failed => |e| {
                vh.warn("{s}: cannot start {s}: {s}", .{ i.s.name, i.s.exec[0], @tagName(e) });
                m.closeLog(i);
                m.closeReady(i);
                i.exit_code = 127;
                m.exited(i, 127, false);
            },
            .fork_failed => |e| {
                vh.warn("{s}: fork: {s}", .{ i.s.name, @tagName(e) });
                m.closeLog(i);
                m.closeReady(i);
                i.next_ms = t + 5000;
                m.setState(i, .down);
            },
        }
    }

    fn startLogger(_: *Manager, i: *Inst) void {
        const lg = i.s.logger orelse return;
        const dir = lg[0 .. mem.lastIndexOfScalar(u8, lg, '/') orelse lg.len];
        var ls: svc.Service = .{ .name = vh.fmt("{s}/log", .{i.s.name}), .exec = &.{lg}, .cwd = dir, .no_new_privs = false, .log = .none };
        ls.abi_filter = i.s.abi_filter;
        const r = spawn.spawn(&ls, .{ .stdin = i.logger_pipe[0] });
        switch (r) {
            .pid => |pid| i.logger_pid = pid,
            .exec_failed => |e| vh.warn("{s}: cannot start the logger {s}: {s}", .{ i.s.name, lg, @tagName(e) }),
            .fork_failed => |e| vh.warn("{s}: fork for the logger: {s}", .{ i.s.name, @tagName(e) }),
        }
    }

    fn markUp(m: *Manager, i: *Inst) void {
        i.ready_deadline_ms = 0;
        i.next_ms = null;
        m.setState(i, .up);
        if (m.root.len > 0 or true) m.closeReady(i);
        // a start that lasted: the failure count starts over
    }

    fn checkReady(m: *Manager, i: *Inst, t: u64) void {
        switch (i.s.ready) {
            .started => m.markUp(i),
            .exit, .fd => {},
            .socket => |p| {
                if (i.next_ms) |n| if (n > t) return;
                if (vh.pathExists(vh.fmt("{s}{s}", .{ m.root, p }))) {
                    m.markUp(i);
                    return;
                }
                i.next_ms = t + 100;
            },
            .check => |script| {
                if (i.check_pid != 0) return;
                if (i.next_ms) |n| if (n > t) return;
                var cs: svc.Service = .{ .name = vh.fmt("{s}/check", .{i.s.name}), .exec = &.{script}, .cwd = i.s.cwd, .no_new_privs = false, .log = .none };
                cs.abi_filter = i.s.abi_filter;
                switch (spawn.spawn(&cs, .{})) {
                    .pid => |pid| i.check_pid = pid,
                    else => {},
                }
                i.next_ms = t + 200;
            },
        }
        if (i.state == .starting and i.ready_deadline_ms != 0 and t >= i.ready_deadline_ms) {
            vh.warn("{s}: not ready after {d} ms: treated as up", .{ i.s.name, i.s.ready_timeout_ms });
            m.markUp(i);
        }
    }

    fn closeLog(m: *Manager, i: *Inst) void {
        if (i.log_r >= 0) {
            m.drainLog(i);
            m.unwatch(i.log_r);
            vh.close(i.log_r);
            i.log_r = -1;
            i.logw.flush();
        }
    }

    fn closeReady(m: *Manager, i: *Inst) void {
        if (i.ready_r >= 0) {
            m.unwatch(i.ready_r);
            vh.close(i.ready_r);
            i.ready_r = -1;
        }
    }

    fn instByFd(m: *Manager, fd: linux.fd_t, which: enum { log, ready, pidfd }) ?*Inst {
        for (m.insts.items) |*i| {
            const f = switch (which) {
                .log => i.log_r,
                .ready => i.ready_r,
                .pidfd => i.pidfd,
            };
            if (f == fd) return i;
        }
        return null;
    }

    fn readLog(m: *Manager, fd: linux.fd_t) void {
        const i = m.instByFd(fd, .log) orelse {
            m.unwatch(fd);
            vh.close(fd);
            return;
        };
        m.drainLog(i);
    }

    fn drainLog(_: *Manager, i: *Inst) void {
        var buf: [16384]u8 = undefined;
        while (true) {
            const rc = linux.read(i.log_r, &buf, buf.len);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS or rc == 0) break;
            i.logw.write(buf[0..rc]);
        }
    }

    fn readReady(m: *Manager, fd: linux.fd_t) void {
        const i = m.instByFd(fd, .ready) orelse {
            m.unwatch(fd);
            vh.close(fd);
            return;
        };
        var buf: [256]u8 = undefined;
        const rc = linux.read(fd, &buf, buf.len);
        const e = linux.errno(rc);
        if (e == .AGAIN or e == .INTR) return;
        // s6: a line means ready; EOF without a line means the program closed it (also ready
        // for a program that just exits the pipe, dinit's semantics are the same)
        if (i.state == .starting) m.markUp(i) else m.closeReady(i);
    }

    // ---------------------------------------------------------------- exits

    fn drainSignals(m: *Manager) void {
        var info: linux.signalfd_siginfo = undefined;
        while (true) {
            const rc = linux.read(m.sigfd, mem.asBytes(&info), @sizeOf(linux.signalfd_siginfo));
            if (linux.errno(rc) != .SUCCESS or rc < @sizeOf(linux.signalfd_siginfo)) break;
            switch (@as(linux.SIG, @enumFromInt(info.signo))) {
                .CHLD => m.reap(),
                .TERM, .INT => if (m.pid1_fd < 0) {
                    // run by hand (tests, a container): the signal is the shutdown request
                    vh.log("signal {d}: stopping every service", .{info.signo});
                    m.beginShutdown();
                },
                .HUP => m.reload(),
                else => {},
            }
        }
    }

    fn reap(m: *Manager) void {
        while (true) {
            var st: i32 = 0;
            const rc = linux.wait4(-1, &st, linux.W.NOHANG, null);
            const e = linux.errno(rc);
            if (e != .SUCCESS or rc == 0) break;
            const pid: linux.pid_t = @intCast(rc);
            const status: u32 = @bitCast(st);
            var found = false;
            for (m.insts.items) |*i| {
                if (i.pid == pid) {
                    found = true;
                    const code: i32 = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 128 + @as(i32, @intCast(@intFromEnum(linux.W.TERMSIG(status))));
                    i.exit_status = st;
                    m.exited(i, code, linux.W.IFSIGNALED(status));
                } else if (i.logger_pid == pid) {
                    found = true;
                    i.logger_pid = 0;
                    if (!m.shutting_down and i.want_up and i.pid != 0) {
                        vh.warn("{s}: the logger exited: started again", .{i.s.name});
                        m.startLogger(i);
                    }
                } else if (i.finish_pid == pid) {
                    found = true;
                    i.finish_pid = 0;
                    m.afterFinish(i);
                } else if (i.check_pid == pid) {
                    found = true;
                    i.check_pid = 0;
                    if (i.state == .starting and linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0) m.markUp(i);
                }
                if (found) break;
            }
            if (!found and m.verbose) vh.log("reaped an orphan, pid {d}", .{pid});
        }
    }

    /// the main process ended; the finish script, then the next state
    fn exited(m: *Manager, i: *Inst, code: i32, signaled: bool) void {
        const t = m.now();
        const was = i.state;
        i.pid = 0;
        i.exit_code = code;
        m.closeLog(i);
        m.closeReady(i);
        if (i.check_pid != 0) _ = linux.kill(i.check_pid, .KILL);
        if (m.verbose or (code != 0 and was != .stopping)) vh.log("{s}: exited with {d}{s} after {d} ms", .{ i.s.name, code, if (signaled) " (signal)" else "", t - i.started_ms });
        // the cgroup may hold children: a longrun that leaves daemons behind is a runit script's habit
        if (m.root.len == 0 and i.s.log != .runit) _ = cgroup.kill(i.s.name);
        if (i.s.finish) |f| {
            var fs: svc.Service = .{ .name = vh.fmt("{s}/finish", .{i.s.name}), .exec = &.{ f, vh.fmt("{d}", .{code}), vh.fmt("{d}", .{i.exit_status}) }, .cwd = i.s.cwd, .no_new_privs = false, .log = .none };
            fs.abi_filter = i.s.abi_filter;
            switch (spawn.spawn(&fs, .{})) {
                .pid => |pid| {
                    i.finish_pid = pid;
                    i.stop_deadline_ms = t + 5000;
                    m.setState(i, .finishing);
                    return;
                },
                else => {},
            }
        }
        m.afterFinish(i);
    }

    fn afterFinish(m: *Manager, i: *Inst) void {
        const t = m.now();
        i.stop_deadline_ms = 0;
        const ran_ms = t - i.started_ms;
        if (i.s.kind == .oneshot) {
            if (i.exit_code == 0) {
                if (i.stamp) |stamp| _ = sys.writeFile(stamp, vh.fmt("{d}\n", .{vh.now()}), 0o600);
                m.setState(i, .done);
                if (i.s.every_ms) |every| {
                    i.next_ms = t + every;
                    i.want_up = true;
                    m.setState(i, .delayed);
                }
                return;
            }
            // a failed oneshot: retried with the backoff while wanted, like a longrun
        }
        if (m.shutting_down or !i.want_up or i.once) {
            i.once = false;
            m.setState(i, .down);
            i.next_ms = null;
            // a runit logger ends with its pipe: the service is down for good
            if (m.shutting_down and i.logger_pipe[1] >= 0) {
                vh.close(i.logger_pipe[1]);
                vh.close(i.logger_pipe[0]);
                i.logger_pipe = .{ -1, -1 };
            }
            if (i.restart_pending) {
                i.restart_pending = false;
                i.want_up = true;
            }
            return;
        }
        const policy_says_no = switch (i.s.restart) {
            .no => true,
            .@"on-failure" => i.exit_code == 0,
            .always => false,
        };
        if (policy_says_no) {
            m.setState(i, if (i.exit_code == 0) .done else .failed);
            i.next_ms = null;
            return;
        }
        // a run of less than a minute counts as a failure: the first restart waits restart_delay,
        // every further one in a row twice as long, up to restart_max
        if (ran_ms < 60_000) i.failures += 1 else i.failures = 0;
        i.restarts += 1;
        const delay = svc.backoffMs(&i.s, i.failures -| 1);
        i.next_ms = t + delay;
        m.setState(i, .down);
        if (i.failures >= 3) vh.warn("{s}: exited {d} times in a row; next start in {d} ms", .{ i.s.name, i.failures, delay });
    }

    // ---------------------------------------------------------------- stopping

    /// stop when nothing that depends on it is still running
    fn maybeStop(m: *Manager, i: *Inst) void {
        for (m.insts.items) |*d| {
            if (d == i) continue;
            var depends = false;
            for (d.s.needs) |n| if (vh.eql(n, i.s.name)) {
                depends = true;
            };
            for (d.s.after) |a| if (vh.eql(a, i.s.name)) {
                depends = true;
            };
            if (depends and (d.pid != 0 or d.state == .stopping or d.state == .finishing or d.state == .starting)) return;
        }
        m.stop(i);
    }

    fn stop(m: *Manager, i: *Inst) void {
        if (i.pid == 0) return;
        _ = linux.kill(i.pid, .TERM);
        // a stopped process must get CONT to see the TERM (sv's own habit)
        _ = linux.kill(i.pid, .CONT);
        i.stop_deadline_ms = m.now() + i.s.stop_timeout_ms;
        m.setState(i, .stopping);
    }

    fn killHard(m: *Manager, i: *Inst) void {
        vh.warn("{s}: did not stop in {d} ms: killed", .{ i.s.name, i.s.stop_timeout_ms });
        if (i.pid != 0) _ = linux.kill(i.pid, .KILL);
        if (m.root.len == 0) _ = cgroup.kill(i.s.name);
        i.stop_deadline_ms = m.now() + 5000;
    }

    pub fn beginShutdown(m: *Manager) void {
        if (m.shutting_down) return;
        m.shutting_down = true;
        m.shutdown_ms = m.now();
        for (m.insts.items) |*i| i.want_up = false;
    }

    // ---------------------------------------------------------------- adoption

    /// services a previous manager left in their cgroups: taken as up, watched by pidfd
    fn adopt(m: *Manager) void {
        if (m.root.len > 0 or !cgroup.available) return;
        for (cgroup.list()) |name| {
            const i = m.find(name) orelse {
                // a cgroup of a service that is no longer enabled: whatever runs there is stopped
                _ = cgroup.kill(name);
                cgroup.remove(name);
                continue;
            };
            const pids = cgroup.procs(name);
            if (pids.len == 0) continue;
            const pidfd_rc = linux.pidfd_open(pids[0], 0);
            if (linux.errno(pidfd_rc) != .SUCCESS) continue;
            i.pidfd = @intCast(pidfd_rc);
            i.pid = pids[0];
            i.started_ms = m.now();
            m.watch(i.pidfd, .pidfd, 0);
            m.setState(i, .up);
            vh.log("{s}: adopted, pid {d} ({d} processes in its cgroup)", .{ name, pids[0], pids.len });
        }
    }

    fn adoptedExit(m: *Manager, fd: linux.fd_t) void {
        const i = m.instByFd(fd, .pidfd) orelse {
            m.unwatch(fd);
            vh.close(fd);
            return;
        };
        m.unwatch(fd);
        vh.close(fd);
        i.pidfd = -1;
        // PID 1 reaps it; the exit code is unknown
        i.exit_status = 0;
        m.exited(i, 0, false);
    }

    // ---------------------------------------------------------------- PID 1

    fn tellPid1(m: *Manager, msg: []const u8) void {
        if (m.pid1_fd < 0) return;
        vh.writeAllFd(m.pid1_fd, msg) catch {};
    }

    fn readPid1(m: *Manager) void {
        var buf: [256]u8 = undefined;
        const rc = linux.read(m.pid1_fd, &buf, buf.len);
        const e = linux.errno(rc);
        if (e == .INTR or e == .AGAIN) return;
        if (e != .SUCCESS or rc == 0) {
            // PID 1 is gone?! nothing to do but keep the services running
            m.unwatch(m.pid1_fd);
            m.pid1_fd = -1;
            return;
        }
        var it = mem.tokenizeScalar(u8, buf[0..rc], '\n');
        while (it.next()) |line| {
            if (vh.eql(line, "stop")) {
                vh.log("PID 1 asks for the services to stop", .{});
                m.beginShutdown();
            } else if (vh.eql(line, "reload")) m.reload();
        }
    }

    // ---------------------------------------------------------------- the control socket

    fn listenSocket(m: *Manager) void {
        const dir = vh.fmt("{s}{s}", .{ m.root, proto.socket_dir });
        vh.mkdirs(dir, 0o755);
        const path = vh.fmt("{s}{s}", .{ m.root, proto.socket_path });
        _ = linux.unlink(vh.z(path).ptr);
        const fd_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
        if (linux.errno(fd_rc) != .SUCCESS) return vh.warn("control socket: socket: {s}", .{@tagName(linux.errno(fd_rc))});
        const fd: linux.fd_t = @intCast(fd_rc);
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        if (path.len >= addr.path.len) return vh.warn("control socket: the path is too long", .{});
        @memcpy(addr.path[0..path.len], path);
        const old_umask = linux.syscall1(.umask, 0o077);
        const brc = linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
        _ = linux.syscall1(.umask, old_umask);
        if (linux.errno(brc) != .SUCCESS) {
            vh.warn("control socket: bind {s}: {s}", .{ path, @tagName(linux.errno(brc)) });
            vh.close(fd);
            return;
        }
        _ = linux.chmod(vh.z(path).ptr, 0o600);
        if (linux.errno(linux.listen(fd, 16)) != .SUCCESS) {
            vh.close(fd);
            return;
        }
        m.listen_fd = fd;
        m.watch(fd, .listen, 0);
    }

    fn acceptConn(m: *Manager) void {
        while (true) {
            const rc = linux.accept4(m.listen_fd, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
            const e = linux.errno(rc);
            if (e != .SUCCESS) return;
            const fd: linux.fd_t = @intCast(rc);
            // root only: the socket is 0600 in a root directory; the peer's uid is checked too
            var cred: extern struct { pid: i32, uid: u32, gid: u32 } = undefined;
            var len: linux.socklen_t = @sizeOf(@TypeOf(cred));
            if (linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len)) == .SUCCESS and cred.uid != 0 and linux.geteuid() == 0) {
                vh.writeAllFd(fd, "err only root may control the services\n") catch {};
                vh.close(fd);
                continue;
            }
            m.conns.append(vh.gpa, .{ .fd = fd }) catch vh.oom();
            m.watch(fd, .conn, 0);
        }
    }

    fn readConn(m: *Manager, fd: linux.fd_t) void {
        var idx: ?usize = null;
        for (m.conns.items, 0..) |c, k| if (c.fd == fd) {
            idx = k;
        };
        const k = idx orelse {
            m.unwatch(fd);
            vh.close(fd);
            return;
        };
        var buf: [1024]u8 = undefined;
        const rc = linux.read(fd, &buf, buf.len);
        const e = linux.errno(rc);
        if (e == .INTR or e == .AGAIN) return;
        if (e != .SUCCESS or rc == 0) {
            m.dropConn(k);
            return;
        }
        const c = &m.conns.items[k];
        c.buf.appendSlice(vh.gpa, buf[0..rc]) catch vh.oom();
        if (c.buf.items.len > 4096) {
            m.dropConn(k);
            return;
        }
        const nl = mem.indexOfScalar(u8, c.buf.items, '\n') orelse return;
        const line = c.buf.items[0..nl];
        const req = proto.parseRequest(line) catch |err| {
            vh.writeAllFd(fd, vh.fmt("err {s}\n", .{if (err == error.UnknownVerb) "unknown command" else "bad request"})) catch {};
            m.dropConn(k);
            return;
        };
        // the connection leaves the list: a waiting request keeps the fd until it is answered
        m.unwatch(fd);
        _ = m.conns.swapRemove(k);
        m.serve(fd, req);
    }

    fn dropConn(m: *Manager, k: usize) void {
        const fd = m.conns.items[k].fd;
        m.unwatch(fd);
        vh.close(fd);
        _ = m.conns.swapRemove(k);
    }

    fn reply(fd: linux.fd_t, body: []const u8, ok: bool, err_text: []const u8) void {
        vh.writeAllFd(fd, body) catch {};
        if (ok) vh.writeAllFd(fd, "ok\n") catch {} else vh.writeAllFd(fd, vh.fmt("err {s}\n", .{err_text})) catch {};
        vh.close(fd);
    }

    fn statusLine(m: *Manager, i: *const Inst) []u8 {
        const l: proto.StatusLine = .{ .name = i.s.name, .state = i.state, .pid = i.pid, .since_ms = m.now() - i.since_ms, .restarts = i.restarts, .want_up = i.want_up, .logger_pid = i.logger_pid, .exit_code = i.exit_code };
        return l.format();
    }

    fn serve(m: *Manager, fd: linux.fd_t, req: proto.Request) void {
        switch (req.verb) {
            .ping => reply(fd, vh.fmt("vh-init manager {s}\n", .{version}), true, ""),
            .list => {
                var out: std.ArrayList(u8) = .empty;
                for (m.order) |idx| out.print(vh.gpa, "{s}\n", .{m.insts.items[idx].s.name}) catch vh.oom();
                reply(fd, out.items, true, "");
            },
            .status => {
                var out: std.ArrayList(u8) = .empty;
                if (req.name.len > 0) {
                    const i = m.find(req.name) orelse return reply(fd, "", false, vh.fmt("no service {s}", .{req.name}));
                    out.appendSlice(vh.gpa, m.statusLine(i)) catch vh.oom();
                } else for (m.order) |idx| out.appendSlice(vh.gpa, m.statusLine(&m.insts.items[idx])) catch vh.oom();
                reply(fd, out.items, true, "");
            },
            .start, .once => {
                const i = m.find(req.name) orelse return reply(fd, "", false, vh.fmt("no service {s}", .{req.name}));
                if (m.shutting_down) return reply(fd, "", false, "the system is shutting down");
                i.want_up = true;
                i.once = req.verb == .once;
                i.failures = 0;
                if (i.state == .down or i.state == .failed or i.state == .done) {
                    i.next_ms = null;
                    i.state = .waiting; // the tick starts it
                    i.since_ms = m.now();
                    if (i.s.kind == .oneshot) i.next_ms = null;
                }
                m.waitOrReply(fd, i, .up, req.arg);
            },
            .stop => {
                const i = m.find(req.name) orelse return reply(fd, "", false, vh.fmt("no service {s}", .{req.name}));
                i.want_up = false;
                i.next_ms = null;
                if (i.state == .delayed or i.state == .waiting) m.setState(i, .down);
                if (i.pid != 0 and i.state != .stopping and i.state != .finishing) m.stop(i);
                m.waitOrReply(fd, i, .down, req.arg);
            },
            .restart => {
                const i = m.find(req.name) orelse return reply(fd, "", false, vh.fmt("no service {s}", .{req.name}));
                if (m.shutting_down) return reply(fd, "", false, "the system is shutting down");
                i.failures = 0;
                if (i.pid != 0) {
                    i.want_up = false;
                    i.restart_pending = true;
                    if (i.state != .stopping and i.state != .finishing) m.stop(i);
                } else {
                    i.want_up = true;
                    i.next_ms = null;
                    i.state = .waiting;
                    i.since_ms = m.now();
                }
                m.waitOrReply(fd, i, .up, req.arg);
            },
            .signal => {
                const i = m.find(req.name) orelse return reply(fd, "", false, vh.fmt("no service {s}", .{req.name}));
                const sig = proto.signalOf(req.arg) orelse return reply(fd, "", false, vh.fmt("unknown signal {s}", .{req.arg}));
                if (i.pid == 0) return reply(fd, "", false, vh.fmt("{s} is not running", .{req.name}));
                _ = linux.kill(i.pid, sig);
                reply(fd, "", true, "");
            },
            .tree, .why => {
                var out: std.ArrayList(u8) = .empty;
                for (m.order) |idx| {
                    const i = &m.insts.items[idx];
                    if (req.verb == .why and !vh.eql(i.s.name, req.name)) continue;
                    out.print(vh.gpa, "{s} ({s}, {s})", .{ i.s.name, @tagName(i.state), i.s.source }) catch vh.oom();
                    if (i.s.needs.len > 0) {
                        out.appendSlice(vh.gpa, " needs") catch vh.oom();
                        for (i.s.needs) |n| out.print(vh.gpa, " {s}", .{n}) catch vh.oom();
                    }
                    if (i.s.after.len > 0) {
                        out.appendSlice(vh.gpa, " after") catch vh.oom();
                        for (i.s.after) |a| out.print(vh.gpa, " {s}", .{a}) catch vh.oom();
                    }
                    if (i.state == .waiting) {
                        for (i.s.needs) |n| if (m.find(n)) |d| if (!(d.state == .up or d.state == .done)) out.print(vh.gpa, " [waits for {s}: {s}]", .{ n, @tagName(d.state) }) catch vh.oom();
                        for (i.s.after) |a| if (m.find(a)) |d| if (!m.settled(d)) out.print(vh.gpa, " [waits for {s}: {s}]", .{ a, @tagName(d.state) }) catch vh.oom();
                    }
                    out.append(vh.gpa, '\n') catch vh.oom();
                }
                if (req.verb == .why and out.items.len == 0) return reply(fd, "", false, vh.fmt("no service {s}", .{req.name}));
                reply(fd, out.items, true, "");
            },
            .blame => {
                // the time each service took to become ready at boot, longest first
                var out: std.ArrayList(u8) = .empty;
                for (m.order) |idx| {
                    const i = &m.insts.items[idx];
                    if (i.started_ms == 0) continue;
                    const took: u64 = if (i.state == .up or i.state == .done) i.since_ms -| i.started_ms else 0;
                    out.print(vh.gpa, "{d} ms {s} (started at +{d} ms)\n", .{ took, i.s.name, i.started_ms -| m.boot_ms }) catch vh.oom();
                }
                reply(fd, out.items, true, "");
            },
            .reload => {
                m.reload();
                reply(fd, vh.fmt("{d} services\n", .{m.insts.items.len}), true, "");
            },
            .poweroff, .reboot, .halt => {
                if (m.pid1_fd < 0) {
                    // run by hand: stop the services and exit; whoever runs us decides the rest
                    m.beginShutdown();
                    reply(fd, "stopping every service (no PID 1 channel: nothing is powered off)\n", true, "");
                    return;
                }
                m.tellPid1(vh.fmt("{s}\n", .{@tagName(req.verb)}));
                reply(fd, "", true, "");
            },
        }
    }

    /// start/stop/restart with a wait: the reply comes when the state is reached or the time is up
    fn waitOrReply(m: *Manager, fd: linux.fd_t, i: *Inst, want: enum { up, down }, arg: []const u8) void {
        const wait_ms: u64 = if (arg.len == 0) 0 else (std.fmt.parseInt(u64, arg, 10) catch 0);
        if (wait_ms == 0) return reply(fd, m.statusLine(i), true, "");
        i.waiters.append(vh.gpa, .{ .fd = fd, .deadline_ms = m.now() + wait_ms, .want = if (want == .up) .up else .down }) catch vh.oom();
        m.wakeWaiters(i);
    }

    fn wakeWaiters(m: *Manager, i: *Inst) void {
        var k: usize = 0;
        while (k < i.waiters.items.len) {
            const w = i.waiters.items[k];
            const reached = switch (w.want) {
                .up => i.state == .up or i.state == .done or i.state == .failed,
                .down => (i.state == .down or i.state == .failed or i.state == .done) and i.pid == 0,
            };
            if (reached) {
                reply(w.fd, m.statusLine(i), i.state != .failed, "the service failed");
                _ = i.waiters.swapRemove(k);
            } else k += 1;
        }
    }

    fn expireWaiters(m: *Manager, i: *Inst, t: u64) void {
        var k: usize = 0;
        while (k < i.waiters.items.len) {
            if (t >= i.waiters.items[k].deadline_ms) {
                reply(i.waiters.items[k].fd, m.statusLine(i), false, "timeout");
                _ = i.waiters.swapRemove(k);
            } else k += 1;
        }
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the epoll key packs a tag and an fd" {
    const k = Manager.key(.log, 42);
    try testing.expectEqual(@as(u8, @intFromEnum(Manager.Tag.log)), @as(u8, @truncate(k >> 32)));
    try testing.expectEqual(@as(linux.fd_t, 42), @as(linux.fd_t, @bitCast(@as(u32, @truncate(k)))));
}
