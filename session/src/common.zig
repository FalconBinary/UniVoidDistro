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
    /// input (seatd hands the active session its devices), video or audio (the sound cards'
    /// playback and control nodes come by an ACL entry each, sound_rule)
    pub const groups = [_][]const u8{ "_seatd", "render" };
    /// the getty of tty3, started and stopped by vh-game tty, never by the boot
    pub const getty = "/etc/sv/agetty-tty3";
    /// the udev rule that gives game the playback and control nodes of every sound card (an
    /// ACL entry on each, at every boot and hotplug); vh-game install writes it, remove takes
    /// it away
    pub const sound_rule = "/etc/udev/rules.d/99-vh-game.rules";
    pub const sound_rule_text =
        \\# vh-game (docs/uni/game.md, G2): the gaming session's own PipeWire plays through the
        \\# sound cards' playback and control nodes, which the user game gets by an ACL entry each,
        \\# at every boot and hotplug. Never a capture node (the microphone), hwdep, the sequencer
        \\# or the timer. vh-game install writes this file, vh-game remove takes it away.
        \\SUBSYSTEM=="sound", KERNEL=="controlC[0-9]*|pcmC[0-9]*D[0-9]*p", ACTION!="remove", RUN+="/usr/bin/setfacl -m u:game:rw $devnode"
        \\
    ;
};

/// the sound cards' device nodes
pub const snd_dir = "/dev/snd";

/// A node of /dev/snd the gaming session plays through: a card's control node (controlC<n>:
/// its mixer, which alsa-lib opens with every PCM) or a playback PCM (pcmC<n>D<m>p). Never a
/// capture PCM (the microphone), hwdep, the sequencer, the timer or anything else.
pub fn playbackNode(name: []const u8) bool {
    if (vh.startsWith(name, "controlC")) return allDigits(name["controlC".len..]);
    if (!vh.startsWith(name, "pcmC") or name[name.len - 1] != 'p') return false;
    const card_dev = name["pcmC".len .. name.len - 1];
    const d = std.mem.indexOfScalar(u8, card_dev, 'D') orelse return false;
    return allDigits(card_dev[0..d]) and allDigits(card_dev[d + 1 ..]);
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

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

test "the sound nodes of the gaming session: playback and control only" {
    for ([_][]const u8{ "controlC0", "controlC12", "pcmC0D0p", "pcmC0D3p", "pcmC1D10p", "pcmC10D0p" }) |n|
        try t.expect(playbackNode(n));
    // the microphone, the codec's hwdep, the sequencer, the timer, compress offload, MIDI,
    // the udev links' directories, and what only looks like a node
    for ([_][]const u8{ "pcmC0D0c", "pcmC0D0", "hwC0D0", "seq", "timer", "comprC0D0", "midiC0D0", "by-path", "by-id", "controlC", "controlCx", "controlC0p", "pcmC0Dp", "pcmCD0p", "pcmC0D0pp", "pcmCxD0p", "pcmC0D0cp", "p", "" }) |n|
        try t.expect(!playbackNode(n));
    // the rule names the same nodes and the user
    try t.expect(std.mem.indexOf(u8, game.sound_rule_text, "KERNEL==\"controlC[0-9]*|pcmC[0-9]*D[0-9]*p\"") != null);
    try t.expect(std.mem.indexOf(u8, game.sound_rule_text, "u:" ++ game.user ++ ":rw") != null);
}
