//! Line edits of the system's configuration files (access.conf, /etc/shells, fstab), each with
//! its exact inverse: what vh-game adds it takes away again byte for byte, which the removal
//! test checks by comparing the whole system before the install and after the removal.
const std = @import("std");
const vh = @import("vh");
const mem = std.mem;

/// whether the text has a line equal to LINE
pub fn has(text: []const u8, line: []const u8) bool {
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (vh.eql(l, line)) return true;
    return false;
}

/// the text with LINE as its last line. A text that does not end with a newline gets one first
/// (remove() leaves it: no file vh-game edits lacks it).
pub fn append(text: []const u8, line: []const u8) []u8 {
    const sep: []const u8 = if (text.len > 0 and text[text.len - 1] != '\n') "\n" else "";
    return vh.fmt("{s}{s}{s}\n", .{ text, sep, line });
}

/// the text without its first line equal to LINE (and that line's newline); null when there is
/// no such line
pub fn remove(text: []const u8, line: []const u8) ?[]u8 {
    var start: usize = 0;
    while (start <= text.len) {
        const end = mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        if (vh.eql(text[start..end], line)) {
            const after = if (end < text.len) end + 1 else end;
            return vh.fmt("{s}{s}", .{ text[0..start], text[after..] });
        }
        if (end == text.len) break;
        start = end + 1;
    }
    return null;
}

/// pam_access's last word, "- : ALL : ALL" (spaces and tabs do not matter): nobody else, anywhere
fn deniesAll(line: []const u8) bool {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ' or c == '\t') continue;
        if (n == buf.len) return false;
        buf[n] = c;
        n += 1;
    }
    return vh.eql(buf[0..n], "-:ALL:ALL");
}

/// access.conf: LINE inserted before the line that denies everyone else, so that pam_access,
/// which takes the first line that matches, sees it; null when there is no such line
pub fn insertBeforeDenyAll(text: []const u8, line: []const u8) ?[]u8 {
    var start: usize = 0;
    while (start < text.len) {
        const end = mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        if (deniesAll(text[start..end])) return vh.fmt("{s}{s}\n{s}", .{ text[0..start], line, text[start..] });
        start = end + 1;
    }
    return null;
}

const t = std.testing;

test "append and remove are exact inverses" {
    const shells = "/bin/sh\n/bin/bash\n";
    const added = append(shells, "/usr/local/bin/vh-game-enter");
    try t.expectEqualStrings("/bin/sh\n/bin/bash\n/usr/local/bin/vh-game-enter\n", added);
    try t.expect(has(added, "/usr/local/bin/vh-game-enter"));
    try t.expectEqualStrings(shells, remove(added, "/usr/local/bin/vh-game-enter").?);
    // a line in the middle, the last line without a newline, a line that is not there
    try t.expectEqualStrings("a\nc\n", remove("a\nb\nc\n", "b").?);
    try t.expectEqualStrings("a\n", remove("a\nb", "b").?);
    try t.expect(remove("a\nb\n", "c") == null);
    // only a whole line counts
    try t.expect(remove("ab\n", "a") == null);
    try t.expect(!has("ab\n", "a"));
}

test "access.conf: before the line that denies everyone" {
    // the tabs of the last line do not matter
    const conf = "# void-hardperf-light: pam_access\n+ : user : tty1\n+ : admin : tty2\n-\t:\tALL :ALL\n";
    const added = insertBeforeDenyAll(conf, "+ : game : tty3").?;
    try t.expectEqualStrings("# void-hardperf-light: pam_access\n+ : user : tty1\n+ : admin : tty2\n+ : game : tty3\n-\t:\tALL :ALL\n", added);
    try t.expectEqualStrings(conf, remove(added, "+ : game : tty3").?);
    try t.expect(insertBeforeDenyAll("+ : user : tty1\n", "+ : game : tty3") == null);
    try t.expect(!deniesAll("- : ALL : LOCAL"));
}
