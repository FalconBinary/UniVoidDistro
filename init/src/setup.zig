//! vh-stage1 --install / --rollback / --status: vh-stage1 in place of /etc/runit/1, the
//! previous file kept as /etc/runit/1.orig, the way back one command (docs/runbook-gf63.md).
//! runit-void does not own /etc/runit/1 as a conf file: a package update puts the shell
//! script back; --status and vh-audit (12-stage1.sh) notice, --install repeats the install.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");

pub const stage1 = "/etc/runit/1";
pub const orig = "/etc/runit/1.orig";
pub const conf = "/etc/vh/stage1.conf";
/// written by the boot for --status and vh-audit (the kernel log may have wrapped)
pub const status_file = "/run/vh/stage1";

pub const Kind = enum { none, shell, vh, other };

/// what /etc/runit/1 is: the runit-void shell script, a vh-stage1 binary, something else
pub fn classify(path: []const u8) Kind {
    const text = vh.readFile(path) catch return .none;
    return classifyText(text);
}

pub fn classifyText(text: []const u8) Kind {
    if (mem.startsWith(u8, text, "#!")) return .shell;
    if (mem.startsWith(u8, text, "\x7fELF") and mem.indexOf(u8, text, "vh-stage1") != null) return .vh;
    return .other;
}

fn needRoot() void {
    if (linux.geteuid() != 0) vh.die("run as root: doas vh-stage1 ...", .{});
}

pub fn install() u8 {
    needRoot();
    const self = vh.readlink("/proc/self/exe") catch vh.die("/proc/self/exe: {s}", .{vh.serr()});
    const bytes = vh.readFile(self) catch vh.die("{s}: {s}", .{ self, vh.serr() });
    if (classifyText(bytes) != .vh) vh.die("{s} does not look like vh-stage1", .{self});
    const dst = sys.p(stage1);
    const keep = sys.p(orig);
    const tmp = vh.fmt("{s}.new", .{dst});
    switch (classify(dst)) {
        .shell, .other => {
            _ = vh.sys(linux.rename(vh.z(dst).ptr, vh.z(keep).ptr)) catch vh.die("{s} -> {s}: {s}", .{ dst, keep, vh.serr() });
            vh.out("kept the previous stage 1 as {s}\n", .{orig});
        },
        .vh => vh.out("{s} is already vh-stage1: replaced by this build\n", .{stage1}),
        .none => vh.out("{s} did not exist\n", .{stage1}),
    }
    if (!sys.writeFile(tmp, bytes, 0o755)) vh.die("{s}: {s}", .{ tmp, vh.serr() });
    _ = sys.chown(tmp, 0, 0);
    _ = vh.sys(linux.rename(vh.z(tmp).ptr, vh.z(dst).ptr)) catch vh.die("{s}: {s}", .{ dst, vh.serr() });
    vh.out("installed {s} as {s}\n", .{ self, stage1 });
    writeConfIfMissing();
    vh.out("The next boot runs stage 1 natively. Check after it: vh-stage1 --status, doas vh-audit stage1\nBack to runit-void's stage 1: doas vh-stage1 --rollback\n", .{});
    return 0;
}

pub fn rollback() u8 {
    needRoot();
    const dst = sys.p(stage1);
    const keep = sys.p(orig);
    if (!vh.pathExists(keep)) vh.die("nothing to roll back to: {s} does not exist (xbps-install -f runit-void restores the stock stage 1)", .{orig});
    _ = vh.sys(linux.rename(vh.z(keep).ptr, vh.z(dst).ptr)) catch vh.die("{s} -> {s}: {s}", .{ keep, dst, vh.serr() });
    vh.out("restored {s} from {s}: the next boot runs runit-void's stage 1 again\n", .{ stage1, orig });
    return 0;
}

pub fn status() u8 {
    const kind = classify(sys.p(stage1));
    const what: []const u8 = switch (kind) {
        .shell => "the runit-void shell script",
        .vh => "vh-stage1",
        .other => "unknown (neither a shell script nor vh-stage1)",
        .none => "missing",
    };
    vh.out("{s}: {s}\n", .{ stage1, what });
    vh.out("{s}: {s}\n", .{ orig, if (vh.pathExists(sys.p(orig))) "present (rollback possible)" else "absent" });
    if (vh.readFile(sys.p(status_file))) |text| {
        vh.out("this boot ({s}):\n{s}", .{ status_file, text });
    } else |_| vh.out("this boot: no {s} (stage 1 did not run as vh-stage1)\n", .{status_file});
    if (kernelMarker()) |line| vh.out("kmsg: {s}\n", .{line});
    return if (kind == .vh) 0 else 1;
}

/// the "vh-stage1: done in N ms" line of this boot from the kernel log, if readable
pub fn kernelMarker() ?[]const u8 {
    const log = sys.kernelLog() orelse return null;
    var found: ?[]const u8 = null;
    var lines = mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |l| if (mem.indexOf(u8, l, "vh-stage1: done in") != null) {
        found = l;
    };
    return found;
}

// ---------------------------------------------------------------- /etc/vh/stage1.conf

/// On a system installed before vh-stage1 existed the values of vh.conf live only in the
/// rendered core-services scripts: they are read from there, else the defaults apply.
fn writeConfIfMissing() void {
    const path = sys.p(conf);
    if (vh.pathExists(path)) {
        vh.out("{s} exists: kept\n", .{conf});
        return;
    }
    const zram = vh.readFile(sys.p("/etc/runit/core-services/05-vh-zram.sh")) catch "";
    const mounts = vh.readFile(sys.p("/etc/runit/core-services/04-vh-mounts.sh")) catch "";
    const algo = zramAlgo(zram) orelse "zstd";
    const percent = zramPercent(zram) orelse "50";
    const shm = shmSize(mounts) orelse "25%";
    const text = vh.fmt(
        \\# void-hardperf-light: settings of vh-stage1 (init/), the values of vh.conf.
        \\# Written by vh-stage1 --install from the core-services scripts that were installed.
        \\VH_SHM_SIZE="{s}"
        \\VH_ZRAM_ALGO="{s}"
        \\VH_ZRAM_PERCENT="{s}"
        \\
    , .{ shm, algo, percent });
    vh.mkdirs(sys.p("/etc/vh"), 0o755);
    if (!sys.writeFile(path, text, 0o644)) vh.die("{s}: {s}", .{ conf, vh.serr() });
    vh.out("wrote {s}: shm {s}, zram {s} {s} percent\n", .{ conf, shm, algo, percent });
}

/// `echo zstd > /sys/block/zram0/comp_algorithm`
pub fn zramAlgo(text: []const u8) ?[]const u8 {
    const tail = " > /sys/block/zram0/comp_algorithm";
    const end = mem.indexOf(u8, text, tail) orelse return null;
    const start = mem.lastIndexOf(u8, text[0..end], "echo ") orelse return null;
    const v = vh.strip(text[start + 5 .. end]);
    return if (v.len == 0 or v[0] == '@') null else v;
}

/// `int($2 * 50 / 100)`
pub fn zramPercent(text: []const u8) ?[]const u8 {
    const tail = " / 100)";
    const end = mem.indexOf(u8, text, tail) orelse return null;
    const start = mem.lastIndexOf(u8, text[0..end], "* ") orelse return null;
    const v = vh.strip(text[start + 2 .. end]);
    return if (v.len == 0 or v[0] == '@') null else v;
}

/// `size=25% /dev/shm`
pub fn shmSize(text: []const u8) ?[]const u8 {
    const start = mem.indexOf(u8, text, "size=") orelse return null;
    var end = start + 5;
    while (end < text.len and text[end] != ' ' and text[end] != ',' and text[end] != '\n') end += 1;
    const v = text[start + 5 .. end];
    return if (v.len == 0 or v[0] == '@') null else v;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "classify stage 1" {
    try testing.expectEqual(Kind.shell, classifyText("#!/bin/sh\n# vim\n"));
    try testing.expectEqual(Kind.vh, classifyText("\x7fELF....vh-stage1: done in...."));
    try testing.expectEqual(Kind.other, classifyText("\x7fELF....something else"));
    try testing.expectEqual(Kind.other, classifyText(""));
}

test "values from the rendered core-services" {
    const zram = "[ -e /sys/block/zram0 ] || modprobe zram\n    echo lz4 > /sys/block/zram0/comp_algorithm\n    _vh_kb=$(awk '/MemTotal/ {print int($2 * 40 / 100)}' /proc/meminfo)\n";
    try testing.expectEqualStrings("lz4", zramAlgo(zram).?);
    try testing.expectEqualStrings("40", zramPercent(zram).?);
    try testing.expectEqualStrings("25%", shmSize("mount -o remount,nosuid,nodev,noexec,size=25% /dev/shm\n").?);
    try testing.expectEqual(@as(?[]const u8, null), zramAlgo("echo @VH_ZRAM_ALGO@ > /sys/block/zram0/comp_algorithm"));
    try testing.expectEqual(@as(?[]const u8, null), shmSize("nothing"));
}
