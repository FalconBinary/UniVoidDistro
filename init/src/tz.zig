//! vh-stage1: the local UTC offset from /etc/localtime (TZif), for the kernel time zone
//! that `hwclock --systz` sets. Without libc there is no localtime(); std.tz parses the
//! file, the offset is the one of the last transition before now (TZif files carry the
//! explicit transitions until 2037; the POSIX footer rule is not evaluated).
const std = @import("std");
const vh = @import("vh");

/// minutes east of UTC at `now`, null when the file is missing or malformed
pub fn localOffsetMinutes(path: []const u8, now: i64) ?i32 {
    const bytes = vh.readFile(path) catch return null;
    return offsetOf(bytes, now);
}

pub fn offsetOf(tzif: []const u8, now: i64) ?i32 {
    var reader = std.Io.Reader.fixed(tzif);
    var tz = std.tz.Tz.parse(vh.gpa, &reader) catch return null;
    defer tz.deinit();
    if (tz.timetypes.len == 0) return null;
    var tt: ?*const std.tz.Timetype = null;
    for (tz.transitions) |t| {
        if (t.ts > now) break;
        tt = t.timetype;
    }
    if (tt == null) {
        // before the first transition: the first standard-time type, as the C library does
        for (tz.timetypes) |*t| if (!t.isDst()) {
            tt = t;
            break;
        };
        if (tt == null) tt = &tz.timetypes[0];
    }
    return @divTrunc(tt.?.offset, 60);
}

const testing = std.testing;

const TestBuf = struct {
    list: std.ArrayList(u8) = .empty,
    fn bytes(self: *TestBuf, b: []const u8) !void {
        try self.list.appendSlice(testing.allocator, b);
    }
    fn be32(self: *TestBuf, v: i32) !void {
        try self.bytes(&std.mem.toBytes(std.mem.nativeToBig(i32, v)));
    }
    fn be64(self: *TestBuf, v: i64) !void {
        try self.bytes(&std.mem.toBytes(std.mem.nativeToBig(i64, v)));
    }
};

test "offset from a minimal TZif" {
    // version-2 file: a legacy block with two types, then the 64-bit block with one
    // transition at t=1000 from type 0 (UTC+1, "X") to type 1 (UTC+2, "Y");
    // counts: isut 0 isstd 0 leap 0 time 1 type 2 char 4
    const zeros15: [15]u8 = @splat(0);
    var b: TestBuf = .{};
    defer b.list.deinit(testing.allocator);
    for ([_]bool{ false, true }) |wide| {
        try b.bytes("TZif2" ++ zeros15);
        for ([_]i32{ 0, 0, 0, 1, 2, 4 }) |c| try b.be32(c);
        if (wide) try b.be64(1000) else try b.be32(1000); // the transition time
        try b.bytes(&[_]u8{1}); // the transition's type index
        try b.be32(3600);
        try b.bytes(&[_]u8{ 0, 0 }); // type 0: offset, isdst, name index
        try b.be32(7200);
        try b.bytes(&[_]u8{ 0, 2 }); // type 1
        try b.bytes("X\x00Y\x00");
    }
    try b.bytes("\nCET-1\n");
    try testing.expectEqual(@as(?i32, 120), offsetOf(b.list.items, 5000));
    try testing.expectEqual(@as(?i32, 60), offsetOf(b.list.items, 10));
    try testing.expectEqual(@as(?i32, null), offsetOf("garbage", 10));
}
