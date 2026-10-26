//! vh-stage1: the core-services of void-hardperf-light natively (rootfs/etc/runit/core-services):
//! zram (05), nftables with the fail-closed ruleset (06), THP (07), AppArmor (09), the
//! sandbox directory and the power profile (11, vh-power boot), the SUID strip (12,
//! vh-suid-strip --quiet), the gaming boot (98, vh-game boot on) and the module lock (99-zz).
//! nft, apparmor_parser, modprobe and vh-game are run by argv; everything else is system calls.
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

/// the energy-performance preference for the power source; the CPU's frequency driver offers
/// it where it can (intel_pstate and amd-pstate-epp alike)
pub fn eppFor(ac: bool) []const u8 {
    return if (ac) "balance_performance" else "balance_power";
}

/// The ACPI platform profile for the power source: the first wanted one the firmware offers
/// (`choices` as platform_profile_choices lists them), null when it offers none of them. On
/// battery low-power, else quiet; on AC balanced, the profile that goes with the EPP
/// balance_performance [VERIFY by measurement per class].
pub fn platformProfile(ac: bool, choices: []const u8) ?[]const u8 {
    const wanted: []const []const u8 = if (ac) &.{"balanced"} else &.{ "low-power", "quiet", "balanced" };
    for (wanted) |w| if (offered(choices, w)) return w;
    return null;
}

/// whether `value` is one of the words of `list` ("default performance balance_performance")
pub fn offered(list: []const u8, value: []const u8) bool {
    var it = mem.tokenizeAny(u8, list, " \t\n");
    while (it.next()) |x| if (vh.eql(x, value)) return true;
    return false;
}

pub const Pci = struct {
    /// the sysfs name, "0000:01:00.1"
    name: []const u8,
    /// the class attribute, "0x030000"
    class: []const u8,
    /// boot_vga is "1": the firmware brought the console up on it
    boot_vga: bool = false,
};

/// the slot of a PCI function: "0000:01:00.1" -> "0000:01:00"
pub fn slot(name: []const u8) []const u8 {
    return name[0 .. mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
}

/// Whether the profile leaves the runtime PM of `d` alone: a bridge (the dGPU sleeps through
/// its root port), or any function in the slot of a display controller that did not bring the
/// console up, whatever its vendor: the dGPU and its audio or USB functions, whose runtime PM
/// its udev rule and its driver decide (docs/uni/runtime.md).
pub fn keepRpm(devs: []const Pci, d: Pci) bool {
    if (vh.startsWith(d.class, "0x0604")) return true;
    for (devs) |x| {
        if (!vh.startsWith(x.class, "0x03") or x.boot_vga) continue;
        if (vh.eql(slot(x.name), slot(d.name))) return true;
    }
    return false;
}

fn writable(path: []const u8) bool {
    return linux.errno(linux.access(vh.z(path).ptr, linux.W_OK)) == .SUCCESS;
}

/// vh-power boot: EPP, the ACPI platform profile and the runtime PM of PCI devices by the
/// power source, /run/vh/power. (The udev rule at plug events keeps calling the vh-power
/// script, which does the same.)
pub fn power() void {
    var supplies: std.ArrayList(Supply) = .empty;
    const ps = sys.p("/sys/class/power_supply");
    for (vh.listDir(ps) catch &.{}) |name| {
        const t = vh.rd(vh.fmt("{s}/{s}/type", .{ ps, name }));
        if (t.len == 0) continue;
        supplies.append(vh.gpa, .{ .type = t, .online = vh.rd(vh.fmt("{s}/{s}/online", .{ ps, name })) }) catch vh.oom();
    }
    const ac = onAc(supplies.items);
    const epp = eppFor(ac);
    const rpm: []const u8 = if (ac) "on" else "auto";
    const cpufreq = sys.p("/sys/devices/system/cpu/cpufreq");
    for (vh.listDir(cpufreq) catch &.{}) |name| {
        if (!vh.startsWith(name, "policy")) continue;
        const f = vh.fmt("{s}/{s}/energy_performance_preference", .{ cpufreq, name });
        if (!writable(f) or !offered(vh.rd(vh.fmt("{s}/{s}/energy_performance_available_preferences", .{ cpufreq, name })), epp)) continue;
        _ = vh.writeStr(f, epp);
    }
    const pp = sys.p("/sys/firmware/acpi/platform_profile");
    if (writable(pp)) {
        if (platformProfile(ac, vh.rd(vh.fmt("{s}_choices", .{pp})))) |want| {
            if (!vh.writeStr(pp, want)) sys.note("! platform profile {s}: {s}", .{ want, vh.serr() });
        }
    }
    const pci = sys.p("/sys/bus/pci/devices");
    var devs: std.ArrayList(Pci) = .empty;
    for (vh.listDir(pci) catch &.{}) |name| {
        const d = vh.fmt("{s}/{s}", .{ pci, name });
        devs.append(vh.gpa, .{ .name = name, .class = vh.rd(vh.fmt("{s}/class", .{d})), .boot_vga = vh.eql(vh.rd(vh.fmt("{s}/boot_vga", .{d})), "1") }) catch vh.oom();
    }
    for (devs.items) |d| {
        if (keepRpm(devs.items, d)) continue;
        const f = vh.fmt("{s}/{s}/power/control", .{ pci, d.name });
        if (writable(f)) _ = vh.writeStr(f, rpm);
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

// ---------------------------------------------------------------- 98-vh-game.sh

/// The gaming boot (vh-game boot on, docs/uni/game.md): vh-game stage1 by argv, while vh-game's
/// stage-1 script is there and the command line turns ia32 on; vh-game itself decides (the last
/// ia32_emulation= of the command line) and loads the controllers' drivers before the module
/// lock below, then binds its marker over /etc/runit/2 for stage 2.
pub fn game() void {
    if (!vh.pathExists(sys.p("/etc/runit/core-services/98-vh-game.sh"))) return;
    const cmdline = vh.readFile(sys.p("/proc/cmdline")) catch return;
    if (mem.indexOf(u8, cmdline, "ia32_emulation=1") == null) return;
    const prog = sys.p("/usr/local/sbin/vh-game");
    if (!vh.isRegular(prog)) return sys.note("! the gaming boot: {s} is missing", .{prog});
    if (sys.exec(&.{ prog, "stage1" }) != 0) sys.note("! vh-game stage1 failed: this gaming boot has no x86_64 filter", .{});
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

test "power: EPP and the platform profile by the power source" {
    try testing.expectEqualStrings("balance_performance", eppFor(true));
    try testing.expectEqualStrings("balance_power", eppFor(false));
    try testing.expect(offered("default performance balance_performance balance_power power", "balance_power"));
    try testing.expect(!offered("default performance", "balance_power"));
    try testing.expect(!offered("balance_performance", "balance"));
    // the firmware's choices decide; a firmware without any wanted profile is left alone
    try testing.expectEqualStrings("low-power", platformProfile(false, "low-power balanced performance").?);
    try testing.expectEqualStrings("quiet", platformProfile(false, "quiet balanced performance").?);
    try testing.expectEqualStrings("balanced", platformProfile(false, "cool balanced performance").?);
    try testing.expectEqualStrings("balanced", platformProfile(true, "low-power balanced performance").?);
    try testing.expect(platformProfile(true, "quiet performance") == null);
    try testing.expect(platformProfile(false, "") == null);
}

test "power: the dGPU of any vendor keeps its runtime PM" {
    // a hybrid laptop: the iGPU brought the console up, the dGPU (VGA or 3D controller, any
    // vendor) did not; its HDMI audio function shares its slot
    const devs = [_]Pci{
        .{ .name = "0000:00:02.0", .class = "0x030000", .boot_vga = true },
        .{ .name = "0000:00:01.0", .class = "0x060400" },
        .{ .name = "0000:00:14.3", .class = "0x028000" },
        .{ .name = "0000:01:00.0", .class = "0x030200" },
        .{ .name = "0000:01:00.1", .class = "0x040300" },
        .{ .name = "0000:02:00.0", .class = "0x010802" },
    };
    try testing.expect(!keepRpm(&devs, devs[0])); // the iGPU follows the profile
    try testing.expect(keepRpm(&devs, devs[1])); // the root port
    try testing.expect(!keepRpm(&devs, devs[2]));
    try testing.expect(keepRpm(&devs, devs[3])); // the dGPU
    try testing.expect(keepRpm(&devs, devs[4])); // its audio function
    try testing.expect(!keepRpm(&devs, devs[5])); // the NVMe disk
    try testing.expectEqualStrings("0000:01:00", slot("0000:01:00.1"));
    // a single GPU that brought the console up is not a dGPU
    const one = [_]Pci{ .{ .name = "0000:00:02.0", .class = "0x030000", .boot_vga = true }, .{ .name = "0000:00:02.1", .class = "0x040300" } };
    try testing.expect(!keepRpm(&one, one[1]));
}

test "nftables: the emergency ruleset flushes and drops" {
    try testing.expect(mem.startsWith(u8, failsafe, "flush ruleset\n"));
    try testing.expect(mem.indexOf(u8, failsafe, "policy drop") != null);
}

// ---------------------------------------------------------------- vh-selinux (docs/uni/selinux.md)

pub const selinux_dir = "/etc/vh/selinux";
pub const selinuxfs = "/sys/fs/selinux";

/// the policy file in /etc/vh/selinux: policy.NN with the highest NN
pub fn policyFile(dir: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_v: u32 = 0;
    for (vh.listDir(dir) catch return null) |n| {
        if (!vh.startsWith(n, "policy.")) continue;
        const v = std.fmt.parseInt(u32, n[7..], 10) catch continue;
        if (v > best_v) {
            best_v = v;
            best = vh.fmt("{s}/{s}", .{ dir, n });
        }
    }
    return best;
}

/// The policy load, right after the pseudo file systems: selinuxfs mounted, the whole policy in
/// one write to /sys/fs/selinux/load, enforcing when /etc/vh/selinux/mode says so (permissive
/// until the policy has passed its definition of done), then the one-way boolean
/// secure_mode_policyload set and committed: from here to the next boot nothing can load another
/// policy, switch enforcing off or set a boolean. A kernel without SELinux active (the stock
/// kernel, lsm= with AppArmor) has no selinuxfs: the step says so and the boot goes on.
pub fn selinuxLoad() void {
    const policy = policyFile(sys.p(selinux_dir)) orelse {
        sys.detail("SELinux: no policy in {s}, skipped", .{selinux_dir});
        return;
    };
    const fs = sys.p(selinuxfs);
    if (!vh.isDir(fs)) {
        sys.detail("SELinux: no {s} in this kernel, skipped", .{selinuxfs});
        return;
    }
    if (!sys.isMountpoint(fs)) {
        sys.mount("selinuxfs", fs, "selinuxfs", 0, null) catch {
            sys.detail("SELinux: selinuxfs did not mount ({s}): not active in this kernel, skipped", .{vh.serr()});
            return;
        };
    }
    const mode = vh.strip(vh.rd(sys.p(selinux_dir ++ "/mode")));
    const enforcing = vh.eql(mode, "enforcing");
    sys.msg("vh: SELinux policy ({s})...", .{if (enforcing) "enforcing" else "permissive"});
    const blob = vh.readFile(policy) catch {
        sys.fail("SELinux: {s}: {s}", .{ policy, vh.serr() });
        return;
    };
    // the kernel takes the policy in one write
    const lfd = vh.openFd(vh.fmt("{s}/load", .{fs}), .{ .ACCMODE = .WRONLY }, 0) catch {
        sys.fail("SELinux: {s}/load: {s}", .{ selinuxfs, vh.serr() });
        return;
    };
    const w = vh.sys(linux.write(lfd, blob.ptr, blob.len)) catch {
        vh.close(lfd);
        sys.fail("SELinux: loading {s} ({d} bytes): {s}; the kernel log has the reason", .{ policy, blob.len, vh.serr() });
        return;
    };
    vh.close(lfd);
    if (w != blob.len) {
        sys.fail("SELinux: the kernel took {d} of {d} bytes of the policy", .{ w, blob.len });
        return;
    }
    _ = sys.kmsg("vh-selinux: policy {s} loaded ({d} bytes)", .{ policy, blob.len });
    // enforcing before the boolean: after it, setenforce is denied to everyone
    if (!vh.writeStr(vh.fmt("{s}/enforce", .{fs}), if (enforcing) "1" else "0")) sys.fail("SELinux: enforce: {s}", .{vh.serr()});
    const b = vh.fmt("{s}/booleans/secure_mode_policyload", .{fs});
    if (vh.pathExists(b)) {
        if (!vh.writeStr(b, "1") or !vh.writeStr(vh.fmt("{s}/commit_pending_bools", .{fs}), "1")) {
            sys.fail("SELinux: secure_mode_policyload: {s}", .{vh.serr()});
        } else sys.detail("SELinux: secure_mode_policyload set: the policy is fixed until the next boot", .{});
    } else sys.note("! SELinux: the policy has no secure_mode_policyload boolean", .{});
    vh.mkdirs(sys.p("/run/vh"), 0o755);
    _ = sys.writeFile(sys.p("/run/vh/selinux"), vh.fmt("policy {s}\nmode {s}\nbytes {d}\n", .{ policy, if (enforcing) "enforcing" else "permissive", blob.len }), 0o644);
}

/// The labels of the file systems stage 1 mounted (tmpfs: /run, /dev/shm, /tmp, /var/tmp; devtmpfs:
/// /dev, whose nodes udev made meanwhile): vh-selabel by argv over them, after mount-all. Nothing
/// to do without an active policy.
pub fn selinuxLabel() void {
    if (!vh.pathExists(sys.p("/run/vh/selinux"))) return;
    const prog = sys.p("/usr/local/sbin/vh-selabel");
    if (!vh.isRegular(prog)) {
        sys.note("! SELinux: no {s}: the tmpfs mounts keep the kernel's labels", .{prog});
        return;
    }
    sys.msg("vh: SELinux labels of /run, /dev, /tmp...", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(vh.gpa, prog) catch vh.oom();
    if (sys.root.len > 0) argv.appendSlice(vh.gpa, &.{ "--root", sys.root }) catch vh.oom();
    argv.appendSlice(vh.gpa, &.{ "--one-fs", "/run", "/dev", "/dev/shm", "/dev/pts", "/tmp", "/var/tmp" }) catch vh.oom();
    const rc = sys.exec(argv.items);
    if (rc != 0) sys.note("! vh-selabel returned {d}", .{rc});
}

test "the policy file with the highest version wins" {
    const dir = "/tmp/vh-selinux-test";
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    vh.mkdirs(dir, 0o700);
    try std.testing.expectEqual(@as(?[]const u8, null), policyFile(dir));
    _ = sys.writeFile(dir ++ "/policy.33", "a", 0o644);
    _ = sys.writeFile(dir ++ "/policy.34", "b", 0o644);
    _ = sys.writeFile(dir ++ "/policy.txt", "c", 0o644);
    try std.testing.expectEqualStrings(dir ++ "/policy.34", policyFile(dir).?);
}
