// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Process hardening of the compositor and the launcher. The launcher is forked before any of the
//! restrictions below, so the programs it starts (terminals, sudo, swaylock) are unaffected.
const std = @import("std");
const linux = std.os.linux;
const wm = @import("wm.zig");
const c = wm.c;
const landlock = @import("landlock.zig");
const seccomp = @import("seccomp.zig");

const CapHeader = extern struct { version: u32, pid: c_int };
const CapData = extern struct { effective: u32, permitted: u32, inheritable: u32 };
const cap_version_3 = 0x20080522;
const PR_CAP_AMBIENT = 47;
const PR_CAP_AMBIENT_CLEAR_ALL = 4;

/// Gives up every capability (e.g. cap_sys_nice set on the binary for realtime scheduling, which
/// is applied before this). Dropping is always allowed; without capabilities this changes nothing.
pub fn dropCaps() void {
    var hdr: CapHeader = .{ .version = cap_version_3, .pid = 0 };
    const none = [2]CapData{ .{ .effective = 0, .permitted = 0, .inheritable = 0 }, .{ .effective = 0, .permitted = 0, .inheritable = 0 } };
    _ = linux.syscall2(.capset, @intFromPtr(&hdr), @intFromPtr(&none));
    _ = linux.prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0);
}

/// Same-user processes can no longer ptrace us or read our memory, and no core dump is written
/// (it would hold clipboard data and keystrokes). Programs we start are not affected (execve resets it).
pub fn noDump() void {
    _ = linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), 0, 0, 0, 0);
}

/// No controlling terminal: from a VT, a compromised process could push input into the shell that
/// started us (TIOCSTI). stdin is never read, so it becomes /dev/null. Call with SIGHUP ignored:
/// a session leader giving up its terminal sends itself SIGHUP.
pub fn detachTty() void {
    const tty = c.open("/dev/tty", c.O_RDWR | c.O_CLOEXEC | c.O_NOCTTY);
    if (tty >= 0) {
        _ = c.ioctl(tty, c.TIOCNOTTY);
        _ = c.close(tty);
    }
    const nul = c.open("/dev/null", c.O_RDONLY);
    if (nul > 0) {
        _ = c.dup2(nul, 0);
        _ = c.close(nul);
    }
}

/// Every client connection and every shared-memory pool holds an fd: the default soft limit of 1024
/// lets one client exhaust them all. The launcher is forked before this, so programs keep the
/// usual limit (select() breaks above 1024).
pub fn raiseFdLimit() void {
    var rl: c.struct_rlimit = undefined;
    if (c.getrlimit(c.RLIMIT_NOFILE, &rl) != 0 or rl.rlim_cur >= rl.rlim_max) return;
    rl.rlim_cur = rl.rlim_max;
    _ = c.setrlimit(c.RLIMIT_NOFILE, &rl);
}

/// SCHED_RR at the lowest realtime priority, if the rtprio limit (or cap_sys_nice) allows it:
/// the cursor and frames keep their pace under full CPU load. Children are reset to normal.
pub fn realtime() bool {
    var p: c.struct_sched_param = .{ .sched_priority = c.sched_get_priority_min(c.SCHED_RR) };
    return c.sched_setscheduler(0, c.SCHED_RR | c.SCHED_RESET_ON_FORK, &p) == 0;
}

// ------------------------------------------------------------------ libinput quirks

var quirks_buf: [std.fs.max_path_bytes:0]u8 = undefined;
var quirks_dir: ?[]const u8 = null;

/// libinput's device quirks of the same version as the libinput built into RefursWM live next to the
/// binary (<prefix>/share/refurswm/libinput): libinput is pointed there (LIBINPUT_QUIRKS_DIR, the
/// user's own setting wins) and the startup Landlock domain may read them.
pub fn bundledQuirks() void {
    if (!@import("build_options").bundled_quirks or c.getenv("LIBINPUT_QUIRKS_DIR") != null) return;
    var exe: [std.fs.max_path_bytes]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &exe, exe.len);
    if (n <= 0 or n >= exe.len) return;
    const bin = std.fs.path.dirname(exe[0..@intCast(n)]) orelse return;
    const prefix = std.fs.path.dirname(bin) orelse return;
    const p = std.fmt.bufPrintSentinel(&quirks_buf, "{s}/share/refurswm/libinput", .{prefix}, 0) catch return;
    if (c.access(p.ptr, c.R_OK) != 0) return;
    _ = c.setenv("LIBINPUT_QUIRKS_DIR", p.ptr, 1);
    quirks_dir = p;
}

// ------------------------------------------------------------------ sandbox

/// REFURS_SANDBOX=0 turns it off, to tell a sandbox denial from a bug on new hardware.
fn enabled() bool {
    const v = c.getenv("REFURS_SANDBOX") orelse return true;
    return !std.mem.eql(u8, std.mem.span(v), "0");
}

var landlock_abi: u32 = 0;

/// Right after the launcher is forked, before wlroots starts (no threads yet): no_new_privs and the
/// startup Landlock domain. Every thread Mesa creates later inherits both.
pub fn early() void {
    if (!enabled()) return;
    if (linux.errno(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS) return;
    var env = landlock.Env.fromProcess();
    env.quirks_dir = quirks_dir;
    landlock_abi = landlock.apply(.startup, env);
}

const SockFprog = extern struct { len: u16, filter: [*]const seccomp.Insn };

/// Before the event loop: the running Landlock domain stacked on top (no more Wayland sockets or xkb
/// rules) and the seccomp filter on every thread (TSYNC). Logs what is in force.
pub fn late() void {
    if (!enabled()) return wm.log("sandbox: off (REFURS_SANDBOX=0)", .{});
    if (landlock_abi != 0) landlock_abi = landlock.apply(.running, landlock.Env.fromProcess());
    var buf: [seccomp.max_len]seccomp.Insn = undefined;
    const prog = seccomp.build(comptime seccomp.native(), @intCast(linux.getpid()), &buf);
    const fprog: SockFprog = .{ .len = @intCast(prog.len), .filter = prog.ptr };
    const rc = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, linux.SECCOMP.FILTER_FLAG.TSYNC, &fprog);
    const sc = linux.errno(rc) == .SUCCESS and rc == 0;
    if (landlock_abi != 0) {
        wm.log("sandbox: landlock (ABI {d}), seccomp {s}", .{ landlock_abi, if (sc) "on" else "FAILED" });
    } else wm.log("sandbox: landlock unavailable (needs lsm=landlock), seccomp {s}", .{if (sc) "on" else "FAILED"});
}
