// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Applies the compositor's sandbox (src/landlock.zig, src/seccomp.zig, same code and order) to
//! itself, then tries what an attacker inside the compositor would try, and what the compositor
//! itself still needs. Prints PASS/FAIL/SKIP lines; the exit code is the number of failures.
//! Run by tests/security.sh: refurs-sandbox-test SCRATCH_DIR
const std = @import("std");
const linux = std.os.linux;
const landlock = @import("landlock");
const seccomp = @import("seccomp");

var fails: u8 = 0;

fn report(name: []const u8, good: bool, detail: linux.E) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} sandbox: {s} ({s})\n", .{ if (good) "PASS" else "FAIL", name, @tagName(detail) }) catch return;
    _ = linux.write(1, line.ptr, line.len);
    if (!good) fails += 1;
}

fn skip(name: []const u8) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "SKIP sandbox: {s}\n", .{name}) catch return;
    _ = linux.write(1, line.ptr, line.len);
}

fn openErr(path: [*:0]const u8, flags: linux.O) linux.E {
    const rc = linux.open(path, flags, 0o600);
    if (linux.errno(rc) == .SUCCESS) _ = linux.close(@intCast(rc));
    return linux.errno(rc);
}

fn mkfile(path: [*:0]const u8) void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) == .SUCCESS) _ = linux.close(@intCast(rc));
}

fn worker(flag: *std.atomic.Value(bool)) void {
    flag.store(true, .release);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var args = init.args.iterate();
    _ = args.skip();
    const dir = args.next() orelse "/tmp/refurs-sandbox";
    var b: [8][256]u8 = undefined;
    const home = std.fmt.bufPrintSentinel(&b[0], "{s}/home", .{dir}, 0) catch return 99;
    const secret = std.fmt.bufPrintSentinel(&b[1], "{s}/home/secret", .{dir}, 0) catch return 99;
    const cache = std.fmt.bufPrintSentinel(&b[2], "{s}/home/.cache", .{dir}, 0) catch return 99;
    const cached = std.fmt.bufPrintSentinel(&b[3], "{s}/home/.cache/shader", .{dir}, 0) catch return 99;
    const icons = std.fmt.bufPrintSentinel(&b[4], "{s}/home/.icons", .{dir}, 0) catch return 99;
    const cursor = std.fmt.bufPrintSentinel(&b[5], "{s}/home/.icons/cursor", .{dir}, 0) catch return 99;
    const outside = std.fmt.bufPrintSentinel(&b[6], "{s}/new-file", .{dir}, 0) catch return 99;
    _ = linux.mkdir(@ptrCast(dir.ptr), 0o700);
    _ = linux.mkdir(home, 0o700);
    _ = linux.mkdir(cache, 0o700);
    _ = linux.mkdir(icons, 0o700);
    mkfile(secret);
    mkfile(cursor);
    _ = linux.unlink(outside);

    // the same steps as sandbox.early + sandbox.late
    _ = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    const env: landlock.Env = .{ .home = home };
    const abi = landlock.apply(.startup, env);
    if (abi != 0) _ = landlock.apply(.running, env);
    var buf: [seccomp.max_len]seccomp.Insn = undefined;
    const prog = seccomp.build(comptime seccomp.native(), @intCast(linux.getpid()), &buf);
    const Fprog = extern struct { len: u16, filter: [*]const seccomp.Insn };
    const fp: Fprog = .{ .len = @intCast(prog.len), .filter = prog.ptr };
    const sc = linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, linux.SECCOMP.FILTER_FLAG.TSYNC, &fp);
    report("seccomp filter installed", linux.errno(sc) == .SUCCESS and sc == 0, linux.errno(sc));

    if (abi == 0) {
        skip("landlock unavailable in this kernel or container");
    } else {
        var e = openErr(secret, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        report("home files unreadable", e == .ACCES, e);
        e = openErr(cached, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true });
        report("shader cache writable", e == .SUCCESS, e);
        e = openErr(cursor, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        report("cursor themes readable", e == .SUCCESS, e);
        e = openErr("/etc/os-release", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        report("system files readable", e == .SUCCESS, e);
        e = openErr(outside, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true });
        report("no new files elsewhere", e == .ACCES, e);
        e = openErr("/etc/os-release", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        report("system files not writable", e == .ACCES or e == .ROFS, e);
    }

    var e = linux.errno(linux.execve("/bin/true", &[_:null]?[*:0]const u8{"/bin/true"}, &[_:null]?[*:0]const u8{}));
    report("execve refused", e == .PERM, e);
    e = linux.errno(linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0));
    report("no network sockets", e == .AFNOSUPPORT, e);
    const us = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(us) == .SUCCESS) {
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        @memcpy(addr.path[0..12], "/run/x.sock\x00");
        e = linux.errno(linux.connect(@intCast(us), @ptrCast(&addr), @sizeOf(linux.sockaddr.un)));
        report("connect refused", e == .PERM, e);
        _ = linux.close(@intCast(us));
    } else report("unix socket", false, linux.errno(us));
    e = linux.errno(linux.syscall5(.clone, 17, 0, 0, 0, 0)); // SIGCHLD: a new process
    report("fork refused", e == .PERM, e);
    e = linux.errno(linux.syscall2(.kill, 1, 0));
    report("signals to others refused", e == .PERM, e);
    e = linux.errno(linux.syscall2(.kill, @intCast(linux.getpid()), 0));
    report("signals to itself allowed", e == .SUCCESS, e);
    e = linux.errno(linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), 1, 0, 0, 0));
    report("cannot become dumpable", e == .PERM, e);
    e = linux.errno(linux.syscall3(.fchmodat, @bitCast(@as(isize, linux.AT.FDCWD)), @intFromPtr(secret.ptr), 0o644));
    report("chmod refused", e == .PERM, e);

    // what Mesa and wlroots still need: threads (glibc: clone3 -> ENOSYS -> clone), shared memory
    var flag = std.atomic.Value(bool).init(false);
    if (std.Thread.spawn(.{}, worker, .{&flag})) |t| {
        t.join();
        report("threads work", flag.load(.acquire), .SUCCESS);
    } else |_| report("threads work", false, .AGAIN);
    const m = linux.memfd_create("t", linux.MFD.CLOEXEC);
    report("memfd works", linux.errno(m) == .SUCCESS, linux.errno(m));
    if (abi != 0) {
        e = openErr("/dev/shm/refurs-sandbox-test", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true });
        report("shm_open works", e == .SUCCESS, e);
        _ = linux.unlink("/dev/shm/refurs-sandbox-test");
    }
    return fails;
}
