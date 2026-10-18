//! vh-kconf probe: sysfs and procfs -> hw.zon. Reads only; never a serial number, a MAC
//! address or a UUID. With --save DIR every file and symlink it read is copied under DIR
//! (a snapshot with the shape of sysfs); with --from DIR it reads such a snapshot instead
//! of the live system, so the probe runs on a Mac and in unit tests (tests/kernel/fixtures).
const std = @import("std");
const vh = @import("vh");
const hw = @import("hw.zig");
const linux = std.os.linux;
const mem = std.mem;

/// Where the files come from: the live system (root "") or a snapshot directory. Every read
/// goes through here so that --save sees it.
pub const Src = struct {
    root: []const u8 = "",
    save: ?[]const u8 = null,

    fn abs(self: *const Src, rel: []const u8) []const u8 {
        return vh.fmt("{s}{s}", .{ self.root, rel });
    }

    /// a whole file, null when absent or unreadable
    pub fn read(self: *const Src, rel: []const u8) ?[]const u8 {
        const data = vh.readFile(self.abs(rel)) catch return null;
        if (self.save) |dir| self.saveFile(dir, rel, data);
        return data;
    }

    /// the first line of a sysfs/proc file without surrounding whitespace, "" when absent
    pub fn line(self: *const Src, rel: []const u8) []const u8 {
        const data = self.read(rel) orelse return "";
        const end = mem.indexOfScalar(u8, data, '\n') orelse data.len;
        return vh.dupe(vh.strip(data[0..end]));
    }

    /// directory entries, sorted; empty when absent
    pub fn list(self: *const Src, rel: []const u8) []const []const u8 {
        const names = vh.listDir(self.abs(rel)) catch return &.{};
        if (self.save) |dir| vh.mkdirs(vh.fmt("{s}{s}", .{ dir, self.resolve(dir, rel) }), 0o755);
        const sorted = vh.gpa.dupe([]const u8, names) catch vh.oom();
        mem.sort([]const u8, sorted, {}, vh.lessStr);
        return sorted;
    }

    /// the target of a symlink, null when it is not one
    pub fn link(self: *const Src, rel: []const u8) ?[]const u8 {
        const target = vh.readlink(self.abs(rel)) catch return null;
        if (self.save) |dir| self.saveLink(dir, rel, target);
        return target;
    }

    pub fn exists(self: *const Src, rel: []const u8) bool {
        const ok = vh.pathExists(self.abs(rel));
        if (ok and self.save != null) _ = self.resolve(self.save.?, rel);
        return ok;
    }

    /// Walk `rel` component by component under the live root; every symlink on the way is
    /// recreated under `dir` with the same relative target, so that the snapshot resolves
    /// exactly as sysfs does. Returns the resolved path.
    fn resolve(self: *const Src, dir: []const u8, rel: []const u8) []const u8 {
        var cur: []const u8 = "";
        var it = mem.tokenizeScalar(u8, rel, '/');
        while (it.next()) |comp| {
            const next = vh.fmt("{s}/{s}", .{ cur, comp });
            const st = vh.stat(self.abs(next), false) catch {
                cur = next;
                continue;
            };
            if (vh.S.isLnk(st.mode)) {
                const target = vh.readlink(self.abs(next)) catch {
                    cur = next;
                    continue;
                };
                writeLink(vh.fmt("{s}{s}", .{ dir, next }), target);
                cur = joinRel(next, target);
            } else {
                cur = next;
            }
        }
        return cur;
    }

    fn saveFile(self: *const Src, dir: []const u8, rel: []const u8, data: []const u8) void {
        const real = self.resolve(dir, rel);
        const path = vh.fmt("{s}{s}", .{ dir, real });
        vh.mkdirs(dirname(path), 0o755);
        vh.writeAtomic(path, data, 0o644);
    }

    fn saveLink(self: *const Src, dir: []const u8, rel: []const u8, target: []const u8) void {
        const parent = dirname(rel);
        const real_parent = self.resolve(dir, parent);
        writeLink(vh.fmt("{s}{s}/{s}", .{ dir, real_parent, basename(rel) }), target);
    }
};

fn writeLink(path: []const u8, target: []const u8) void {
    vh.mkdirs(dirname(path), 0o755);
    _ = vh.sys(linux.symlink(vh.z(target).ptr, vh.z(path).ptr)) catch {
        if (vh.errno != .EXIST) vh.die("{s}: {s}", .{ path, vh.serr() });
    };
}

pub fn basename(path: []const u8) []const u8 {
    const p = mem.trimEnd(u8, path, "/");
    return if (mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
}

pub fn dirname(path: []const u8) []const u8 {
    const p = mem.trimEnd(u8, path, "/");
    return if (mem.lastIndexOfScalar(u8, p, '/')) |i| p[0..i] else "";
}

/// `target` relative to the directory of `base` (absolute targets stay), "." and ".." applied
pub fn joinRel(base: []const u8, target: []const u8) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (target.len == 0 or target[0] != '/') {
        var bit = mem.tokenizeScalar(u8, dirname(base), '/');
        while (bit.next()) |c| parts.append(vh.gpa, c) catch vh.oom();
    }
    var tit = mem.tokenizeScalar(u8, target, '/');
    while (tit.next()) |c| {
        if (vh.eql(c, ".")) continue;
        if (vh.eql(c, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        parts.append(vh.gpa, c) catch vh.oom();
    }
    return vh.fmt("/{s}", .{mem.join(vh.gpa, "/", parts.items) catch vh.oom()});
}

// ---------------------------------------------------------------- the probe

pub fn run(src: *const Src) hw.Hw {
    var h: hw.Hw = .{};
    h.probe.kernel = src.line("/proc/sys/kernel/osrelease");
    h.probe.source = if (src.root.len == 0) "live" else vh.dupe(basename(src.root));
    h.machine = machine(src);
    h.cpu = cpu(src);
    h.firmware = firmware(src);
    h.filesystems = filesystems(src);
    h.modules = modules(src);
    h.devices = devices(src);
    return h;
}

fn machine(src: *const Src) hw.Machine {
    const d = "/sys/class/dmi/id/";
    return .{
        .sys_vendor = src.line(d ++ "sys_vendor"),
        .product_name = src.line(d ++ "product_name"),
        .product_family = src.line(d ++ "product_family"),
        .product_version = src.line(d ++ "product_version"),
        .board_vendor = src.line(d ++ "board_vendor"),
        .board_name = src.line(d ++ "board_name"),
        .bios_vendor = src.line(d ++ "bios_vendor"),
        .bios_version = src.line(d ++ "bios_version"),
        .bios_date = src.line(d ++ "bios_date"),
        .chassis_type = src.line(d ++ "chassis_type"),
    };
}

fn cpu(src: *const Src) hw.Cpu {
    var c: hw.Cpu = .{};
    const info = src.read("/proc/cpuinfo") orelse "";
    var lines = mem.tokenizeScalar(u8, info, '\n');
    var threads: u32 = 0;
    var first = true;
    while (lines.next()) |raw| {
        const colon = mem.indexOfScalar(u8, raw, ':') orelse continue;
        const key = vh.strip(raw[0..colon]);
        const val = vh.dupe(vh.strip(raw[colon + 1 ..]));
        if (vh.eql(key, "processor")) {
            threads += 1;
            if (threads > 1) first = false;
            continue;
        }
        if (!first) continue;
        if (vh.eql(key, "vendor_id")) c.vendor = val else if (vh.eql(key, "cpu family")) c.family = num(val) else if (vh.eql(key, "model")) c.model = num(val) else if (vh.eql(key, "model name")) c.model_name = val else if (vh.eql(key, "stepping")) c.stepping = num(val) else if (vh.eql(key, "microcode")) c.microcode = val else if (vh.eql(key, "cpu cores")) c.cores = num(val) else if (vh.eql(key, "flags")) c.flags = val;
    }
    // what sysfs says wins over the cpuinfo count: every present CPU, online or not
    var present: u32 = 0;
    for (src.list("/sys/devices/system/cpu")) |n| {
        if (n.len > 3 and vh.startsWith(n, "cpu") and std.ascii.isDigit(n[3])) present += 1;
    }
    c.threads = if (present > 0) present else threads;
    c.smt = vh.eql(src.line("/sys/devices/system/cpu/smt/active"), "1");
    var caches: std.ArrayList(hw.Cache) = .empty;
    const cdir = "/sys/devices/system/cpu/cpu0/cache";
    for (src.list(cdir)) |n| {
        if (!vh.startsWith(n, "index")) continue;
        const p = vh.fmt("{s}/{s}/", .{ cdir, n });
        caches.append(vh.gpa, .{
            .level = num(src.line(vh.fmt("{s}level", .{p}))),
            .kind = src.line(vh.fmt("{s}type", .{p})),
            .size_kb = sizeKb(src.line(vh.fmt("{s}size", .{p}))),
            .shared = src.line(vh.fmt("{s}shared_cpu_list", .{p})),
        }) catch vh.oom();
    }
    c.caches = caches.items;
    return c;
}

fn num(s: []const u8) u32 {
    return std.fmt.parseInt(u32, s, 0) catch 0;
}

/// "32K", "12288K", "1M" -> KiB
fn sizeKb(s: []const u8) u32 {
    if (s.len == 0) return 0;
    const unit = s[s.len - 1];
    const digits = if (std.ascii.isDigit(unit)) s else s[0 .. s.len - 1];
    const n = std.fmt.parseInt(u32, digits, 10) catch return 0;
    return switch (unit) {
        'M' => n * 1024,
        'G' => n * 1024 * 1024,
        else => n,
    };
}

fn firmware(src: *const Src) hw.Firmware {
    var f: hw.Firmware = .{};
    f.efi = src.exists("/sys/firmware/efi");
    if (f.efi) {
        f.efi_bits = num(src.line("/sys/firmware/efi/fw_platform_size"));
        for (src.list("/sys/firmware/efi/efivars")) |n| {
            if (!vh.startsWith(n, "SecureBoot-")) continue;
            const data = src.read(vh.fmt("/sys/firmware/efi/efivars/{s}", .{n})) orelse break;
            // four bytes of attributes, then the value
            if (data.len > 4) f.secure_boot = data[4] == 1;
            break;
        }
    }
    f.tpm = src.exists("/sys/class/tpm/tpm0");
    if (f.tpm) {
        f.tpm_version = num(src.line("/sys/class/tpm/tpm0/tpm_version_major"));
        if (src.link("/sys/class/tpm/tpm0/device/driver")) |t| f.tpm_driver = vh.dupe(basename(t));
    }
    return f;
}

fn filesystems(src: *const Src) []const []const u8 {
    var set: vh.Strv = .{};
    const mounts = src.read("/proc/mounts") orelse "";
    var lines = mem.tokenizeScalar(u8, mounts, '\n');
    while (lines.next()) |l| {
        var it = mem.tokenizeAny(u8, l, " \t");
        _ = it.next();
        _ = it.next();
        const fstype = it.next() orelse continue;
        if (!set.has(fstype)) set.add(fstype);
    }
    set.sort();
    return set.slice();
}

fn modules(src: *const Src) []const []const u8 {
    var set: vh.Strv = .{};
    const text = src.read("/proc/modules") orelse "";
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var it = mem.tokenizeAny(u8, l, " \t");
        const name = it.next() orelse continue;
        if (!set.has(name)) set.add(name);
    }
    set.sort();
    return set.slice();
}

fn devices(src: *const Src) []const hw.Device {
    var devs: std.ArrayList(hw.Device) = .empty;
    for (src.list("/sys/bus")) |bus| {
        const ddir = vh.fmt("/sys/bus/{s}/devices", .{bus});
        for (src.list(ddir)) |name| {
            const base = vh.fmt("{s}/{s}", .{ ddir, name });
            const modalias = src.line(vh.fmt("{s}/modalias", .{base}));
            if (modalias.len == 0) continue;
            var d: hw.Device = .{ .bus = vh.dupe(bus), .name = vh.dupe(name), .modalias = modalias };
            if (src.link(vh.fmt("{s}/driver", .{base}))) |t| {
                d.driver = vh.dupe(basename(t));
                if (src.link(vh.fmt("{s}/driver/module", .{base}))) |m| d.module = vh.dupe(basename(m));
            }
            devs.append(vh.gpa, d) catch vh.oom();
        }
    }
    // the DMI alias (dmi: patterns of platform drivers), not on a bus
    const dmi = src.line("/sys/class/dmi/id/modalias");
    if (dmi.len > 0) devs.append(vh.gpa, .{ .bus = "dmi", .name = "id", .modalias = dmi }) catch vh.oom();
    mem.sort(hw.Device, devs.items, {}, lessDevice);
    return devs.items;
}

fn lessDevice(_: void, a: hw.Device, b: hw.Device) bool {
    const o = mem.order(u8, a.bus, b.bus);
    if (o != .eq) return o == .lt;
    return mem.order(u8, a.name, b.name) == .lt;
}

// ---------------------------------------------------------------- tests

/// the repository root for the tests: $VH_REPO, or ".", ".." or "../.." (the tests run from
/// the repository root, from kernel/, or from a build directory); null when not found
pub fn repoRoot() ?[]const u8 {
    if (vh.getenv("VH_REPO")) |r| {
        if (vh.pathExists(vh.fmt("{s}/kernel/profiles", .{r}))) return r;
    }
    const roots = [_][]const u8{ ".", "..", "../.." };
    for (roots) |r| {
        if (vh.pathExists(vh.fmt("{s}/kernel/profiles", .{r}))) return r;
    }
    return null;
}

/// a repository file for the tests, or null
pub fn repoPath(rel: []const u8) ?[]const u8 {
    const root = repoRoot() orelse return null;
    const p = vh.fmt("{s}/{s}", .{ root, rel });
    return if (vh.pathExists(p)) p else null;
}

test "paths" {
    try std.testing.expectEqualStrings("r8169", basename("../../../bus/pci/drivers/r8169"));
    try std.testing.expectEqualStrings("/sys/bus/pci", dirname("/sys/bus/pci/devices"));
    try std.testing.expectEqualStrings("/sys/devices/pci0000:00/0000:00:1f.6", joinRel("/sys/bus/pci/devices/0000:00:1f.6", "../../../devices/pci0000:00/0000:00:1f.6"));
    try std.testing.expectEqualStrings("/abs", joinRel("/sys/bus/x", "/abs"));
    try std.testing.expectEqualStrings("/sys/bus/pci/drivers/r8169", joinRel("/sys/devices/pci0000:00/0000:00:1f.6/driver", "../../../bus/pci/drivers/r8169"));
    try std.testing.expectEqual(@as(u32, 32), sizeKb("32K"));
    try std.testing.expectEqual(@as(u32, 12288), sizeKb("12288K"));
    try std.testing.expectEqual(@as(u32, 1024), sizeKb("1M"));
    try std.testing.expectEqual(@as(u32, 0), sizeKb(""));
}

test "probe: the GF63 fixture" {
    const dir = repoPath("tests/kernel/fixtures/gf63") orelse return error.SkipZigTest;
    const src: Src = .{ .root = dir };
    const h = run(&src);
    try std.testing.expectEqualStrings("6.18.57_1", h.probe.kernel);
    try std.testing.expectEqualStrings("gf63", h.probe.source);
    try std.testing.expectEqualStrings("GF63 Thin 10SCXR", h.machine.product_name);
    try std.testing.expectEqualStrings("MS-16R5", h.machine.board_name);
    try std.testing.expectEqualStrings("GenuineIntel", h.cpu.vendor);
    try std.testing.expectEqual(@as(u32, 6), h.cpu.family);
    try std.testing.expectEqual(@as(u32, 165), h.cpu.model);
    try std.testing.expectEqual(@as(u32, 6), h.cpu.cores);
    try std.testing.expectEqual(@as(u32, 12), h.cpu.threads);
    try std.testing.expect(h.cpu.smt);
    try std.testing.expectEqual(@as(usize, 4), h.cpu.caches.len);
    try std.testing.expectEqual(@as(u32, 12288), h.cpu.caches[3].size_kb);
    try std.testing.expect(mem.indexOf(u8, h.cpu.flags, " aes ") != null);
    try std.testing.expect(h.firmware.efi);
    try std.testing.expectEqual(@as(u32, 64), h.firmware.efi_bits);
    try std.testing.expectEqual(@as(?bool, true), h.firmware.secure_boot);
    try std.testing.expect(h.firmware.tpm);
    try std.testing.expectEqual(@as(u32, 2), h.firmware.tpm_version);
    try std.testing.expectEqualStrings("tpm_crb", h.firmware.tpm_driver);
    try std.testing.expect(h.hasModule("iwlmvm"));
    try std.testing.expect(h.hasModule("dm_crypt"));
    var has_xfs = false;
    for (h.filesystems) |f| if (vh.eql(f, "xfs")) {
        has_xfs = true;
    };
    try std.testing.expect(has_xfs);
    var wifi: ?hw.Device = null;
    var gpu: ?hw.Device = null;
    var nvme: ?hw.Device = null;
    var dmi: ?hw.Device = null;
    for (h.devices) |d| {
        if (vh.eql(d.name, "0000:00:14.3")) wifi = d;
        if (vh.eql(d.name, "0000:01:00.0")) gpu = d;
        if (vh.eql(d.name, "0000:02:00.0")) nvme = d;
        if (vh.eql(d.bus, "dmi")) dmi = d;
    }
    try std.testing.expectEqualStrings("pci:v00008086d000006F0sv00008086sd00000034bc02sc80i00", wifi.?.modalias);
    try std.testing.expectEqualStrings("iwlwifi", wifi.?.driver);
    try std.testing.expectEqualStrings("iwlwifi", wifi.?.module);
    try std.testing.expectEqualStrings("", gpu.?.driver);
    try std.testing.expectEqualStrings("nvme", nvme.?.driver);
    try std.testing.expectEqualStrings("nvme", nvme.?.module);
    try std.testing.expect(vh.startsWith(dmi.?.modalias, "dmi:bvn"));
    // sorted by bus then name, and no serial numbers anywhere
    for (h.devices[1..], 0..) |d, i| try std.testing.expect(!lessDevice({}, d, h.devices[i]));
    const text = hw.render(h);
    try std.testing.expect(mem.indexOf(u8, text, "serial") == null);
    try std.testing.expect(mem.indexOf(u8, text, "product_uuid") == null);
    // the snapshot round trip: --save of a snapshot reproduces it
    const copy = vh.fmt("/tmp/vh-kconf-test-{d}", .{linux.getpid()});
    _ = vh.runOpts(&.{ "rm", "-rf", copy }, .{});
    const saving: Src = .{ .root = dir, .save = copy };
    _ = run(&saving);
    const again: Src = .{ .root = copy };
    const h2 = run(&again);
    try std.testing.expectEqual(h.devices.len, h2.devices.len);
    try std.testing.expectEqualStrings(hw.render(h), mem.replaceOwned(u8, vh.gpa, hw.render(h2), basename(copy), "gf63") catch vh.oom());
    _ = vh.runOpts(&.{ "rm", "-rf", copy }, .{});
}
