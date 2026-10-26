//! zig/lib/selabel.zig: file contexts for vh-selabel (selinux/, docs/uni/selinux.md): the
//! `regex [-type] context` lines secilc writes from the policy's filecon statements, matched
//! against a path without libselinux or a regex library. The subset of regular expressions the
//! policy keeps to (tests/selinux/checks.py checks every pattern against it): literals, `\.`
//! and other escapes, `.` and `.*`, `[...]` and `[^...]` with `*`, `+` or `?`, groups
//! `(a|b)` with `?`, `*` or `+`, `(/.*)?`. A path is matched whole. Among the lines that match,
//! the most specific wins: the longest literal prefix before the first metacharacter, as
//! libselinux orders its specs; equal prefixes go to the later line.
const std = @import("std");
const mem = std.mem;
const vh = @import("vh");

pub const Kind = enum { any, file, dir, char, block, socket, fifo, symlink };

const Node = union(enum) {
    lit: u8,
    any,
    class: Class,
    group: []const []const Item,
};
const Class = struct { neg: bool, set: [256]bool };
const Item = struct { node: Node, min: u8, max: u8 };
const many: u8 = 255;

pub const Spec = struct {
    pattern: []const u8,
    items: []const Item,
    /// the literal start of the pattern, what a path must begin with
    prefix: []const u8,
    kind: Kind,
    context: []const u8,
    line: usize,
};

pub const ParseError = error{ BadPattern, BadLine };

/// one file_contexts line; null for a comment or an empty line
pub fn parseLine(line: []const u8, lineno: usize) ParseError!?Spec {
    const t = vh.strip(line);
    if (t.len == 0 or t[0] == '#') return null;
    var it = mem.tokenizeAny(u8, t, " \t");
    const pat = it.next() orelse return error.BadLine;
    var second = it.next() orelse return error.BadLine;
    var kind: Kind = .any;
    if (second.len == 2 and second[0] == '-') {
        kind = switch (second[1]) {
            '-' => .file,
            'd' => .dir,
            'c' => .char,
            'b' => .block,
            's' => .socket,
            'p' => .fifo,
            'l' => .symlink,
            else => return error.BadLine,
        };
        second = it.next() orelse return error.BadLine;
    }
    if (it.next() != null) return error.BadLine;
    var p = Parser{ .s = pat };
    const items = try p.sequence(false);
    if (p.i != pat.len) return error.BadPattern;
    return .{ .pattern = vh.dupe(pat), .items = items, .prefix = vh.dupe(literalPrefix(pat)), .kind = kind, .context = vh.dupe(second), .line = lineno };
}

/// the text up to the first metacharacter (an escape counts as a literal)
pub fn literalPrefix(pat: []const u8) []const u8 {
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        switch (pat[i]) {
            '.', '*', '+', '?', '[', '(', '|', ')', '{', '^', '$' => break,
            '\\' => break,
            else => {},
        }
    }
    return pat[0..i];
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    /// items until the end or a `)` or `|` (inside a group)
    fn sequence(p: *Parser, in_group: bool) ParseError![]const Item {
        var items: std.ArrayList(Item) = .empty;
        while (p.peek()) |c| {
            if (in_group and (c == ')' or c == '|')) break;
            var node: Node = undefined;
            switch (c) {
                '.' => {
                    p.i += 1;
                    node = .any;
                },
                '\\' => {
                    p.i += 1;
                    const e = p.peek() orelse return error.BadPattern;
                    p.i += 1;
                    node = .{ .lit = e };
                },
                '[' => node = .{ .class = try p.class() },
                '(' => {
                    p.i += 1;
                    var alts: std.ArrayList([]const Item) = .empty;
                    while (true) {
                        alts.append(vh.gpa, try p.sequence(true)) catch vh.oom();
                        const d = p.peek() orelse return error.BadPattern;
                        p.i += 1;
                        if (d == ')') break;
                    }
                    node = .{ .group = alts.items };
                },
                '*', '+', '?', ')', '|', '{', '^', '$' => return error.BadPattern,
                else => {
                    p.i += 1;
                    node = .{ .lit = c };
                },
            }
            var item: Item = .{ .node = node, .min = 1, .max = 1 };
            if (p.peek()) |q| {
                if (q == '*') {
                    item.min = 0;
                    item.max = many;
                    p.i += 1;
                } else if (q == '+') {
                    item.min = 1;
                    item.max = many;
                    p.i += 1;
                } else if (q == '?') {
                    item.min = 0;
                    item.max = 1;
                    p.i += 1;
                }
            }
            items.append(vh.gpa, item) catch vh.oom();
        }
        return items.items;
    }

    fn class(p: *Parser) ParseError!Class {
        p.i += 1; // [
        var c: Class = .{ .neg = false, .set = @splat(false) };
        if (p.peek() == '^') {
            c.neg = true;
            p.i += 1;
        }
        var first = true;
        while (true) {
            const ch = p.peek() orelse return error.BadPattern;
            if (ch == ']' and !first) {
                p.i += 1;
                break;
            }
            first = false;
            p.i += 1;
            var lo = ch;
            if (lo == '\\') {
                lo = p.peek() orelse return error.BadPattern;
                p.i += 1;
            }
            if (p.peek() == '-' and p.i + 1 < p.s.len and p.s[p.i + 1] != ']') {
                p.i += 1;
                const hi = p.peek() orelse return error.BadPattern;
                p.i += 1;
                if (hi < lo) return error.BadPattern;
                var x: usize = lo;
                while (x <= hi) : (x += 1) c.set[x] = true;
            } else c.set[lo] = true;
        }
        return c;
    }
};

/// the whole text matches the items
pub fn matches(items: []const Item, text: []const u8) bool {
    return matchFrom(items, 0, text, 0, 0);
}

fn nodeMatchesChar(n: Node, ch: u8) bool {
    return switch (n) {
        .lit => |l| l == ch,
        .any => true,
        .class => |c| c.set[ch] != c.neg,
        .group => false,
    };
}

/// backtracking over the items from index `k` at text position `pos`; `depth` bounds the recursion
fn matchFrom(items: []const Item, k: usize, text: []const u8, pos: usize, depth: u32) bool {
    if (depth > 4096) return false;
    if (k == items.len) return pos == text.len;
    const it = items[k];
    switch (it.node) {
        .group => |alts| {
            // zero repetitions
            if (it.min == 0 and matchFrom(items, k + 1, text, pos, depth + 1)) return true;
            // one or more: each repetition tries every alternative and every end position
            return matchGroupReps(items, k, alts, text, pos, 1, depth + 1);
        },
        else => {
            // the longest run of single characters this node takes, then back off
            var n: usize = 0;
            const limit: usize = if (it.max == many) text.len - pos else it.max;
            while (n < limit and pos + n < text.len and nodeMatchesChar(it.node, text[pos + n])) n += 1;
            while (true) {
                if (n >= it.min and matchFrom(items, k + 1, text, pos + n, depth + 1)) return true;
                if (n == 0) return false;
                n -= 1;
            }
        },
    }
}

fn matchGroupReps(items: []const Item, k: usize, alts: []const []const Item, text: []const u8, pos: usize, rep: u32, depth: u32) bool {
    const it = items[k];
    if (depth > 4096) return false;
    for (alts) |alt| {
        // every end position the alternative can reach from pos
        var end = pos;
        while (end <= text.len) : (end += 1) {
            if (!matchesSub(alt, text[pos..end], depth + 1)) continue;
            if (rep >= it.min and matchFrom(items, k + 1, text, end, depth + 1)) return true;
            if ((it.max == many or rep < it.max) and end > pos and matchGroupReps(items, k, alts, text, end, rep + 1, depth + 1)) return true;
        }
    }
    return false;
}

fn matchesSub(items: []const Item, text: []const u8, depth: u32) bool {
    return matchFrom(items, 0, text, 0, depth);
}

/// the kind of a file, from its mode
pub fn kindOf(mode: u32) Kind {
    return switch (mode & 0o170000) {
        0o100000 => .file,
        0o040000 => .dir,
        0o020000 => .char,
        0o060000 => .block,
        0o140000 => .socket,
        0o010000 => .fifo,
        0o120000 => .symlink,
        else => .any,
    };
}

pub const Table = struct {
    specs: []const Spec,

    pub fn parse(text: []const u8) ParseError!Table {
        var list: std.ArrayList(Spec) = .empty;
        var lines = mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            if (try parseLine(line, n)) |s| list.append(vh.gpa, s) catch vh.oom();
        }
        return .{ .specs = list.items };
    }

    /// the context of a path of the given kind, or null when no line matches. The most specific
    /// line wins, as libselinux orders its specs: a pattern without metacharacters (the exact path)
    /// before one with them, then the longer literal prefix, then the later line.
    pub fn lookup(t: *const Table, path: []const u8, kind: Kind) ?[]const u8 {
        var best: ?*const Spec = null;
        for (t.specs) |*s| {
            if (s.kind != .any and s.kind != kind) continue;
            if (!mem.startsWith(u8, path, s.prefix)) continue;
            if (!matches(s.items, path)) continue;
            if (best) |b| {
                const s_exact = s.prefix.len == s.pattern.len;
                const b_exact = b.prefix.len == b.pattern.len;
                if (b_exact and !s_exact) continue;
                if (s_exact == b_exact and s.prefix.len < b.prefix.len) continue;
            }
            best = s;
        }
        return if (best) |b| b.context else null;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn m(pat: []const u8, text: []const u8) !bool {
    var p = Parser{ .s = pat };
    const items = try p.sequence(false);
    try testing.expectEqual(pat.len, p.i);
    return matches(items, text);
}

test "the subset: literals, escapes, any, classes, groups, quantifiers" {
    try testing.expect(try m("/usr/bin(/.*)?", "/usr/bin"));
    try testing.expect(try m("/usr/bin(/.*)?", "/usr/bin/ls"));
    try testing.expect(try m("/usr/bin(/.*)?", "/usr/bin/a/b/c"));
    try testing.expect(!try m("/usr/bin(/.*)?", "/usr/binx"));
    try testing.expect(!try m("/usr/bin(/.*)?", "/usr/bi"));
    try testing.expect(try m("/usr/lib/ld-linux.*\\.so.*", "/usr/lib/ld-linux-x86-64.so.2"));
    try testing.expect(!try m("/usr/lib/ld-linux.*\\.so.*", "/usr/lib/ld-linuxXso2"));
    try testing.expect(try m("/dev/tty[0-9]+", "/dev/tty12"));
    try testing.expect(!try m("/dev/tty[0-9]+", "/dev/tty"));
    try testing.expect(!try m("/dev/tty[0-9]+", "/dev/ttyS0"));
    try testing.expect(try m("/dev/(sd|nvme|vd|mmcblk)[a-z0-9]+(p[0-9]+)?", "/dev/nvme0n1p2"));
    try testing.expect(try m("/dev/(sd|nvme|vd|mmcblk)[a-z0-9]+(p[0-9]+)?", "/dev/sda"));
    try testing.expect(!try m("/dev/(sd|nvme|vd|mmcblk)[a-z0-9]+(p[0-9]+)?", "/dev/sr0"));
    try testing.expect(try m("/usr/bin/(ba|da)?sh", "/usr/bin/sh"));
    try testing.expect(try m("/usr/bin/(ba|da)?sh", "/usr/bin/bash"));
    try testing.expect(!try m("/usr/bin/(ba|da)?sh", "/usr/bin/zsh"));
    try testing.expect(try m("/etc/sv/[^/]+/(run|finish|check)", "/etc/sv/iwd/run"));
    try testing.expect(!try m("/etc/sv/[^/]+/(run|finish|check)", "/etc/sv/iwd/log/run"));
    try testing.expect(try m("/etc/sv/[^/]+/log/run", "/etc/sv/iwd/log/run"));
    try testing.expect(try m("/home/[^/]+", "/home/user"));
    try testing.expect(!try m("/home/[^/]+", "/home/user/x"));
    try testing.expect(try m("/home/[^/]+/.*", "/home/user/x"));
    try testing.expect(try m("/var/log/(wtmp|btmp|lastlog).*", "/var/log/wtmp"));
    try testing.expect(try m("/var/log/(wtmp|btmp|lastlog).*", "/var/log/btmp.1"));
    try testing.expect(try m("/usr/local/sbin/vh-(power|bluetooth|suid-strip)", "/usr/local/sbin/vh-suid-strip"));
    try testing.expect(try m("/", "/"));
    try testing.expect(!try m("/", "/a"));
    try testing.expect(try m("/.*", "/anything/at/all"));
    try testing.expect(try m("/dev/watchdog[0-9]*", "/dev/watchdog"));
    try testing.expect(try m("/dev/zram[0-9]+", "/dev/zram0"));
}

test "bad patterns are refused" {
    var p = Parser{ .s = "/usr/[abc" };
    try testing.expectError(error.BadPattern, p.sequence(false));
    p = Parser{ .s = "/usr/(a|b" };
    try testing.expectError(error.BadPattern, p.sequence(false));
    p = Parser{ .s = "*oops" };
    try testing.expectError(error.BadPattern, p.sequence(false));
}

test "the table: the most specific line wins" {
    const text =
        \\# comment
        \\/  -d  system_u:object_r:root_t:s0
        \\/.*  system_u:object_r:file_t:s0
        \\/usr  -d  system_u:object_r:usr_t:s0
        \\/usr/.*  system_u:object_r:usr_t:s0
        \\/usr/bin(/.*)?  system_u:object_r:bin_t:s0
        \\/usr/bin/(ba|da)?sh  --  system_u:object_r:shell_exec_t:s0
        \\/etc(/.*)?  system_u:object_r:etc_t:s0
        \\/etc/shadow.*  --  system_u:object_r:shadow_t:s0
        \\/dev/log  -s  system_u:object_r:devlog_t:s0
    ;
    const t = try Table.parse(text);
    try testing.expectEqual(@as(usize, 9), t.specs.len);
    try testing.expectEqualStrings("system_u:object_r:root_t:s0", t.lookup("/", .dir).?);
    try testing.expectEqualStrings("system_u:object_r:usr_t:s0", t.lookup("/usr", .dir).?);
    try testing.expectEqualStrings("system_u:object_r:usr_t:s0", t.lookup("/usr/share/x", .file).?);
    try testing.expectEqualStrings("system_u:object_r:bin_t:s0", t.lookup("/usr/bin/ls", .file).?);
    try testing.expectEqualStrings("system_u:object_r:shell_exec_t:s0", t.lookup("/usr/bin/bash", .file).?);
    try testing.expectEqualStrings("system_u:object_r:bin_t:s0", t.lookup("/usr/bin/bash", .dir).?); // a directory named bash: not the -- line
    try testing.expectEqualStrings("system_u:object_r:etc_t:s0", t.lookup("/etc/passwd", .file).?);
    try testing.expectEqualStrings("system_u:object_r:shadow_t:s0", t.lookup("/etc/shadow-", .file).?);
    try testing.expectEqualStrings("system_u:object_r:devlog_t:s0", t.lookup("/dev/log", .socket).?);
    try testing.expectEqualStrings("system_u:object_r:file_t:s0", t.lookup("/dev/log", .file).?);
    try testing.expectEqualStrings("system_u:object_r:file_t:s0", t.lookup("/opt", .dir).?);
    try testing.expectEqual(@as(?[]const u8, null), (try Table.parse("/x -- a:b:c:s0")).lookup("/y", .file));
    try testing.expectError(error.BadLine, Table.parse("onlyonefield"));
    try testing.expectError(error.BadLine, Table.parse("/x -q a:b:c:s0"));
}

test "kinds from modes" {
    try testing.expectEqual(Kind.dir, kindOf(0o040755));
    try testing.expectEqual(Kind.file, kindOf(0o100644));
    try testing.expectEqual(Kind.symlink, kindOf(0o120777));
    try testing.expectEqual(Kind.socket, kindOf(0o140600));
}
