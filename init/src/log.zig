//! vh-init: the service logs. Each service's stdout and stderr is a pipe the manager reads;
//! every line goes to /var/log/vh/NAME/current with a UTC time stamp, as svlogd keeps them
//! (current, rotated to @STAMP.s when it reaches log_size, log_keep old files kept), or to the
//! kernel log with the service's name as the prefix (`log = kmsg`). No logger process per
//! service: runit runs one svlogd per service (two processes per service); here the manager
//! does it in its event loop. /var/log/vh is root's (0700).
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");

pub const dir = "/var/log/vh";

pub const Kind = enum { file, kmsg };

pub const Writer = struct {
    name: []const u8,
    kind: Kind,
    size_limit: u64,
    keep: u32,
    fd: linux.fd_t = -1,
    size: u64 = 0,
    partial: std.ArrayList(u8) = .empty,
    /// a message once when the directory cannot be made
    warned: bool = false,
    /// --root DIR of the tests
    root: []const u8 = "",

    pub fn init(name: []const u8, kind: Kind, size_limit: u64, keep: u32) Writer {
        return .{ .name = name, .kind = kind, .size_limit = size_limit, .keep = keep };
    }

    fn logDir(w: *const Writer) []u8 {
        return vh.fmt("{s}{s}/{s}", .{ w.root, dir, w.name });
    }

    fn open(w: *Writer) bool {
        if (w.fd >= 0) return true;
        const d = w.logDir();
        vh.mkdirs(d, 0o700);
        _ = linux.chmod(vh.z(vh.fmt("{s}{s}", .{ w.root, dir })).ptr, 0o700);
        const f = vh.fmt("{s}/current", .{d});
        w.fd = vh.openFd(f, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true }, 0o600) catch {
            if (!w.warned) vh.warn("log {s}: {s}: {s}", .{ w.name, f, vh.serr() });
            w.warned = true;
            return false;
        };
        const st = vh.fstat(w.fd) catch null;
        w.size = if (st) |s| s.size else 0;
        return true;
    }

    /// bytes read from the service's pipe: whole lines are written, the rest waits
    pub fn write(w: *Writer, bytes: []const u8) void {
        var rest = bytes;
        while (mem.indexOfScalar(u8, rest, '\n')) |nl| {
            if (w.partial.items.len > 0) {
                w.partial.appendSlice(vh.gpa, rest[0..nl]) catch vh.oom();
                w.line(w.partial.items);
                w.partial.clearRetainingCapacity();
            } else w.line(rest[0..nl]);
            rest = rest[nl + 1 ..];
        }
        if (rest.len > 0) {
            w.partial.appendSlice(vh.gpa, rest) catch vh.oom();
            // a line that never ends (a program printing a progress bar) is flushed at 4 KiB
            if (w.partial.items.len >= 4096) {
                w.line(w.partial.items);
                w.partial.clearRetainingCapacity();
            }
        }
    }

    /// the end of the pipe: whatever is left is a line
    pub fn flush(w: *Writer) void {
        if (w.partial.items.len > 0) {
            w.line(w.partial.items);
            w.partial.clearRetainingCapacity();
        }
    }

    fn line(w: *Writer, text: []const u8) void {
        const clean = stripControl(text);
        switch (w.kind) {
            .kmsg => {
                const kfd = vh.openFd(vh.fmt("{s}/dev/kmsg", .{w.root}), .{ .ACCMODE = .WRONLY, .NONBLOCK = true }, 0) catch return;
                defer vh.close(kfd);
                vh.writeAllFd(kfd, vh.fmt("<6>{s}: {s}\n", .{ w.name, clean[0..@min(clean.len, 900)] })) catch {};
            },
            .file => {
                if (!w.open()) return;
                const rec = vh.fmt("{s} {s}\n", .{ stamp(), clean });
                vh.writeAllFd(w.fd, rec) catch {
                    vh.close(w.fd);
                    w.fd = -1;
                    return;
                };
                w.size += rec.len;
                if (w.size >= w.size_limit) w.rotate();
            },
        }
    }

    /// current -> @STAMP.s; the oldest files beyond `keep` are removed
    pub fn rotate(w: *Writer) void {
        if (w.fd >= 0) {
            vh.close(w.fd);
            w.fd = -1;
        }
        const d = w.logDir();
        const cur = vh.fmt("{s}/current", .{d});
        const old = vh.fmt("{s}/@{s}.s", .{ d, fileStamp() });
        _ = linux.rename(vh.z(cur).ptr, vh.z(old).ptr);
        w.size = 0;
        // prune
        var names: std.ArrayList([]const u8) = .empty;
        for (vh.listDir(d) catch &.{}) |n| if (n.len > 3 and n[0] == '@' and vh.endsWith(n, ".s")) names.append(vh.gpa, n) catch vh.oom();
        mem.sort([]const u8, names.items, {}, vh.lessStr);
        var i: usize = 0;
        while (names.items.len - i > w.keep) : (i += 1) _ = linux.unlink(vh.z(vh.fmt("{s}/{s}", .{ d, names.items[i] })).ptr);
    }
};

/// control characters other than TAB become "?", as svlogd's -r does by default for escapes
pub fn stripControl(s: []const u8) []const u8 {
    var dirty = false;
    for (s) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) {
        dirty = true;
        break;
    };
    if (!dirty) return s;
    const out = vh.dupe(s);
    for (out) |*c| if ((c.* < 0x20 and c.* != '\t') or c.* == 0x7f) {
        c.* = '?';
    };
    return out;
}

/// "2026-10-26T02:00:00.123Z"
pub fn stamp() []u8 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const base = vh.utcTime(ts.sec); // "YYYY-MM-DD HH:MM:SS"
    const ms: u32 = @intCast(@divTrunc(ts.nsec, 1_000_000));
    const out = vh.fmt("{s}.{d:0>3}Z", .{ base, ms });
    out[10] = 'T';
    return out;
}

/// a stamp fit for a file name: 20261026T020000.123Z
fn fileStamp() []u8 {
    const s = stamp();
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| if (c != '-' and c != ':') out.append(vh.gpa, c) catch vh.oom();
    return out.items;
}

const testing = std.testing;

test "control characters" {
    try testing.expectEqualStrings("a\tb", stripControl("a\tb"));
    try testing.expectEqualStrings("a?b?", stripControl("a\x1bb\x7f"));
}

test "stamp shape" {
    const s = stamp();
    try testing.expectEqual(@as(usize, 24), s.len);
    try testing.expectEqual(@as(u8, 'T'), s[10]);
    try testing.expectEqual(@as(u8, 'Z'), s[23]);
    try testing.expectEqual(@as(usize, 20), fileStamp().len);
}
