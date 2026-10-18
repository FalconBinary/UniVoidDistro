//! vh-stage1: what the shared vh library does not have and stage 1 needs: mount(2),
//! the mount table, the kernel log, timing, messages in the runit-void style, user and
//! group lookups, and the test root (--root DIR puts every path under DIR).
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");

pub const MS = linux.MS;
/// mount(2) flag of Linux 5.10 that std.os.linux.MS does not list
pub const MS_NOSYMFOLLOW: u32 = 1 << 8;
pub const SWAP_FLAG_PREFER: u32 = 0x8000;
pub const SWAP_FLAG_PRIO_MASK: u32 = 0x7fff;
pub const SWAP_FLAG_DISCARD: u32 = 0x10000;

/// --root DIR (tests): every path of stage 1 is DIR/path; "" is the real system
pub var root: []const u8 = "";
/// -v: every setting and every program run is printed
pub var verbose = false;
/// stage 1 of a boot (the default) or a test run (--step, --root): no emergency shell in a test
pub var boot_mode = true;
/// steps that reported an error (the boot continues; the count goes to the kmsg summary)
pub var failures: usize = 0;

pub fn p(path: []const u8) []const u8 {
    if (root.len == 0) return path;
    return vh.fmt("{s}{s}", .{ root, path });
}

// ---------------------------------------------------------------- messages (as /etc/runit/functions)

/// "=> text" in bold, like msg() of runit-void
pub fn msg(comptime f: []const u8, args: anytype) void {
    vh.out("\x1b[1m=> " ++ f ++ "\x1b[m\n", args);
    vh.flush();
}

/// "WARNING: text" in bold yellow, like msg_warn()
pub fn warn(comptime f: []const u8, args: anytype) void {
    vh.out("\x1b[1m\x1b[33mWARNING: " ++ f ++ "\x1b[m\n", args);
    vh.flush();
}

/// an error of a step: printed, counted, the boot goes on
pub fn fail(comptime f: []const u8, args: anytype) void {
    failures += 1;
    vh.out("\x1b[1m\x1b[31mERROR: " ++ f ++ "\x1b[m\n", args);
    vh.flush();
}

/// a plain line (the "! ..." notes of the vh scripts)
pub fn note(comptime f: []const u8, args: anytype) void {
    vh.out(f ++ "\n", args);
    vh.flush();
}

/// only with -v
pub fn detail(comptime f: []const u8, args: anytype) void {
    if (!verbose) return;
    vh.out("   " ++ f ++ "\n", args);
    vh.flush();
}

/// The one place a shell is ever started: runit-void's emergency_shell on a failure the
/// boot cannot continue from (root not writable, fstab, swap). In a test run it is a message.
pub fn emergency() void {
    note("\nCannot continue due to errors above, starting emergency shell.\nWhen ready type exit to continue booting.", .{});
    if (!boot_mode) {
        note("(test run: no emergency shell)", .{});
        return;
    }
    _ = vh.run(&.{ "/bin/sh", "-l" });
}

// ---------------------------------------------------------------- the kernel log and time

var kmsg_fd: linux.fd_t = -1;

/// a line into the kernel log (dmesg), level info; silently nothing without /dev/kmsg
pub fn kmsg(comptime f: []const u8, args: anytype) void {
    if (kmsg_fd < 0) kmsg_fd = vh.openFd(p("/dev/kmsg"), .{ .ACCMODE = .WRONLY, .NONBLOCK = true }, 0) catch return;
    const line = vh.fmt("<6>" ++ f ++ "\n", args);
    vh.writeAllFd(kmsg_fd, line) catch {};
}

/// CLOCK_MONOTONIC in microseconds
pub fn monoUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1000)));
}

// ---------------------------------------------------------------- programs

/// Run a program by argv without a shell (PATH lookup); the exit code, 127 if not found.
pub fn exec(argv: []const []const u8) u8 {
    if (verbose) {
        vh.out("   exec:", .{});
        for (argv) |a| vh.out(" {s}", .{a});
        vh.out("\n", .{});
    }
    return vh.run(argv);
}

/// the same with text on stdin
pub fn execIn(argv: []const []const u8, in: []const u8) u8 {
    if (verbose) {
        vh.out("   exec:", .{});
        for (argv) |a| vh.out(" {s}", .{a});
        vh.out(" (with stdin)\n", .{});
    }
    return vh.runOpts(argv, .{ .in = in });
}

/// like `command -v`: the program exists in PATH
pub fn inPath(name: []const u8) bool {
    const path = vh.getenv("PATH") orelse "/usr/bin:/usr/sbin";
    var it = mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (linux.errno(linux.access(vh.z(vh.fmt("{s}/{s}", .{ dir, name })).ptr, linux.X_OK)) == .SUCCESS) return true;
    }
    return false;
}

// ---------------------------------------------------------------- mounts

pub fn mount(src: ?[]const u8, dir: []const u8, fstype: ?[]const u8, flags: u32, data: ?[]const u8) vh.Error!void {
    const s: ?[*:0]const u8 = if (src) |x| vh.z(x).ptr else null;
    const t: ?[*:0]const u8 = if (fstype) |x| vh.z(x).ptr else null;
    const d: usize = if (data) |x| (if (x.len == 0) 0 else @intFromPtr(vh.z(x).ptr)) else 0;
    _ = try vh.sys(linux.mount(s, vh.z(dir).ptr, t, flags, d));
}

/// like `mountpoint -q`: the directory is the root of a mount (its device differs from
/// the parent's, or it is the root inode); works before /proc is mounted
pub fn isMountpoint(path: []const u8) bool {
    const st = vh.stat(path, true) catch return false;
    const parent = vh.stat(vh.fmt("{s}/..", .{path}), true) catch return false;
    if (st.dev_major != parent.dev_major or st.dev_minor != parent.dev_minor) return true;
    return st.ino == parent.ino;
}

/// /proc/self/mountinfo: what is mounted where
pub const MountInfo = struct {
    pub const Entry = struct {
        dev: []const u8, // major:minor
        root: []const u8, // the path inside the file system that is mounted here
        target: []const u8,
        fstype: []const u8,
        source: []const u8,
        opts: []const u8,
    };
    entries: []const Entry = &.{},

    /// the real table (never under --root: the kernel's view is the truth)
    pub fn load() MountInfo {
        const text = vh.readFile("/proc/self/mountinfo") catch return .{};
        return parse(text);
    }

    pub fn parse(text: []const u8) MountInfo {
        var list: std.ArrayList(Entry) = .empty;
        var lines = mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = mem.tokenizeScalar(u8, line, ' ');
            _ = f.next() orelse continue; // id
            _ = f.next() orelse continue; // parent
            const dev = f.next() orelse continue;
            const r = f.next() orelse continue;
            const target = f.next() orelse continue;
            const opts = f.next() orelse continue;
            // optional fields up to "-"
            while (f.next()) |x| if (mem.eql(u8, x, "-")) break;
            const fstype = f.next() orelse continue;
            const source = f.next() orelse continue;
            list.append(vh.gpa, .{ .dev = dev, .root = unescape(r), .target = unescape(target), .fstype = fstype, .source = unescape(source), .opts = opts }) catch vh.oom();
        }
        return .{ .entries = list.items };
    }

    /// something is mounted on target
    pub fn isMounted(self: MountInfo, target: []const u8) bool {
        for (self.entries) |e| if (mem.eql(u8, e.target, target)) return true;
        return false;
    }

    /// a bind mount of source already sits on target (the same device and the same
    /// path inside it), like the "already mounted" check of mount -a
    pub fn isBound(self: MountInfo, source: []const u8, target: []const u8) bool {
        const h = self.holder(source) orelse return false;
        const rel = relIn(h, source);
        for (self.entries) |e| if (mem.eql(u8, e.target, target) and mem.eql(u8, e.dev, h.dev) and mem.eql(u8, e.root, rel)) return true;
        return false;
    }

    /// the mount that holds path: the longest target that is a prefix of it
    pub fn holder(self: MountInfo, path: []const u8) ?Entry {
        var best: ?Entry = null;
        for (self.entries) |e| {
            if (!isPrefixDir(e.target, path)) continue;
            if (best == null or e.target.len >= best.?.target.len) best = e;
        }
        return best;
    }

    /// the path of `path` inside the file system of the mount e
    pub fn relIn(e: Entry, path: []const u8) []const u8 {
        const rest = if (mem.eql(u8, e.target, "/")) path else path[e.target.len..];
        if (rest.len == 0 or mem.eql(u8, rest, "/")) return e.root;
        if (mem.eql(u8, e.root, "/")) return rest;
        return vh.fmt("{s}{s}", .{ e.root, rest });
    }

    fn isPrefixDir(dir: []const u8, path: []const u8) bool {
        if (mem.eql(u8, dir, "/")) return path.len > 0 and path[0] == '/';
        if (!mem.startsWith(u8, path, dir)) return false;
        return path.len == dir.len or path[dir.len] == '/';
    }

    /// \040 and the like in mountinfo and fstab fields
    pub fn unescape(s: []const u8) []const u8 {
        if (mem.indexOfScalar(u8, s, '\\') == null) return s;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\' and i + 3 < s.len and isOct(s[i + 1]) and isOct(s[i + 2]) and isOct(s[i + 3])) {
                out.append(vh.gpa, (s[i + 1] - '0') * 64 + (s[i + 2] - '0') * 8 + (s[i + 3] - '0')) catch vh.oom();
                i += 3;
            } else out.append(vh.gpa, s[i]) catch vh.oom();
        }
        return out.items;
    }

    fn isOct(c: u8) bool {
        return c >= '0' and c <= '7';
    }
};

// ---------------------------------------------------------------- files, users, groups

/// create or truncate a file with the mode (umask does not apply: fchmod), optional owner
pub fn touch(path: []const u8, mode: linux.mode_t, uid: ?u32, gid: ?u32) bool {
    const fd = vh.openFd(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .NOFOLLOW = true }, mode) catch return false;
    defer vh.close(fd);
    _ = vh.sys(linux.fchmod(fd, mode)) catch return false;
    if (uid != null or gid != null) {
        _ = vh.sys(linux.fchown(fd, uid orelse std.math.maxInt(u32), gid orelse std.math.maxInt(u32))) catch return false;
    }
    return true;
}

/// write data into a new file with the mode (an existing file is replaced in place)
pub fn writeFile(path: []const u8, data: []const u8, mode: linux.mode_t) bool {
    const fd = vh.openFd(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true }, mode) catch return false;
    defer vh.close(fd);
    _ = vh.sys(linux.fchmod(fd, mode)) catch return false;
    vh.writeAllFd(fd, data) catch return false;
    return true;
}

/// mkdir -p with the mode on the last directory, then chmod (setgid bits survive umask)
pub fn mkdirMode(path: []const u8, mode: linux.mode_t) bool {
    vh.mkdirs(path, mode & 0o777);
    _ = vh.sys(linux.chmod(vh.z(path).ptr, mode)) catch return false;
    return true;
}

pub fn chown(path: []const u8, uid: u32, gid: u32) bool {
    _ = vh.sys(linux.chown(vh.z(path).ptr, uid, gid)) catch return false;
    return true;
}

/// the GID of a group from /etc/group (under --root: DIR/etc/group)
pub fn groupId(name: []const u8) ?u32 {
    return lookupId(vh.readFile(p("/etc/group")) catch return null, name, 2);
}

pub const User = struct { uid: u32, gid: u32 };

/// the UID and the primary GID of a user from /etc/passwd
pub fn userId(name: []const u8) ?User {
    const text = vh.readFile(p("/etc/passwd")) catch return null;
    const uid = lookupId(text, name, 2) orelse return null;
    const gid = lookupId(text, name, 3) orelse return null;
    return .{ .uid = uid, .gid = gid };
}

/// "name:x:N:..." tables: the numeric field (0-based) of the line whose first field is name
pub fn lookupId(text: []const u8, name: []const u8, field: usize) ?u32 {
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = mem.splitScalar(u8, line, ':');
        const n = f.next() orelse continue;
        if (!mem.eql(u8, n, name)) continue;
        var i: usize = 1;
        while (f.next()) |x| : (i += 1) if (i == field) return std.fmt.parseInt(u32, x, 10) catch null;
        return null;
    }
    return null;
}

/// uname -r
pub fn release() []const u8 {
    var u: linux.utsname = undefined;
    if (linux.errno(linux.uname(&u)) != .SUCCESS) return "";
    return vh.dupe(mem.sliceTo(&u.release, 0));
}

/// the files of a directory sorted by name (nothing on error)
pub fn sortedDir(path: []const u8) []const []const u8 {
    const names = vh.listDir(path) catch return &.{};
    const copy = vh.gpa.dupe([]const u8, names) catch vh.oom();
    mem.sort([]const u8, copy, {}, vh.lessStr);
    return copy;
}

/// the words of a file without the "#" lines (modules.preload and the like)
pub fn words(text: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        var it = mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |w| list.append(vh.gpa, w) catch vh.oom();
    }
    return list.items;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "mountinfo: parse, holder, bind detection" {
    const text =
        \\22 1 259:2 / / rw,noatime - xfs /dev/mapper/cryptroot rw,attr2
        \\23 22 0:21 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw,hidepid=invisible
        \\40 22 259:2 /home /home rw,nosuid,nodev,noexec - xfs /dev/mapper/cryptroot rw
        \\41 22 0:30 / /mnt/with\040space rw - tmpfs tmpfs rw
    ;
    const mi = MountInfo.parse(text);
    try testing.expectEqual(@as(usize, 4), mi.entries.len);
    try testing.expect(mi.isMounted("/proc"));
    try testing.expect(mi.isMounted("/mnt/with space"));
    try testing.expect(!mi.isMounted("/home/xfer"));
    try testing.expect(mi.isBound("/home", "/home"));
    try testing.expect(!mi.isBound("/home/xfer", "/home/xfer"));
    try testing.expect(!mi.isBound("/var/lib/vh-browser", "/var/lib/vh-browser"));
    try testing.expectEqualStrings("/", mi.holder("/etc/fstab").?.target);
    try testing.expectEqualStrings("/home", mi.holder("/home/user/x").?.target);
    try testing.expectEqualStrings("/home/user/x", MountInfo.relIn(mi.holder("/home/user/x").?, "/home/user/x"));
    try testing.expectEqualStrings("/etc", MountInfo.relIn(mi.entries[0], "/etc"));
}

test "mountinfo: octal escapes" {
    try testing.expectEqualStrings("a b", MountInfo.unescape("a\\040b"));
    try testing.expectEqualStrings("a\\04", MountInfo.unescape("a\\04"));
    try testing.expectEqualStrings("tab\t", MountInfo.unescape("tab\\011"));
}

test "lookupId: group and passwd fields" {
    const group = "root:x:0:\nproc:x:981:admin\nutmp:x:22:\n";
    try testing.expectEqual(@as(?u32, 981), lookupId(group, "proc", 2));
    try testing.expectEqual(@as(?u32, 22), lookupId(group, "utmp", 2));
    try testing.expectEqual(@as(?u32, null), lookupId(group, "nobody", 2));
    const passwd = "user:x:1000:1000:User:/home/user:/bin/bash\nbrowser:x:999:998::/var/lib/vh-browser:/usr/bin/nologin\n";
    try testing.expectEqual(@as(?u32, 1000), lookupId(passwd, "user", 2));
    try testing.expectEqual(@as(?u32, 998), lookupId(passwd, "browser", 3));
}

test "words: comments and blank lines are dropped" {
    const w = words("# modules\n\nvfat fat\n  nls_utf8\n; x\n");
    try testing.expectEqual(@as(usize, 3), w.len);
    try testing.expectEqualStrings("nls_utf8", w[2]);
}

test "p: the test root prefix" {
    root = "";
    try testing.expectEqualStrings("/etc/fstab", p("/etc/fstab"));
    root = "/tmp/r";
    try testing.expectEqualStrings("/tmp/r/etc/fstab", p("/etc/fstab"));
    root = "";
}
