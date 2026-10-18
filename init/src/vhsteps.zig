//! vh-stage1: the core-services of void-hardperf-light natively (rootfs/etc/runit/core-services):
//! zram (05), nftables with the fail-closed ruleset (06), THP (07), AppArmor (09), the
//! sandbox directory and the power profile (11, vh-power boot), the SUID strip (12,
//! vh-suid-strip --quiet) and the module lock (99-zz). nft, apparmor_parser and modprobe
//! are run by argv; everything else is system calls.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");

// ---------------------------------------------------------------- 05-vh-zram.sh.in

/// swap in compressed memory: the module, the algorithm, the size as a share of RAM,
/// the swap signature (mkswap) and swapon with priority 100
pub fn zram(algo: []const u8, percent: u64) void {
    const dev = sys.p("/sys/block/zram0");
    if (!vh.pathExists(dev)) {
        if (sys.exec(&.{ "modprobe", "zram", "num_devices=1" }) != 0 or !vh.pathExists(dev)) {
            sys.detail("zram: no zram device, skipped", .{});
            return;
        }
    }
    if (!vh.eql(vh.rd(vh.fmt("{s}/disksize", .{dev})), "0")) {
        sys.detail("zram0 is already set up", .{});
        return;
    }
    sys.msg("vh: zram ({s}, {d} percent of RAM)...", .{ algo, percent });
    if (!vh.writeStr(vh.fmt("{s}/comp_algorithm", .{dev}), algo)) sys.fail("zram: comp_algorithm {s}: {s}", .{ algo, vh.serr() });
    const total_kb = memTotalKb(vh.rd(sys.p("/proc/meminfo"))) orelse {
        sys.fail("zram: MemTotal not found in /proc/meminfo", .{});
        return;
    };
    const kb = total_kb * percent / 100;
    if (!vh.writeStr(vh.fmt("{s}/disksize", .{dev}), vh.fmt("{d}K", .{kb}))) {
        sys.fail("zram: disksize: {s}", .{vh.serr()});
        return;
    }
    const size = std.fmt.parseInt(u64, vh.rd(vh.fmt("{s}/disksize", .{dev})), 10) catch kb * 1024;
    const node = sys.p("/dev/zram0");
    if (!mkswap(node, size)) return;
    if (sys.root.len > 0) return; // a test root has no block device to swap on
    _ = vh.sys(linux.syscall2(.swapon, @intFromPtr(vh.z(node).ptr), sys.SWAP_FLAG_PREFER | 100)) catch
        sys.fail("swapon /dev/zram0: {s}", .{vh.serr()});
}

/// "MemTotal:       16274016 kB"
pub fn memTotalKb(meminfo: []const u8) ?u64 {
    var lines = mem.tokenizeScalar(u8, meminfo, '\n');
    while (lines.next()) |line| {
        if (!vh.startsWith(line, "MemTotal:")) continue;
        var it = mem.tokenizeAny(u8, line[9..], " \t");
        const n = it.next() orelse return null;
        return std.fmt.parseInt(u64, n, 10) catch null;
    }
    return null;
}

/// the swap signature of mkswap(8): version 1, the last page, no bad pages, a random
/// UUID, no label, "SWAPSPACE2" at the end of the first page
pub fn swapHeader(page: []u8, size: u64) void {
    @memset(page, 0);
    mem.writeInt(u32, page[1024..1028], 1, .little);
    mem.writeInt(u32, page[1028..1032], @intCast(size / page.len - 1), .little);
    mem.writeInt(u32, page[1032..1036], 0, .little);
    var uuid: [16]u8 = undefined;
    _ = linux.getrandom(&uuid, uuid.len, 0);
    uuid[6] = (uuid[6] & 0x0f) | 0x40;
    uuid[8] = (uuid[8] & 0x3f) | 0x80;
    @memcpy(page[1036..1052], &uuid);
    @memcpy(page[page.len - 10 ..], "SWAPSPACE2");
}

fn mkswap(node: []const u8, size: u64) bool {
    const page_len = std.heap.pageSize();
    if (size < page_len * 10) {
        sys.fail("zram: {d} bytes is too small for swap", .{size});
        return false;
    }
    const page = vh.gpa.alloc(u8, page_len) catch vh.oom();
    swapHeader(page, size);
    const fd = vh.openFd(node, .{ .ACCMODE = .RDWR }, 0) catch {
        sys.fail("mkswap {s}: {s}", .{ node, vh.serr() });
        return false;
    };
    defer vh.close(fd);
    vh.writeAllFd(fd, page) catch {
        sys.fail("mkswap {s}: {s}", .{ node, vh.serr() });
        return false;
    };
    _ = linux.fsync(fd);
    return true;
}

// ---------------------------------------------------------------- 06-vh-nftables.sh

pub const failsafe =
    \\flush ruleset
    \\table inet vh_failsafe {
    \\    chain input { type filter hook input priority filter; policy drop; iif "lo" accept; }
    \\    chain forward { type filter hook forward priority filter; policy drop; }
    \\    chain output { type filter hook output priority filter; policy drop; oif "lo" accept; }
    \\}
    \\
;

/// the firewall before any network service; fail-closed when the ruleset does not load
pub fn nftables() void {
    sys.msg("vh: nftables...", .{});
    if (sys.exec(&.{ "nft", "-f", sys.p("/etc/nftables.conf") }) == 0) return;
    sys.note("! nftables.conf did not load: the emergency ruleset is active (all network closed)", .{});
    const rc = sys.execIn(&.{ "nft", "-f", "-" }, failsafe);
    if (rc != 0) sys.fail("nft: the emergency ruleset did not load either (exit {d}): no firewall", .{rc});
}

// ---------------------------------------------------------------- 07-vh-mm.sh

pub fn thp() void {
    const path = sys.p("/sys/kernel/mm/transparent_hugepage/defrag");
    if (linux.errno(linux.access(vh.z(path).ptr, linux.W_OK)) != .SUCCESS) {
        sys.detail("THP defrag: not writable, skipped", .{});
        return;
    }
    if (!vh.writeStr(path, "defer+madvise")) sys.fail("THP defrag: {s}", .{vh.serr()});
}

// ---------------------------------------------------------------- 09-vh-apparmor.sh

pub const profiles = [_][]const u8{ "vh.firefox", "vh.unbound", "vh.chronyd", "vh.iwd", "unix-chkpwd" };

/// only the listed profiles and the vh.local.* ones, from the compiled cache
pub fn apparmor() void {
    if (!vh.isDir(sys.p("/sys/kernel/security/apparmor"))) {
        sys.detail("AppArmor: not active, skipped", .{});
        return;
    }
    sys.msg("vh: AppArmor profiles...", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(vh.gpa, &.{ "apparmor_parser", "--replace", "--write-cache", "--cache-loc", sys.p("/var/cache/apparmor"), "--" }) catch vh.oom();
    const n0 = argv.items.len;
    for (profiles) |name| {
        const path = sys.p(vh.fmt("/etc/apparmor.d/{s}", .{name}));
        if (vh.isRegular(path)) argv.append(vh.gpa, path) catch vh.oom() else sys.note("! AppArmor: no profile {s}", .{name});
    }
    for (sys.sortedDir(sys.p("/etc/apparmor.d"))) |name|
        if (vh.startsWith(name, "vh.local.")) argv.append(vh.gpa, sys.p(vh.fmt("/etc/apparmor.d/{s}", .{name}))) catch vh.oom();
    if (argv.items.len == n0) {
        sys.note("! AppArmor: no profiles to load", .{});
        return;
    }
    if (sys.exec(argv.items) != 0) sys.note("! AppArmor: not every profile loaded: docs/08", .{});
}

// ---------------------------------------------------------------- 11-vh-runtime.sh.in

/// /run/vh-sandbox (2750 user:browser) and the power profile at boot
pub fn runtime(user: []const u8, browser: []const u8) void {
    const dir = sys.p("/run/vh-sandbox");
    if (!sys.mkdirMode(dir, 0o2750)) sys.fail("{s}: {s}", .{ dir, vh.serr() });
    const u = sys.userId(user);
    const g = sys.groupId(browser);
    if (u == null or g == null) {
        sys.fail("/run/vh-sandbox: no user {s} or no group {s} (VH_USER, VH_BROWSER_USER in /etc/vh/vh.env)", .{ user, browser });
    } else if (!sys.chown(dir, u.?.uid, g.?)) sys.fail("chown {s}: {s}", .{ dir, vh.serr() });
    power();
}

pub const Supply = struct { type: []const u8, online: []const u8 };

/// on AC: a Mains supply that is online; without any battery (a desktop, a VM) always AC
pub fn onAc(supplies: []const Supply) bool {
    var on_ac = false;
    var has_bat = false;
    for (supplies) |s| {
        if (vh.eql(s.type, "Mains") and vh.eql(s.online, "1")) on_ac = true;
        if (vh.eql(s.type, "Battery")) has_bat = true;
    }
    return on_ac or !has_bat;
}

/// vh-power boot: EPP and the runtime PM of PCI devices by the power source, /run/vh/power.
/// (The udev rule at plug events keeps calling the vh-power script.)
pub fn power() void {
    var supplies: std.ArrayList(Supply) = .empty;
    const ps = sys.p("/sys/class/power_supply");
    for (vh.listDir(ps) catch &.{}) |name| {
        const t = vh.rd(vh.fmt("{s}/{s}/type", .{ ps, name }));
        if (t.len == 0) continue;
        supplies.append(vh.gpa, .{ .type = t, .online = vh.rd(vh.fmt("{s}/{s}/online", .{ ps, name })) }) catch vh.oom();
    }
    const ac = onAc(supplies.items);
    const epp: []const u8 = if (ac) "balance_performance" else "balance_power";
    const rpm: []const u8 = if (ac) "on" else "auto";
    const cpufreq = sys.p("/sys/devices/system/cpu/cpufreq");
    for (vh.listDir(cpufreq) catch &.{}) |name| {
        if (!vh.startsWith(name, "policy")) continue;
        const f = vh.fmt("{s}/{s}/energy_performance_preference", .{ cpufreq, name });
        if (linux.errno(linux.access(vh.z(f).ptr, linux.W_OK)) == .SUCCESS) _ = vh.writeStr(f, epp);
    }
    const pci = sys.p("/sys/bus/pci/devices");
    for (vh.listDir(pci) catch &.{}) |name| {
        const d = vh.fmt("{s}/{s}", .{ pci, name });
        // bridges are left alone (the dGPU sleeps through them), NVIDIA is always auto (docs/04)
        if (vh.startsWith(vh.rd(vh.fmt("{s}/class", .{d})), "0x0604")) continue;
        if (vh.eql(vh.rd(vh.fmt("{s}/vendor", .{d})), "0x10de")) continue;
        const f = vh.fmt("{s}/power/control", .{d});
        if (linux.errno(linux.access(vh.z(f).ptr, linux.W_OK)) == .SUCCESS) _ = vh.writeStr(f, rpm);
    }
    vh.mkdirs(sys.p("/run/vh"), 0o755);
    if (!sys.writeFile(sys.p("/run/vh/power"), if (ac) "ac\n" else "battery\n", 0o644)) sys.fail("/run/vh/power: {s}", .{vh.serr()});
    sys.detail("power profile: {s}", .{if (ac) "ac" else "battery"});
}

// ---------------------------------------------------------------- 12-vh-suid.sh

/// needed by root only: SUID is stripped
pub const strip_suid = [_][]const u8{ "/usr/bin/passwd", "/usr/bin/chage", "/usr/bin/mount", "/usr/bin/umount" };
/// needed by nobody (excluded through noextract); stripped if they appeared anyway
pub const strip_both = [_][]const u8{
    "/usr/bin/su",         "/usr/bin/sg",        "/usr/bin/newgrp",    "/usr/bin/chsh",   "/usr/bin/chfn",
    "/usr/bin/expiry",     "/usr/bin/gpasswd",   "/usr/bin/newuidmap", "/usr/bin/newgidmap", "/usr/bin/wall",
    "/usr/bin/write",      "/usr/lib/utempter/utempter", "/usr/bin/xbps-uchroot", "/usr/libexec/dbus-daemon-launch-helper",
};
pub const ping = [_][]const u8{ "/usr/bin/iputils-ping", "/usr/bin/ping" };

/// vh-suid-strip --quiet: the bits and the file capabilities a package update brought back
pub fn suid() void {
    for (strip_suid) |f| stripBits(sys.p(f), vh.S.ISUID, "SUID stripped");
    for (strip_both) |f| stripBits(sys.p(f), vh.S.ISUID | vh.S.ISGID, "SUID/SGID stripped (noextract was expected)");
    if (vh.readFile(sys.p("/etc/vh/suid-strip.list"))) |text| {
        var lines = mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = vh.strip(raw);
            if (line.len == 0 or line[0] == '#') continue;
            const path = sys.p(line);
            if (!vh.isRegular(path)) continue;
            stripBits(path, vh.S.ISUID | vh.S.ISGID, "SUID/SGID stripped (vh-pkg)");
            if (hasCaps(path)) stripCaps(path, "capabilities stripped (vh-pkg)");
        }
    } else |_| {}
    for (ping) |f| {
        const path = sys.p(f);
        const st = vh.stat(path, false) catch continue;
        if (!vh.S.isReg(st.mode)) continue;
        if (hasCaps(path)) stripCaps(path, "capabilities stripped");
    }
}

fn stripBits(path: []const u8, bits: u32, what: []const u8) void {
    const st = vh.stat(path, true) catch return;
    const mode: u32 = st.mode;
    if (mode & bits == 0) return;
    _ = vh.sys(linux.chmod(vh.z(path).ptr, mode & ~bits & 0o7777)) catch {
        sys.fail("chmod {s}: {s}", .{ path, vh.serr() });
        return;
    };
    sys.detail("{s}: {s}", .{ what, path });
}

pub fn hasCaps(path: []const u8) bool {
    const rc = linux.lgetxattr(vh.z(path).ptr, "security.capability", undefined, 0);
    return linux.errno(rc) == .SUCCESS;
}

fn stripCaps(path: []const u8, what: []const u8) void {
    _ = vh.sys(linux.removexattr(vh.z(path).ptr, "security.capability")) catch {
        sys.fail("setcap -r {s}: {s}", .{ path, vh.serr() });
        return;
    };
    sys.detail("{s}: {s}", .{ what, path });
}

// ---------------------------------------------------------------- 99-zz-vh-modlock.sh

/// the modules of /etc/vh/modules.preload, then kernel.modules_disabled=1 (stage 3 of the install)
pub fn modlock() void {
    if (!vh.pathExists(sys.p("/etc/vh/modlock.enabled"))) return;
    const mods = sys.words(vh.readFile(sys.p("/etc/vh/modules.preload")) catch "");
    if (mods.len > 0) {
        sys.msg("vh: preloading modules...", .{});
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(vh.gpa, &.{ "modprobe", "-a" }) catch vh.oom();
        argv.appendSlice(vh.gpa, mods) catch vh.oom();
        if (sys.exec(argv.items) != 0) sys.note("! modprobe: not every module of /etc/vh/modules.preload loaded", .{});
    }
    sys.msg("vh: kernel module loading is blocked until reboot", .{});
    if (!vh.writeStr(sys.p("/proc/sys/kernel/modules_disabled"), "1")) sys.fail("kernel.modules_disabled: {s}", .{vh.serr()});
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "zram: MemTotal" {
    try testing.expectEqual(@as(?u64, 16274016), memTotalKb("MemFree: 1 kB\nMemTotal:       16274016 kB\n"));
    try testing.expectEqual(@as(?u64, null), memTotalKb("MemFree: 1 kB\n"));
    try testing.expectEqual(@as(u64, 8137008), memTotalKb("MemTotal: 16274016 kB").? * 50 / 100);
}

test "zram: the swap signature" {
    var page: [4096]u8 = undefined;
    swapHeader(&page, 8 * 1024 * 1024);
    try testing.expectEqual(@as(u32, 1), mem.readInt(u32, page[1024..1028], .little));
    try testing.expectEqual(@as(u32, 2047), mem.readInt(u32, page[1028..1032], .little));
    try testing.expectEqualStrings("SWAPSPACE2", page[4086..]);
    try testing.expectEqual(@as(u8, 0x40), page[1036 + 6] & 0xf0);
    try testing.expectEqual(@as(u8, 0x80), page[1036 + 8] & 0xc0);
    try testing.expectEqual(@as(u8, 0), page[0]);
}

test "power: AC or battery" {
    try testing.expect(onAc(&.{})); // a VM: no supplies
    try testing.expect(onAc(&.{.{ .type = "Battery", .online = "" }, .{ .type = "Mains", .online = "1" }}));
    try testing.expect(!onAc(&.{.{ .type = "Battery", .online = "" }, .{ .type = "Mains", .online = "0" }}));
    try testing.expect(onAc(&.{.{ .type = "Mains", .online = "0" }})); // no battery at all
}

test "nftables: the emergency ruleset flushes and drops" {
    try testing.expect(mem.startsWith(u8, failsafe, "flush ruleset\n"));
    try testing.expect(mem.indexOf(u8, failsafe, "policy drop") != null);
}
