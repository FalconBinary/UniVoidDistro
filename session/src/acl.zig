//! POSIX access ACLs as Linux keeps them, the xattr system.posix_acl_access: a header (version
//! 2) and entries of tag, permissions and id, sorted by tag, then id. vh-root lets a root's own
//! user, and nobody else, pass through /var/lib/vh with one named-user entry; the removal puts
//! the xattr back as it was (or takes it away) and the mode with it.
const std = @import("std");
const vh = @import("vh");
const mem = std.mem;

pub const name = "system.posix_acl_access";

pub const Tag = struct {
    pub const user_obj: u16 = 0x01;
    pub const user: u16 = 0x02;
    pub const group_obj: u16 = 0x04;
    pub const group: u16 = 0x08;
    pub const mask: u16 = 0x10;
    pub const other: u16 = 0x20;
};
const undefined_id: u32 = 0xffff_ffff;
const version: u32 = 2;

pub const Entry = struct { tag: u16, perm: u16, id: u32 = undefined_id };

/// the entries of an xattr; null when it is not one Linux writes
pub fn parse(x: []const u8) ?[]Entry {
    if (x.len < 4 or (x.len - 4) % 8 != 0 or mem.readInt(u32, x[0..4], .little) != version) return null;
    var out: std.ArrayList(Entry) = .empty;
    var i: usize = 4;
    while (i < x.len) : (i += 8) out.append(vh.gpa, .{
        .tag = mem.readInt(u16, x[i..][0..2], .little),
        .perm = mem.readInt(u16, x[i + 2 ..][0..2], .little),
        .id = mem.readInt(u32, x[i + 4 ..][0..4], .little),
    }) catch vh.oom();
    return out.items;
}

pub fn serialize(entries: []const Entry) []u8 {
    const out = vh.gpa.alloc(u8, 4 + 8 * entries.len) catch vh.oom();
    mem.writeInt(u32, out[0..4], version, .little);
    for (entries, 0..) |e, k| {
        const o = 4 + 8 * k;
        mem.writeInt(u16, out[o..][0..2], e.tag, .little);
        mem.writeInt(u16, out[o + 2 ..][0..2], e.perm, .little);
        mem.writeInt(u32, out[o + 4 ..][0..4], e.id, .little);
    }
    return out;
}

/// The ACL that adds PERM for the user UID to EXISTING (null: the ACL the mode MODE stands for):
/// the named entry, and the mask recomputed as the union of the group class (the owning group,
/// the named users and groups), as setfacl does
pub fn withUser(existing: ?[]const u8, mode: u32, uid: u32, perm: u16) ?[]u8 {
    var list: std.ArrayList(Entry) = .empty;
    if (existing) |x| {
        list.appendSlice(vh.gpa, parse(x) orelse return null) catch vh.oom();
    } else {
        list.appendSlice(vh.gpa, &.{
            .{ .tag = Tag.user_obj, .perm = @intCast((mode >> 6) & 7) },
            .{ .tag = Tag.group_obj, .perm = @intCast((mode >> 3) & 7) },
            .{ .tag = Tag.other, .perm = @intCast(mode & 7) },
        }) catch vh.oom();
    }
    var found = false;
    for (list.items) |*e| if (e.tag == Tag.user and e.id == uid) {
        e.perm |= perm;
        found = true;
    };
    if (!found) list.append(vh.gpa, .{ .tag = Tag.user, .perm = perm, .id = uid }) catch vh.oom();
    var m: u16 = 0;
    var has_mask = false;
    for (list.items) |e| {
        if (e.tag == Tag.user or e.tag == Tag.group_obj or e.tag == Tag.group) m |= e.perm;
        if (e.tag == Tag.mask) has_mask = true;
    }
    if (has_mask) {
        for (list.items) |*e| if (e.tag == Tag.mask) {
            e.perm = m;
        };
    } else list.append(vh.gpa, .{ .tag = Tag.mask, .perm = m }) catch vh.oom();
    mem.sort(Entry, list.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return if (a.tag != b.tag) a.tag < b.tag else a.id < b.id;
        }
    }.less);
    return serialize(list.items);
}

/// What withoutUser leaves: the ACL to write, or null when nothing but the mode is left (the
/// xattr goes, and the mode's group bits, which the mask held, are the owning group's again)
pub const Without = struct { acl: ?[]u8, group: u16 };

/// The ACL EXISTING without the named entry of UID, the mask recomputed as setfacl -x does;
/// null when it has no such entry
pub fn withoutUser(existing: []const u8, uid: u32) ?Without {
    const entries = parse(existing) orelse return null;
    var list: std.ArrayList(Entry) = .empty;
    var found = false;
    var named = false;
    var group: u16 = 0;
    for (entries) |e| {
        if (e.tag == Tag.user and e.id == uid) {
            found = true;
            continue;
        }
        if (e.tag == Tag.user or e.tag == Tag.group) named = true;
        if (e.tag == Tag.group_obj) group = e.perm;
        list.append(vh.gpa, e) catch vh.oom();
    }
    if (!found) return null;
    if (!named) return .{ .acl = null, .group = group };
    var m: u16 = 0;
    for (list.items) |e| if (e.tag == Tag.user or e.tag == Tag.group_obj or e.tag == Tag.group) {
        m |= e.perm;
    };
    for (list.items) |*e| if (e.tag == Tag.mask) {
        e.perm = m;
    };
    return .{ .acl = serialize(list.items), .group = group };
}

/// the permissions the named entry of UID grants, the mask applied; null without such an entry
pub fn userPerm(x: []const u8, uid: u32) ?u16 {
    const entries = parse(x) orelse return null;
    var perm: ?u16 = null;
    var m: u16 = 7;
    for (entries) |e| {
        if (e.tag == Tag.user and e.id == uid) perm = e.perm;
        if (e.tag == Tag.mask) m = e.perm;
    }
    return if (perm) |p| p & m else null;
}

/// whether the ACL lets UID search (x) through: its named entry and the mask both allow it
pub fn lets(x: []const u8, uid: u32) bool {
    const entries = parse(x) orelse return false;
    var user = false;
    var m: u16 = 7;
    for (entries) |e| {
        if (e.tag == Tag.user and e.id == uid and e.perm & 1 != 0) user = true;
        if (e.tag == Tag.mask) m = e.perm;
    }
    return user and m & 1 != 0;
}

pub fn hex(b: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (b) |c| out.print(vh.gpa, "{x:0>2}", .{c}) catch vh.oom();
    return out.items;
}

pub fn unhex(s: []const u8) ?[]u8 {
    if (s.len % 2 != 0) return null;
    const out = vh.gpa.alloc(u8, s.len / 2) catch vh.oom();
    for (out, 0..) |*c, k| c.* = std.fmt.parseInt(u8, s[2 * k .. 2 * k + 2], 16) catch return null;
    return out;
}

const t = std.testing;

test "a named user's search bit on a directory only root enters, and the mask" {
    const x = withUser(null, 0o700, 1003, 1).?;
    const e = parse(x).?;
    try t.expectEqual(@as(usize, 5), e.len);
    try t.expectEqual(Entry{ .tag = Tag.user_obj, .perm = 7 }, e[0]);
    try t.expectEqual(Entry{ .tag = Tag.user, .perm = 1, .id = 1003 }, e[1]);
    try t.expectEqual(Entry{ .tag = Tag.group_obj, .perm = 0 }, e[2]);
    try t.expectEqual(Entry{ .tag = Tag.mask, .perm = 1 }, e[3]);
    try t.expectEqual(Entry{ .tag = Tag.other, .perm = 0 }, e[4]);
    try t.expect(lets(x, 1003));
    try t.expect(!lets(x, 1001));
    // the bytes: version 2, then tag, perm, id of each entry, little-endian
    try t.expectEqualStrings("02000000" ++ "01000700ffffffff" ++ "02000100eb030000" ++ "04000000ffffffff" ++ "10000100ffffffff" ++ "20000000ffffffff", hex(x));
    try t.expectEqualSlices(u8, x, unhex(hex(x)).?);
    // an ACL there already: the entry added, the others and their order kept, the mask the union
    const y = withUser(withUser(null, 0o750, 2000, 4).?, 0, 1003, 1).?;
    const f = parse(y).?;
    try t.expectEqual(@as(usize, 6), f.len);
    try t.expectEqual(Entry{ .tag = Tag.user, .perm = 1, .id = 1003 }, f[1]);
    try t.expectEqual(Entry{ .tag = Tag.user, .perm = 4, .id = 2000 }, f[2]);
    try t.expectEqual(Entry{ .tag = Tag.mask, .perm = 5 }, f[4]);
    // the same user again changes nothing
    try t.expectEqualSlices(u8, y, withUser(y, 0, 1003, 1).?);
    try t.expect(parse("garbage") == null);
}

test "a sound card's node: game's entry added, then taken away to the mode alone" {
    // root:audio 0660, as udev makes it: game reads and writes, other users still not
    const x = withUser(null, 0o20660, 1003, 6).?;
    try t.expectEqualStrings("02000000" ++ "01000600ffffffff" ++ "02000600eb030000" ++ "04000600ffffffff" ++ "10000600ffffffff" ++ "20000000ffffffff", hex(x));
    try t.expectEqual(@as(?u16, 6), userPerm(x, 1003));
    try t.expect(userPerm(x, 1001) == null);
    // the removal: no named entry is left, so no ACL either, and the group keeps rw
    const w = withoutUser(x, 1003).?;
    try t.expect(w.acl == null);
    try t.expectEqual(@as(u16, 6), w.group);
    try t.expect(withoutUser(x, 1001) == null);
    // another named entry stays, with the mask recomputed from what is left
    const y = withUser(withUser(null, 0o640, 2000, 1).?, 0, 1003, 6).?;
    const v = withoutUser(y, 1003).?;
    const e = parse(v.acl.?).?;
    try t.expectEqual(@as(usize, 5), e.len);
    try t.expectEqual(Entry{ .tag = Tag.user, .perm = 1, .id = 2000 }, e[1]);
    try t.expectEqual(Entry{ .tag = Tag.mask, .perm = 5 }, e[3]);
    try t.expectEqual(@as(u16, 4), v.group);
    // a mask narrower than the entry: what it really grants
    const z = parse(x).?;
    z[3].perm = 4;
    try t.expectEqual(@as(?u16, 4), userPerm(serialize(z), 1003));
}
