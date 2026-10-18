//! thor: the policy rules, the package deny list and the path categories (docs/18).
//! Shared by the policy inside libxbps (policy.zig) and the thor command; no exported
//! symbols, so thor does not shadow the libxbps functions with them.
const std = @import("std");
const mem = std.mem;

// ---------------------------------------------------------------- deny list

pub const Deny = struct { name: [:0]const u8, why: [:0]const u8 };

/// carried over from vh-pkg; the reasons are the same
pub const deny = [_]Deny{
    // compilers: malware would build a tool in place
    .{ .name = "gcc", .why = "C compiler (often pulled in through libgccjit, e.g. by emacs-pgtk/gtk3)" },
    .{ .name = "clang", .why = "C compiler" },
    .{ .name = "tcc", .why = "C compiler" },
    .{ .name = "make", .why = "build system" },
    .{ .name = "rust", .why = "compiler" },
    .{ .name = "go", .why = "compiler" },
    .{ .name = "zig", .why = "compiler (the Zig used for building lives only in the live environment's RAM)" },
    // interpreters: they bypass noexec (ctypes, FFI); the system has none on purpose
    .{ .name = "python3", .why = "interpreter: runs code from files on noexec mounts (docs/05)" },
    .{ .name = "perl", .why = "interpreter: runs code from files on noexec mounts (docs/05)" },
    .{ .name = "ruby", .why = "interpreter" },
    .{ .name = "nodejs", .why = "interpreter" },
    // privileged daemons and helpers
    .{ .name = "polkit", .why = "SUID pkexec and a rights daemon; doas does its job here" },
    .{ .name = "elogind", .why = "session manager; here it is seatd" },
    .{ .name = "udisks2", .why = "mounts disks without a password through D-Bus" },
    .{ .name = "gvfs", .why = "virtual file system daemons" },
    .{ .name = "avahi", .why = "mDNS: announces the host name to the network, listens on a port" },
    .{ .name = "cups", .why = "print server, listens on a port" },
    .{ .name = "NetworkManager", .why = "a second network manager next to iwd" },
    .{ .name = "ModemManager", .why = "modem daemon" },
    .{ .name = "connman", .why = "a second network manager" },
    .{ .name = "wpa_supplicant", .why = "a second Wi-Fi daemon next to iwd" },
    .{ .name = "openssh", .why = "contains the sshd server (do not enable the service)" },
    .{ .name = "sudo", .why = "a second SUID privilege-escalation tool" },
    .{ .name = "usbguard", .why = "pulls in polkit" },
    .{ .name = "cronie", .why = "scheduler: a persistence point" },
    .{ .name = "dcron", .why = "scheduler" },
    .{ .name = "fcron", .why = "scheduler" },
    .{ .name = "snooze", .why = "scheduler" },
    .{ .name = "at", .why = "scheduler" },
    .{ .name = "xorg-server", .why = "X11: no window isolation" },
    .{ .name = "xorg-server-xwayland", .why = "Xwayland: no window isolation" },
    .{ .name = "xdg-desktop-portal", .why = "D-Bus portals" },
    .{ .name = "gnome-keyring", .why = "key daemon with D-Bus" },
    .{ .name = "pulseaudio", .why = "conflicts with PipeWire" },
    .{ .name = "fuse", .why = "SUID fusermount; the fuse module is denied" },
    .{ .name = "fuse3", .why = "SUID fusermount3; the fuse module is denied" },
    .{ .name = "flatpak", .why = "needs userns and fuse" },
    .{ .name = "podman", .why = "needs userns and overlay" },
    .{ .name = "docker", .why = "root daemon, needs overlay and iptables" },
    .{ .name = "tlp", .why = "power daemon; vh-power does its job" },
    .{ .name = "thermald", .why = "power daemon" },
    .{ .name = "power-profiles-daemon", .why = "power daemon" },
    .{ .name = "auto-cpufreq", .why = "power daemon" },
    .{ .name = "acpid", .why = "suspends on lid close; here it is vh-acpid" },
    // xbps itself: the thor package replaces it; the plain package would roll back the policy
    .{ .name = "xbps", .why = "replaced by the thor package (updating thor: install/build-thor.sh, docs/18)" },
};

const deny_prefix = [_]Deny{
    .{ .name = "xdg-desktop-portal-", .why = "D-Bus portals" },
    .{ .name = "llvm", .why = "compiler (LLVM)" },
};

pub fn denyReason(name: []const u8) ?[:0]const u8 {
    for (deny) |d| if (mem.eql(u8, name, d.name)) return d.why;
    for (deny_prefix) |d| if (mem.startsWith(u8, name, d.name)) return d.why;
    return null;
}

/// SUID/SGID the system cannot work without (vh-audit expects exactly these)
pub const suid_allowed = [_][]const u8{ "/usr/bin/doas", "/usr/bin/unix_chkpwd" };

/// file capabilities the system cannot work without (vh-audit expects exactly these):
/// nanoklogd (socklog-void) reads the kernel log as an unprivileged user and needs cap_syslog
pub const caps_allowed = [_][]const u8{"/usr/bin/nanoklogd"};

// ---------------------------------------------------------------- path categories

pub fn base(p: []const u8) []const u8 {
    return std.fs.path.basename(p);
}

pub fn isKernelHook(p: []const u8) bool {
    return mem.startsWith(u8, p, "/etc/kernel.d/");
}

/// the directory of a dracut module: /usr/lib/dracut/modules.d/90foo/
pub fn dracutModule(p: []const u8) ?[]const u8 {
    const pre = "/usr/lib/dracut/modules.d/";
    if (!mem.startsWith(u8, p, pre)) return null;
    const slash = mem.indexOfScalarPos(u8, p, pre.len, '/') orelse return null;
    return p[0 .. slash + 1];
}

pub fn isLoginScript(p: []const u8) bool {
    return (mem.startsWith(u8, p, "/etc/profile.d/") and mem.endsWith(u8, p, ".sh") and p.len > 18) or
        (mem.startsWith(u8, p, "/etc/bash/bashrc.d/") and p.len > 19);
}

pub fn isSysctl(p: []const u8) bool {
    return (mem.startsWith(u8, p, "/usr/lib/sysctl.d/") or mem.startsWith(u8, p, "/run/sysctl.d/")) and
        mem.endsWith(u8, p, ".conf") and base(p).len > 5;
}

pub fn isUdevRule(p: []const u8) bool {
    return (mem.startsWith(u8, p, "/usr/lib/udev/rules.d/") or mem.startsWith(u8, p, "/etc/udev/rules.d/")) and
        mem.endsWith(u8, p, ".rules") and base(p).len > 6;
}

/// MODE="0666" and the like: a device for everyone (like udev_world_mode in the old vh-pkg)
pub fn udevWorldMode(t: []const u8) bool {
    const modes = [_][]const u8{ "666", "777", "766", "776", "677" };
    var from: usize = 0;
    while (mem.indexOfPos(u8, t, from, "MODE")) |p| {
        from = p + 4;
        var q = p + 4;
        while (q < t.len and isSpace(t[q])) q += 1;
        if (q < t.len and t[q] == ':') q += 1;
        if (q >= t.len or t[q] != '=') continue;
        q += 1;
        while (q < t.len and isSpace(t[q])) q += 1;
        if (q >= t.len or t[q] != '"') continue;
        q += 1;
        if (q < t.len and t[q] == '0') q += 1;
        for (modes) |m| if (t.len - q >= 4 and mem.eql(u8, t[q .. q + 3], m) and t[q + 3] == '"') return true;
    }
    return false;
}

pub fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0b or ch == 0x0c;
}

test "deny list" {
    try std.testing.expect(denyReason("polkit") != null);
    try std.testing.expect(denyReason("xdg-desktop-portal-wlr") != null);
    try std.testing.expect(denyReason("llvm19") != null);
    try std.testing.expect(denyReason("firefox") == null);
    try std.testing.expect(denyReason("thor") == null);
}

test "path categories" {
    try std.testing.expect(isKernelHook("/etc/kernel.d/post-install/20-dracut"));
    try std.testing.expectEqualStrings("/usr/lib/dracut/modules.d/90crypt/", dracutModule("/usr/lib/dracut/modules.d/90crypt/module-setup.sh").?);
    try std.testing.expect(dracutModule("/usr/lib/dracut/modules.d/README") == null);
    try std.testing.expect(isLoginScript("/etc/profile.d/x.sh"));
    try std.testing.expect(!isLoginScript("/etc/profile.d/.sh"));
    try std.testing.expect(isSysctl("/usr/lib/sysctl.d/99-x.conf"));
    try std.testing.expect(!isSysctl("/usr/lib/sysctl.d/.conf"));
    try std.testing.expect(isUdevRule("/usr/lib/udev/rules.d/60-x.rules"));
}

test "udev MODE 0666" {
    try std.testing.expect(udevWorldMode("KERNEL==\"fuse\", MODE=\"0666\""));
    try std.testing.expect(udevWorldMode("MODE:=\"666\""));
    try std.testing.expect(udevWorldMode("MODE = \"0777\""));
    try std.testing.expect(!udevWorldMode("MODE=\"0660\""));
    try std.testing.expect(!udevWorldMode("MODE=\"0666"));
    try std.testing.expect(!udevWorldMode("MODE"));
}
