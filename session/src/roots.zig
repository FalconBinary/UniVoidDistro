//! The roots of vh-root: /var/lib/vh/roots/NAME, each a Void userland of its own that thor
//! installs with `-r ROOT` under the root's own policy (ROOT/etc/thor: thor's deny list holds in
//! every root, and the profile's exceptions in that root only). The system's packages, its thor
//! policy and its deny list do not change.
//!
//! /var/lib/vh/roots is a bind mount of itself with nosuid and nodev (an fstab line made with the
//! first root and taken away with the last): even a SUID bit thor missed, or a device node a
//! package script made, means nothing there. thor strips SUID bits and file capabilities
//! anyway, in every root.
const std = @import("std");
const vh = @import("vh");
const profiles = @import("profiles");
const common = @import("common.zig");
const lines = @import("lines.zig");
const rmtree = @import("rmtree.zig");
const sys = @import("sys.zig");
const linux = std.os.linux;
const mem = std.mem;

const Profile = profiles.Profile;

pub const Opts = struct {
    sys: common.System = .{},
    /// the package manager (the tests give a stand-in with thor's arguments)
    thor: []const u8 = "/usr/bin/thor",
};

/// what /var/lib/vh/roots/.vh-root records: the directories vh-root made for the first root
const marker = "/.vh-root";

pub fn path(o: Opts, name: []const u8) []const u8 {
    return o.sys.path(vh.fmt("{s}/{s}", .{ common.roots_dir, name }));
}

pub fn exists(o: Opts, name: []const u8) bool {
    return vh.isDir(path(o, name));
}

/// The directory of every root, its fstab line and its mount (nosuid, nodev), made with the
/// first root; /var/lib/vh too when it was not there, so that the last root's removal can take
/// away exactly what the first one brought. A root's own user (game) has to pass through
/// /var/lib/vh: one that only root may enter (vh-limine-update makes it 0700) gets the search
/// bit for others while a root exists, and its mode back with the last one.
fn ensureRootsDir(o: Opts) void {
    const roots = o.sys.path(common.roots_dir);
    if (!vh.isDir(roots)) {
        var text: std.ArrayList(u8) = .empty;
        text.appendSlice(vh.gpa, "# vh-root: what the first root brought, which the last one's removal takes away\n") catch vh.oom();
        const vd = o.sys.path(common.vh_dir);
        if (!vh.isDir(vd)) {
            sys.mkdir(vd, 0o755) catch vh.die("{s}: {s}", .{ vd, vh.serr() });
            sys.chmod(vd, 0o755) catch vh.die("{s}: {s}", .{ vd, vh.serr() });
            text.print(vh.gpa, "made {s}\n", .{common.vh_dir}) catch vh.oom();
        } else {
            const st = vh.stat(vd, false) catch vh.die("{s}: {s}", .{ vd, vh.serr() });
            const mode = st.mode & 0o7777;
            if (mode & 0o001 == 0) {
                sys.chmod(vd, mode | 0o001) catch vh.die("{s}: {s}", .{ vd, vh.serr() });
                text.print(vh.gpa, "mode {s} {o}\n", .{ common.vh_dir, mode }) catch vh.oom();
            }
        }
        sys.mkdir(roots, 0o755) catch vh.die("{s}: {s}", .{ roots, vh.serr() });
        sys.chmod(roots, 0o755) catch vh.die("{s}: {s}", .{ roots, vh.serr() });
        vh.writeAtomic(vh.fmt("{s}{s}", .{ roots, marker }), text.items, 0o644);
    }
    const fstab = o.sys.path("/etc/fstab");
    const line = common.fstabBind(common.roots_dir);
    const text = vh.readFile(fstab) catch vh.die("{s}: {s}", .{ fstab, vh.serr() });
    if (!lines.has(text, line)) writeKeeping(fstab, lines.append(text, line));
    if (!isMountPoint(roots)) sys.bind(roots, roots, sys.MS.NOSUID | sys.MS.NODEV) catch vh.die("mount {s}: {s}", .{ roots, vh.serr() });
}

/// the roots directory, its mount and fstab line, and what the first root made, after the last
/// root is gone
fn dropRootsDir(o: Opts) void {
    const roots = o.sys.path(common.roots_dir);
    if (!vh.isDir(roots)) return;
    for (vh.listDir(roots) catch &.{}) |n| if (!vh.eql(n, marker[1..])) return;
    if (isMountPoint(roots)) sys.umount(roots, 0) catch vh.die("umount {s}: {s}", .{ roots, vh.serr() });
    const fstab = o.sys.path("/etc/fstab");
    const text = vh.readFile(fstab) catch vh.die("{s}: {s}", .{ fstab, vh.serr() });
    if (lines.remove(text, common.fstabBind(common.roots_dir))) |new| writeKeeping(fstab, new);
    const made = vh.readFile(vh.fmt("{s}{s}", .{ roots, marker })) catch "";
    vh.unlink(vh.fmt("{s}{s}", .{ roots, marker })) catch {};
    _ = vh.sys(linux.rmdir(vh.z(roots).ptr)) catch vh.die("{s}: {s}", .{ roots, vh.serr() });
    var it = mem.splitScalar(u8, made, '\n');
    while (it.next()) |l| {
        if (vh.startsWith(l, "made ")) {
            const d = o.sys.path(l[5..]);
            // only when empty: something else may have moved in meanwhile
            _ = linux.rmdir(vh.z(d).ptr);
        } else if (vh.startsWith(l, "mode ")) {
            var f = mem.tokenizeScalar(u8, l[5..], ' ');
            const d = o.sys.path(f.next() orelse continue);
            const m = std.fmt.parseInt(u32, f.next() orelse continue, 8) catch continue;
            sys.chmod(d, m) catch vh.die("{s}: {s}", .{ d, vh.serr() });
        }
    }
}

pub fn isMountPoint(p: []const u8) bool {
    const info = vh.readFile("/proc/self/mountinfo") catch return false;
    for (rmtree.mountsUnder(info, p)) |m| if (vh.eql(m, p)) return true;
    return false;
}

/// a file of the system replaced in place, keeping its owner and mode
pub fn writeKeeping(p: []const u8, data: []const u8) void {
    const st = vh.stat(p, true) catch vh.die("{s}: {s}", .{ p, vh.serr() });
    vh.writeAtomic(p, data, st.mode & 0o7777);
    sys.chown(p, st.uid, st.gid) catch vh.die("{s}: {s}", .{ p, vh.serr() });
}

fn copyFile(src: []const u8, dst: []const u8, mode: u32) void {
    const data = vh.readFile(src) catch vh.die("{s}: {s}", .{ src, vh.serr() });
    vh.writeAtomic(dst, data, mode);
}

/// Create the root NAME of PROFILE with its packages and EXTRA (the plan's packages for this
/// machine). The root stays 0700 root:root while thor fills it; at the end it gets the
/// profile's mode and the group GID. A failure removes what was made.
pub fn create(o: Opts, name: []const u8, profile: Profile, extra: []const []const u8, gid: ?u32) void {
    if (!common.validName(name)) vh.die("{s}: a root's name is lowercase letters, digits and -", .{name});
    if (exists(o, name)) vh.die("the root {s} exists already: {s}", .{ name, path(o, name) });
    ensureRootsDir(o);
    const root = path(o, name);
    sys.mkdir(root, 0o700) catch vh.die("{s}: {s}", .{ root, vh.serr() });
    errdefer_remove = .{ .o = o, .name = name };
    defer errdefer_remove = null;

    // the repository keys of the system (xbps checks every package's signature with them)
    vh.mkdirs(vh.fmt("{s}/var/db/xbps/keys", .{root}), 0o755);
    const keys = o.sys.path("/var/db/xbps/keys");
    const names = vh.listDir(keys) catch vh.die("{s}: {s}", .{ keys, vh.serr() });
    var n_keys: usize = 0;
    for (names) |k| if (vh.endsWith(k, ".plist")) {
        copyFile(vh.fmt("{s}/{s}", .{ keys, k }), vh.fmt("{s}/var/db/xbps/keys/{s}", .{ root, k }), 0o644);
        n_keys += 1;
    };
    if (n_keys == 0) fail("{s}: no repository key", .{keys});
    // the repositories of the system, and what the root does not extract
    vh.mkdirs(vh.fmt("{s}/etc/xbps.d", .{root}), 0o755);
    for (profile.repositories) |r| {
        const src = o.sys.path(vh.fmt("/etc/xbps.d/{s}", .{r}));
        if (!vh.isRegular(src)) fail("{s}: not there; the root takes its repositories from the system's", .{src});
        copyFile(src, vh.fmt("{s}/etc/xbps.d/{s}", .{ root, r }), 0o644);
    }
    if (profile.noextract.len > 0) {
        var ne: std.ArrayList(u8) = .empty;
        ne.appendSlice(vh.gpa, "# vh-root: not extracted in this root (its profile)\n") catch vh.oom();
        for (profile.noextract) |p| ne.print(vh.gpa, "noextract={s}\n", .{p}) catch vh.oom();
        vh.writeAtomic(vh.fmt("{s}/etc/xbps.d/30-vh-noextract.conf", .{root}), ne.items, 0o644);
    }
    // the root's thor policy: learn while the profile's packages go in, as the installer does
    // for the system, then enforce; the deny list holds but for the profile's exceptions
    vh.mkdirs(vh.fmt("{s}/etc/thor", .{root}), 0o755);
    setPolicy(root, "learn");
    var allow: std.ArrayList(u8) = .empty;
    allow.appendSlice(vh.gpa, vh.fmt("# vh-root: names of thor's deny list allowed in this root only (profile {s})\n", .{profile.name})) catch vh.oom();
    for (profile.allow) |a| allow.print(vh.gpa, "{s}\n", .{a}) catch vh.oom();
    vh.writeAtomic(vh.fmt("{s}/etc/thor/allow.conf", .{root}), allow.items, 0o644);
    vh.writeAtomic(vh.fmt("{s}/etc/vh-root", .{root}), vh.fmt("# vh-root: this root's profile\nprofile={s}\n", .{profile.name}), 0o644);

    var pkgs: vh.Strv = .{};
    for (profile.packages) |p| pkgs.add(p);
    for (extra) |p| if (!pkgs.has(p)) pkgs.add(p);
    if (thor(o, root, "install", pkgs.slice()) != 0) fail("thor could not install the root's packages (above)", .{});
    setPolicy(root, "enforce");
    dropCache(root);

    sys.chmod(root, profile.mode) catch vh.die("{s}: {s}", .{ root, vh.serr() });
    if (gid) |g| sys.chown(root, 0, g) catch vh.die("{s}: {s}", .{ root, vh.serr() });
    vh.log("created the root {s} ({s}): {d} packages asked for, {d} MiB", .{ name, profile.name, pkgs.len(), sizeMiB(root) });
}

/// thor in a root: install PKG..., or update
fn thor(o: Opts, root: []const u8, cmd: []const u8, pkgs: []const []const u8) u8 {
    // strict network mode (optional/strict-net): thor opens the mirrors itself only for the
    // system, not for -r
    const strict = o.sys.path("/etc/vh/optional/strict-net");
    if (vh.pathExists(strict)) _ = vh.run(&.{ o.sys.path("/usr/local/sbin/vh-net"), "xbps", "60" });
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(vh.gpa, &.{ o.thor, cmd, "-y", "-r", root }) catch vh.oom();
    argv.appendSlice(vh.gpa, pkgs) catch vh.oom();
    return vh.run(argv.items);
}

fn setPolicy(root: []const u8, mode: []const u8) void {
    vh.writeAtomic(vh.fmt("{s}/etc/thor/policy.conf", .{root}), vh.fmt("# thor (docs/18): enforce -- the policy applies; learn -- only while the root is being made\nmode={s}\n", .{mode}), 0o644);
}

/// the downloaded packages: xbps keeps them in the root, nothing needs them after the install
fn dropCache(root: []const u8) void {
    const cache = vh.fmt("{s}/var/cache/xbps", .{root});
    if (!vh.isDir(cache)) return;
    for (vh.listDir(cache) catch &.{}) |n| {
        const p = vh.fmt("{s}/{s}", .{ cache, n });
        if (vh.isDir(p)) rmtree.removeTree(p) else vh.unlink(p) catch {};
    }
}

/// packages into a root (the root's policy applies)
pub fn install(o: Opts, name: []const u8, pkgs: []const []const u8) u8 {
    if (!exists(o, name)) vh.die("no root {s}", .{name});
    const rc = thor(o, path(o, name), "install", pkgs);
    dropCache(path(o, name));
    return rc;
}

pub fn update(o: Opts, name: []const u8) u8 {
    if (!exists(o, name)) vh.die("no root {s}", .{name});
    const rc = thor(o, path(o, name), "update", &.{});
    dropCache(path(o, name));
    return rc;
}

/// The root and everything in it. Refused while a process lives in it (its root or its working
/// directory there): vh-game remove ends the session first.
pub fn remove(o: Opts, name: []const u8) void {
    if (!common.validName(name)) vh.die("{s}: not a root's name", .{name});
    const root = path(o, name);
    if (vh.isDir(root)) {
        if (userOf(root)) |pid| vh.die("process {d} works in {s}: end it first", .{ pid, root });
        rmtree.removeTree(root);
        vh.log("removed the root {s}", .{name});
    }
    dropRootsDir(o);
}

/// a process whose root directory or working directory is ROOT or below it
fn userOf(root: []const u8) ?linux.pid_t {
    const names = vh.listDir("/proc") catch return null;
    for (names) |n| {
        const pid = std.fmt.parseInt(linux.pid_t, n, 10) catch continue;
        for ([_][]const u8{ "root", "cwd" }) |what| {
            const l = vh.readlink(vh.fmt("/proc/{d}/{s}", .{ pid, what })) catch continue;
            if (vh.eql(l, root) or (vh.startsWith(l, root) and l.len > root.len and l[root.len] == '/')) return pid;
        }
    }
    return null;
}

/// the disk space of a tree in MiB (st_blocks, hard links counted once per inode is not needed:
/// xbps makes none across packages)
pub fn sizeMiB(p: []const u8) u64 {
    const fd = vh.openFd(p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true }, 0) catch return 0;
    defer vh.close(fd);
    return blocks(fd) * 512 / (1024 * 1024);
}

fn blocks(dfd: vh.fd_t) u64 {
    var sum: u64 = 0;
    for (vh.listDirFd(dfd) catch return 0) |n| {
        const st = vh.statAt(dfd, n, false) catch continue;
        sum += st.blocks;
        if (vh.S.isDir(st.mode)) {
            const sub = vh.openAt(dfd, n, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true }) catch continue;
            sum += blocks(sub);
            vh.close(sub);
        }
    }
    return sum;
}

/// the number of packages of a root's pkgdb
pub fn packageCount(root: []const u8) usize {
    const db = vh.readFile(vh.fmt("{s}/var/db/xbps/pkgdb-0.38.plist", .{root})) catch return 0;
    return mem.count(u8, db, "<key>pkgver</key>");
}

pub fn list(o: Opts) void {
    const roots = o.sys.path(common.roots_dir);
    const names = vh.listDir(roots) catch {
        vh.outs("no roots\n");
        return;
    };
    var sorted: vh.Strv = .{};
    for (names) |n| if (vh.isDir(vh.fmt("{s}/{s}", .{ roots, n }))) sorted.add(n);
    sorted.sort();
    if (sorted.len() == 0) vh.outs("no roots\n");
    for (sorted.slice()) |n| {
        const r = vh.fmt("{s}/{s}", .{ roots, n });
        var kv: vh.Kv = .{};
        kv.read(vh.fmt("{s}/etc/vh-root", .{r}), false);
        var pol: vh.Kv = .{};
        pol.read(vh.fmt("{s}/etc/thor/policy.conf", .{r}), false);
        vh.out("{s}\tprofile {s}\t{d} packages\t{d} MiB\tthor policy {s}\n", .{ n, kv.get("profile", "?"), packageCount(r), sizeMiB(r), pol.get("mode", "?") });
    }
}

// a failure while a root is made takes it away again (and the roots directory, if it was the first)
var errdefer_remove: ?struct { o: Opts, name: []const u8 } = null;
/// what a caller that made more than the root says after such a failure (vh-game: its account)
pub var after_failure: []const u8 = "";

fn fail(comptime f: []const u8, args: anytype) noreturn {
    vh.warn(f, args);
    if (errdefer_remove) |r| {
        errdefer_remove = null;
        vh.warn("removing the unfinished root {s}", .{r.name});
        remove(r.o, r.name);
    }
    if (after_failure.len > 0) vh.warn("{s}", .{after_failure});
    vh.exit(1);
}

const t = std.testing;

test "the place of a root" {
    try t.expectEqualStrings("/tmp/x/var/lib/vh/roots/game", path(.{ .sys = .{ .prefix = "/tmp/x" } }, "game"));
    try t.expectEqualStrings("/var/lib/vh/roots/game", path(.{}, "game"));
}
