//! void-hardperf-light: generator of the seccomp-BPF filters for the sandboxes (docs/08, docs/13).
//!
//! The classic BPF program is assembled here and passed to bwrap --seccomp FD. The filter
//! is applied after the sandbox is assembled, inherited by every descendant and never removed.
//!
//! The filter is built for the architecture the program is compiled for (builtin.cpu.arch:
//! x86_64 or aarch64): the audit architecture and, on x86_64 alone, the x32 check come from
//! the target; the policy (what is allowed, denied or checked by its arguments) is the same
//! on both.
//!
//! The instruction order serves the kernel's seccomp cache: first the architecture and the
//! x32 bit, then the calls with argument checks and the denied ones, and everything else is
//! an unconditional ALLOW that reads no arguments: the kernel caches such calls and does not
//! run the BPF program for them. Jumps are given as labels and computed by the assembler;
//! selftest() runs both filters through the built-in BPF interpreter on a set of calls with
//! expected results.
const std = @import("std");
const builtin = @import("builtin");
const vh = @import("vh");

/// a classic BPF instruction in the kernel format (struct sock_filter)
pub const Ins = struct { code: u16, jt: u8, jf: u8, k: u32 };

pub const max_ins = 256;

/// AUDIT_ARCH_* (linux/audit.h): what the kernel puts into seccomp_data.arch
const AUDIT_ARCH_X86_64: u32 = 0xC000003E;
const AUDIT_ARCH_I386: u32 = 0x40000003;
const AUDIT_ARCH_AARCH64: u32 = 0xC00000B7;
const AUDIT_ARCH_ARM: u32 = 0x40000028;
const audit_arches = [_]u32{ AUDIT_ARCH_X86_64, AUDIT_ARCH_I386, AUDIT_ARCH_AARCH64, AUDIT_ARCH_ARM };
/// the target's architecture: a call of any other is killed, the 32-bit compat ABIs among them
/// (i386 under an x86_64 kernel, arm under an arm64 one)
const AUDIT_ARCH: u32 = switch (builtin.cpu.arch) {
    .x86_64 => AUDIT_ARCH_X86_64,
    .aarch64 => AUDIT_ARCH_AARCH64,
    else => @compileError("seccomp: no filter for this architecture"),
};
/// the x32 ABI of x86_64: a system call number with this bit set reaches the kernel's x32 entry
/// points under AUDIT_ARCH_X86_64, so the filter answers ENOSYS; no other architecture has it
const X32_BIT: u32 = 0x40000000;
const has_x32 = builtin.cpu.arch == .x86_64;
const RET_ALLOW: u32 = 0x7FFF0000;
const RET_KILL: u32 = 0x80000000;
fn errnoRet(e: u32) u32 {
    return 0x00050000 | e;
}
const EPERM_: u32 = 1;
const ENOSYS_: u32 = 38;
const EAFNOSUPPORT_: u32 = 97;

/// x86_64 system call numbers
const NR = struct {
    const read = 0;
    const write = 1;
    const mmap = 9;
    const socket = 41;
    const socketpair = 53;
    const setsockopt = 54;
    const clone = 56;
    const ptrace = 101;
    const syslog = 103;
    const personality = 135;
    const vhangup = 153;
    const modify_ldt = 154;
    const pivot_root = 155;
    const chroot = 161;
    const acct = 163;
    const mount = 165;
    const umount2 = 166;
    const swapon = 167;
    const swapoff = 168;
    const iopl = 172;
    const ioperm = 173;
    const init_module = 175;
    const delete_module = 176;
    const quotactl = 179;
    const kexec_load = 246;
    const add_key = 248;
    const request_key = 249;
    const keyctl = 250;
    const unshare = 272;
    const perf_event_open = 298;
    const open_by_handle_at = 304;
    const setns = 308;
    const process_vm_readv = 310;
    const process_vm_writev = 311;
    const finit_module = 313;
    const kexec_file_load = 320;
    const bpf = 321;
    const userfaultfd = 323;
    const io_uring_setup = 425;
    const io_uring_enter = 426;
    const io_uring_register = 427;
    const open_tree = 428;
    const move_mount = 429;
    const fsopen = 430;
    const fsconfig = 431;
    const fsmount = 432;
    const fspick = 433;
    const clone3 = 435;
    const mount_setattr = 442;
};

const CLONE_NEW_MASK: u32 = 0x7E020000; // NEWNS|NEWCGROUP|NEWUTS|NEWIPC|NEWUSER|NEWPID|NEWNET
const AF_UNIX_: u32 = 1;
const AF_INET_: u32 = 2;
const AF_INET6_: u32 = 10;
const AF_NETLINK_: u32 = 16;
const IPPROTO_TCP_: u32 = 6;
const IPPROTO_UDP_: u32 = 17;
const NETLINK_ROUTE_: u32 = 0;
const SOL_SOCKET_: u32 = 1;
const SOL_TCP_: u32 = 6;
const TCP_ULP_: u32 = 31; // kTLS and other ULPs: kernel attack surface
const SO_ATTACH_FILTER_: u32 = 26;
const SO_ATTACH_BPF_: u32 = 50;
const SO_ATTACH_REUSEPORT_CBPF_: u32 = 51; // cBPF/eBPF on a socket without privileges
const SO_ATTACH_REUSEPORT_EBPF_: u32 = 52;

const deny_common = [_]u32{
    NR.perf_event_open, NR.bpf,                NR.userfaultfd,       NR.add_key,          NR.request_key, NR.keyctl,
    NR.kexec_load,      NR.kexec_file_load,    NR.io_uring_setup,    NR.io_uring_enter,   NR.io_uring_register,
    NR.modify_ldt,      NR.mount,              NR.umount2,           NR.pivot_root,       NR.fsopen,
    NR.fsconfig,        NR.fsmount,            NR.fspick,            NR.move_mount,       NR.open_tree,
    NR.mount_setattr,   NR.ptrace,             NR.process_vm_readv,  NR.process_vm_writev, NR.init_module,
    NR.finit_module,    NR.delete_module,      NR.iopl,              NR.ioperm,           NR.open_by_handle_at,
    NR.chroot,          NR.acct,               NR.swapon,            NR.swapoff,          NR.syslog,
    NR.vhangup,         NR.quotactl,           NR.unshare,           NR.setns,
};

const LD: u16 = 0x20;
const JEQ: u16 = 0x15;
const JGE: u16 = 0x35;
const JSET: u16 = 0x45;
const RET: u16 = 0x06;

/// labels; next means "the next instruction"
const L = enum(u8) { next, kill, enosys, eperm, eafno, allow, deny, c3, sp, t, inet, nl, so, sol };

/// a mini assembler for classic BPF: jumps go to labels
const As = struct {
    code: [max_ins]struct { op: u16, jt: L, jf: L, k: u32 } = undefined,
    n: usize = 0,
    labels: [std.enums.values(L).len]i32 = @splat(-1),

    fn emit(a: *As, op: u16, k: u32, jt: L, jf: L) void {
        if (a.n >= max_ins) vh.die("seccomp: program too long", .{});
        a.code[a.n] = .{ .op = op, .k = k, .jt = jt, .jf = jf };
        a.n += 1;
    }
    fn label(a: *As, l: L) void {
        a.labels[@intFromEnum(l)] = @intCast(a.n);
    }
    fn ldNr(a: *As) void {
        a.emit(LD, 0, .next, .next);
    }
    fn ldArch(a: *As) void {
        a.emit(LD, 4, .next, .next);
    }
    /// the low 32 bits of args[i]
    fn ldArg(a: *As, i: u32) void {
        a.emit(LD, 16 + 8 * i, .next, .next);
    }
    fn jmp(a: *As, op: u16, k: u32, jt: L, jf: L) void {
        a.emit(op, k, jt, jf);
    }
    fn ret(a: *As, k: u32) void {
        a.emit(RET, k, .next, .next);
    }
    fn off(a: *const As, i: usize, l: L) u8 {
        if (l == .next) return 0;
        const target = a.labels[@intFromEnum(l)];
        const d = target - @as(i32, @intCast(i)) - 1;
        if (target < 0 or d < 0 or d > 255) vh.die("seccomp: jump to label {d} from {d}: {d}", .{ @intFromEnum(l), i, d });
        return @intCast(d);
    }
    fn assemble(a: *const As, out: []Ins) []Ins {
        for (a.code[0..a.n], 0..) |c, i|
            out[i] = .{ .code = c.op, .jt = a.off(i, c.jt), .jf = a.off(i, c.jf), .k = c.k };
        return out[0..a.n];
    }
};

fn header(a: *As) void {
    a.ldArch();
    a.jmp(JEQ, AUDIT_ARCH, .next, .kill);
    a.ldNr();
    if (has_x32) a.jmp(JGE, X32_BIT, .enosys, .next);
}

fn tail(a: *As, allow_ptrace: bool) void {
    // clone: no CLONE_NEW* flags (new namespaces)
    a.jmp(JEQ, NR.clone, .next, .c3);
    a.ldArg(0);
    a.jmp(JSET, CLONE_NEW_MASK, .eperm, .allow);
    // clone3: the flags live in a struct behind a pointer, invisible to BPF. ENOSYS makes glibc fall back to clone
    a.label(.c3);
    a.jmp(JEQ, NR.clone3, .enosys, .next);
    // personality: only 0 and the query of the current value (no READ_IMPLIES_EXEC, ADDR_NO_RANDOMIZE)
    a.jmp(JEQ, NR.personality, .next, .deny);
    a.ldArg(0);
    a.jmp(JEQ, 0, .allow, .next);
    a.jmp(JEQ, 0xFFFFFFFF, .allow, .eperm);
    a.label(.deny);
    for (deny_common) |nr| {
        // Firefox needs ptrace for its own processes (the profiler, hang reports)
        if (allow_ptrace and nr == NR.ptrace) continue;
        a.jmp(JEQ, nr, .eperm, .next);
    }
    a.label(.allow);
    a.ret(RET_ALLOW);
    a.label(.eperm);
    a.ret(errnoRet(EPERM_));
    a.label(.enosys);
    a.ret(errnoRet(ENOSYS_));
    a.label(.eafno);
    a.ret(errnoRet(EAFNOSUPPORT_));
    a.label(.kill);
    a.ret(RET_KILL);
}

fn socketpairUnix(a: *As, nxt: L) void {
    a.jmp(JEQ, NR.socketpair, .next, nxt);
    a.ldArg(0);
    a.jmp(JEQ, AF_UNIX_, .allow, .eafno);
}

fn viewer(out: []Ins) []Ins {
    var a: As = .{};
    header(&a);
    a.jmp(JEQ, NR.socket, .next, .sp);
    a.ldArg(0);
    a.jmp(JEQ, AF_UNIX_, .allow, .eafno);
    a.label(.sp);
    socketpairUnix(&a, .t);
    a.label(.t);
    tail(&a, false);
    return a.assemble(out);
}

/// AF_UNIX; AF_INET/INET6 only TCP and UDP (closes MPTCP, SCTP, UDP-Lite, raw sockets);
/// AF_NETLINK only NETLINK_ROUTE (no NETLINK_NETFILTER: nf_tables, the CVE-2024-1086
/// class); socketpair only AF_UNIX; setsockopt without TCP_ULP and BPF on sockets.
fn browser(out: []Ins) []Ins {
    var a: As = .{};
    header(&a);
    a.jmp(JEQ, NR.socket, .next, .sp);
    a.ldArg(0);
    a.jmp(JEQ, AF_UNIX_, .allow, .next);
    a.jmp(JEQ, AF_INET_, .inet, .next);
    a.jmp(JEQ, AF_INET6_, .inet, .next);
    a.jmp(JEQ, AF_NETLINK_, .nl, .eafno);
    a.label(.inet);
    a.ldArg(2);
    a.jmp(JEQ, 0, .allow, .next);
    a.jmp(JEQ, IPPROTO_TCP_, .allow, .next);
    a.jmp(JEQ, IPPROTO_UDP_, .allow, .eafno);
    a.label(.nl);
    a.ldArg(2);
    a.jmp(JEQ, NETLINK_ROUTE_, .allow, .eafno);
    a.label(.sp);
    socketpairUnix(&a, .so);
    a.label(.so);
    a.jmp(JEQ, NR.setsockopt, .next, .t);
    a.ldArg(1);
    a.jmp(JEQ, SOL_TCP_, .next, .sol);
    a.ldArg(2);
    a.jmp(JEQ, TCP_ULP_, .eperm, .allow);
    a.label(.sol);
    a.jmp(JEQ, SOL_SOCKET_, .next, .allow);
    a.ldArg(2);
    a.jmp(JEQ, SO_ATTACH_FILTER_, .eperm, .next);
    a.jmp(JEQ, SO_ATTACH_BPF_, .eperm, .next);
    a.jmp(JEQ, SO_ATTACH_REUSEPORT_CBPF_, .eperm, .next);
    a.jmp(JEQ, SO_ATTACH_REUSEPORT_EBPF_, .eperm, .allow);
    a.label(.t);
    tail(&a, true);
    return a.assemble(out);
}

/// build a filter: kind is "browser" or "viewer"; null when there is no such filter
pub fn build(kind: []const u8, out: []Ins) ?[]Ins {
    if (vh.eql(kind, "browser")) return browser(out);
    if (vh.eql(kind, "viewer")) return viewer(out);
    return null;
}

/// the program as bytes for bwrap --seccomp (8 bytes per instruction, little-endian)
pub fn bytes(prog: []const Ins, out: []u8) []u8 {
    for (prog, 0..) |in, i| {
        const p = out[8 * i ..][0..8];
        std.mem.writeInt(u16, p[0..2], in.code, .little);
        p[2] = in.jt;
        p[3] = in.jf;
        std.mem.writeInt(u32, p[4..8], in.k, .little);
    }
    return out[0 .. 8 * prog.len];
}

/// a classic BPF interpreter for checking the filter (only the instructions in use);
/// the data is struct seccomp_data: nr, arch, ip, args[6]
fn runBpf(prog: []const Ins, nr: u32, args: [6]u64, arch: u32) u32 {
    var data: [64]u8 = @splat(0);
    std.mem.writeInt(u32, data[0..4], nr, .little);
    std.mem.writeInt(u32, data[4..8], arch, .little);
    for (args, 0..) |a, i| std.mem.writeInt(u64, data[16 + 8 * i ..][0..8], a, .little);
    var pc: usize = 0;
    var acc: u32 = 0;
    while (true) {
        if (pc >= prog.len) vh.die("seccomp: ran past the end of the program", .{});
        const in = prog[pc];
        if (in.code == LD) {
            if (in.k > data.len - 4) vh.die("seccomp: read outside seccomp_data", .{});
            acc = std.mem.readInt(u32, data[in.k..][0..4], .little);
            pc += 1;
        } else if (in.code == RET) {
            return in.k;
        } else {
            const cond = if (in.code == JEQ) acc == in.k else if (in.code == JGE) acc >= in.k else (acc & in.k) != 0;
            pc += 1 + @as(usize, if (cond) in.jt else in.jf);
        }
    }
}

const Case = struct { name: []const u8, nr: u32, args: [3]u64, want: u32 };

const A = RET_ALLOW;
const P = 0x00050000 | EPERM_;
const N = 0x00050000 | ENOSYS_;
const F = 0x00050000 | EAFNOSUPPORT_;

const browser_cases = [_]Case{
    .{ .name = "socket(AF_UNIX)", .nr = NR.socket, .args = .{ AF_UNIX_, 1, 0 }, .want = A },
    .{ .name = "socket(AF_INET, TCP)", .nr = NR.socket, .args = .{ AF_INET_, 1, IPPROTO_TCP_ }, .want = A },
    .{ .name = "socket(AF_INET, 0)", .nr = NR.socket, .args = .{ AF_INET_, 2, 0 }, .want = A },
    .{ .name = "socket(AF_INET6, UDP)", .nr = NR.socket, .args = .{ AF_INET6_, 2, IPPROTO_UDP_ }, .want = A },
    .{ .name = "socket(AF_INET, MPTCP)", .nr = NR.socket, .args = .{ AF_INET_, 1, 262 }, .want = F },
    .{ .name = "socket(AF_INET, SCTP)", .nr = NR.socket, .args = .{ AF_INET_, 1, 132 }, .want = F },
    .{ .name = "socket(AF_NETLINK, ROUTE)", .nr = NR.socket, .args = .{ AF_NETLINK_, 3, NETLINK_ROUTE_ }, .want = A },
    .{ .name = "socket(AF_NETLINK, NETFILTER)", .nr = NR.socket, .args = .{ AF_NETLINK_, 3, 12 }, .want = F },
    .{ .name = "socket(AF_PACKET)", .nr = NR.socket, .args = .{ 17, 3, 0 }, .want = F },
    .{ .name = "socket(AF_ALG)", .nr = NR.socket, .args = .{ 38, 5, 0 }, .want = F },
    .{ .name = "socketpair(AF_UNIX)", .nr = NR.socketpair, .args = .{ AF_UNIX_, 1, 0 }, .want = A },
    .{ .name = "socketpair(AF_INET)", .nr = NR.socketpair, .args = .{ AF_INET_, 1, 0 }, .want = F },
    .{ .name = "setsockopt(SOL_TCP, TCP_NODELAY)", .nr = NR.setsockopt, .args = .{ 3, SOL_TCP_, 1 }, .want = A },
    .{ .name = "setsockopt(SOL_TCP, TCP_ULP)", .nr = NR.setsockopt, .args = .{ 3, SOL_TCP_, TCP_ULP_ }, .want = P },
    .{ .name = "setsockopt(SOL_SOCKET, SO_RCVBUF)", .nr = NR.setsockopt, .args = .{ 3, SOL_SOCKET_, 8 }, .want = A },
    .{ .name = "setsockopt(SO_ATTACH_FILTER)", .nr = NR.setsockopt, .args = .{ 3, SOL_SOCKET_, 26 }, .want = P },
    .{ .name = "setsockopt(SO_ATTACH_BPF)", .nr = NR.setsockopt, .args = .{ 3, SOL_SOCKET_, 50 }, .want = P },
    .{ .name = "setsockopt(SO_ATTACH_REUSEPORT_CBPF)", .nr = NR.setsockopt, .args = .{ 3, SOL_SOCKET_, 51 }, .want = P },
    .{ .name = "setsockopt(SO_ATTACH_REUSEPORT_EBPF)", .nr = NR.setsockopt, .args = .{ 3, SOL_SOCKET_, 52 }, .want = P },
    .{ .name = "setsockopt(SO_DETACH_REUSEPORT_BPF 68)", .nr = NR.setsockopt, .args = .{ 3, SOL_SOCKET_, 68 }, .want = A },
    .{ .name = "setsockopt(IPPROTO_IP)", .nr = NR.setsockopt, .args = .{ 3, 0, 1 }, .want = A },
    .{ .name = "clone(plain thread)", .nr = NR.clone, .args = .{ 0x3D0F00, 0, 0 }, .want = A },
    .{ .name = "clone(CLONE_NEWUSER)", .nr = NR.clone, .args = .{ 0x10000000 | 17, 0, 0 }, .want = P },
    .{ .name = "clone3", .nr = NR.clone3, .args = .{ 0, 0, 0 }, .want = N },
    .{ .name = "personality(0)", .nr = NR.personality, .args = .{ 0, 0, 0 }, .want = A },
    .{ .name = "personality(query)", .nr = NR.personality, .args = .{ 0xFFFFFFFF, 0, 0 }, .want = A },
    .{ .name = "personality(READ_IMPLIES_EXEC)", .nr = NR.personality, .args = .{ 0x0400000, 0, 0 }, .want = P },
    .{ .name = "ptrace", .nr = NR.ptrace, .args = .{ 0, 0, 0 }, .want = A },
    .{ .name = "mount", .nr = NR.mount, .args = .{ 0, 0, 0 }, .want = P },
    .{ .name = "unshare", .nr = NR.unshare, .args = .{ 0, 0, 0 }, .want = P },
    .{ .name = "keyctl", .nr = NR.keyctl, .args = .{ 0, 0, 0 }, .want = P },
    .{ .name = "bpf", .nr = NR.bpf, .args = .{ 0, 0, 0 }, .want = P },
    .{ .name = "io_uring_setup", .nr = NR.io_uring_setup, .args = .{ 0, 0, 0 }, .want = P },
    .{ .name = "perf_event_open", .nr = NR.perf_event_open, .args = .{ 0, 0, 0 }, .want = P },
    .{ .name = "read", .nr = NR.read, .args = .{ 0, 0, 0 }, .want = A },
    .{ .name = "mmap", .nr = NR.mmap, .args = .{ 0, 0, 0 }, .want = A },
};

/// what one architecture alone has: the x32 bit on x86_64
const arch_cases: []const Case = if (has_x32) &.{
    .{ .name = "x32 read", .nr = X32_BIT | NR.read, .args = .{ 0, 0, 0 }, .want = N },
} else &.{};

const viewer_cases = [_]Case{
    .{ .name = "socket(AF_UNIX)", .nr = NR.socket, .args = .{ AF_UNIX_, 1, 0 }, .want = A },
    .{ .name = "socket(AF_INET)", .nr = NR.socket, .args = .{ AF_INET_, 1, 6 }, .want = F },
    .{ .name = "socketpair(AF_UNIX)", .nr = NR.socketpair, .args = .{ AF_UNIX_, 1, 0 }, .want = A },
    .{ .name = "clone(CLONE_NEWNET)", .nr = NR.clone, .args = .{ 0x40000000 | 17, 0, 0 }, .want = P },
    .{ .name = "clone3", .nr = NR.clone3, .args = .{ 0, 0, 0 }, .want = N },
    .{ .name = "ptrace", .nr = NR.ptrace, .args = .{ 0, 0, 0 }, .want = P },
    .{ .name = "setns", .nr = NR.setns, .args = .{ 0, 0, 0 }, .want = P },
    .{ .name = "personality(ADDR_NO_RANDOMIZE)", .nr = NR.personality, .args = .{ 0x0040000, 0, 0 }, .want = P },
    .{ .name = "write", .nr = NR.write, .args = .{ 0, 0, 0 }, .want = A },
};

/// printf's %#x: 0 -> "0", otherwise "0x..."
fn hexAlt(v: u32) []const u8 {
    return if (v == 0) "0" else vh.fmt("0x{x}", .{v});
}

/// check both filters with the built-in interpreter; returns the number of failures
pub fn selftest() usize {
    const Set = struct { kind: []const u8, cases: []const Case, arch: []const Case };
    const sets = [_]Set{
        .{ .kind = "browser", .cases = &browser_cases, .arch = arch_cases },
        .{ .kind = "viewer", .cases = &viewer_cases, .arch = &.{} },
    };
    var bad: usize = 0;
    for (sets) |s| {
        var buf: [max_ins]Ins = undefined;
        const prog = build(s.kind, &buf).?;
        var checks: usize = 0;
        for (audit_arches) |arch| {
            if (arch == AUDIT_ARCH) continue;
            checks += 1;
            if (runBpf(prog, NR.read, @splat(0), arch) != RET_KILL) {
                vh.out("FAIL {s}: a foreign architecture (0x{x}) is not killed\n", .{ s.kind, arch });
                bad += 1;
            }
        }
        for ([_][]const Case{ s.cases, s.arch }) |cases| for (cases) |c| {
            checks += 1;
            const got = runBpf(prog, c.nr, .{ c.args[0], c.args[1], c.args[2], 0, 0, 0 }, AUDIT_ARCH);
            if (got != c.want) {
                vh.out("FAIL {s}: {s}: {s}, expected {s}\n", .{ s.kind, c.name, hexAlt(got), hexAlt(c.want) });
                bad += 1;
            }
        };
        vh.out("{s}: {d} instructions, {d} checks\n", .{ s.kind, prog.len, checks });
    }
    if (bad > 0) vh.out("selftest: {d} failures\n", .{bad}) else vh.outs("selftest: OK\n");
    vh.flush();
    return bad;
}

test "filter selftest" {
    try std.testing.expectEqual(@as(usize, 0), selftest());
}
