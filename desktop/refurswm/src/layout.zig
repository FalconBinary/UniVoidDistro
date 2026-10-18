// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Pure layout logic: no Wayland here, so it is unit-tested on any host (`zig build test`).
//! Two layouts per workspace, switchable at runtime:
//!   dwindle - Hyprland-style binary tree: a new window splits the focused one along its longer side
//!   scroll  - an endless horizontal strip of columns (PaperWM/niri style); the view scrolls to the focus
//! Both only compute boxes; the caller applies them. Nothing here allocates per frame.
const std = @import("std");

/// Coordinates and sizes that come from a client are clamped into ±LIMIT (real outputs are at most
/// 16k wide), so a few of them always add up without overflowing i32. Box math also saturates,
/// so even values that bypassed `sanitize` cannot crash the compositor (ReleaseSafe panics on overflow).
pub const LIMIT: i32 = 1 << 16;

pub const Box = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn shrink(b: Box, by: i32) Box {
        return .{ .x = b.x +| by, .y = b.y +| by, .w = @max(1, b.w -| (by *| 2)), .h = @max(1, b.h -| (by *| 2)) };
    }

    pub fn empty(b: Box) bool {
        return b.w <= 0 or b.h <= 0;
    }

    pub fn contains(b: Box, x: f64, y: f64) bool {
        return x >= @as(f64, @floatFromInt(b.x)) and y >= @as(f64, @floatFromInt(b.y)) and
            x < @as(f64, @floatFromInt(b.x +| b.w)) and y < @as(f64, @floatFromInt(b.y +| b.h));
    }

    /// For anything a client controls: position within ±LIMIT, size within 1..LIMIT.
    pub fn sanitize(b: Box) Box {
        return .{
            .x = std.math.clamp(b.x, -LIMIT, LIMIT),
            .y = std.math.clamp(b.y, -LIMIT, LIMIT),
            .w = std.math.clamp(b.w, 1, LIMIT),
            .h = std.math.clamp(b.h, 1, LIMIT),
        };
    }
};

pub fn intersect(a: Box, b: Box) Box {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x +| a.w, b.x +| b.w);
    const y1 = @min(a.y +| a.h, b.y +| b.h);
    if (x1 <= x0 or y1 <= y0) return .{};
    return .{ .x = x0, .y = y0, .w = x1 -| x0, .h = y1 -| y0 };
}

/// Float to pixels without the panic @intFromFloat has for NaN or out-of-range values.
pub fn px(v: f64) i32 {
    return std.math.lossyCast(i32, @round(v));
}

pub const Mode = enum { dwindle, scroll };
pub const Dir = enum { left, right, up, down };

fn clampRatio(r: f32) f32 {
    return std.math.clamp(r, 0.1, 0.9);
}

pub fn Dwindle(comptime W: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            parent: ?*Node = null,
            box: Box = .{},
            kind: union(enum) {
                leaf: W,
                split: struct { a: *Node, b: *Node, horizontal: bool, ratio: f32 = 0.5 },
            },
        };

        root: ?*Node = null,

        fn find(n: *Node, w: W) ?*Node {
            switch (n.kind) {
                .leaf => |l| return if (l == w) n else null,
                .split => |sp| return find(sp.a, w) orelse find(sp.b, w),
            }
        }

        fn lastLeaf(n: *Node) *Node {
            var cur = n;
            while (true) switch (cur.kind) {
                .leaf => return cur,
                .split => |sp| cur = sp.b,
            };
        }

        fn replace(self: *Self, old: *Node, new: *Node) void {
            new.parent = old.parent;
            if (old.parent) |p| {
                if (p.kind.split.a == old) p.kind.split.a = new else p.kind.split.b = new;
            } else self.root = new;
        }

        pub fn contains(self: *Self, w: W) bool {
            return if (self.root) |r| find(r, w) != null else false;
        }

        /// Splits `target` (or the newest window) in two; the new window takes the right/bottom half.
        pub fn insert(self: *Self, gpa: std.mem.Allocator, w: W, target: ?W) !void {
            const leaf = try gpa.create(Node);
            leaf.* = .{ .kind = .{ .leaf = w } };
            const root = self.root orelse {
                self.root = leaf;
                return;
            };
            const t = (if (target) |tw| find(root, tw) else null) orelse lastLeaf(root);
            const split = gpa.create(Node) catch |e| {
                gpa.destroy(leaf);
                return e;
            };
            // split along the longer side, as Hyprland does with split_width_multiplier = 1
            split.* = .{ .box = t.box, .kind = .{ .split = .{ .a = t, .b = leaf, .horizontal = t.box.w >= t.box.h } } };
            self.replace(t, split);
            t.parent = split;
            leaf.parent = split;
        }

        pub fn remove(self: *Self, gpa: std.mem.Allocator, w: W) void {
            const n = find(self.root orelse return, w) orelse return;
            if (n.parent) |p| {
                const sib = if (p.kind.split.a == n) p.kind.split.b else p.kind.split.a;
                self.replace(p, sib);
                gpa.destroy(p);
            } else self.root = null;
            gpa.destroy(n);
        }

        pub fn arrange(self: *Self, box: Box, gap: i32, ctx: anytype) void {
            const b: Box = .{ .x = box.x, .y = box.y, .w = @max(1, box.w), .h = @max(1, box.h) };
            if (self.root) |r| place(r, b, gap, ctx);
        }

        fn place(n: *Node, box: Box, gap: i32, ctx: anytype) void {
            n.box = box;
            switch (n.kind) {
                .leaf => |w| ctx.emit(w, box),
                .split => |sp| {
                    var a = box;
                    var b = box;
                    if (sp.horizontal) {
                        const aw = px(@as(f64, @floatFromInt(box.w -| gap)) * @as(f64, sp.ratio));
                        a.w = @max(1, aw);
                        b.x = box.x +| aw +| gap;
                        b.w = @max(1, box.w -| aw -| gap);
                    } else {
                        const ah = px(@as(f64, @floatFromInt(box.h -| gap)) * @as(f64, sp.ratio));
                        a.h = @max(1, ah);
                        b.y = box.y +| ah +| gap;
                        b.h = @max(1, box.h -| ah -| gap);
                    }
                    place(sp.a, a, gap, ctx);
                    place(sp.b, b, gap, ctx);
                },
            }
        }

        /// grow=true: positive delta makes `w` bigger (keyboard); false: delta moves the divider (mouse drag).
        pub fn resize(self: *Self, w: W, dx: i32, dy: i32, grow: bool) void {
            const n = find(self.root orelse return, w) orelse return;
            inline for (.{ true, false }) |horiz| {
                const d = if (horiz) dx else dy;
                if (d != 0) {
                    var child = n;
                    while (child.parent) |p| : (child = p) {
                        const sp = &p.kind.split;
                        if (sp.horizontal != horiz) continue;
                        const span: f32 = @floatFromInt(@max(1, if (horiz) p.box.w else p.box.h));
                        const df = @as(f32, @floatFromInt(d)) / span;
                        sp.ratio = clampRatio(if (grow and sp.b == child) sp.ratio - df else sp.ratio + df);
                        break;
                    }
                }
            }
        }

        pub fn swap(self: *Self, a: W, b: W) void {
            const r = self.root orelse return;
            const na = find(r, a) orelse return;
            const nb = find(r, b) orelse return;
            na.kind.leaf = b;
            nb.kind.leaf = a;
        }

        pub fn toggleSplit(self: *Self, w: W) void {
            const n = find(self.root orelse return, w) orelse return;
            if (n.parent) |p| p.kind.split.horizontal = !p.kind.split.horizontal;
        }

        /// Windows in tree order (used to rebuild the other layout on a mode switch).
        pub fn collect(self: *Self, gpa: std.mem.Allocator, out: *std.ArrayList(W)) !void {
            if (self.root) |r| try walk(r, gpa, out);
        }

        fn walk(n: *Node, gpa: std.mem.Allocator, out: *std.ArrayList(W)) !void {
            switch (n.kind) {
                .leaf => |w| try out.append(gpa, w),
                .split => |sp| {
                    try walk(sp.a, gpa, out);
                    try walk(sp.b, gpa, out);
                },
            }
        }

        pub fn clear(self: *Self, gpa: std.mem.Allocator) void {
            if (self.root) |r| free(r, gpa);
            self.root = null;
        }

        fn free(n: *Node, gpa: std.mem.Allocator) void {
            switch (n.kind) {
                .leaf => {},
                .split => |sp| {
                    free(sp.a, gpa);
                    free(sp.b, gpa);
                },
            }
            gpa.destroy(n);
        }
    };
}

pub fn Scroll(comptime W: type) type {
    return struct {
        const Self = @This();

        pub const Column = struct {
            wins: std.ArrayList(W) = .empty,
            width: f32,
        };

        cols: std.ArrayList(Column) = .empty,
        /// strip x of the left screen edge, in pixels
        offset: i32 = 0,

        pub fn find(self: *Self, w: W) ?struct { col: usize, row: usize } {
            for (self.cols.items, 0..) |col, ci| {
                for (col.wins.items, 0..) |x, ri| if (x == w) return .{ .col = ci, .row = ri };
            }
            return null;
        }

        pub fn contains(self: *Self, w: W) bool {
            return self.find(w) != null;
        }

        /// New column right of the focused one (or at the end).
        pub fn insert(self: *Self, gpa: std.mem.Allocator, w: W, after: ?W, width: f32) !void {
            const at = if (after) |a| if (self.find(a)) |p| p.col + 1 else self.cols.items.len else self.cols.items.len;
            var col: Column = .{ .width = width };
            try col.wins.append(gpa, w);
            self.cols.insert(gpa, at, col) catch |e| {
                col.wins.deinit(gpa);
                return e;
            };
        }

        pub fn remove(self: *Self, gpa: std.mem.Allocator, w: W) void {
            const p = self.find(w) orelse return;
            const col = &self.cols.items[p.col];
            _ = col.wins.orderedRemove(p.row);
            if (col.wins.items.len == 0) {
                col.wins.deinit(gpa);
                _ = self.cols.orderedRemove(p.col);
            }
        }

        fn colWidth(col: Column, box: Box, gap: i32) i32 {
            // width 1/n fits n columns exactly: n*cw + (n-1)*gap = box.w
            const f = @as(f64, col.width) * @as(f64, @floatFromInt(box.w +| gap)) - @as(f64, @floatFromInt(gap));
            return @max(1, px(f));
        }

        /// `scroll_to`: keyboard focus moved to this window, bring its column into view.
        pub fn arrange(self: *Self, box: Box, gap: i32, scroll_to: ?W, center: bool, ctx: anytype) void {
            if (scroll_to) |w| if (self.find(w)) |p| {
                var x: i32 = 0;
                for (self.cols.items[0..p.col]) |col| x = x +| colWidth(col, box, gap) +| gap;
                const cw = colWidth(self.cols.items[p.col], box, gap);
                if (center) {
                    self.offset = x +| @divTrunc(cw -| box.w, 2);
                } else if (x < self.offset) {
                    self.offset = x;
                } else if (x +| cw > self.offset +| box.w) {
                    self.offset = x +| cw -| box.w;
                }
            };
            var x: i32 = box.x -| self.offset;
            for (self.cols.items) |col| {
                const cw = colWidth(col, box, gap);
                const n: i32 = @intCast(col.wins.items.len);
                const avail = box.h -| ((n - 1) *| gap);
                var y = box.y;
                for (col.wins.items, 0..) |w, i| {
                    const last = i + 1 == col.wins.items.len;
                    const h = if (last) box.y +| box.h -| y else @divTrunc(avail, n);
                    ctx.emit(w, Box{ .x = x, .y = y, .w = cw, .h = @max(1, h) });
                    y = y +| h +| gap;
                }
                x = x +| cw +| gap;
            }
        }

        /// left/right swaps whole columns, up/down moves the window inside its column.
        pub fn move(self: *Self, w: W, dir: Dir) void {
            const p = self.find(w) orelse return;
            const cols = self.cols.items;
            switch (dir) {
                .left => if (p.col > 0) std.mem.swap(Column, &cols[p.col], &cols[p.col - 1]),
                .right => if (p.col + 1 < cols.len) std.mem.swap(Column, &cols[p.col], &cols[p.col + 1]),
                .up => if (p.row > 0) std.mem.swap(W, &cols[p.col].wins.items[p.row], &cols[p.col].wins.items[p.row - 1]),
                .down => {
                    const ws = cols[p.col].wins.items;
                    if (p.row + 1 < ws.len) std.mem.swap(W, &ws[p.row], &ws[p.row + 1]);
                },
            }
        }

        /// Moves the window into the neighbouring column (stacked below its windows).
        pub fn merge(self: *Self, gpa: std.mem.Allocator, w: W, dir: Dir) !void {
            const p = self.find(w) orelse return;
            const target = switch (dir) {
                .left => if (p.col > 0) p.col - 1 else return,
                .right => if (p.col + 1 < self.cols.items.len) p.col + 1 else return,
                else => return,
            };
            try self.cols.items[target].wins.append(gpa, w);
            const src = &self.cols.items[p.col];
            _ = src.wins.orderedRemove(p.row);
            if (src.wins.items.len == 0) {
                src.wins.deinit(gpa);
                _ = self.cols.orderedRemove(p.col);
            }
        }

        /// Takes the window out of a shared column into its own column on the right.
        pub fn expel(self: *Self, gpa: std.mem.Allocator, w: W) !void {
            const p = self.find(w) orelse return;
            const col = &self.cols.items[p.col];
            if (col.wins.items.len < 2) return;
            var nc: Column = .{ .width = col.width };
            try nc.wins.append(gpa, w);
            self.cols.insert(gpa, p.col + 1, nc) catch |e| {
                nc.wins.deinit(gpa);
                return e;
            };
            _ = self.cols.items[p.col].wins.orderedRemove(p.row);
        }

        pub fn resize(self: *Self, w: W, dx: i32, area_w: i32) void {
            const p = self.find(w) orelse return;
            const col = &self.cols.items[p.col];
            col.width = std.math.clamp(col.width + @as(f32, @floatFromInt(dx)) / @as(f32, @floatFromInt(@max(1, area_w))), 0.1, 1.0);
        }

        pub fn cycleWidth(self: *Self, w: W, presets: []const f32) void {
            const p = self.find(w) orelse return;
            const col = &self.cols.items[p.col];
            for (presets) |pr| if (pr > col.width + 0.01) {
                col.width = pr;
                return;
            };
            col.width = presets[0];
        }

        pub fn collect(self: *Self, gpa: std.mem.Allocator, out: *std.ArrayList(W)) !void {
            for (self.cols.items) |col| try out.appendSlice(gpa, col.wins.items);
        }

        pub fn clear(self: *Self, gpa: std.mem.Allocator) void {
            for (self.cols.items) |*col| col.wins.deinit(gpa);
            self.cols.clearRetainingCapacity();
            self.offset = 0;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.clear(gpa);
            self.cols.deinit(gpa);
        }
    };
}

/// Nearest box in a direction: must lie past the current edge; overlap on the other axis wins,
/// then distance. Works for both layouts (scroll columns off-screen included).
pub fn neighbor(cur: Box, dir: Dir, cands: []const Box) ?usize {
    var best: ?usize = null;
    var best_score: i64 = std.math.maxInt(i64);
    const cx = cur.x +| @divTrunc(cur.w, 2);
    const cy = cur.y +| @divTrunc(cur.h, 2);
    for (cands, 0..) |b, i| {
        const past = switch (dir) {
            .left => b.x +| b.w <= cur.x +| 1,
            .right => b.x >= cur.x +| cur.w -| 1,
            .up => b.y +| b.h <= cur.y +| 1,
            .down => b.y >= cur.y +| cur.h -| 1,
        };
        if (!past) continue;
        const horiz = dir == .left or dir == .right;
        const overlap = if (horiz) @min(cur.y +| cur.h, b.y +| b.h) -| @max(cur.y, b.y) else @min(cur.x +| cur.w, b.x +| b.w) -| @max(cur.x, b.x);
        const bx = b.x +| @divTrunc(b.w, 2);
        const by = b.y +| @divTrunc(b.h, 2);
        const along: i64 = if (horiz) @abs(bx -| cx) else @abs(by -| cy);
        const across: i64 = if (horiz) @abs(by -| cy) else @abs(bx -| cx);
        const score = (if (overlap > 0) @as(i64, 0) else 1 << 40) + along * 4 + across;
        if (score < best_score) {
            best_score = score;
            best = i;
        }
    }
    return best;
}

// ---------------------------------------------------------------- tests

const Rec = struct {
    ids: [16]u32 = undefined,
    boxes: [16]Box = undefined,
    n: usize = 0,
    fn emit(self: *Rec, w: u32, b: Box) void {
        self.ids[self.n] = w;
        self.boxes[self.n] = b;
        self.n += 1;
    }
    fn get(self: *const Rec, w: u32) Box {
        for (self.ids[0..self.n], 0..) |id, i| if (id == w) return self.boxes[i];
        unreachable;
    }
};

const tt = std.testing;

test "dwindle splits along the longer side, new window right/bottom" {
    var d: Dwindle(u32) = .{};
    defer d.clear(tt.allocator);
    const area: Box = .{ .w = 1000, .h = 600 };
    var r: Rec = .{};
    try d.insert(tt.allocator, 1, null);
    d.arrange(area, 0, &r);
    try tt.expectEqual(Box{ .w = 1000, .h = 600 }, r.get(1));

    try d.insert(tt.allocator, 2, 1);
    r = .{};
    d.arrange(area, 0, &r);
    try tt.expectEqual(Box{ .w = 500, .h = 600 }, r.get(1));
    try tt.expectEqual(Box{ .x = 500, .w = 500, .h = 600 }, r.get(2));

    // 2 is 500x600: taller than wide, so it splits vertically
    try d.insert(tt.allocator, 3, 2);
    r = .{};
    d.arrange(area, 0, &r);
    try tt.expectEqual(Box{ .x = 500, .w = 500, .h = 300 }, r.get(2));
    try tt.expectEqual(Box{ .x = 500, .y = 300, .w = 500, .h = 300 }, r.get(3));

    d.remove(tt.allocator, 2);
    r = .{};
    d.arrange(area, 0, &r);
    try tt.expectEqual(@as(usize, 2), r.n);
    try tt.expectEqual(Box{ .x = 500, .w = 500, .h = 600 }, r.get(3));
}

test "dwindle gaps, resize, swap" {
    var d: Dwindle(u32) = .{};
    defer d.clear(tt.allocator);
    const area: Box = .{ .w = 1010, .h = 600 };
    var r: Rec = .{};
    try d.insert(tt.allocator, 1, null);
    d.arrange(area, 10, &r);
    try d.insert(tt.allocator, 2, 1);
    r = .{};
    d.arrange(area, 10, &r);
    try tt.expectEqual(Box{ .w = 500, .h = 600 }, r.get(1));
    try tt.expectEqual(Box{ .x = 510, .w = 500, .h = 600 }, r.get(2));

    d.resize(2, 100, 0, true); // grow the right window
    r = .{};
    d.arrange(area, 10, &r);
    try tt.expect(r.get(2).w > 590 and r.get(2).w < 610);
    d.swap(1, 2);
    r = .{};
    d.arrange(area, 10, &r);
    try tt.expect(r.get(1).x > 400);
    d.remove(tt.allocator, 1);
    d.remove(tt.allocator, 2);
    try tt.expect(d.root == null);
}

test "scroll strip keeps the focused column in view" {
    var s: Scroll(u32) = .{};
    defer s.deinit(tt.allocator);
    const area: Box = .{ .w = 1000, .h = 500 };
    try s.insert(tt.allocator, 1, null, 0.5);
    try s.insert(tt.allocator, 2, 1, 0.5);
    try s.insert(tt.allocator, 3, 2, 0.5);
    var r: Rec = .{};
    s.arrange(area, 0, 3, false, &r);
    try tt.expectEqual(@as(i32, 500), s.offset);
    try tt.expectEqual(Box{ .x = 500, .w = 500, .h = 500 }, r.get(3));
    try tt.expectEqual(Box{ .x = -500, .w = 500, .h = 500 }, r.get(1));

    r = .{};
    s.arrange(area, 0, 1, false, &r);
    try tt.expectEqual(@as(i32, 0), s.offset);

    try s.merge(tt.allocator, 3, .left); // 3 stacks under 2
    r = .{};
    s.arrange(area, 0, null, false, &r);
    try tt.expectEqual(Box{ .x = 500, .w = 500, .h = 250 }, r.get(2));
    try tt.expectEqual(Box{ .x = 500, .y = 250, .w = 500, .h = 250 }, r.get(3));
    try s.expel(tt.allocator, 3);
    try tt.expectEqual(@as(usize, 3), s.cols.items.len);

    s.cycleWidth(1, &.{ 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0 });
    try tt.expect(s.cols.items[0].width > 0.6);
    s.remove(tt.allocator, 2);
    try tt.expectEqual(@as(usize, 2), s.cols.items.len);
}

test "scroll gaps: two half columns fill the area exactly" {
    var s: Scroll(u32) = .{};
    defer s.deinit(tt.allocator);
    const area: Box = .{ .x = 10, .y = 10, .w = 990, .h = 500 };
    try s.insert(tt.allocator, 1, null, 0.5);
    try s.insert(tt.allocator, 2, 1, 0.5);
    var r: Rec = .{};
    s.arrange(area, 10, 2, false, &r);
    const b = r.get(2);
    try tt.expectEqual(area.x + area.w, b.x + b.w);
    try tt.expectEqual(@as(i32, 0), s.offset);
}

test "neighbor picks the overlapping box first" {
    const cur: Box = .{ .w = 500, .h = 600 };
    const cands = [_]Box{
        .{ .x = 500, .w = 500, .h = 300 },
        .{ .x = 500, .y = 300, .w = 500, .h = 300 },
        .{ .x = 0, .y = 600, .w = 500, .h = 100 },
    };
    try tt.expectEqual(@as(?usize, 0), neighbor(cur, .right, &cands));
    try tt.expectEqual(@as(?usize, 2), neighbor(cur, .down, &cands));
    try tt.expectEqual(@as(?usize, null), neighbor(cur, .left, &cands));
}

test "sanitize keeps client values in the safe range" {
    const min = std.math.minInt(i32);
    const max = std.math.maxInt(i32);
    const b = (Box{ .x = min, .y = max, .w = max, .h = min }).sanitize();
    try tt.expectEqual(Box{ .x = -LIMIT, .y = LIMIT, .w = LIMIT, .h = 1 }, b);
    // the box math saturates instead of panicking even on raw extremes
    _ = intersect(.{ .x = min, .y = min, .w = max, .h = max }, .{ .x = max, .y = max, .w = max, .h = max });
    _ = (Box{ .x = max, .y = min, .w = min, .h = max }).shrink(max);
    try tt.expect(!(Box{ .x = max, .y = max, .w = max, .h = max }).contains(0, 0));
    try tt.expectEqual(@as(i32, max), px(std.math.inf(f64)));
    try tt.expectEqual(@as(i32, 0), px(std.math.nan(f64)));
}

// Random operation sequences on both layouts, with random (also degenerate) areas and gaps:
// nothing panics or leaks, every window stays in the layout exactly once, every box is non-empty.
test "layouts survive random operation sequences" {
    var prng = std.Random.DefaultPrng.init(0x5eed_2026);
    const r = prng.random();
    const Set = struct {
        ids: [64]u32 = undefined,
        n: usize = 0,
        fn has(s: *const @This(), w: u32) bool {
            return std.mem.indexOfScalar(u32, s.ids[0..s.n], w) != null;
        }
        fn pick(s: *const @This(), rr: std.Random) ?u32 {
            return if (s.n == 0) null else s.ids[rr.uintLessThan(usize, s.n)];
        }
        fn del(s: *@This(), w: u32) void {
            const i = std.mem.indexOfScalar(u32, s.ids[0..s.n], w).?;
            s.ids[i] = s.ids[s.n - 1];
            s.n -= 1;
        }
    };
    const Check = struct {
        seen: [64]u32 = undefined,
        n: usize = 0,
        fn emit(self: *@This(), w: u32, b: Box) void {
            std.debug.assert(b.w >= 1 and b.h >= 1);
            self.seen[self.n] = w;
            self.n += 1;
        }
        fn same(self: *@This(), set: *const Set) !void {
            try tt.expectEqual(set.n, self.n);
            for (self.seen[0..self.n]) |w| try tt.expect(set.has(w));
        }
    };
    const extremes = [_]i32{ std.math.minInt(i32), -LIMIT, -1, 0, 1, LIMIT, std.math.maxInt(i32) };
    var next: u32 = 1;
    for (0..200) |_| {
        var d: Dwindle(u32) = .{};
        defer d.clear(tt.allocator);
        var sc: Scroll(u32) = .{};
        defer sc.deinit(tt.allocator);
        var set: Set = .{};
        const area: Box = if (r.uintLessThan(u8, 8) == 0)
            .{ .x = extremes[r.uintLessThan(usize, extremes.len)], .y = extremes[r.uintLessThan(usize, extremes.len)], .w = extremes[r.uintLessThan(usize, extremes.len)], .h = extremes[r.uintLessThan(usize, extremes.len)] }
        else
            .{ .x = r.intRangeAtMost(i32, -LIMIT, LIMIT), .y = r.intRangeAtMost(i32, -LIMIT, LIMIT), .w = r.intRangeAtMost(i32, 1, LIMIT), .h = r.intRangeAtMost(i32, 1, LIMIT) };
        const gap = r.intRangeAtMost(i32, 0, 64);
        for (0..500) |_| {
            switch (r.uintLessThan(u8, 10)) {
                0, 1, 2 => if (set.n < 64) {
                    const w = next;
                    next += 1;
                    try d.insert(tt.allocator, w, set.pick(r));
                    try sc.insert(tt.allocator, w, set.pick(r), 0.1 + r.float(f32) * 0.9);
                    set.ids[set.n] = w;
                    set.n += 1;
                },
                3 => if (set.pick(r)) |w| {
                    d.remove(tt.allocator, w);
                    sc.remove(tt.allocator, w);
                    set.del(w);
                },
                4 => if (set.pick(r)) |a| if (set.pick(r)) |b| d.swap(a, b),
                5 => if (set.pick(r)) |w| {
                    d.toggleSplit(w);
                    d.resize(w, r.intRangeAtMost(i32, -20000, 20000), r.intRangeAtMost(i32, -20000, 20000), r.boolean());
                    sc.resize(w, r.intRangeAtMost(i32, -20000, 20000), area.w);
                },
                6 => if (set.pick(r)) |w| sc.move(w, r.enumValue(Dir)),
                7 => if (set.pick(r)) |w| try sc.merge(tt.allocator, w, r.enumValue(Dir)),
                8 => if (set.pick(r)) |w| {
                    try sc.expel(tt.allocator, w);
                    sc.cycleWidth(w, &.{ 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0 });
                },
                else => {
                    var cd: Check = .{};
                    d.arrange(area, gap, &cd);
                    try cd.same(&set);
                    var cs: Check = .{};
                    sc.arrange(area, gap, set.pick(r), r.boolean(), &cs);
                    try cs.same(&set);
                },
            }
        }
    }
}
