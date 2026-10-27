//! modules.alias and modules.builtin.modinfo of the stock kernel: which module claims a
//! modalias. The patterns are shell globs (depmod writes them from MODULE_DEVICE_TABLE);
//! fnmatch() here does what kmod does: "*", "?", "[set]" with "!" or "^" negation and ranges.
const std = @import("std");
const vh = @import("vh");
const mem = std.mem;

pub const Entry = struct {
    pattern: []const u8,
    module: []const u8,
    /// the literal start of the pattern, up to the first wildcard: a quick reject
    prefix: []const u8,
};

pub const Match = struct {
    /// loadable modules of the stock kernel, in table order, without duplicates
    loadable: []const []const u8,
    /// drivers already built into the stock kernel
    builtin: []const []const u8,

    pub fn any(self: Match) bool {
        return self.loadable.len > 0 or self.builtin.len > 0;
    }
};

pub const Table = struct {
    loadable: std.ArrayList(Entry) = .empty,
    builtin: std.ArrayList(Entry) = .empty,
    builtin_names: std.StringHashMapUnmanaged(void) = .empty,

    /// modules.alias: "alias PATTERN MODULE" lines; anything else is ignored
    pub fn loadAliases(self: *Table, text: []const u8) void {
        var lines = mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = vh.strip(raw);
            if (!vh.startsWith(line, "alias ")) continue;
            var it = mem.tokenizeAny(u8, line[6..], " \t");
            const pat = it.next() orelse continue;
            const m = it.next() orelse continue;
            self.loadable.append(vh.gpa, entry(pat, m)) catch vh.oom();
        }
    }

    /// modules.builtin.modinfo: NUL-separated "MODULE.key=value" records; the alias and
    /// file keys are used
    pub fn loadBuiltinModinfo(self: *Table, bytes: []const u8) void {
        var recs = mem.tokenizeScalar(u8, bytes, 0);
        while (recs.next()) |rec| {
            const dot = mem.indexOfScalar(u8, rec, '.') orelse continue;
            const eq = mem.indexOfScalarPos(u8, rec, dot, '=') orelse continue;
            const name = normalize(rec[0..dot]);
            const key = rec[dot + 1 .. eq];
            // every record names a built-in module, whatever its key
            self.builtin_names.put(vh.gpa, name, {}) catch vh.oom();
            if (vh.eql(key, "alias")) self.builtin.append(vh.gpa, entry(rec[eq + 1 ..], name)) catch vh.oom();
        }
    }

    /// modules.builtin: "kernel/dir/name.ko" lines
    pub fn loadBuiltinList(self: *Table, text: []const u8) void {
        var lines = mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = vh.strip(raw);
            if (line.len == 0) continue;
            const base = if (mem.lastIndexOfScalar(u8, line, '/')) |i| line[i + 1 ..] else line;
            const name = if (vh.endsWith(base, ".ko")) base[0 .. base.len - 3] else base;
            self.builtin_names.put(vh.gpa, normalize(name), {}) catch vh.oom();
        }
    }

    pub fn isBuiltin(self: *const Table, name: []const u8) bool {
        return self.builtin_names.contains(normalize(name));
    }

    pub fn match(self: *const Table, modalias: []const u8) Match {
        return .{
            .loadable = matchIn(self.loadable.items, modalias),
            .builtin = matchIn(self.builtin.items, modalias),
        };
    }
};

fn matchIn(entries: []const Entry, modalias: []const u8) []const []const u8 {
    var found: vh.Strv = .{};
    for (entries) |e| {
        if (!vh.startsWith(modalias, e.prefix)) continue;
        if (!fnmatch(e.pattern, modalias)) continue;
        if (!found.has(e.module)) found.add(e.module);
    }
    return found.slice();
}

fn entry(pattern: []const u8, module: []const u8) Entry {
    const p = vh.dupe(pattern);
    const w = mem.indexOfAny(u8, p, "*?[") orelse p.len;
    return .{ .pattern = p, .module = normalize(module), .prefix = p[0..w] };
}

/// module names: "-" and "_" are the same to kmod; the "_" form is used everywhere here
pub fn normalize(name: []const u8) []const u8 {
    const n = vh.dupe(name);
    for (n) |*c| {
        if (c.* == '-') c.* = '_';
    }
    return n;
}

/// a shell-style glob: "*" any run, "?" one byte, "[abc]", "[a-z]", "[!x]" or "[^x]"
pub fn fnmatch(pattern: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (si < s.len) {
        if (pi < pattern.len) {
            const c = pattern[pi];
            if (c == '*') {
                star_p = pi;
                star_s = si;
                pi += 1;
                continue;
            } else if (c == '?') {
                pi += 1;
                si += 1;
                continue;
            } else if (c == '[') {
                if (classEnd(pattern, pi)) |end| {
                    if (classMatch(pattern[pi + 1 .. end], s[si])) {
                        pi = end + 1;
                        si += 1;
                        continue;
                    }
                } else if (s[si] == '[') {
                    pi += 1;
                    si += 1;
                    continue;
                }
            } else if (c == s[si]) {
                pi += 1;
                si += 1;
                continue;
            }
        }
        if (star_p) |sp| {
            pi = sp + 1;
            star_s += 1;
            si = star_s;
            continue;
        }
        return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

/// the index of the "]" that closes the class opened at pattern[open]; null if unclosed
fn classEnd(pattern: []const u8, open: usize) ?usize {
    var i = open + 1;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1; // a leading "]" is a literal
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == ']') return i;
    }
    return null;
}

fn classMatch(class: []const u8, c: u8) bool {
    var i: usize = 0;
    var negate = false;
    if (i < class.len and (class[i] == '!' or class[i] == '^')) {
        negate = true;
        i += 1;
    }
    var hit = false;
    while (i < class.len) : (i += 1) {
        const a = class[i];
        if (i + 2 < class.len and class[i + 1] == '-') {
            if (c >= a and c <= class[i + 2]) hit = true;
            i += 2;
        } else if (a == c) hit = true;
    }
    return hit != negate;
}

test "fnmatch" {
    try std.testing.expect(fnmatch("pci:v00008086d000006F0sv*sd*bc*sc*i*", "pci:v00008086d000006F0sv00008086sd00000034bc02sc80i00"));
    try std.testing.expect(!fnmatch("pci:v00008086d000006F0sv*sd*bc*sc*i*", "pci:v00008086d000006F1sv00008086sd00000034bc02sc80i00"));
    try std.testing.expect(fnmatch("usb:v*p*d*dc*dsc*dp*ic0Eisc01ip00in*", "usb:v5986p211Cd0003dcEFdsc02dp01ic0Eisc01ip00in00"));
    try std.testing.expect(fnmatch("acpi*:PNP0C50:*", "acpi:SYNA3602:PNP0C50:"));
    try std.testing.expect(fnmatch("cpu:type:x86,ven0000fam*mod*:feature:*01C0*", "cpu:type:x86,ven0000fam0006mod00A5:feature:,0000,0001,01C0,01C6"));
    try std.testing.expect(!fnmatch("cpu:type:x86,ven0000fam*mod*:feature:*01C0*", "cpu:type:x86,ven0000fam0006mod00A5:feature:,0000,0001,01C6"));
    try std.testing.expect(fnmatch("a?c", "abc"));
    try std.testing.expect(!fnmatch("a?c", "ac"));
    try std.testing.expect(fnmatch("a[bc]d", "acd"));
    try std.testing.expect(!fnmatch("a[bc]d", "aed"));
    try std.testing.expect(fnmatch("a[!bc]d", "aed"));
    try std.testing.expect(fnmatch("a[a-c]d", "abd"));
    try std.testing.expect(fnmatch("*", ""));
    try std.testing.expect(fnmatch("", ""));
    try std.testing.expect(!fnmatch("", "x"));
    try std.testing.expect(fnmatch("x*", "x"));
    try std.testing.expect(fnmatch("*x*y*", "axbyc"));
    try std.testing.expect(!fnmatch("*x*y*", "aybxc"));
    try std.testing.expect(fnmatch("a[", "a["));
}

test "alias tables" {
    var t: Table = .{};
    t.loadAliases(
        \\# Aliases extracted from modules themselves.
        \\alias pci:v00008086d000006F0sv*sd*bc*sc*i* iwlwifi
        \\alias pci:v000010DEd*sv*sd*bc03sc*i* nouveau
        \\alias acpi*:PNP0C0C:* button
        \\alias acpi*:PNP0C0C:* tiny_power_button
        \\alias hdaudio:v10EC0233r*a01* snd-hda-codec-alc269
        \\garbage line
    );
    t.loadBuiltinModinfo("nvme.file=drivers/nvme/host/nvme\x00nvme.alias=pci:v*d*sv*sd*bc01sc08i02*\x00i8042.alias=pnp:dPNP0303*\x00i8042.license=GPL\x00");
    t.loadBuiltinList("kernel/drivers/usb/core/usbcore.ko\nkernel/fs/efivarfs/efivarfs.ko\n");
    const wifi = t.match("pci:v00008086d000006F0sv00008086sd00000034bc02sc80i00");
    try std.testing.expectEqual(@as(usize, 1), wifi.loadable.len);
    try std.testing.expectEqualStrings("iwlwifi", wifi.loadable[0]);
    try std.testing.expectEqual(@as(usize, 0), wifi.builtin.len);
    const gpu = t.match("pci:v000010DEd00001F99sv00001462sd000012D5bc03sc00i00");
    try std.testing.expectEqualStrings("nouveau", gpu.loadable[0]);
    const btn = t.match("acpi:PNP0C0C:");
    try std.testing.expectEqual(@as(usize, 2), btn.loadable.len);
    try std.testing.expectEqualStrings("tiny_power_button", btn.loadable[1]);
    const codec = t.match("hdaudio:v10EC0233r00100003a01");
    try std.testing.expectEqualStrings("snd_hda_codec_alc269", codec.loadable[0]);
    const nvme = t.match("pci:v0000144Dd0000A809sv0000144Dsd0000A801bc01sc08i02");
    try std.testing.expect(!nvme.any() == false);
    try std.testing.expectEqual(@as(usize, 0), nvme.loadable.len);
    try std.testing.expectEqualStrings("nvme", nvme.builtin[0]);
    try std.testing.expect(!t.match("pci:v0000AAAAd0000BBBBsv*sd*bc00sc00i00").any());
    try std.testing.expect(t.isBuiltin("nvme"));
    try std.testing.expect(t.isBuiltin("usbcore"));
    try std.testing.expect(t.isBuiltin("i8042"));
    try std.testing.expect(!t.isBuiltin("iwlwifi"));
}

/// The pinned files of an architecture, by name under kernel/pins (README.md there): the x86_64
/// ones under their plain names, the others under names that say the architecture. Null for an
/// architecture without pins.
pub const Pins = struct { dotconfig: []const u8, alias: []const u8, builtin: []const u8, builtin_modinfo: []const u8, firmware: []const u8 };
pub fn pinNames(arch: []const u8) ?Pins {
    if (vh.eql(arch, "x86_64")) return .{
        .dotconfig = "x86_64-dotconfig",
        .alias = "modules.alias",
        .builtin = "modules.builtin",
        .builtin_modinfo = "modules.builtin.modinfo",
        .firmware = "modules.firmware",
    };
    if (vh.eql(arch, "aarch64")) return .{
        .dotconfig = "aarch64-dotconfig",
        .alias = "aarch64-modules.alias",
        .builtin = "aarch64-modules.builtin",
        .builtin_modinfo = "aarch64-modules.builtin.modinfo",
        .firmware = "aarch64-modules.firmware",
    };
    return null;
}
