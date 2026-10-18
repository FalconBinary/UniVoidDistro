// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! The compositor's seccomp filter: a classic BPF program built for one architecture.
//! A deny-list: the compositor keeps every system call wlroots, Mesa and libinput make, and loses
//! what an attacker who took it over would want next: running programs, touching other processes,
//! the network, kernel attack surface (bpf, io_uring, userfaultfd, modules...). Decisions on the
//! syscall number alone are cached by the kernel (5.11+) as per-syscall bitmaps, so allowed calls
//! cost nothing; only clone, socket, kill/tgkill and prctl look at an argument.
//! Pure code: `zig build test` runs the program in a small BPF interpreter for x86_64 and aarch64.
const std = @import("std");

pub const Arch = enum { x86_64, aarch64 };

/// struct sock_filter
pub const Insn = extern struct { code: u16, jt: u8, jf: u8, k: u32 };

pub const ret_kill_process: u32 = 0x80000000;
pub const ret_errno: u32 = 0x00050000;
pub const ret_allow: u32 = 0x7fff0000;
pub const EPERM = 1;
pub const ENOSYS = 38;
pub const EAFNOSUPPORT = 97;

const audit_arch = std.enums.EnumArray(Arch, u32).init(.{ .x86_64 = 0xC000003E, .aarch64 = 0xC00000B7 });
const clone_thread = 0x10000;
const af_unix = 1;
const af_netlink = 16;
const pr_set_dumpable = 4;
const pr_set_ptracer = 0x59616d61;

const ld_w_abs = 0x20;
const jeq_k = 0x15;
const jge_k = 0x35;
const jset_k = 0x45;
const ret_k = 0x06;

// offsets in struct seccomp_data (little endian)
const off_nr = 0;
const off_arch = 4;
fn argLo(i: u32) u32 {
    return 16 + 8 * i;
}
fn argHi(i: u32) u32 {
    return 20 + 8 * i;
}

/// Answered with EPERM. Names missing on an architecture (fork on aarch64) are skipped.
const denied = [_][]const u8{
    // running programs: the launcher does that, the compositor never execs or forks
    "execve",                  "execveat",          "fork",              "vfork",
    // other processes
    "ptrace",                  "process_vm_readv",  "process_vm_writev", "pidfd_getfd",
    "pidfd_send_signal",       "process_madvise",   "process_mrelease",  "kcmp",
    "tkill",                   "move_pages",        "migrate_pages",
    // network: every connection the compositor needs is open before the filter
    "connect",                 "bind",              "listen",
    // the kernel and the machine
    "kexec_load",              "kexec_file_load",   "init_module",       "finit_module",
    "delete_module",           "reboot",            "swapon",            "swapoff",
    "acct",                    "mount",             "umount2",           "pivot_root",
    "chroot",                  "unshare",           "setns",             "mount_setattr",
    "move_mount",              "open_tree",         "open_tree_attr",    "fsopen",
    "fsconfig",                "fsmount",           "fspick",            "bpf",
    "perf_event_open",         "userfaultfd",       "io_uring_setup",    "io_uring_enter",
    "io_uring_register",       "keyctl",            "add_key",           "request_key",
    "settimeofday",            "clock_settime",     "clock_adjtime",     "adjtimex",
    "personality",             "iopl",              "ioperm",            "modify_ldt",
    "uselib",                  "ustat",             "sysfs",             "_sysctl",
    "vhangup",                 "syslog",            "lookup_dcookie",    "nfsservctl",
    "quotactl",                "quotactl_fd",       "open_by_handle_at", "name_to_handle_at",
    "fanotify_init",
    // file modes and owners by path: Landlock does not cover them (chmod 0644 ~/.ssh/id_* would
    // leak a key). fchmod/fchown on an fd stay: wlroots seals its keymap shm with fchmod(fd, 0).
    "chmod",                   "fchmodat",          "fchmodat2",         "chown",
    "lchown",                  "fchownat",
};

fn Sys(comptime arch: Arch) type {
    return switch (arch) {
        .x86_64 => std.os.linux.syscalls.X64,
        .aarch64 => std.os.linux.syscalls.Arm64,
    };
}

fn nr(comptime arch: Arch, comptime name: []const u8) u32 {
    return @intCast(@intFromEnum(@field(Sys(arch), name)));
}

pub const max_len = 320;

const Builder = struct {
    buf: *[max_len]Insn,
    n: usize = 0,

    fn add(b: *Builder, code: u16, jt: u8, jf: u8, k: u32) void {
        b.buf[b.n] = .{ .code = code, .jt = jt, .jf = jf, .k = k };
        b.n += 1;
    }
    fn ld(b: *Builder, off: u32) void {
        b.add(ld_w_abs, 0, 0, off);
    }
    fn ret(b: *Builder, k: u32) void {
        b.add(ret_k, 0, 0, k);
    }
    /// With the syscall number in A: on `num` run the next `len` instructions, else skip them.
    fn on(b: *Builder, num: u32, len: u8) void {
        b.add(jeq_k, 0, len, num);
    }
};

/// Builds the filter for `arch`. `pid`: kill/tgkill may only target this process (abort() does).
pub fn build(comptime arch: Arch, pid: u32, out: *[max_len]Insn) []const Insn {
    var b: Builder = .{ .buf = out };
    b.ld(off_arch);
    b.add(jeq_k, 1, 0, audit_arch.get(arch));
    b.ret(ret_kill_process); // another ABI (int 0x80 on x86_64): never legitimate here
    b.ld(off_nr);
    if (arch == .x86_64) {
        // x32 syscalls share the arch value; their numbers have bit 30 set
        b.add(jge_k, 0, 1, 0x40000000);
        b.ret(ret_kill_process);
    }
    inline for (denied) |name| if (@hasField(Sys(arch), name)) {
        b.on(nr(arch, name), 1);
        b.ret(ret_errno | EPERM);
    };
    // glibc falls back from clone3 (flags hidden behind a pointer) to clone
    b.on(nr(arch, "clone3"), 1);
    b.ret(ret_errno | ENOSYS);
    // clone: threads (Mesa) yes, processes no
    b.on(nr(arch, "clone"), 4);
    b.ld(argLo(0));
    b.add(jset_k, 0, 1, clone_thread);
    b.ret(ret_allow);
    b.ret(ret_errno | EPERM);
    // socket: socketpair for granted programs is a separate call; udev uses netlink
    b.on(nr(arch, "socket"), 5);
    b.ld(argLo(0));
    b.add(jeq_k, 2, 0, af_unix);
    b.add(jeq_k, 1, 0, af_netlink);
    b.ret(ret_errno | EAFNOSUPPORT);
    b.ret(ret_allow);
    // signals only to ourselves (abort, raise); arg 0 is the target process
    inline for (.{ "kill", "tgkill", "rt_sigqueueinfo", "rt_tgsigqueueinfo" }) |name| {
        b.on(nr(arch, name), 6);
        b.ld(argLo(0));
        b.add(jeq_k, 0, 3, pid);
        b.ld(argHi(0));
        b.add(jeq_k, 0, 1, 0);
        b.ret(ret_allow);
        b.ret(ret_errno | EPERM);
    }
    // prctl: everything but making us dumpable or ptraceable again
    b.on(nr(arch, "prctl"), 5);
    b.ld(argLo(0));
    b.add(jeq_k, 2, 0, pr_set_dumpable);
    b.add(jeq_k, 1, 0, pr_set_ptracer);
    b.ret(ret_allow);
    b.ret(ret_errno | EPERM);
    b.ret(ret_allow);
    return out[0..b.n];
}

pub fn native() Arch {
    return switch (@import("builtin").cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        else => @compileError("seccomp filter: only x86_64 and aarch64"),
    };
}

// ---------------------------------------------------------------- tests

/// Runs `prog` like the kernel would. `args_read` reports whether an argument was looked at
/// (such syscalls cannot be cached by the kernel).
fn eval(prog: []const Insn, arch: u32, num: u32, args: [6]u64, args_read: *bool) u32 {
    var a: u32 = 0;
    var pc: usize = 0;
    while (true) {
        const i = prog[pc];
        pc += 1;
        switch (i.code) {
            ld_w_abs => a = switch (i.k) {
                off_nr => num,
                off_arch => arch,
                else => blk: {
                    args_read.* = true;
                    const idx = (i.k - 16) / 8;
                    const v = args[idx];
                    break :blk if ((i.k - 16) % 8 == 0) @truncate(v) else @truncate(v >> 32);
                },
            },
            jeq_k => pc += if (a == i.k) i.jt else i.jf,
            jge_k => pc += if (a >= i.k) i.jt else i.jf,
            jset_k => pc += if (a & i.k != 0) i.jt else i.jf,
            ret_k => return i.k,
            else => unreachable,
        }
    }
}

fn check(comptime arch: Arch) !void {
    const tt = std.testing;
    var buf: [max_len]Insn = undefined;
    const pid = 4321;
    const prog = build(arch, pid, &buf);
    const me = audit_arch.get(arch);
    const Case = struct { name: []const u8, args: [6]u64 = @splat(0), want: u32 };
    const neg1: u64 = @bitCast(@as(i64, -1));
    const cases = [_]Case{
        .{ .name = "read", .want = ret_allow },
        .{ .name = "ioctl", .want = ret_allow },
        .{ .name = "mmap", .want = ret_allow },
        .{ .name = "futex", .want = ret_allow },
        .{ .name = "recvmsg", .want = ret_allow },
        .{ .name = "accept4", .want = ret_allow },
        .{ .name = "socketpair", .want = ret_allow },
        .{ .name = "landlock_restrict_self", .want = ret_allow },
        .{ .name = "execve", .want = ret_errno | EPERM },
        .{ .name = "ptrace", .want = ret_errno | EPERM },
        .{ .name = "connect", .want = ret_errno | EPERM },
        .{ .name = "io_uring_setup", .want = ret_errno | EPERM },
        .{ .name = "bpf", .want = ret_errno | EPERM },
        .{ .name = "fchmodat", .want = ret_errno | EPERM },
        .{ .name = "fchmod", .want = ret_allow },
        .{ .name = "clone3", .want = ret_errno | ENOSYS },
        .{ .name = "clone", .args = .{ 0x3d0f00, 0, 0, 0, 0, 0 }, .want = ret_allow },
        .{ .name = "clone", .args = .{ 0x01200011, 0, 0, 0, 0, 0 }, .want = ret_errno | EPERM },
        .{ .name = "socket", .args = .{ af_unix, 1, 0, 0, 0, 0 }, .want = ret_allow },
        .{ .name = "socket", .args = .{ af_netlink, 3, 15, 0, 0, 0 }, .want = ret_allow },
        .{ .name = "socket", .args = .{ 2, 1, 0, 0, 0, 0 }, .want = ret_errno | EAFNOSUPPORT },
        .{ .name = "kill", .args = .{ pid, 6, 0, 0, 0, 0 }, .want = ret_allow },
        .{ .name = "kill", .args = .{ 1, 9, 0, 0, 0, 0 }, .want = ret_errno | EPERM },
        .{ .name = "kill", .args = .{ neg1, 9, 0, 0, 0, 0 }, .want = ret_errno | EPERM },
        .{ .name = "kill", .args = .{ pid | (1 << 32), 9, 0, 0, 0, 0 }, .want = ret_errno | EPERM },
        .{ .name = "tgkill", .args = .{ pid, pid, 6, 0, 0, 0 }, .want = ret_allow },
        .{ .name = "tgkill", .args = .{ 77, 77, 9, 0, 0, 0 }, .want = ret_errno | EPERM },
        .{ .name = "prctl", .args = .{ 15, 0, 0, 0, 0, 0 }, .want = ret_allow },
        .{ .name = "prctl", .args = .{ pr_set_dumpable, 1, 0, 0, 0, 0 }, .want = ret_errno | EPERM },
        .{ .name = "prctl", .args = .{ pr_set_ptracer, neg1, 0, 0, 0, 0 }, .want = ret_errno | EPERM },
    };
    inline for (cases) |cs| {
        var read = false;
        try tt.expectEqual(cs.want, eval(prog, me, nr(arch, cs.name), cs.args, &read));
    }
    var read = false;
    try tt.expectEqual(ret_kill_process, eval(prog, 0x40000003, 0, @splat(0), &read)); // i386
    if (arch == .x86_64) {
        try tt.expectEqual(ret_kill_process, eval(prog, me, 0x40000000 | 59, @splat(0), &read)); // x32 execve
        try tt.expectEqual(ret_errno | EPERM, eval(prog, me, nr(arch, "fork"), @splat(0), &read));
    }
    // every syscall that is decided by its number alone never reads an argument: kernel-cacheable
    const with_args = [_][]const u8{ "clone", "socket", "kill", "tgkill", "rt_sigqueueinfo", "rt_tgsigqueueinfo", "prctl" };
    for (std.enums.values(Sys(arch))) |sys| {
        const name = @tagName(sys);
        var reads = false;
        _ = eval(prog, me, @intCast(@intFromEnum(sys)), @splat(0), &reads);
        var expect_reads = false;
        for (with_args) |w| if (std.mem.eql(u8, w, name)) {
            expect_reads = true;
        };
        try tt.expectEqual(expect_reads, reads);
    }
}

test "seccomp filter decisions on x86_64" {
    try check(.x86_64);
}

test "seccomp filter decisions on aarch64" {
    try check(.aarch64);
}
