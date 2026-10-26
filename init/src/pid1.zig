//! vh-init: PID 1 (docs/ROADMAP.md, I). Tiny on purpose: a ReleaseSafe panic here would be a
//! kernel panic, so the service graph lives in the manager, a child that is started again if
//! it dies. PID 1 does: stage 1 in-process (the steps of vh-stage1), the manager, zombies,
//! the signals of a shutdown (SIGINT from Ctrl+Alt+Del or the fixed power button, SIGTERM,
//! SIGUSR1 halt, SIGUSR2 poweroff, SIGCONT with runit's /run/runit/stopit so that runit-void's
//! halt, poweroff and reboot keep working), stage 3.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");
const stage1 = @import("stage1.zig");
const shutdown = @import("shutdown.zig");
const manager = @import("manager.zig");

pub const version = manager.version;

const Ctx = struct {
    manager_pid: linux.pid_t = 0,
    /// the socketpair to the manager: our end
    chan: linux.fd_t = -1,
    manager_restarts: u32 = 0,
    manager_last_start_us: u64 = 0,
    shutting_down: ?shutdown.Kind = null,
    stop_sent_us: u64 = 0,
    container: bool = false,
    self_exe: []const u8 = "/proc/self/exe",
    /// --test: no stage 1 (the tests run in a container as PID 1 of their namespace)
    skip_stage1: bool = false,
    extra_dir: ?[]const u8 = null,
    verbose: bool = false,
};
var ctx: Ctx = .{};

fn kmsg(comptime f: []const u8, args: anytype) void {
    _ = sys.kmsg("vh-init: " ++ f, args);
    if (ctx.container or ctx.verbose) sys.msg("vh-init: " ++ f, args);
}

fn startManager() void {
    var sp: [2]linux.fd_t = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0, &sp)) != .SUCCESS) {
        sys.fail("socketpair: {s}", .{vh.serr()});
        return;
    }
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    argv.append(vh.gpa, "vh-init") catch vh.oom();
    argv.append(vh.gpa, "--manager") catch vh.oom();
    if (ctx.verbose) argv.append(vh.gpa, "-v") catch vh.oom();
    if (ctx.extra_dir) |d| {
        argv.append(vh.gpa, "--dir") catch vh.oom();
        argv.append(vh.gpa, vh.z(d).ptr) catch vh.oom();
    }
    const cargv = argv.toOwnedSliceSentinel(vh.gpa, null) catch vh.oom();
    const exe = vh.z(ctx.self_exe);
    vh.flush();
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        sys.fail("fork: {s}", .{@tagName(linux.errno(rc))});
        vh.close(sp[0]);
        vh.close(sp[1]);
        return;
    }
    if (rc == 0) {
        // the manager gets its channel as fd 3 (not CLOEXEC); every signal unblocked
        const empty = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
        _ = linux.dup2(sp[1], 3);
        _ = linux.execve(exe.ptr, cargv.ptr, vh.envp);
        linux.exit_group(127);
    }
    vh.close(sp[1]);
    ctx.chan = sp[0];
    ctx.manager_pid = @intCast(rc);
    ctx.manager_last_start_us = sys.monoUs();
    kmsg("manager started, pid {d}", .{ctx.manager_pid});
}

fn reap() void {
    while (true) {
        var st: i32 = 0;
        const rc = linux.wait4(-1, &st, linux.W.NOHANG, null);
        const e = linux.errno(rc);
        if (e != .SUCCESS or rc == 0) break;
        if (@as(linux.pid_t, @intCast(rc)) == ctx.manager_pid) managerDied(@bitCast(st));
    }
}

fn managerDied(status: u32) void {
    const code: i32 = if (linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else 128 + @as(i32, @intCast(@intFromEnum(linux.W.TERMSIG(status))));
    ctx.manager_pid = 0;
    if (ctx.chan >= 0) {
        vh.close(ctx.chan);
        ctx.chan = -1;
    }
    if (ctx.shutting_down != null) {
        // the manager exits 0 when every service is down: stage 3 follows
        kmsg("manager exited with {d} during the shutdown", .{code});
        shutdown.run(ctx.shutting_down.?, ctx.container);
        return;
    }
    // a crash: started again with a backoff; it picks the services up from their cgroups
    const ran_us = sys.monoUs() - ctx.manager_last_start_us;
    if (ran_us > 60 * 1_000_000) ctx.manager_restarts = 0 else ctx.manager_restarts += 1;
    const delay_s: u64 = @min(@as(u64, 1) << @intCast(@min(ctx.manager_restarts, 5)), 30);
    kmsg("manager exited with {d} after {d} ms: started again in {d} s", .{ code, ran_us / 1000, delay_s });
    const ts: linux.timespec = .{ .sec = @intCast(delay_s), .nsec = 0 };
    _ = linux.nanosleep(&ts, null);
    startManager();
}

fn requestShutdown(kind: shutdown.Kind) void {
    if (ctx.shutting_down != null) return;
    ctx.shutting_down = kind;
    kmsg("{s} requested", .{@tagName(kind)});
    if (ctx.manager_pid != 0 and ctx.chan >= 0) {
        vh.writeAllFd(ctx.chan, "stop\n") catch {};
        ctx.stop_sent_us = sys.monoUs();
    } else shutdown.run(kind, ctx.container);
}

/// runit's protocol: /run/runit/stopit executable means "shut down", /run/runit/reboot
/// executable means "by rebooting" (runit-init 0 / 6, halt, poweroff, reboot of runit-void,
/// and /etc/runit/ctrlaltdel)
fn runitFiles() ?shutdown.Kind {
    const st = vh.stat("/run/runit/stopit", true) catch return null;
    if (st.mode & 0o100 == 0) return null;
    const rb = vh.stat("/run/runit/reboot", true) catch return .poweroff;
    return if (rb.mode & 0o100 != 0) .reboot else .poweroff;
}

fn ctrlAltDel() void {
    // runit runs /etc/runit/ctrlaltdel on SIGINT, which chooses between a reboot and the power
    // button's action (UniVoidDistro's, rootfs/etc/runit/ctrlaltdel); then the stopit file is read
    const script = "/etc/runit/ctrlaltdel";
    if (vh.isRegular(script)) {
        // the script's processes get the default signal mask; ours stays blocked for the signalfd
        var blocked: linux.sigset_t = undefined;
        const empty = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, &blocked);
        _ = sys.exec(&.{script});
        _ = linux.sigprocmask(linux.SIG.SETMASK, &blocked, null);
        reap();
        if (runitFiles()) |k| requestShutdown(k);
        return;
    }
    requestShutdown(.reboot);
}

fn readChannel() void {
    var buf: [256]u8 = undefined;
    const rc = linux.read(ctx.chan, &buf, buf.len);
    const e = linux.errno(rc);
    if (e == .INTR or e == .AGAIN) return;
    if (e != .SUCCESS or rc == 0) return;
    var it = mem.tokenizeScalar(u8, buf[0..rc], '\n');
    while (it.next()) |line| {
        if (vh.startsWith(line, "ready ")) {
            kmsg("services {s} ms after the manager started", .{line[6..]});
        } else if (vh.eql(line, "stopped")) {
            kmsg("every service is down", .{});
            shutdown.run(ctx.shutting_down orelse .poweroff, ctx.container);
        } else if (vh.eql(line, "poweroff")) {
            requestShutdown(.poweroff);
        } else if (vh.eql(line, "reboot")) {
            requestShutdown(.reboot);
        } else if (vh.eql(line, "halt")) {
            requestShutdown(.halt);
        }
    }
}

pub const Options = struct {
    skip_stage1: bool = false,
    extra_dir: ?[]const u8 = null,
    verbose: bool = false,
    /// --test-pid1: allowed when not PID 1 (a container's namespace init is PID 1 anyway)
    force: bool = false,
};

pub fn main(o: Options) noreturn {
    if (linux.getpid() != 1 and !o.force) vh.die("not PID 1 (vh-init --manager, vh-ctl, or init=/usr/local/sbin/vh-init on the kernel command line)", .{});
    ctx.skip_stage1 = o.skip_stage1;
    ctx.extra_dir = o.extra_dir;
    ctx.verbose = o.verbose;
    ctx.container = vh.getenv("container") != null or vh.pathExists("/.dockerenv");
    ctx.self_exe = vh.readlink("/proc/self/exe") catch "/usr/local/sbin/vh-init";
    _ = linux.syscall1(.umask, 0o022);
    vh.setenv("PATH", "/usr/bin:/usr/sbin:/usr/local/sbin:/usr/local/bin");
    // Ctrl+Alt+Del becomes SIGINT to us instead of an immediate reboot
    _ = linux.reboot(.MAGIC1, .MAGIC2, .CAD_OFF, null);
    const t0 = sys.monoUs();
    kmsg("vh-init {s} as PID 1{s}", .{ version, if (ctx.container) " (container)" else "" });

    // stage 1: the steps of vh-stage1, in this process. Signals keep their default
    // dispositions here, which the kernel discards for PID 1, so the programs stage 1 runs
    // by argv (udevd, modprobe, nft) inherit nothing blocked.
    if (!ctx.skip_stage1) {
        const failures = stage1.runBoot();
        kmsg("stage 1 done in {d} ms ({d} errors)", .{ (sys.monoUs() - t0 + 500) / 1000, failures });
    }
    // from here every signal arrives through the signalfd
    var all = linux.sigfillset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &all, null);
    var want = linux.sigemptyset();
    for ([_]linux.SIG{ .CHLD, .INT, .TERM, .USR1, .USR2, .CONT, .HUP, .WINCH }) |s| linux.sigaddset(&want, s);
    const sigfd_rc = linux.signalfd(-1, &want, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
    if (linux.errno(sigfd_rc) != .SUCCESS) vh.die("signalfd: {s}", .{@tagName(linux.errno(sigfd_rc))});
    const sigfd: linux.fd_t = @intCast(sigfd_rc);
    startManager();

    var pfds = [_]linux.pollfd{
        .{ .fd = sigfd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = ctx.chan, .events = linux.POLL.IN, .revents = 0 },
    };
    while (true) {
        pfds[1].fd = ctx.chan;
        pfds[0].revents = 0;
        pfds[1].revents = 0;
        // during a shutdown the manager has 60 s to stop everything
        const timeout: i32 = if (ctx.shutting_down != null) 1000 else -1;
        const rc = linux.poll(&pfds, pfds.len, timeout);
        if (linux.errno(rc) != .SUCCESS and linux.errno(rc) != .INTR) {
            const ts: linux.timespec = .{ .sec = 1, .nsec = 0 };
            _ = linux.nanosleep(&ts, null);
            continue;
        }
        if (pfds[0].revents != 0) {
            var info: linux.signalfd_siginfo = undefined;
            while (true) {
                const n = linux.read(sigfd, mem.asBytes(&info), @sizeOf(linux.signalfd_siginfo));
                if (linux.errno(n) != .SUCCESS or n < @sizeOf(linux.signalfd_siginfo)) break;
                switch (@as(linux.SIG, @enumFromInt(info.signo))) {
                    .CHLD => reap(),
                    .INT => ctrlAltDel(),
                    .TERM => requestShutdown(.poweroff),
                    .USR1 => requestShutdown(.halt),
                    .USR2 => requestShutdown(.poweroff),
                    .CONT => if (runitFiles()) |k| requestShutdown(k),
                    .HUP => if (ctx.chan >= 0) vh.writeAllFd(ctx.chan, "reload\n") catch {},
                    else => {},
                }
            }
        }
        reap();
        if (pfds[1].revents != 0 and ctx.chan >= 0) {
            if (pfds[1].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0 and pfds[1].revents & linux.POLL.IN == 0) {
                // the manager closed its end; its exit is handled by SIGCHLD
                reap();
            } else readChannel();
        }
        if (ctx.shutting_down) |k| if (ctx.stop_sent_us != 0 and sys.monoUs() - ctx.stop_sent_us > 60 * 1_000_000) {
            kmsg("the manager did not stop the services in 60 s: stage 3 anyway", .{});
            shutdown.run(k, ctx.container);
        };
    }
}
