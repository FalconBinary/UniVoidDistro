//! What vh-root, vh-game and vh-game-enter share: the places and the names of the gaming
//! session, and the system root they act on (a directory in the tests, "/" on a machine).
const std = @import("std");
const vh = @import("vh");
const linux = std.os.linux;

/// every root of vh-root: /var/lib/vh/roots/NAME
pub const roots_dir = "/var/lib/vh/roots";
pub const vh_dir = "/var/lib/vh";

/// the gaming session (vh-game)
pub const game = struct {
    pub const user = "game";
    /// the name of its root under roots_dir
    pub const root = "game";
    pub const home = "/home/game";
    pub const shell = "/usr/local/bin/vh-game-enter";
    pub const tty = "tty3";
    pub const gecos = "gaming session (vh-game)";
    /// seatd's socket (gamescope's DRM and input through it) and the GPU's render nodes; never
    /// input (seatd hands the active session its devices), video or audio
    pub const groups = [_][]const u8{ "_seatd", "render" };
    /// the getty of tty3, started and stopped by vh-game tty, never by the boot
    pub const getty = "/etc/sv/agetty-tty3";
};

/// The system root the programs act on: "" is the machine itself; the tests give a directory
/// that holds a system's files.
pub const System = struct {
    prefix: []const u8 = "",

    pub fn path(s: System, p: []const u8) []const u8 {
        return vh.fmt("{s}{s}", .{ s.prefix, p });
    }
};

pub fn needRoot(what: []const u8) void {
    if (linux.geteuid() != 0) vh.die("run: doas {s}", .{what});
}

/// the fstab line of a bind mount of PATH onto itself: no SUID bit, no device node, exec allowed
pub fn fstabBind(path: []const u8) []const u8 {
    return vh.fmt("{s}\t{s}\tnone\tbind,nosuid,nodev\t0 0", .{ path, path });
}

/// a root's or user's name: lowercase letters, digits and "-", from a letter, at most 31
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 31 or !std.ascii.isLower(name[0])) return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return true;
}

/// KEY='value' of a plan.env line (vh-plan writes nothing else); null when KEY is not there
pub fn planValue(env: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, env, '\n');
    while (it.next()) |l| {
        if (!vh.startsWith(l, key) or l.len < key.len + 3 or l[key.len] != '=') continue;
        const v = l[key.len + 1 ..];
        if (v.len < 2 or v[0] != '\'' or v[v.len - 1] != '\'') return null;
        return v[1 .. v.len - 1];
    }
    return null;
}

/// a word list of a plan value, "a b c"
pub fn words(s: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    while (it.next()) |w| out.append(vh.gpa, w) catch vh.oom();
    return out.items;
}

const t = std.testing;

test "names, plan values, the fstab line" {
    try t.expect(validName("game") and validName("kbuild-2"));
    try t.expect(!validName("") and !validName("Game") and !validName("../x") and !validName("2a") and !validName("a b"));
    const env = "# vh-plan\nVH_PLAN_PACKAGES='bluez iwd'\nVH_PLAN_GAME_PACKAGES='mesa-vulkan-intel'\nVH_PLAN_GAME='x'\n";
    try t.expectEqualStrings("mesa-vulkan-intel", planValue(env, "VH_PLAN_GAME_PACKAGES").?);
    try t.expectEqualStrings("x", planValue(env, "VH_PLAN_GAME").?);
    try t.expect(planValue(env, "VH_PLAN_NONE") == null);
    try t.expectEqual(@as(usize, 2), words(planValue(env, "VH_PLAN_PACKAGES").?).len);
    try t.expectEqualStrings("/home/game\t/home/game\tnone\tbind,nosuid,nodev\t0 0", fstabBind("/home/game"));
}
