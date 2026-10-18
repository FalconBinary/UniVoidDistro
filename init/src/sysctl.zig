//! vh-stage1: sysctl.d with the priorities of `sysctl --system` (procps-ng): the *.conf
//! files of /etc/sysctl.d, /run/sysctl.d, /usr/local/lib/sysctl.d, /usr/lib/sysctl.d and
//! /lib/sysctl.d, a base name once (the first directory in that order wins: a file in /etc
//! masks the one of the same name in /usr/lib), applied in base-name order, then
//! /etc/sysctl.conf. A key that does not exist (ENOENT) is skipped and logged, as sysctl
//! prints "cannot stat"; a key starting with "-" is silent about errors.
//! Note: runit-void's 08-sysctl.sh puts /run/sysctl.d before /etc/sysctl.d; procps and
//! this program put /etc first. This system has no /run/sysctl.d.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");

pub const dirs = [_][]const u8{ "/etc/sysctl.d", "/run/sysctl.d", "/usr/local/lib/sysctl.d", "/usr/lib/sysctl.d", "/lib/sysctl.d" };

pub const File = struct { path: []const u8, name: []const u8 };

/// The files to apply in order, from the listings of the directories (in the order of
/// `dirs`): a base name is taken from the first directory that has it, then everything
/// is sorted by base name. Pure, so it is tested without a file system.
pub fn order(listings: []const []const []const u8) []File {
    return mergeByName(&dirs, listings, ".conf");
}

/// the drop-in rule shared with modules-load.d: the files with the suffix from several
/// directories, a base name once (the first directory wins), sorted by base name
pub fn mergeByName(dir_paths: []const []const u8, listings: []const []const []const u8, suffix: []const u8) []File {
    var files: std.ArrayList(File) = .empty;
    for (listings, 0..) |names, di| {
        for (names) |name| {
            if (!vh.endsWith(name, suffix) or name.len <= suffix.len) continue;
            var seen = false;
            for (files.items) |f| if (vh.eql(f.name, name)) {
                seen = true;
                break;
            };
            if (seen) continue;
            files.append(vh.gpa, .{ .path = vh.fmt("{s}/{s}", .{ dir_paths[di], name }), .name = name }) catch vh.oom();
        }
    }
    mem.sort(File, files.items, {}, lessByName);
    return files.items;
}

fn lessByName(_: void, a: File, b: File) bool {
    return mem.order(u8, a.name, b.name) == .lt;
}

pub const Setting = struct {
    key: []const u8,
    value: []const u8,
    /// "-key": errors are not reported
    quiet: bool,
};

/// the settings of one file: "key = value" lines; "#" and ";" start comments
pub fn parseFile(text: []const u8) []Setting {
    var list: std.ArrayList(Setting) = .empty;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        var key = vh.strip(line[0..eq]);
        if (key.len == 0) continue;
        var quiet = false;
        if (key[0] == '-') {
            quiet = true;
            key = vh.strip(key[1..]);
        }
        list.append(vh.gpa, .{ .key = key, .value = vh.strip(line[eq + 1 ..]), .quiet = quiet }) catch vh.oom();
    }
    return list.items;
}

/// the /proc/sys path of a key: dots become slashes; a key written with slashes keeps its
/// dots (net/ipv4/conf/eth0.100/rp_filter), as sysctl(8) defines it
pub fn keyPath(key: []const u8) []u8 {
    if (mem.indexOfScalar(u8, key, '/') != null) {
        const k = mem.trimStart(u8, key, "/");
        return vh.fmt("/proc/sys/{s}", .{k});
    }
    const out = vh.fmt("/proc/sys/{s}", .{key});
    for (out[10..]) |*c| if (c.* == '.') {
        c.* = '/';
    };
    return out;
}

pub fn isGlob(key: []const u8) bool {
    return mem.indexOfAny(u8, key, "*?[") != null;
}

pub const Counts = struct { applied: usize = 0, missing: usize = 0, failed: usize = 0 };

/// one setting into /proc/sys (under --root: DIR/proc/sys); prints "key = value" with -v
pub fn applyOne(s: Setting, counts: *Counts) void {
    if (isGlob(s.key)) {
        sys.note("sysctl: {s}: patterns are not supported by vh-stage1 (skipped)", .{s.key});
        counts.failed += 1;
        return;
    }
    const path = sys.p(keyPath(s.key));
    const fd = vh.openFd(path, .{ .ACCMODE = .WRONLY }, 0) catch {
        if (vh.errno == .NOENT) {
            counts.missing += 1;
            if (!s.quiet) sys.note("sysctl: {s}: no such key (skipped)", .{s.key});
        } else {
            counts.failed += 1;
            if (!s.quiet) sys.note("sysctl: {s}: {s}", .{ s.key, vh.serr() });
        }
        return;
    };
    defer vh.close(fd);
    const line = vh.fmt("{s}\n", .{s.value});
    vh.writeAllFd(fd, line) catch {
        counts.failed += 1;
        if (!s.quiet) sys.note("sysctl: setting {s} = {s}: {s}", .{ s.key, s.value, vh.serr() });
        return;
    };
    counts.applied += 1;
    sys.detail("{s} = {s}", .{ s.key, s.value });
}

/// 08-sysctl.sh: every file in order, then /etc/sysctl.conf
pub fn apply() void {
    sys.msg("Loading sysctl(8) settings...", .{});
    var listings: [dirs.len][]const []const u8 = undefined;
    for (dirs, 0..) |d, i| listings[i] = sys.sortedDir(sys.p(d));
    const files = order(&listings);
    var counts: Counts = .{};
    for (files) |f| applyFile(sys.p(f.path), &counts);
    const conf = sys.p("/etc/sysctl.conf");
    if (vh.isRegular(conf)) applyFile(conf, &counts);
    sys.detail("sysctl: {d} applied, {d} unknown keys skipped, {d} errors", .{ counts.applied, counts.missing, counts.failed });
    if (counts.failed > 0) sys.failures += 1;
}

fn applyFile(path: []const u8, counts: *Counts) void {
    const text = vh.readFile(path) catch {
        sys.note("sysctl: {s}: {s}", .{ path, vh.serr() });
        return;
    };
    sys.detail("* Applying {s} ...", .{path});
    for (parseFile(text)) |s| applyOne(s, counts);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "sysctl: a same-named file in /etc masks /usr/lib; base-name order across directories" {
    const etc = [_][]const u8{ "30-vh-hardening.conf", "10-void.conf", "README", "50-vh-performance.conf" };
    const run = [_][]const u8{};
    const local = [_][]const u8{};
    const usr = [_][]const u8{ "10-void-user.conf", "10-void.conf", "20-bpf.conf" };
    const lib = [_][]const u8{};
    const files = order(&.{ &etc, &run, &local, &usr, &lib });
    try testing.expectEqual(@as(usize, 5), files.len);
    try testing.expectEqualStrings("/usr/lib/sysctl.d/10-void-user.conf", files[0].path);
    try testing.expectEqualStrings("/etc/sysctl.d/10-void.conf", files[1].path);
    try testing.expectEqualStrings("/usr/lib/sysctl.d/20-bpf.conf", files[2].path);
    try testing.expectEqualStrings("/etc/sysctl.d/30-vh-hardening.conf", files[3].path);
    try testing.expectEqualStrings("/etc/sysctl.d/50-vh-performance.conf", files[4].path);
}

test "sysctl: /etc before /run, as procps" {
    const etc = [_][]const u8{"10-x.conf"};
    const run = [_][]const u8{ "10-x.conf", "05-y.conf" };
    const none = [_][]const u8{};
    const files = order(&.{ &etc, &run, &none, &none, &none });
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings("/run/sysctl.d/05-y.conf", files[0].path);
    try testing.expectEqualStrings("/etc/sysctl.d/10-x.conf", files[1].path);
}

test "sysctl: file parsing" {
    const s = parseFile("# c\n; c\nkernel.printk = 3 3 3 3\n-net.ipv4.missing=1\nfs.protected_fifos=2  \n\nbroken line\n");
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqualStrings("kernel.printk", s[0].key);
    try testing.expectEqualStrings("3 3 3 3", s[0].value);
    try testing.expect(!s[0].quiet);
    try testing.expectEqualStrings("net.ipv4.missing", s[1].key);
    try testing.expect(s[1].quiet);
    try testing.expectEqualStrings("2", s[2].value);
}

test "sysctl: key to path" {
    try testing.expectEqualStrings("/proc/sys/net/ipv4/conf/all/rp_filter", keyPath("net.ipv4.conf.all.rp_filter"));
    try testing.expectEqualStrings("/proc/sys/net/ipv4/conf/eth0.100/rp_filter", keyPath("net/ipv4/conf/eth0.100/rp_filter"));
    try testing.expectEqualStrings("/proc/sys/kernel/yama/ptrace_scope", keyPath("/kernel/yama/ptrace_scope"));
    try testing.expect(isGlob("net.ipv4.conf.*.rp_filter"));
    try testing.expect(!isGlob("net.ipv4.conf.all.rp_filter"));
}
