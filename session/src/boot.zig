//! The gaming boot (docs/uni/game.md, G3): the stock UKI's twin with ia32_emulation=1 and an
//! entry of its own in Limine, both made by vh-limine-update while the marker below exists, and
//! what that boot does: the controllers' drivers before the module lock, the login of game on
//! tty3, and every other process tree under a seccomp filter that lets the x86_64 ABI through
//! and kills a process at its first 32-bit system call. ia32 is then within the gaming
//! session's reach alone; the everyday boot keeps ia32_emulation=0 and changes in nothing.
//!
//!   stage 1 (98-vh-game.sh, or vh-stage1's step vh-game): vh-game stage1. In the gaming boot
//!     only: the controllers' drivers, then the marker bound over /etc/runit/2.
//!   stage 2: runit runs /etc/runit/2, that is the marker, "#!/usr/local/sbin/vh-game stage2":
//!     the bind mount goes, the getty of tty3 starts outside the filter, the filter is set on
//!     this process, and runit-void's own /etc/runit/2 runs under it: runsvdir and every
//!     service, getty, login and desktop of the boot.
const std = @import("std");
const builtin = @import("builtin");
const vh = @import("vh");
const common = @import("common.zig");
const sys = @import("sys.zig");
const linux = std.os.linux;
const mem = std.mem;
const G = common.game;

/// the marker of the gaming boot (vh-game boot on writes it, boot off removes it) and the
/// program runit runs as stage 2 in that boot
pub const marker = "/etc/vh/game-boot";
pub const marker_text =
    \\#!/usr/local/sbin/vh-game stage2
    \\# vh-game boot on (docs/uni/game.md, G3): the gaming boot is on. vh-limine-update gives the
    \\# newest stock UKI a twin with ia32_emulation=1, the last entry of Limine's menu. In that
    \\# boot stage 1 binds this file over /etc/runit/2, and runit runs it as stage 2: vh-game
    \\# stage2 starts the login of game on tty3, puts every other process of the boot under a
    \\# filter that kills a 32-bit system call, and runs runit-void's own /etc/runit/2.
    \\# vh-game boot off removes this file and the entry.
    \\
;
pub const stage2_path = "/etc/runit/2";
/// stage 1's step of runit-void (vh-stage1 runs the same program by argv)
pub const core_script = "/etc/runit/core-services/98-vh-game.sh";
pub const core_script_text =
    \\# vh-game boot on (docs/uni/game.md, G3): the gaming boot. In it vh-game stage1 loads the
    \\# controllers' drivers before the module lock (99-zz-vh-modlock.sh) and binds
    \\# /etc/vh/game-boot over /etc/runit/2, so that stage 2 starts the login of game on tty3
    \\# and puts every other process of the boot under the x86_64 filter. In every other boot
    \\# it does nothing. vh-game boot off removes this file.
    \\case " $(cat /proc/cmdline) " in
    \\*" ia32_emulation=1 "*) [ -x /usr/local/sbin/vh-game ] && /usr/local/sbin/vh-game stage1 ;;
    \\esac
    \\
;
pub const program = "/usr/local/sbin/vh-game";

/// The drivers of game controllers, loaded in the gaming boot before the module lock: a pad
/// plugged in later finds its driver loaded (modules_disabled=1 loads nothing after stage 1).
/// The stock kernel has them as modules (Void's config); the everyday boot loads none of them
/// unless such a pad is there at boot.
pub const controllers = [_][]const u8{
    "xpad",         "joydev",     "hid-playstation", "hid-sony",        "hid-nintendo", "hid-steam",
    "hid-microsoft", "hid-logitech", "hid-logitech-dj", "hid-logitech-hidpp", "usbhid", "hid-generic",
};

/// Whether a kernel command line turns ia32 on: every ia32_emulation= in turn, as the kernel
/// reads them (the last one decides), each value read as kstrtobool reads it; a value it
/// cannot read changes nothing.
pub fn ia32On(cmdline: []const u8) bool {
    var on = false;
    var it = mem.tokenizeAny(u8, cmdline, " \t\n\x00");
    while (it.next()) |w| {
        const key = "ia32_emulation=";
        if (!vh.startsWith(w, key)) continue;
        const v = w[key.len..];
        if (v.len == 0) continue;
        switch (v[0]) {
            'y', 'Y', 't', 'T', '1' => on = true,
            'n', 'N', 'f', 'F', '0' => on = false,
            'o', 'O' => if (v.len > 1) switch (v[1]) {
                'n', 'N' => on = true,
                'f', 'F' => on = false,
                else => {},
            },
            else => {},
        }
    }
    return on;
}

/// this boot is the gaming one: the gaming boot is on and the command line turns ia32 on
pub fn gamingBoot(S: common.System) bool {
    return vh.pathExists(S.path(marker)) and ia32On(vh.readFile(S.path("/proc/cmdline")) catch "");
}

/// whether this process is under a seccomp filter (/proc/self/status: "Seccomp: 2")
pub fn filtered() bool {
    const st = vh.readFile("/proc/self/status") catch return false;
    var it = mem.splitScalar(u8, st, '\n');
    while (it.next()) |l| if (vh.startsWith(l, "Seccomp:")) return !vh.eql(vh.strip(l["Seccomp:".len..]), "0");
    return false;
}

// ---------------------------------------------------------------- the filter

/// struct sock_filter and struct sock_fprog
pub const Ins = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
const Fprog = extern struct { len: u16, filter: [*]const Ins };

const LD: u16 = 0x20; // BPF_LD | BPF_W | BPF_ABS
const JEQ: u16 = 0x15; // BPF_JMP | BPF_JEQ | BPF_K
const JGE: u16 = 0x35; // BPF_JMP | BPF_JGE | BPF_K
const RET: u16 = 0x06; // BPF_RET | BPF_K
const AUDIT_ARCH_X86_64: u32 = 0xC000003E;
const AUDIT_ARCH_I386: u32 = 0x40000003;
const X32_SYSCALL_BIT: u32 = 0x40000000;
const RET_ALLOW: u32 = 0x7FFF0000;
const RET_KILL_PROCESS: u32 = 0x80000000;
const RET_ENOSYS: u32 = 0x00050000 | 38;

/// The x86_64 ABI and nothing else: a 32-bit system call (int $0x80, sysenter, the call of a
/// 32-bit program) kills the process before the kernel's ia32 code runs; the x32 ABI gets
/// ENOSYS, as in the sandboxes' filters (zig/lib/seccomp.zig). seccomp_data: nr at 0, arch at 4.
/// The verdict of an x86_64 call depends on its number alone, so the kernel's seccomp cache
/// answers it without running the program.
pub const filter = [_]Ins{
    .{ .code = LD, .jt = 0, .jf = 0, .k = 4 },
    .{ .code = JEQ, .jt = 1, .jf = 0, .k = AUDIT_ARCH_X86_64 },
    .{ .code = RET, .jt = 0, .jf = 0, .k = RET_KILL_PROCESS },
    .{ .code = LD, .jt = 0, .jf = 0, .k = 0 },
    .{ .code = JGE, .jt = 0, .jf = 1, .k = X32_SYSCALL_BIT },
    .{ .code = RET, .jt = 0, .jf = 0, .k = RET_ENOSYS },
    .{ .code = RET, .jt = 0, .jf = 0, .k = RET_ALLOW },
};

/// The filter on this process and everything it starts, for good. Without no_new_privs: root
/// sets it with CAP_SYS_ADMIN, and SUID programs (doas) keep working under it.
pub fn setFilter() vh.Error!void {
    if (builtin.cpu.arch != .x86_64) {
        vh.errno = .NOSYS;
        return error.Sys;
    }
    const prog: Fprog = .{ .len = filter.len, .filter = &filter };
    _ = try vh.sys(linux.seccomp(linux.SECCOMP.SET_MODE_FILTER, 0, &prog));
}

// ---------------------------------------------------------------- tty3

/// our runsv of the getty: its command line is exactly "runsv /etc/sv/agetty-tty3"
pub fn gettyRunsv() ?linux.pid_t {
    const want = "runsv\x00" ++ G.getty ++ "\x00";
    const names = vh.listDir("/proc") catch return null;
    for (names) |n| {
        const pid = std.fmt.parseInt(linux.pid_t, n, 10) catch continue;
        if (vh.eql(sys.cmdline(pid), want)) return pid;
    }
    return null;
}

/// runsv of the getty of tty3, in a session of its own, its output to /dev/null; runsv keeps
/// its state in /run/runit/supervise.agetty-tty3, beside the boot's services
pub fn spawnGetty() vh.Error!void {
    try sys.mkdir("/run/runit", 0o755);
    const pid = try vh.sys(linux.fork());
    if (pid == 0) {
        _ = linux.setsid();
        const null_fd = vh.openFd("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch linux.exit_group(127);
        for ([_]i32{ 0, 1, 2 }) |fd| _ = linux.dup2(null_fd, fd);
        _ = linux.chdir("/");
        const argv = [_:null]?[*:0]const u8{ "runsv", G.getty };
        const envp = [_:null]?[*:0]const u8{"PATH=/usr/bin:/usr/sbin:/bin:/sbin"};
        _ = linux.execve("/usr/bin/runsv", &argv, &envp);
        linux.exit_group(127);
    }
}

// ---------------------------------------------------------------- the stages

/// vh-game stage1: stage 1 runs it while the gaming boot is on; in any boot but the gaming one
/// it does nothing
pub fn stage1() u8 {
    if (!gamingBoot(.{})) return 0;
    vh.log("the gaming boot: the controllers' drivers, the login of {s} on {s}, the x86_64 filter for every other process", .{ G.user, G.tty });
    var argv: std.ArrayList([]const u8) = .empty;
    // -q: a driver this kernel has built in, or lacks, is no error
    argv.appendSlice(vh.gpa, &.{ "/usr/bin/modprobe", "-q", "-a" }) catch vh.oom();
    argv.appendSlice(vh.gpa, &controllers) catch vh.oom();
    if (vh.run(argv.items) != 0) vh.warn("not every controller driver loaded", .{});
    sys.mount(marker, stage2_path, null, sys.MS.BIND, null) catch {
        vh.warn("{s} over {s}: {s}: this boot runs without the x86_64 filter and without the login on {s}", .{ marker, stage2_path, vh.serr(), G.tty });
        return 1;
    };
    return 0;
}

/// vh-game stage2: runit's stage 2 of the gaming boot. Whatever fails before it, runit-void's
/// own stage 2 runs at the end: a boot without its services would be worse than one without
/// the filter, and vh-audit names a boot without it.
pub fn stage2() noreturn {
    // only as runit's stage 2 through the bind mount of stage 1, never by hand
    if (linux.getppid() != 1 or !isMountPoint(stage2_path)) vh.die("vh-game stage2 is the stage 2 of the gaming boot, which runit runs", .{});
    sys.umount(stage2_path, linux.MNT.DETACH) catch vh.warn("umount {s}: {s}", .{ stage2_path, vh.serr() });
    if (gettyRunsv() == null) spawnGetty() catch vh.warn("the getty of {s}: {s}", .{ G.tty, vh.serr() });
    setFilter() catch vh.warn("the x86_64 filter: {s}: every process of this boot may make 32-bit system calls", .{vh.serr()});
    vh.flush();
    const argv = [_:null]?[*:0]const u8{stage2_path};
    const rc = linux.execve(stage2_path, &argv, vh.envp);
    vh.die("{s}: {s}", .{ stage2_path, vh.strerror(linux.errno(rc)) });
}

/// PATH is the mount point of a mount of /proc/self/mountinfo: a file bound over a file is one,
/// though its device and inode look like its directory's
fn isMountPoint(path: []const u8) bool {
    const mi = vh.readFile("/proc/self/mountinfo") catch return false;
    var it = mem.splitScalar(u8, mi, '\n');
    while (it.next()) |l| {
        var f = mem.tokenizeScalar(u8, l, ' ');
        var k: usize = 0;
        while (f.next()) |w| : (k += 1) if (k == 4) {
            if (vh.eql(w, path)) return true;
            break;
        };
    }
    return false;
}

// ---------------------------------------------------------------- tests

const t = std.testing;

/// the filter run as the kernel runs it, on one system call
fn verdict(nr: u32, arch: u32) u32 {
    var a: u32 = 0;
    var pc: usize = 0;
    while (pc < filter.len) {
        const i = filter[pc];
        switch (i.code) {
            LD => {
                a = if (i.k == 0) nr else arch;
                pc += 1;
            },
            JEQ => pc += 1 + @as(usize, if (a == i.k) i.jt else i.jf),
            JGE => pc += 1 + @as(usize, if (a >= i.k) i.jt else i.jf),
            RET => return i.k,
            else => unreachable,
        }
    }
    unreachable;
}

test "the gaming boot: ia32 on the command line, as the kernel reads it" {
    try t.expect(ia32On("root=UUID=x ia32_emulation=1 ro\x00"));
    try t.expect(!ia32On("root=UUID=x ia32_emulation=0 ro"));
    try t.expect(!ia32On("root=UUID=x ro"));
    // the last one decides; a value kstrtobool cannot read changes nothing
    try t.expect(!ia32On("ia32_emulation=1 ia32_emulation=0"));
    try t.expect(ia32On("ia32_emulation=0 ia32_emulation=on"));
    try t.expect(ia32On("ia32_emulation=y ia32_emulation=x"));
    try t.expect(!ia32On("ia32_emulation=1 ia32_emulation=off"));
    try t.expect(!ia32On("xia32_emulation=1 ia32_emulation= "));
    // the stage-1 script's quick test agrees with the twin's command line
    try t.expect(mem.indexOf(u8, core_script_text, "*\" ia32_emulation=1 \"*") != null);
    try t.expect(vh.startsWith(marker_text, "#!" ++ program ++ " stage2\n"));
}

test "the x86_64 filter: x86_64 through, a 32-bit call kills, x32 gets ENOSYS" {
    for ([_]u32{ 0, 1, 39, 59, 231, 435, 462 }) |nr| try t.expectEqual(RET_ALLOW, verdict(nr, AUDIT_ARCH_X86_64));
    for ([_]u32{ 0, 1, 20, 11, 252, 435 }) |nr| try t.expectEqual(RET_KILL_PROCESS, verdict(nr, AUDIT_ARCH_I386));
    try t.expectEqual(RET_KILL_PROCESS, verdict(0, 0));
    try t.expectEqual(RET_ENOSYS, verdict(X32_SYSCALL_BIT | 39, AUDIT_ARCH_X86_64));
    // every verdict of the x86_64 ABI rests on the number alone (no argument is loaded): the
    // kernel's seccomp cache takes the program's place for these
    for (filter) |i| if (i.code == LD) try t.expect(i.k == 0 or i.k == 4);
}

/// i386 getpid (20) through int $0x80 in a child, with or without the filter; the wait status
fn child32(with_filter: bool) u32 {
    const pid = linux.fork();
    if (pid == 0) {
        if (with_filter) {
            // no CAP_SYS_ADMIN in a test: no_new_privs lets anyone set a filter
            _ = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
            setFilter() catch linux.exit_group(3);
            // the x86_64 ABI goes through
            if (linux.getpid() <= 0) linux.exit_group(4);
        }
        const r = asm volatile ("int $0x80"
            : [ret] "={eax}" (-> u32),
            : [nr] "{eax}" (@as(u32, 20)),
            : .{ .memory = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true });
        linux.exit_group(if (r > 0 and r < 0x80000000) 0 else 5);
    }
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    return @bitCast(status);
}

test "the x86_64 filter on a real process: a 32-bit system call kills it" {
    // int $0x80 exists on x86_64 alone: the branch is not even compiled elsewhere
    if (builtin.cpu.arch == .x86_64) {
        // a kernel without ia32 (ia32_emulation=0) answers int $0x80 itself: nothing to test there
        const plain = child32(false);
        if (!linux.W.IFEXITED(plain) or linux.W.EXITSTATUS(plain) != 0) return error.SkipZigTest;
        const st = child32(true);
        try t.expect(linux.W.IFSIGNALED(st));
        try t.expectEqual(linux.SIG.SYS, linux.W.TERMSIG(st));
    } else return error.SkipZigTest;
}
