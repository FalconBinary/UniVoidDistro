//! vh-stage1: the small steps of runit-void natively: static device nodes and
//! modules-load.d (one modprobe each), console setup (03-console-setup.sh), 05-misc.sh
//! (utmp, the wtmp boot record of `halt -B`, seedrng, lo, hostname, time zone), the runit
//! control files, the dmesg log, the sbin merge and 99-cleanup.sh.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");
const seed = @import("seed.zig");
const tz = @import("tz.zig");
const sysctl = @import("sysctl.zig");

// ---------------------------------------------------------------- 01-static-devnodes.sh

/// the modules of modules.devname (kmod static-nodes), loaded with one modprobe -abq
pub fn staticDevnodes() void {
    if (!vh.pathExists(sys.p("/proc/modules"))) return;
    const rel = sys.release();
    const text = vh.readFile(sys.p(vh.fmt("/usr/lib/modules/{s}/modules.devname", .{rel}))) catch
        vh.readFile(sys.p(vh.fmt("/lib/modules/{s}/modules.devname", .{rel}))) catch return;
    const mods = devnameModules(text);
    if (mods.len == 0) return;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(vh.gpa, &.{ "modprobe", "-abq" }) catch vh.oom();
    argv.appendSlice(vh.gpa, mods) catch vh.oom();
    _ = sys.exec(argv.items); // -q: missing or denied modules are quiet, as in runit-void
}

/// "module devname major:minor" lines; the module names
pub fn devnameModules(text: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        if (line.len == 0 or line[0] == '#') continue;
        var it = mem.tokenizeAny(u8, line, " \t");
        if (it.next()) |m| list.append(vh.gpa, m) catch vh.oom();
    }
    return list.items;
}

// ---------------------------------------------------------------- 02-kmods.sh

pub const modules_load_dirs = [_][]const u8{ "/etc/modules-load.d", "/run/modules-load.d", "/usr/lib/modules-load.d" };

/// modules-load(8) of runit-void: modules-load= and rd.modules-load= from the kernel
/// command line, then the *.conf files (a base name once, /etc first, sorted), one modprobe -ab
pub fn kmods() void {
    if (!vh.pathExists(sys.p("/proc/modules"))) return;
    sys.msg("Loading kernel modules...", .{});
    var mods: std.ArrayList([]const u8) = .empty;
    mods.appendSlice(vh.gpa, cmdlineModules(vh.rd("/proc/cmdline"))) catch vh.oom();
    var listings: [modules_load_dirs.len][]const []const u8 = undefined;
    for (modules_load_dirs, 0..) |d, i| listings[i] = sys.sortedDir(sys.p(d));
    for (sysctl.mergeByName(&modules_load_dirs, &listings, ".conf")) |f| {
        const text = vh.readFile(sys.p(f.path)) catch continue;
        mods.appendSlice(vh.gpa, sys.words(text)) catch vh.oom();
    }
    if (mods.items.len == 0) {
        sys.detail("no modules to load", .{});
        return;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(vh.gpa, &.{ "modprobe", "-ab" }) catch vh.oom();
    argv.appendSlice(vh.gpa, mods.items) catch vh.oom();
    if (sys.exec(argv.items) != 0) sys.note("modprobe: not every module of modules-load.d loaded", .{});
}

/// modules-load=a,b and rd.modules-load=c on the command line
pub fn cmdlineModules(cmdline: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = mem.tokenizeAny(u8, cmdline, " \t\n");
    while (it.next()) |w| {
        const v = if (vh.startsWith(w, "modules-load=")) w[13..] else if (vh.startsWith(w, "rd.modules-load=")) w[16..] else continue;
        var parts = mem.tokenizeScalar(u8, v, ',');
        while (parts.next()) |m| list.append(vh.gpa, m) catch vh.oom();
    }
    return list.items;
}

// ---------------------------------------------------------------- 03-console-setup.sh

pub const Console = struct {
    font: []const u8 = "",
    font_map: []const u8 = "",
    font_unimap: []const u8 = "",
    ttys: i64 = 12,
    keymap: []const u8 = "",
    hardwareclock: []const u8 = "",
};

/// the console font on every tty (only with FONT set), the keymap only when it is not
/// the kernel's own US one, the kernel time zone for the RTC mode (hwclock --systz)
pub fn console(c: Console) void {
    if (c.font.len > 0) {
        sys.msg("Setting up TTYs font to '{s}'...", .{c.font});
        var i: i64 = 0;
        while (i <= c.ttys) : (i += 1) {
            var argv: std.ArrayList([]const u8) = .empty;
            argv.append(vh.gpa, "setfont") catch vh.oom();
            if (c.font_map.len > 0) argv.appendSlice(vh.gpa, &.{ "-m", c.font_map }) catch vh.oom();
            if (c.font_unimap.len > 0) argv.appendSlice(vh.gpa, &.{ "-u", c.font_unimap }) catch vh.oom();
            argv.appendSlice(vh.gpa, &.{ c.font, "-C", vh.fmt("/dev/tty{d}", .{i}) }) catch vh.oom();
            _ = sys.exec(argv.items);
        }
    }
    if (needsLoadkeys(c.keymap)) {
        sys.msg("Setting up keymap to '{s}'...", .{c.keymap});
        if (sys.exec(&.{ "loadkeys", "-q", "-u", c.keymap }) != 0) sys.fail("loadkeys {s} failed", .{c.keymap});
    } else if (c.keymap.len > 0) sys.detail("keymap {s}: the kernel's built-in map, loadkeys not needed", .{c.keymap});
    if (c.hardwareclock.len > 0) {
        sys.msg("Setting up RTC to '{s}'...", .{c.hardwareclock});
        if (!setKernelTz(c.hardwareclock)) sys.emergency();
    }
}

/// us is the keymap compiled into the kernel: nothing to load
pub fn needsLoadkeys(keymap: []const u8) bool {
    return keymap.len > 0 and !vh.eql(keymap, "us");
}

/// what `hwclock --systz --utc|--localtime --noadjfile` does to the kernel: the time zone
/// (minutes west of UTC of the local zone from /etc/localtime, for file systems that
/// store local time) and, for a UTC RTC, a first call with zero so the kernel never
/// warps the clock. The RTC itself is not touched.
fn setKernelTz(mode: []const u8) bool {
    var utc = false;
    if (std.ascii.eqlIgnoreCase(mode, "utc")) {
        utc = true;
    } else if (!std.ascii.eqlIgnoreCase(mode, "localtime")) {
        sys.fail("HARDWARECLOCK={s}: utc or localtime", .{mode});
        return false;
    }
    const offset = tz.localOffsetMinutes(sys.p("/etc/localtime"), vh.now());
    if (offset == null) sys.note("hwclock: /etc/localtime not readable: the kernel time zone stays UTC", .{});
    if (!utc and offset == null) {
        // a local-time RTC needs the warp with the real offset: the stock tool does it
        return sys.exec(&.{ "hwclock", "--systz", "--localtime", "--noadjfile" }) == 0;
    }
    if (utc) {
        if (!settz(0)) return false;
    }
    if (offset) |o| return settz(-o);
    return true;
}

fn settz(minuteswest: i32) bool {
    if (sys.root.len > 0) {
        sys.detail("settimeofday(tz_minuteswest={d}) skipped under --root", .{minuteswest});
        return true;
    }
    const tzv = linux.timezone{ .minuteswest = minuteswest, .dsttime = 0 };
    _ = vh.sys(linux.syscall2(.settimeofday, 0, @intFromPtr(&tzv))) catch {
        sys.fail("settimeofday: {s}", .{vh.serr()});
        return false;
    };
    sys.detail("kernel time zone: {d} minutes west of UTC", .{minuteswest});
    return true;
}

// ---------------------------------------------------------------- 05-misc.sh

/// struct utmp of glibc: on x86_64 the fields keep the 32-bit layout (384 bytes); on
/// aarch64 (the test container) session and tv are 64-bit (400 bytes)
pub const Utmp = switch (builtin.cpu.arch) {
    .x86_64 => extern struct {
        type: i16,
        _pad: i16 = 0,
        pid: i32 = 0,
        line: [32]u8 = @splat(0),
        id: [4]u8 = @splat(0),
        user: [32]u8 = @splat(0),
        host: [256]u8 = @splat(0),
        exit_termination: i16 = 0,
        exit_code: i16 = 0,
        session: i32 = 0,
        tv_sec: i32 = 0,
        tv_usec: i32 = 0,
        addr_v6: [4]i32 = @splat(0),
        reserved: [20]u8 = @splat(0),
    },
    else => extern struct {
        type: i16,
        _pad: i16 = 0,
        pid: i32 = 0,
        line: [32]u8 = @splat(0),
        id: [4]u8 = @splat(0),
        user: [32]u8 = @splat(0),
        host: [256]u8 = @splat(0),
        exit_termination: i16 = 0,
        exit_code: i16 = 0,
        session: i64 = 0,
        tv_sec: i64 = 0,
        tv_usec: i64 = 0,
        addr_v6: [4]i32 = @splat(0),
        reserved: [20]u8 = @splat(0),
    },
};
comptime {
    if (builtin.cpu.arch == .x86_64) std.debug.assert(@sizeOf(Utmp) == 384);
    if (builtin.cpu.arch == .aarch64) std.debug.assert(@sizeOf(Utmp) == 400);
}
pub const BOOT_TIME: i16 = 2;

/// the record `halt -B` writes: BOOT_TIME, user reboot, line ~, id ~~, host = the kernel release
pub fn bootRecord(now_sec: i64, now_usec: i64, release: []const u8) Utmp {
    var u: Utmp = .{ .type = BOOT_TIME };
    @memcpy(u.user[0..6], "reboot");
    u.line[0] = '~';
    u.id[0] = '~';
    u.id[1] = '~';
    const n = @min(release.len, u.host.len);
    @memcpy(u.host[0..n], release[0..n]);
    u.tv_sec = @intCast(now_sec);
    u.tv_usec = @intCast(now_usec);
    return u;
}

/// /run/utmp, the boot record in wtmp and utmp, seedrng, lo, the host name, the time zone
pub fn misc(container: bool, skip_credit: bool, rc_hostname: []const u8, timezone: []const u8) void {
    const utmp_gid = sys.groupId("utmp");
    if (!sys.touch(sys.p("/run/utmp"), 0o664, 0, utmp_gid)) sys.fail("/run/utmp: {s}", .{vh.serr()});
    wtmpBoot(utmp_gid);
    if (!container) {
        sys.msg("Seeding random number generator...", .{});
        seed.load(skip_credit);
    }
    sys.msg("Setting up loopback interface...", .{});
    loUp();
    hostname(rc_hostname);
    if (timezone.len > 0) {
        sys.msg("Setting up timezone to '{s}'...", .{timezone});
        const link = sys.p("/etc/localtime");
        _ = linux.unlink(vh.z(link).ptr);
        _ = vh.sys(linux.symlink(vh.z(vh.fmt("/usr/share/zoneinfo/{s}", .{timezone})).ptr, vh.z(link).ptr)) catch
            sys.fail("/etc/localtime: {s}", .{vh.serr()});
    }
}

/// halt -B: a BOOT_TIME record appended to /var/log/wtmp (created if missing) and /run/utmp
fn wtmpBoot(utmp_gid: ?u32) void {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const rec = bootRecord(ts.sec, @divTrunc(ts.nsec, 1000), sys.release());
    const wtmp = sys.p("/var/log/wtmp");
    if (!vh.pathExists(wtmp)) _ = sys.touch(wtmp, 0o664, 0, utmp_gid);
    for ([_][]const u8{ wtmp, sys.p("/run/utmp") }) |path| {
        const fd = vh.openFd(path, .{ .ACCMODE = .WRONLY, .APPEND = true }, 0) catch continue;
        defer vh.close(fd);
        vh.writeAllFd(fd, mem.asBytes(&rec)) catch sys.fail("{s}: {s}", .{ path, vh.serr() });
    }
}

/// ip link set up dev lo
fn loUp() void {
    const fd_rc = vh.sys(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)) catch {
        sys.fail("socket: {s}", .{vh.serr()});
        return;
    };
    const fd: linux.fd_t = @intCast(fd_rc);
    defer vh.close(fd);
    var req = mem.zeroes(linux.ifreq);
    @memcpy(req.ifrn.name[0..2], "lo");
    _ = vh.sys(linux.ioctl(fd, linux.SIOCGIFFLAGS, @intFromPtr(&req))) catch {
        sys.fail("lo: SIOCGIFFLAGS: {s}", .{vh.serr()});
        return;
    };
    if (req.ifru.flags.UP) {
        sys.detail("lo is already up", .{});
        return;
    }
    req.ifru.flags.UP = true;
    _ = vh.sys(linux.ioctl(fd, linux.SIOCSIFFLAGS, @intFromPtr(&req))) catch sys.fail("lo: SIOCSIFFLAGS: {s}", .{vh.serr()});
}

/// /etc/hostname, else HOSTNAME of rc.conf; sethostname(2) (under --root: the fake /proc file)
fn hostname(rc_hostname: []const u8) void {
    var name = rc_hostname;
    if (vh.readFile(sys.p("/etc/hostname"))) |text| {
        name = vh.strip(mem.sliceTo(text, '\n'));
    } else |_| {}
    if (name.len == 0) {
        sys.warn("Didn't setup a hostname!", .{});
        return;
    }
    sys.msg("Setting up hostname to '{s}'...", .{name});
    if (sys.root.len > 0) {
        if (!sys.writeFile(sys.p("/proc/sys/kernel/hostname"), name, 0o644)) sys.fail("hostname: {s}", .{vh.serr()});
        return;
    }
    _ = vh.sys(linux.syscall2(.sethostname, @intFromPtr(name.ptr), name.len)) catch sys.fail("sethostname: {s}", .{vh.serr()});
}

// ---------------------------------------------------------------- 10-runit-control.sh

pub fn runitControl() void {
    vh.mkdirs(sys.p("/run/runit"), 0o755);
    for ([_][]const u8{ "/run/runit/stopit", "/run/runit/reboot" }) |f|
        if (!sys.touch(sys.p(f), 0, null, null)) sys.fail("{s}: {s}", .{ f, vh.serr() });
}

// ---------------------------------------------------------------- 97-dmesg.sh

/// the kernel log into /var/log/dmesg.log (0600 when dmesg_restrict is on), through syslog(2):
/// every record the ring holds, as the dmesg of 97-dmesg.sh saves them
pub fn dmesgLog() void {
    const log = sys.kernelLog() orelse {
        sys.fail("dmesg: syslog: {s}", .{vh.serr()});
        return;
    };
    const text = stripLevels(log);
    const mode: linux.mode_t = if (vh.eql(vh.rd(sys.p("/proc/sys/kernel/dmesg_restrict")), "1")) 0o600 else 0o644;
    if (!sys.writeFile(sys.p("/var/log/dmesg.log"), text, mode)) sys.fail("/var/log/dmesg.log: {s}", .{vh.serr()});
}

/// "<6>[    0.000000] text" -> "[    0.000000] text", as dmesg prints it
pub fn stripLevels(text: []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) out.append(vh.gpa, '\n') catch vh.oom();
        first = false;
        var l = line;
        if (l.len > 0 and l[0] == '<') {
            if (mem.indexOfScalar(u8, l[0..@min(l.len, 5)], '>')) |e| l = l[e + 1 ..];
        }
        out.appendSlice(vh.gpa, l) catch vh.oom();
    }
    return out.items;
}

// ---------------------------------------------------------------- 98-sbin-merge.sh

/// /usr/sbin -> bin when /usr/sbin is still a directory of symlinks (old installs)
pub fn sbinMerge() void {
    const sbin = sys.p("/usr/sbin");
    const st = vh.stat(sbin, false) catch return;
    if (!vh.S.isDir(st.mode)) return;
    const names = vh.listDir(sbin) catch return;
    for (names) |n| {
        const e = vh.stat(vh.fmt("{s}/{s}", .{ sbin, n }), false) catch continue;
        if (vh.S.isReg(e.mode)) {
            sys.msg("Detected {s}/{s} file, can't create /usr/sbin symlink.", .{ sbin, n });
            return;
        }
    }
    sys.msg("Creating /usr/sbin -> /usr/bin symlink, moving existing to /usr/sbin.old", .{});
    _ = vh.sys(linux.rename(vh.z(sbin).ptr, vh.z(vh.fmt("{s}.old", .{sbin})).ptr)) catch {
        sys.fail("/usr/sbin: {s}", .{vh.serr()});
        return;
    };
    _ = vh.sys(linux.symlink("bin", vh.z(sbin).ptr)) catch sys.fail("/usr/sbin symlink: {s}", .{vh.serr()});
}

// ---------------------------------------------------------------- 99-cleanup.sh

pub fn cleanup() void {
    const utmp_gid = sys.groupId("utmp");
    const logs = [_]struct { path: []const u8, mode: linux.mode_t }{
        .{ .path = "/var/log/wtmp", .mode = 0o664 },
        .{ .path = "/var/log/btmp", .mode = 0o600 },
        .{ .path = "/var/log/lastlog", .mode = 0o600 },
    };
    for (logs) |l| {
        const path = sys.p(l.path);
        if (!vh.pathExists(path) and !sys.touch(path, l.mode, 0, utmp_gid)) sys.fail("{s}: {s}", .{ l.path, vh.serr() });
    }
    for ([_][]const u8{ "/tmp/.X11-unix", "/tmp/.ICE-unix" }) |d|
        if (!sys.mkdirMode(sys.p(d), 0o1777)) sys.fail("{s}: {s}", .{ d, vh.serr() });
    for ([_][]const u8{ "/etc/nologin", "/forcefsck", "/forcequotacheck", "/fastboot" }) |f|
        _ = linux.unlink(vh.z(sys.p(f)).ptr);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "modules.devname: module names" {
    const m = devnameModules("# Device nodes to trigger on-demand module loading.\ncuse cuse c10:203\nfuse fuse c10:229\n");
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expectEqualStrings("cuse", m[0]);
    try testing.expectEqualStrings("fuse", m[1]);
}

test "modules-load= on the command line" {
    const m = cmdlineModules("root=x modules-load=a,b quiet rd.modules-load=c");
    try testing.expectEqual(@as(usize, 3), m.len);
    try testing.expectEqualStrings("b", m[1]);
    try testing.expectEqualStrings("c", m[2]);
    try testing.expectEqual(@as(usize, 0), cmdlineModules("root=x quiet").len);
}

test "loadkeys only for a non-us keymap" {
    try testing.expect(!needsLoadkeys(""));
    try testing.expect(!needsLoadkeys("us"));
    try testing.expect(needsLoadkeys("de"));
    try testing.expect(needsLoadkeys("us-acentos"));
}

test "the boot record of halt -B" {
    const u = bootRecord(1_700_000_000, 123, "6.18.57_1");
    try testing.expectEqual(BOOT_TIME, u.type);
    try testing.expectEqualStrings("reboot", mem.sliceTo(&u.user, 0));
    try testing.expectEqualStrings("~", mem.sliceTo(&u.line, 0));
    try testing.expectEqualStrings("~~", mem.sliceTo(&u.id, 0));
    try testing.expectEqualStrings("6.18.57_1", mem.sliceTo(&u.host, 0));
    try testing.expectEqual(@as(i64, 1_700_000_000), @as(i64, u.tv_sec));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Utmp, "line"));
    try testing.expectEqual(@as(usize, 76), @offsetOf(Utmp, "host"));
}

test "dmesg: the level prefix is removed" {
    try testing.expectEqualStrings("[    0.000000] Linux version\n[    0.1] x\n<nolevel", stripLevels("<5>[    0.000000] Linux version\n<6>[    0.1] x\n<nolevel"));
    try testing.expectEqualStrings("", stripLevels(""));
}
