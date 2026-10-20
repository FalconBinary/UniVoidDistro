//! /etc/passwd, /etc/shadow, /etc/group and /etc/gshadow: the lines of the game user added, and
//! taken away again exactly. shadow's tools (useradd, userdel, passwd) rewrite the backup copies
//! /etc/passwd-, /etc/shadow-, /etc/group- and /etc/gshadow- at every change, so after them the
//! system would not be what it was byte for byte; vh-game edits the files itself instead, under
//! the lock lckpwdf(3) takes, writing a new file beside the old one and renaming it into place
//! with the old one's owner and mode, as shadow does.
const std = @import("std");
const vh = @import("vh");
const lines = @import("lines.zig");
const linux = std.os.linux;
const mem = std.mem;

/// field I (from 0) of a colon-separated line
pub fn field(line: []const u8, i: usize) ?[]const u8 {
    var it = mem.splitScalar(u8, line, ':');
    var n: usize = 0;
    while (it.next()) |f| : (n += 1) if (n == i) return f;
    return null;
}

/// the line of NAME (its first field)
pub fn find(text: []const u8, name: []const u8) ?[]const u8 {
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        const f = field(l, 0) orelse continue;
        if (vh.eql(f, name)) return l;
    }
    return null;
}

fn idUsed(text: []const u8, id: u32) bool {
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        const f = field(l, 2) orelse continue;
        const n = std.fmt.parseInt(u32, f, 10) catch continue;
        if (n == id) return true;
    }
    return false;
}

/// the smallest id from MIN to MAX that is neither a user's nor a group's: the user and its own
/// group get the same number, as useradd gives them (login.defs: UID_MIN 1000, UID_MAX 60000)
pub fn freeId(passwd: []const u8, group: []const u8, min: u32, max: u32) ?u32 {
    var id = min;
    while (id <= max) : (id += 1) {
        if (!idUsed(passwd, id) and !idUsed(group, id)) return id;
    }
    return null;
}

/// group or gshadow: USER appended to the member list of GROUP (the fourth field of both
/// files); null when there is no such group, the text itself when USER is in it already
pub fn addMember(text: []const u8, group: []const u8, user: []const u8) ?[]u8 {
    return editMembers(text, group, user, true);
}

/// the inverse of addMember: USER taken out of GROUP's member list, the others in their order
pub fn removeMember(text: []const u8, group: []const u8, user: []const u8) ?[]u8 {
    return editMembers(text, group, user, false);
}

fn editMembers(text: []const u8, group: []const u8, user: []const u8, add: bool) ?[]u8 {
    const line = find(text, group) orelse return null;
    // the fourth field is the last one in both files: the members, comma-separated
    var cut: usize = 0;
    var colons: usize = 0;
    for (line, 0..) |c, i| if (c == ':') {
        colons += 1;
        if (colons == 3) {
            cut = i + 1;
            break;
        }
    };
    if (colons < 3) return null;
    const head = line[0..cut];
    const members = line[cut..];
    var list: vh.Strv = .{};
    var present = false;
    var it = mem.splitScalar(u8, members, ',');
    while (it.next()) |m| {
        if (m.len == 0) continue;
        if (vh.eql(m, user)) {
            present = true;
            if (!add) continue;
        }
        list.add(m);
    }
    if (add and present) return vh.dupe(text);
    if (add) list.add(user);
    const new_line = vh.fmt("{s}{s}", .{ head, list.join(",") });
    const at = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
    return vh.fmt("{s}{s}{s}", .{ text[0..at], new_line, text[at + line.len ..] });
}

/// The four files of a system root under the lock of lckpwdf(3): fcntl F_SETLKW on
/// /etc/.pwd.lock, which a system shadow's tools have run on already has. A lock file vh-game had
/// to create is removed again when it unlocks.
pub const Files = struct {
    prefix: []const u8,
    lock_fd: vh.fd_t,
    created: bool,

    pub fn lock(prefix: []const u8) Files {
        const lock_path = vh.fmt("{s}/etc/.pwd.lock", .{prefix});
        const existed = vh.pathExists(lock_path);
        const fd = vh.openFd(lock_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .NOFOLLOW = true }, 0o600) catch vh.die("{s}: {s}", .{ lock_path, vh.serr() });
        var fl = mem.zeroes(linux.Flock);
        fl.type = linux.F.WRLCK;
        fl.whence = linux.SEEK.SET;
        _ = vh.sysRetry(linux.fcntl, .{ fd, linux.F.SETLKW, @intFromPtr(&fl) }) catch vh.die("{s}: lock: {s}", .{ lock_path, vh.serr() });
        return .{ .prefix = prefix, .lock_fd = fd, .created = !existed };
    }

    pub fn unlock(self: Files) void {
        if (self.created) vh.unlink(vh.fmt("{s}/etc/.pwd.lock", .{self.prefix})) catch {};
        vh.close(self.lock_fd);
    }

    pub fn path(self: Files, name: []const u8) []const u8 {
        return vh.fmt("{s}/etc/{s}", .{ self.prefix, name });
    }

    /// the file's text; null when it does not exist (gshadow is optional)
    pub fn read(self: Files, name: []const u8) ?[]u8 {
        return vh.readFile(self.path(name)) catch |e| switch (e) {
            error.Sys => if (vh.errno == .NOENT) null else vh.die("{s}: {s}", .{ self.path(name), vh.serr() }),
        };
    }

    /// the file replaced by DATA: NAME+ with the old file's owner and mode, synced, renamed
    pub fn write(self: Files, name: []const u8, data: []const u8) void {
        const dst = self.path(name);
        const old = vh.stat(dst, false) catch vh.die("{s}: {s}", .{ dst, vh.serr() });
        const tmp = vh.fmt("{s}+", .{dst});
        vh.unlink(tmp) catch {};
        const fd = vh.openFd(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600) catch vh.die("{s}: {s}", .{ tmp, vh.serr() });
        vh.writeAllFd(fd, data) catch vh.die("{s}: {s}", .{ tmp, vh.serr() });
        _ = vh.sys(linux.fchown(fd, old.uid, old.gid)) catch vh.die("{s}: {s}", .{ tmp, vh.serr() });
        _ = vh.sys(linux.fchmod(fd, old.mode & 0o7777)) catch vh.die("{s}: {s}", .{ tmp, vh.serr() });
        _ = vh.sys(linux.fsync(fd)) catch vh.die("{s}: {s}", .{ tmp, vh.serr() });
        vh.close(fd);
        _ = vh.sys(linux.rename(vh.z(tmp).ptr, vh.z(dst).ptr)) catch vh.die("{s}: {s}", .{ dst, vh.serr() });
    }
};

/// The account of the gaming session: what install writes and remove takes away.
pub const User = struct {
    name: []const u8,
    id: u32,
    gecos: []const u8,
    home: []const u8,
    shell: []const u8,
    /// the yescrypt hash, "$y$..."
    hash: []const u8,
    /// days since 1970 for shadow's last change
    days: i64,

    pub fn passwdLine(u: User) []const u8 {
        return vh.fmt("{s}:x:{d}:{d}:{s}:{s}:{s}", .{ u.name, u.id, u.id, u.gecos, u.home, u.shell });
    }
    pub fn shadowLine(u: User) []const u8 {
        return vh.fmt("{s}:{s}:{d}:0:99999:7:::", .{ u.name, u.hash, u.days });
    }
    pub fn groupLine(u: User) []const u8 {
        return vh.fmt("{s}:x:{d}:", .{ u.name, u.id });
    }
    pub fn gshadowLine(u: User) []const u8 {
        return vh.fmt("{s}:!::", .{u.name});
    }
};

/// Every line of NAME taken out of the four files, and NAME out of the member lists of GROUPS.
/// Absent lines are skipped: removal also undoes an install that stopped halfway.
pub fn removeUser(f: Files, name: []const u8, groups: []const []const u8) void {
    for ([_][]const u8{ "passwd", "shadow", "group", "gshadow" }) |file| {
        var text = f.read(file) orelse continue;
        var changed = false;
        if (find(text, name)) |l| {
            text = lines.remove(text, vh.dupe(l)).?;
            changed = true;
        }
        if (vh.eql(file, "group") or vh.eql(file, "gshadow")) for (groups) |g| {
            const before = text;
            text = removeMember(text, g, name) orelse continue;
            changed = changed or !vh.eql(before, text);
        };
        if (changed) f.write(file, text);
    }
}

const t = std.testing;

test "the game user's lines and their exact removal" {
    const passwd = "root:x:0:0:root:/root:/bin/bash\nadmin:x:1000:1000::/home/admin:/bin/bash\nuser:x:1001:1001::/home/user:/bin/bash\nbrowser:x:999:999::/var/lib/vh-browser:/usr/bin/nologin\n";
    const group = "root:x:0:\n_seatd:x:996:user\nrender:x:995:user,browser\nadmin:x:1000:\nuser:x:1001:\nxfer:x:1002:user,browser\n";
    const gshadow = "root:::\n_seatd:!::user\nrender:!::user,browser\n";
    const id = freeId(passwd, group, 1000, 60000).?;
    // 1000 and 1001 are users, 1002 a group: the user and its group get 1003
    try t.expectEqual(@as(u32, 1003), id);
    const u: User = .{ .name = "game", .id = id, .gecos = "gaming session", .home = "/home/game", .shell = "/usr/local/bin/vh-game-enter", .hash = "$y$j9T$salt$hash", .days = 20381 };
    try t.expectEqualStrings("game:x:1003:1003:gaming session:/home/game:/usr/local/bin/vh-game-enter", u.passwdLine());
    try t.expectEqualStrings("game:$y$j9T$salt$hash:20381:0:99999:7:::", u.shadowLine());
    // install: the account, its group, the members
    const p2 = lines.append(passwd, u.passwdLine());
    var g2 = lines.append(group, u.groupLine());
    g2 = addMember(g2, "_seatd", "game").?;
    g2 = addMember(g2, "render", "game").?;
    try t.expectEqualStrings("root:x:0:\n_seatd:x:996:user,game\nrender:x:995:user,browser,game\nadmin:x:1000:\nuser:x:1001:\nxfer:x:1002:user,browser\ngame:x:1003:\n", g2);
    var gs2 = addMember(lines.append(gshadow, u.gshadowLine()), "_seatd", "game").?;
    gs2 = addMember(gs2, "render", "game").?;
    // adding twice changes nothing; a group that is not there is null
    try t.expectEqualStrings(g2, addMember(g2, "render", "game").?);
    try t.expect(addMember(g2, "video", "game") == null);
    // remove: the same bytes as before
    try t.expectEqualStrings(passwd, lines.remove(p2, find(p2, "game").?).?);
    var g3 = lines.remove(g2, find(g2, "game").?).?;
    g3 = removeMember(g3, "_seatd", "game").?;
    g3 = removeMember(g3, "render", "game").?;
    try t.expectEqualStrings(group, g3);
    var gs3 = lines.remove(gs2, find(gs2, "game").?).?;
    gs3 = removeMember(gs3, "_seatd", "game").?;
    gs3 = removeMember(gs3, "render", "game").?;
    try t.expectEqualStrings(gshadow, gs3);
    // an empty member list
    try t.expectEqualStrings("audio:x:12:game\n", addMember("audio:x:12:\n", "audio", "game").?);
    try t.expectEqualStrings("audio:x:12:\n", removeMember("audio:x:12:game\n", "audio", "game").?);
    // another user whose name contains game's stays
    try t.expectEqualStrings("g:x:5:gamer\n", removeMember("g:x:5:gamer,game\n", "g", "game").?);
}

test "the lock file and the replaced files keep owner and mode" {
    const dir = "/tmp/vh-session-accounts-test";
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    vh.mkdirs(dir ++ "/etc", 0o755);
    vh.writeAtomic(dir ++ "/etc/shadow", "root:!:20000:0:99999:7:::\n", 0o600);
    vh.writeAtomic(dir ++ "/etc/passwd", "root:x:0:0:root:/root:/bin/bash\n", 0o644);
    const f = Files.lock(dir);
    try t.expect(f.created);
    try t.expect(f.read("gshadow") == null);
    f.write("shadow", lines.append(f.read("shadow").?, "game:$y$x:1:0:99999:7:::"));
    const st = try vh.stat(dir ++ "/etc/shadow", false);
    try t.expectEqual(@as(u32, 0o600), st.mode & 0o7777);
    try t.expect(!vh.pathExists(dir ++ "/etc/shadow+"));
    removeUser(f, "game", &.{});
    try t.expectEqualStrings("root:!:20000:0:99999:7:::\n", f.read("shadow").?);
    f.unlock();
    // the lock file vh-game created is gone again
    try t.expect(!vh.pathExists(dir ++ "/etc/.pwd.lock"));
}
