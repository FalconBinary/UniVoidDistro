//! Removing a directory tree: vh-root remove and vh-game remove delete the gaming root and the
//! game user's home. No symlink is followed (every entry is opened relative to its directory
//! with O_NOFOLLOW), and a tree that has a file system mounted inside is refused, so that a bind
//! mount left behind cannot lead the removal into the rest of the system.
const std = @import("std");
const vh = @import("vh");
const linux = std.os.linux;
const mem = std.mem;

/// a path of /proc/self/mountinfo: \040 (space), \011 (tab), \012 (newline), \134 (backslash)
pub fn unescape(s: []const u8) []const u8 {
    if (mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 3 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 4], 8)) |c| {
                out.append(vh.gpa, c) catch vh.oom();
                i += 4;
                continue;
            } else |_| {}
        }
        out.append(vh.gpa, s[i]) catch vh.oom();
        i += 1;
    }
    return out.items;
}

/// the mount points (field 5 of mountinfo) that are PATH or below it
pub fn mountsUnder(mountinfo: []const u8, path: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = mem.splitScalar(u8, mountinfo, '\n');
    while (it.next()) |line| {
        var f = mem.tokenizeScalar(u8, line, ' ');
        _ = f.next() orelse continue;
        _ = f.next() orelse continue;
        _ = f.next() orelse continue;
        _ = f.next() orelse continue;
        const mp = unescape(f.next() orelse continue);
        if (vh.eql(mp, path) or (vh.startsWith(mp, path) and mp.len > path.len and mp[path.len] == '/'))
            out.append(vh.gpa, mp) catch vh.oom();
    }
    return out.items;
}

/// PATH and everything below it; dies on an error, and before removing anything when a file
/// system is mounted at PATH or below it
pub fn removeTree(path: []const u8) void {
    const info = vh.readFile("/proc/self/mountinfo") catch vh.die("/proc/self/mountinfo: {s}", .{vh.serr()});
    const busy = mountsUnder(info, path);
    if (busy.len > 0) vh.die("{s}: a file system is mounted at {s}: unmount it first", .{ path, busy[0] });
    const st = vh.stat(path, false) catch |e| switch (e) {
        error.Sys => if (vh.errno == .NOENT) return else vh.die("{s}: {s}", .{ path, vh.serr() }),
    };
    if (!vh.S.isDir(st.mode)) vh.die("{s}: not a directory", .{path});
    const fd = vh.openFd(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true }, 0) catch vh.die("{s}: {s}", .{ path, vh.serr() });
    emptyDir(fd, path, st.dev_major, st.dev_minor);
    vh.close(fd);
    _ = vh.sys(linux.rmdir(vh.z(path).ptr)) catch vh.die("{s}: {s}", .{ path, vh.serr() });
}

fn emptyDir(dfd: vh.fd_t, where: []const u8, major: u32, minor: u32) void {
    const names = vh.listDirFd(dfd) catch vh.die("{s}: {s}", .{ where, vh.serr() });
    for (names) |name| {
        const full = vh.fmt("{s}/{s}", .{ where, name });
        const st = vh.statAt(dfd, name, false) catch vh.die("{s}: {s}", .{ full, vh.serr() });
        if (vh.S.isDir(st.mode)) {
            // another file system here would be a mount the check above did not see: stop
            if (st.dev_major != major or st.dev_minor != minor) vh.die("{s}: on another file system", .{full});
            const sub = vh.openAt(dfd, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true }) catch vh.die("{s}: {s}", .{ full, vh.serr() });
            emptyDir(sub, full, major, minor);
            vh.close(sub);
            vh.unlinkAt(dfd, name, true) catch vh.die("{s}: {s}", .{ full, vh.serr() });
        } else {
            vh.unlinkAt(dfd, name, false) catch vh.die("{s}: {s}", .{ full, vh.serr() });
        }
    }
}

const t = std.testing;

test "mountinfo: the mounts below a path, escaped names" {
    const info =
        \\22 1 254:0 / / rw,noatime - xfs /dev/mapper/cryptroot rw
        \\40 22 254:0 /var/lib/vh/roots /var/lib/vh/roots rw,nosuid,nodev - xfs /dev/mapper/cryptroot rw
        \\41 22 254:0 /home/game /home/game rw,nosuid,nodev - xfs /dev/mapper/cryptroot rw
        \\42 22 0:30 / /home/gamer rw - tmpfs tmpfs rw
        \\43 40 0:31 / /var/lib/vh/roots/game/my\040dir rw - tmpfs tmpfs rw
    ;
    const a = mountsUnder(info, "/var/lib/vh/roots/game");
    try t.expectEqual(@as(usize, 1), a.len);
    try t.expectEqualStrings("/var/lib/vh/roots/game/my dir", a[0]);
    try t.expectEqual(@as(usize, 1), mountsUnder(info, "/home/game").len);
    try t.expectEqual(@as(usize, 2), mountsUnder(info, "/var/lib/vh/roots").len);
    try t.expectEqualStrings("a\\b", unescape("a\\134b"));
}

test "a tree is removed, a symlink out of it is not followed" {
    const dir = "/tmp/vh-session-rmtree-test";
    _ = vh.runOpts(&.{ "rm", "-rf", dir, dir ++ "-outside" }, .{});
    vh.mkdirs(dir ++ "/a/b/c", 0o755);
    vh.mkdirs(dir ++ "-outside", 0o755);
    vh.writeAtomic(dir ++ "-outside/keep", "x", 0o644);
    vh.writeAtomic(dir ++ "/a/b/c/f", "y", 0o644);
    _ = try vh.sys(linux.symlink(dir ++ "-outside", dir ++ "/a/link"));
    _ = try vh.sys(linux.symlink(dir ++ "-outside/keep", dir ++ "/a/b/keep"));
    removeTree(dir);
    try t.expect(!vh.pathExists(dir));
    try t.expect(vh.isRegular(dir ++ "-outside/keep"));
    // a path that is not there is not an error
    removeTree(dir);
}
