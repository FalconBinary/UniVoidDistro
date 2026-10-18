// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Программная отрисовка в ARGB8888 (premultiplied): заливки, прямоугольники и
//! векторные примитивы со сглаживанием через функции расстояния (SDF). Цифры и иконки — свои
//! векторные фигуры, поэтому масштабируются без потерь.
//!
//! Скорость:
//! - смешивание целочисленное и векторное (SIMD): 8 пикселей за шаг, все 4 канала сразу, точное
//!   деление на 255 с округлением — результат бит в бит как у скалярного пути (тест внизу);
//! - у прямоугольников функция расстояния считается только у краёв, середина строки
//!   заливается одним проходом;
//! - маски покрытия иконок и глифов кешируются: повторный кадр — только смешивание с цветом;
//! - Canvas можно ограничить прямоугольником (top/bot/left/right): бар перерисовывает только
//!   изменившиеся элементы, всё за пределами не вычисляется вовсе.

const std = @import("std");

pub const Canvas = struct {
    px: []u32,
    w: i32,
    h: i32,
    /// Рисовать только строки [top, bot): частичная перерисовка (анимация, подсветка строки).
    /// Примитивы пропускают всё выше и ниже, не вычисляя.
    top: i32 = 0,
    bot: i32 = std.math.maxInt(i32),
    /// То же по столбцам: [left, right).
    left: i32 = 0,
    right: i32 = std.math.maxInt(i32),

    /// Первая и последняя+1 строка рисунка в [y0, y1), обрезанные по полосе.
    inline fn rows(self: *const Canvas, y0: i32, y1: i32) [2]i32 {
        return .{ @max(y0, @max(0, self.top)), @min(y1, @min(self.h, self.bot)) };
    }

    /// Первый и последний+1 столбец для рисунка в [x0, x1), обрезанные по области.
    inline fn colRange(self: *const Canvas, x0: i32, x1: i32) [2]i32 {
        return .{ @max(x0, @max(0, self.left)), @min(x1, @min(self.w, self.right)) };
    }

    /// Ограничить рисование прямоугольником (в пикселях устройства).
    pub fn clip(self: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32) void {
        self.left = x0;
        self.top = y0;
        self.right = x1;
        self.bot = y1;
    }

    pub fn unclip(self: *Canvas) void {
        self.clip(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    }

    pub fn clear(self: *Canvas, color: u32) void {
        const r = self.rows(0, self.h);
        const c = self.colRange(0, self.w);
        if (r[0] >= r[1] or c[0] >= c[1]) return;
        const w: usize = @intCast(self.w);
        const v = premul(color);
        if (c[0] == 0 and c[1] == self.w) {
            @memset(self.px[@as(usize, @intCast(r[0])) * w .. @as(usize, @intCast(r[1])) * w], v);
            return;
        }
        var y = r[0];
        while (y < r[1]) : (y += 1) @memset(self.row(y)[@intCast(c[0])..@intCast(c[1])], v);
    }

    /// Смешать цвет (не premultiplied ARGB) с покрытием cov (0..1).
    pub inline fn blend(self: *Canvas, x: i32, y: i32, color: u32, cov: f32) void {
        if (cov <= 0.0 or y < self.top or y >= self.bot or x < self.left or x >= self.right) return;
        const i: usize = @intCast(y * self.w + x);
        blendPx(&self.px[i], color, coverAlpha(color >> 24, cov));
    }

    fn row(self: *Canvas, y: i32) []u32 {
        const w: usize = @intCast(self.w);
        return self.px[@as(usize, @intCast(y)) * w ..][0..w];
    }

    /// Смешать 8-битную маску покрытия (глиф шрифта) с `color`.
    pub fn blit(self: *Canvas, bmp: []const u8, w: u16, h: u16, x: i32, y: i32, color: u32) void {
        const alpha = color >> 24;
        const cc = self.colRange(x, x + @as(i32, w));
        const c0: i32 = cc[0] - x;
        const c1: i32 = cc[1] - x;
        const rr = self.rows(y, y + @as(i32, h));
        const r0: i32 = rr[0] - y;
        const r1: i32 = rr[1] - y;
        if (c0 >= c1 or r0 >= r1) return;
        var r = r0;
        while (r < r1) : (r += 1) {
            const src = bmp[@as(usize, @intCast(r)) * w ..][@intCast(c0)..@intCast(c1)];
            const dst = self.row(y + r)[@intCast(x + c0)..][0..src.len];
            blendMask(dst, src, color, alpha);
        }
    }

    /// Изображение с premultiplied-альфой (0xAARRGGBB, w×h) один к одному в точку устройства (x, y).
    pub fn argb(self: *Canvas, src: []const u32, w: u32, h: u32, x: i32, y: i32) void {
        if (src.len < @as(usize, w) * h) return;
        const iw: i32 = @intCast(w);
        const cc = self.colRange(x, x + iw);
        const c0: i32 = cc[0] - x;
        const c1: i32 = cc[1] - x;
        const rr = self.rows(y, y + @as(i32, @intCast(h)));
        const r0: i32 = rr[0] - y;
        const r1: i32 = rr[1] - y;
        if (c0 >= c1 or r0 >= r1) return;
        var r = r0;
        while (r < r1) : (r += 1) {
            const s = src[@as(usize, @intCast(r)) * w ..][@intCast(c0)..@intCast(c1)];
            const dst = self.row(y + r)[@intCast(x + c0)..][0..s.len];
            overSpan(dst, s);
        }
    }

    /// RGB-изображение (3 байта на пиксель, sw×sh) в прямоугольник устройства (x, y, w, h):
    /// при уменьшении усредняется.
    pub fn image(self: *Canvas, rgb: []const u8, sw: u32, sh: u32, x: f32, y: f32, w: f32, h: f32) void {
        if (w < 1 or h < 1 or sw == 0 or sh == 0 or rgb.len < @as(usize, sw) * sh * 3) return;
        const xc = self.colRange(@intFromFloat(@floor(x)), @intFromFloat(@ceil(x + w)));
        const x0 = xc[0];
        const x1 = xc[1];
        const yr = self.rows(@intFromFloat(@floor(y)), @intFromFloat(@ceil(y + h)));
        const y0 = yr[0];
        const y1 = yr[1];
        if (x0 >= x1 or y0 >= y1) return;
        const fx: f32 = @as(f32, @floatFromInt(sw)) / w;
        const fy: f32 = @as(f32, @floatFromInt(sh)) / h;
        const b = Box{ .cx = x + w / 2, .cy = y + h / 2, .hw = w / 2, .hh = h / 2, .r = 0 };
        if (fx == 1 and fy == 1 and x == @floor(x) and y == @floor(y)) return self.image1(rgb, sw, b, x0, y0, x1, y1, x, y);
        // исходные столбцы для каждого столбца результата — один раз на изображение
        var cols: [4096][2]u32 = undefined;
        const ncols: usize = @intCast(x1 - x0);
        if (ncols > cols.len) return;
        for (cols[0..ncols], 0..) |*c, i| {
            const lx = @as(f32, @floatFromInt(x0 + @as(i32, @intCast(i)))) - x;
            c[0] = @intFromFloat(std.math.clamp(@floor(lx * fx), 0, @as(f32, @floatFromInt(sw - 1))));
            c[1] = @max(c[0] + 1, @min(sw, @as(u32, @intFromFloat(@max(0, @floor((lx + 1) * fx))))));
        }
        var py = y0;
        while (py < y1) : (py += 1) {
            const ly = @as(f32, @floatFromInt(py)) - y;
            const sy0: u32 = @intFromFloat(std.math.clamp(@floor(ly * fy), 0, @as(f32, @floatFromInt(sh - 1))));
            const sy1: u32 = @max(sy0 + 1, @min(sh, @as(u32, @intFromFloat(@max(0, @floor((ly + 1) * fy))))));
            const span = b.fullSpan(py, x0, x1, 0.5);
            const dst = self.row(py);
            var px = x0;
            while (px < x1) : (px += 1) {
                var cov: f32 = 1;
                if (px < span[0] or px >= span[1]) {
                    cov = 0.5 - b.sdf(@as(f32, @floatFromInt(px)) + 0.5, @as(f32, @floatFromInt(py)) + 0.5);
                    if (cov <= 0) continue;
                }
                const c = cols[@intCast(px - x0)];
                var acc: [3]u32 = .{ 0, 0, 0 };
                var sy = sy0;
                while (sy < sy1) : (sy += 1) {
                    var i = (@as(usize, sy) * sw + c[0]) * 3;
                    var sx = c[0];
                    while (sx < c[1]) : (sx += 1) {
                        acc[0] += rgb[i];
                        acc[1] += rgb[i + 1];
                        acc[2] += rgb[i + 2];
                        i += 3;
                    }
                }
                const cnt = (sy1 - sy0) * (c[1] - c[0]);
                const col = 0xff000000 | ((acc[0] / cnt) << 16) | ((acc[1] / cnt) << 8) | (acc[2] / cnt);
                blendPx(&dst[@intCast(px)], col, coverAlpha(255, cov));
            }
        }
    }

    /// Изображение уже в размер экрана (миниатюры под масштаб): пиксель в пиксель,
    /// середина строки простым копированием, только дробные края через функцию расстояния.
    fn image1(self: *Canvas, rgb: []const u8, sw: u32, b: Box, x0: i32, y0: i32, x1: i32, y1: i32, x: f32, y: f32) void {
        const ix: i32 = @intFromFloat(x);
        const iy: i32 = @intFromFloat(y);
        var py = y0;
        while (py < y1) : (py += 1) {
            const src = rgb[@as(usize, @intCast(py - iy)) * sw * 3 ..];
            const dst = self.row(py);
            const span = b.fullSpan(py, x0, x1, 0.5);
            var px = x0;
            while (px < x1) : (px += 1) {
                const i: usize = @as(usize, @intCast(px - ix)) * 3;
                const col = 0xff000000 | (@as(u32, src[i]) << 16) | (@as(u32, src[i + 1]) << 8) | src[i + 2];
                if (px >= span[0] and px < span[1]) {
                    dst[@intCast(px)] = col;
                } else {
                    const cov = 0.5 - b.sdf(@as(f32, @floatFromInt(px)) + 0.5, @as(f32, @floatFromInt(py)) + 0.5);
                    if (cov > 0) blendPx(&dst[@intCast(px)], col, coverAlpha(255, cov));
                }
            }
        }
    }

    /// Обходит пиксели прямоугольника и закрашивает с покрытием clamp(0.5 - dist).
    fn paint(self: *Canvas, x0f: f32, y0f: f32, x1f: f32, y1f: f32, color: u32, ctx: anytype, comptime dist: fn (@TypeOf(ctx), f32, f32) f32) void {
        const xc = self.colRange(@intFromFloat(@max(-1e6, @floor(x0f))), @intFromFloat(@min(1e6, @ceil(x1f))));
        const x0 = xc[0];
        const x1 = xc[1];
        const yr = self.rows(@intFromFloat(@max(-1e6, @floor(y0f))), @intFromFloat(@min(1e6, @ceil(y1f))));
        const y0 = yr[0];
        const y1 = yr[1];
        const alpha = color >> 24;
        var y = y0;
        while (y < y1) : (y += 1) {
            const dst = self.row(y);
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            var x = x0;
            while (x < x1) : (x += 1) {
                const cov = 0.5 - dist(ctx, @as(f32, @floatFromInt(x)) + 0.5, fy);
                if (cov > 0) blendPx(&dst[@intCast(x)], color, coverAlpha(alpha, cov));
            }
        }
    }

    /// Пиксели строки y в [xa, xb) — с покрытием по функции расстояния прямоугольника b
    /// (заливка или контур с полутолщиной hw).
    fn boxEdges(self: *Canvas, b: Box, y: i32, xa: i32, xb: i32, color: u32, comptime outline: bool, hw: f32) void {
        const dst = self.row(y);
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const alpha = color >> 24;
        var x = xa;
        while (x < xb) : (x += 1) {
            const d = b.sdf(@as(f32, @floatFromInt(x)) + 0.5, fy);
            const cov = 0.5 - (if (outline) @abs(d) - hw else d);
            if (cov > 0) blendPx(&dst[@intCast(x)], color, coverAlpha(alpha, cov));
        }
    }

    pub fn fillRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, color: u32) void {
        if (!(w > 0 and h > 0)) return;
        const b = Box{ .cx = x + w / 2, .cy = y + h / 2, .hw = w / 2, .hh = h / 2, .r = 0 };
        const xc = self.colRange(@intFromFloat(@floor(x - 1)), @intFromFloat(@ceil(x + w + 1)));
        const x0 = xc[0];
        const x1 = xc[1];
        const yr = self.rows(@intFromFloat(@floor(y - 1)), @intFromFloat(@ceil(y + h + 1)));
        const y0 = yr[0];
        const y1 = yr[1];
        if (x0 >= x1) return;
        var py = y0;
        while (py < y1) : (py += 1) {
            // полностью покрытая середина строки одним проходом, края через функцию расстояния
            const s = b.fullSpan(py, x0, x1, 0.5);
            self.boxEdges(b, py, x0, s[0], color, false, 0);
            fillSpan(self.row(py)[@intCast(s[0])..@intCast(s[1])], color);
            self.boxEdges(b, py, s[1], x1, color, false, 0);
        }
    }

    /// Контур скруглённого прямоугольника толщиной `stroke` (по центру линии — края b).
    fn strokeBox(self: *Canvas, b: Box, stroke: f32, color: u32) void {
        const hw = stroke / 2;
        const pad = hw + 1;
        const xc = self.colRange(@intFromFloat(@floor(b.cx - b.hw - pad)), @intFromFloat(@ceil(b.cx + b.hw + pad)));
        const x0 = xc[0];
        const x1 = xc[1];
        const yr = self.rows(@intFromFloat(@floor(b.cy - b.hh - pad)), @intFromFloat(@ceil(b.cy + b.hh + pad)));
        const y0 = yr[0];
        const y1 = yr[1];
        if (x0 >= x1) return;
        var py = y0;
        while (py < y1) : (py += 1) {
            // внутри «дыры» (дальше полутолщины + 0.5 от линии) покрытие нулевое — пропуск
            const s = b.fullSpan(py, x0, x1, hw + 0.5);
            self.boxEdges(b, py, x0, s[0], color, true, hw);
            self.boxEdges(b, py, s[1], x1, color, true, hw);
        }
    }

    /// Рисует набор примитивов. Координаты примитивов — в «единицах»,
    /// пиксель = (ox, oy) + единица * s. stroke — толщина линий в пикселях.
    pub fn prims(self: *Canvas, list: []const Prim, ox: f32, oy: f32, s: f32, stroke: f32, color: u32) void {
        // один контур прямоугольника (рамка меню, фокус) — середину не обходить
        if (list.len == 1 and list[0] == .box) {
            const v = list[0].box;
            const w = v.w * s;
            const h = v.h * s;
            const b = Box{ .cx = ox + v.x * s + w / 2, .cy = oy + v.y * s + h / 2, .hw = w / 2, .hh = h / 2, .r = v.r * s };
            return self.strokeBox(b, stroke, color);
        }
        var buf: [24]Prim = undefined;
        const n = @min(list.len, buf.len);
        var bx0: f32 = 1e9;
        var by0: f32 = 1e9;
        var bx1: f32 = -1e9;
        var by1: f32 = -1e9;
        for (list[0..n], 0..) |p, i| {
            const t = p.transform(ox, oy, s);
            buf[i] = t;
            const b = t.bounds();
            bx0 = @min(bx0, b[0]);
            by0 = @min(by0, b[1]);
            bx1 = @max(bx1, b[2]);
            by1 = @max(by1, b[3]);
        }
        const ctx = Group{ .p = buf[0..n], .hw = stroke / 2 };
        const pad = stroke / 2 + 1;
        self.paint(bx0 - pad, by0 - pad, bx1 + pad, by1 + pad, color, ctx, Group.sdf);
    }

    /// То же, что prims, но маска покрытия считается один раз и дальше берётся из кеша:
    /// иконки и цифры одинаковы в каждом кадре, и перерисовка — только смешивание с цветом.
    /// Положение учитывается с точностью 1/4 пикселя (целые положения — пиксель в пиксель, как prims).
    pub fn icon(self: *Canvas, list: []const Prim, ox: f32, oy: f32, s: f32, stroke: f32, color: u32) void {
        if (list.len == 0 or list.len > 24 or !(@abs(ox) < 1e6 and @abs(oy) < 1e6))
            return self.prims(list, ox, oy, s, stroke, color);
        const qx = @round(ox * 4);
        const qy = @round(oy * 4);
        const fx = @mod(qx, 4);
        const fy = @mod(qy, 4);
        const m = maskFor(list, fx / 4, fy / 4, s, stroke) orelse return self.prims(list, ox, oy, s, stroke, color);
        const ix: i32 = @intFromFloat((qx - fx) / 4);
        const iy: i32 = @intFromFloat((qy - fy) / 4);
        self.blit(mask_pool[m.off..][0 .. @as(usize, m.w) * m.h], m.w, m.h, ix + m.x0, iy + m.y0, color);
    }
};

// ---------------------------------------------------------------- кеш масок иконок

const MaskSlot = struct { key: u64 = 0, x0: i32 = 0, y0: i32 = 0, w: u16 = 0, h: u16 = 0, off: u32 = 0, used: u32 = 0 };
const MASK_SLOTS = 128;
var mask_slots: [MASK_SLOTS]MaskSlot = @as([MASK_SLOTS]MaskSlot, @splat(.{}));
var mask_pool: [128 * 1024]u8 = undefined;
var mask_used: usize = 0;
var mask_tick: u32 = 0;

/// Ключ набора примитивов — по значениям полей (не по адресу и не по байтам с выравниванием).
fn maskKey(list: []const Prim, fx: f32, fy: f32, s: f32, stroke: f32) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const mix = struct {
        fn f(acc: *u64, v: f32) void {
            acc.* = (acc.* ^ @as(u32, @bitCast(v))) *% 0x100000001b3;
            acc.* ^= acc.* >> 29;
        }
    }.f;
    mix(&h, fx);
    mix(&h, fy);
    mix(&h, s);
    mix(&h, stroke);
    for (list) |p| {
        mix(&h, @floatFromInt(@intFromEnum(std.meta.activeTag(p))));
        switch (p) {
            .seg => |v| inline for (.{ v.x0, v.y0, v.x1, v.y1 }) |x| mix(&h, x),
            .arc => |v| inline for (.{ v.cx, v.cy, v.r, v.a0, v.a1 }) |x| mix(&h, x),
            .ring => |v| inline for (.{ v.cx, v.cy, v.r }) |x| mix(&h, x),
            .dot => |v| inline for (.{ v.cx, v.cy, v.r }) |x| mix(&h, x),
            .box => |v| inline for (.{ v.x, v.y, v.w, v.h, v.r }) |x| mix(&h, x),
            .fbox => |v| inline for (.{ v.x, v.y, v.w, v.h, v.r }) |x| mix(&h, x),
        }
    }
    return if (h == 0) 1 else h;
}

/// Маска покрытия (0..255) набора примитивов с началом в (fx, fy) внутри пикселя.
fn maskFor(list: []const Prim, fx: f32, fy: f32, s: f32, stroke: f32) ?*const MaskSlot {
    const key = maskKey(list, fx, fy, s, stroke);
    // два слота-кандидата: иконки одного кадра не вытесняют друг друга по кругу
    const sa = &mask_slots[key % MASK_SLOTS];
    const sb = &mask_slots[(key >> 32) % MASK_SLOTS];
    mask_tick +%= 1;
    if (sa.key == key) {
        sa.used = mask_tick;
        return sa;
    }
    if (sb.key == key) {
        sb.used = mask_tick;
        return sb;
    }
    const slot = if (sa.key == 0 or (sb.key != 0 and mask_tick -% sa.used >= mask_tick -% sb.used)) sa else sb;

    var buf: [24]Prim = undefined;
    var bx0: f32 = 1e9;
    var by0: f32 = 1e9;
    var bx1: f32 = -1e9;
    var by1: f32 = -1e9;
    for (list, 0..) |p, i| {
        const t = p.transform(fx, fy, s);
        buf[i] = t;
        const b = t.bounds();
        bx0 = @min(bx0, b[0]);
        by0 = @min(by0, b[1]);
        bx1 = @max(bx1, b[2]);
        by1 = @max(by1, b[3]);
    }
    // та же область, что обходит prims: рамка примитивов плюс полутолщина и запасной пиксель
    const pad = stroke / 2 + 1;
    const x0f = @floor(bx0 - pad);
    const y0f = @floor(by0 - pad);
    const wf = @ceil(bx1 + pad) - x0f;
    const hf = @ceil(by1 + pad) - y0f;
    if (!(wf >= 1 and hf >= 1 and wf <= 256 and hf <= 256 and @abs(x0f) < 4096 and @abs(y0f) < 4096)) return null;
    const w: usize = @intFromFloat(wf);
    const h: usize = @intFromFloat(hf);
    if (mask_used + w * h > mask_pool.len) { // пул кончился — начать заново
        mask_used = 0;
        for (&mask_slots) |*m| m.* = .{};
    }
    const out = mask_pool[mask_used..][0 .. w * h];
    const g = Group{ .p = buf[0..list.len], .hw = stroke / 2 };
    for (0..h) |j| {
        const py = y0f + @as(f32, @floatFromInt(j)) + 0.5;
        for (out[j * w ..][0..w], 0..) |*o, i| {
            // покрытие как в paint/coverAlpha: clamp(0.5 − d), с округлением до 1/255
            const cov = 0.5 - g.sdf(x0f + @as(f32, @floatFromInt(i)) + 0.5, py);
            o.* = if (cov <= 0) 0 else if (cov >= 1) 255 else @intFromFloat(cov * 255 + 0.5);
        }
    }
    slot.* = .{ .key = key, .x0 = @intFromFloat(x0f), .y0 = @intFromFloat(y0f), .w = @intCast(w), .h = @intCast(h), .off = @intCast(mask_used), .used = mask_tick };
    mask_used += w * h;
    return slot;
}

pub fn premul(c: u32) u32 {
    const a = c >> 24;
    if (a == 255) return c;
    var out: u32 = a << 24;
    inline for (.{ 0, 8, 16 }) |sh| {
        out |= (((c >> sh) & 0xff) * a / 255) << sh;
    }
    return out;
}

// ---------------------------------------------------------------- SIMD
// 8 пикселей = 32 байта = 32 канала по u16. Порядок байт в u32 (B, G, R, A) не важен: формула одна
// для всех каналов. Максимум s·a + d·(255 − a) + 128 = 65153 — помещается в u16 без переполнения.

const N = 8;
const W16 = @Vector(N * 4, u16);
const U8x = @Vector(N * 4, u8);

/// Каждый из 8 элементов повторён 4 раза: альфа пикселя на все его каналы.
const rep4: @Vector(N * 4, i32) = blk: {
    var m: [N * 4]i32 = undefined;
    for (0..N * 4) |i| m[i] = @intCast(i / 4);
    break :blk m;
};

inline fn load8(p: *const [N]u32) W16 {
    const b: U8x = @bitCast(p.*);
    return b;
}

inline fn store8(p: *[N]u32, v: W16) void {
    p.* = @bitCast(@as(U8x, @truncate(v)));
}

/// x / 255 с округлением, точно для 0..65535 (векторно).
inline fn div255v(x: W16) W16 {
    const t = x +% @as(W16, @splat(128));
    return (t +% (t >> @splat(8))) >> @splat(8);
}

/// Цвет (не premultiplied, альфа канала → 255) во все 8 пикселей.
inline fn splatColor(color: u32) W16 {
    const one: [N]u32 = @splat(color | 0xff000000);
    return load8(&one);
}

/// dst = color·a + dst·(1 − a), где a = alpha·mask / 255 для каждого пикселя (глифы, иконки).
fn blendMask(dst: []u32, mask: []const u8, color: u32, alpha: u32) void {
    var i: usize = 0;
    if (dst.len >= N) {
        const s = splatColor(color);
        const al: @Vector(N, u16) = @splat(@intCast(alpha));
        while (i + N <= dst.len) : (i += N) {
            const m: @Vector(N, u16) = mask[i..][0..N].*;
            if (@reduce(.Or, m) == 0) continue; // пусто — пропуск без записи
            const a8 = div255v8(al *% m);
            const a: W16 = @shuffle(u16, a8, undefined, rep4);
            const d = load8(dst[i..][0..N]);
            store8(dst[i..][0..N], div255v(s *% a +% d *% (@as(W16, @splat(255)) -% a)));
        }
    }
    while (i < dst.len) : (i += 1) {
        if (mask[i] != 0) blendPx(&dst[i], color, div255(alpha * mask[i]));
    }
}

inline fn div255v8(x: @Vector(N, u16)) @Vector(N, u16) {
    const t = x +% @as(@Vector(N, u16), @splat(128));
    return (t +% (t >> @splat(8))) >> @splat(8);
}

/// dst = src + dst·(1 − src.a) — premultiplied src поверх (иконки приложений).
fn overSpan(dst: []u32, src: []const u32) void {
    var i: usize = 0;
    while (i + N <= dst.len) : (i += N) {
        const sp = src[i..][0..N];
        var amax: u32 = 0;
        var amin: u32 = 255;
        inline for (0..N) |k| {
            amax = @max(amax, sp[k] >> 24);
            amin = @min(amin, sp[k] >> 24);
        }
        if (amax == 0) continue;
        if (amin == 255) {
            dst[i..][0..N].* = sp.*;
            continue;
        }
        const s = load8(sp);
        const sa: @Vector(N, u16) = .{ @intCast(sp[0] >> 24), @intCast(sp[1] >> 24), @intCast(sp[2] >> 24), @intCast(sp[3] >> 24), @intCast(sp[4] >> 24), @intCast(sp[5] >> 24), @intCast(sp[6] >> 24), @intCast(sp[7] >> 24) };
        const k: W16 = @shuffle(u16, @as(@Vector(N, u16), @splat(255)) -% sa, undefined, rep4);
        const d = load8(dst[i..][0..N]);
        store8(dst[i..][0..N], s +% div255v(d *% k));
    }
    while (i < dst.len) : (i += 1) {
        const p = src[i];
        const a = p >> 24;
        if (a == 0) continue;
        dst[i] = if (a == 255) p else p + scalePx(dst[i], 255 - a);
    }
}

/// Все четыре канала × k / 255 (по два канала в каждой 16-битной половине слова).
inline fn scalePx(c: u32, k: u32) u32 {
    const rb = (c & 0x00ff00ff) * k + 0x00800080;
    const ag = ((c >> 8) & 0x00ff00ff) * k + 0x00800080;
    return (((rb + ((rb >> 8) & 0x00ff00ff)) >> 8) & 0x00ff00ff) | ((ag + ((ag >> 8) & 0x00ff00ff)) & 0xff00ff00);
}

/// x / 255 с округлением, точно для 0..65535.
inline fn div255(x: u32) u32 {
    return (x + 128 + ((x + 128) >> 8)) >> 8;
}

/// Непрозрачность 0..255: альфа цвета × покрытие.
inline fn coverAlpha(alpha: u32, cov: f32) u32 {
    if (cov >= 1) return alpha;
    return div255(alpha * @as(u32, @intFromFloat(cov * 255 + 0.5)));
}

/// d = c·a + d·(1 − a) во всех четырёх каналах сразу (c не premultiplied,
/// альфа-канал получает 255): по два канала в каждой 16-битной половине слова.
inline fn blendPx(d: *u32, color: u32, a: u32) void {
    if (a == 0) return;
    if (a >= 255) {
        d.* = color | 0xff000000;
        return;
    }
    const s = color | 0xff000000;
    const dv = d.*;
    const inv = 255 - a;
    const rb = (s & 0x00ff00ff) * a + (dv & 0x00ff00ff) * inv + 0x00800080;
    const ag = ((s >> 8) & 0x00ff00ff) * a + ((dv >> 8) & 0x00ff00ff) * inv + 0x00800080;
    d.* = (((rb + ((rb >> 8) & 0x00ff00ff)) >> 8) & 0x00ff00ff) | ((ag + ((ag >> 8) & 0x00ff00ff)) & 0xff00ff00);
}

/// Залить строку цветом с полным покрытием. Повторяющиеся пиксели фона
/// (а после clear — вся строка) смешиваются один раз.
fn fillSpan(dst: []u32, color: u32) void {
    const a = color >> 24;
    if (a >= 255) return @memset(dst, color | 0xff000000);
    if (a == 0) return;
    var last_in: u32 = 0;
    var last_out: u32 = 0;
    var have = false;
    for (dst) |*d| {
        if (!have or d.* != last_in) {
            last_in = d.*;
            blendPx(d, color, a);
            last_out = d.*;
            have = true;
        } else d.* = last_out;
    }
}

const Box = struct {
    cx: f32,
    cy: f32,
    hw: f32,
    hh: f32,
    r: f32,
    fn sdf(b: Box, x: f32, y: f32) f32 {
        return sdBox(x - b.cx, y - b.cy, b.hw, b.hh, b.r);
    }

    /// Пиксели строки y в [x0, x1), чьё расстояние до края ≤ −t (при t = 0.5 — полностью
    /// покрыты). Возвращает [начало, конец) — пустой диапазон, если таких нет.
    fn fullSpan(b: Box, y: i32, x0: i32, x1: i32, t: f32) [2]i32 {
        // радиус больше половины стороны — формула ниже неверна, считаем всё по расстоянию
        if (b.r > @min(b.hw, b.hh)) return .{ x1, x1 };
        const dy = @abs(@as(f32, @floatFromInt(y)) + 0.5 - b.cy);
        var ih: f32 = undefined;
        if (b.r >= t) {
            const qy = dy - (b.hh - b.r);
            const rt = b.r - t;
            if (qy <= 0) {
                ih = b.hw - t;
            } else if (qy <= rt) {
                ih = b.hw - b.r + @sqrt(rt * rt - qy * qy);
            } else return .{ x1, x1 };
        } else if (dy <= b.hh - t) {
            ih = b.hw - t;
        } else return .{ x1, x1 };
        ih -= 1e-3; // запас на ошибку округления: граничные пиксели посчитает функция расстояния
        if (ih < 0) return .{ x1, x1 };
        // центр пикселя x + 0.5 в [cx − ih, cx + ih]
        const lo = std.math.clamp(@ceil(b.cx - ih - 0.5), @as(f32, @floatFromInt(x0)), @as(f32, @floatFromInt(x1)));
        const hi = std.math.clamp(@floor(b.cx + ih - 0.5) + 1, lo, @as(f32, @floatFromInt(x1)));
        return .{ @intFromFloat(lo), @intFromFloat(hi) };
    }
};

fn sdBox(px: f32, py: f32, hw: f32, hh: f32, r: f32) f32 {
    const qx = @abs(px) - (hw - r);
    const qy = @abs(py) - (hh - r);
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - r;
}

fn segDist(px: f32, py: f32, x0: f32, y0: f32, x1: f32, y1: f32) f32 {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const l2 = dx * dx + dy * dy;
    var t: f32 = if (l2 > 0) ((px - x0) * dx + (py - y0) * dy) / l2 else 0;
    t = std.math.clamp(t, 0.0, 1.0);
    const ex = px - (x0 + t * dx);
    const ey = py - (y0 + t * dy);
    return @sqrt(ex * ex + ey * ey);
}

/// Быстрый atan2 (ошибка ~1e-5 рад) — чтобы не зависеть от сигнатуры std.math.atan2.
fn atan2(y: f32, x: f32) f32 {
    const ax = @abs(x);
    const ay = @abs(y);
    const mx = @max(ax, ay);
    if (mx == 0) return 0;
    const a = @min(ax, ay) / mx;
    const s = a * a;
    var r = ((-0.0464964749 * s + 0.15931422) * s - 0.327622764) * s * a + a;
    if (ay > ax) r = 1.57079637 - r;
    if (x < 0) r = 3.14159274 - r;
    if (y < 0) r = -r;
    return r;
}

const TAU: f32 = 6.28318531;

/// Векторный примитив. Углы дуг в градусах, 0° = вправо, 90° = вниз,
/// дуга идёт по часовой от a0 к a1.
pub const Prim = union(enum) {
    seg: struct { x0: f32, y0: f32, x1: f32, y1: f32 },
    arc: struct { cx: f32, cy: f32, r: f32, a0: f32, a1: f32, ends: [4]f32 = .{ 0, 0, 0, 0 } }, // ends — концы, считаются в transform
    ring: struct { cx: f32, cy: f32, r: f32 },
    dot: struct { cx: f32, cy: f32, r: f32 }, // заливка
    box: struct { x: f32, y: f32, w: f32, h: f32, r: f32 }, // контур
    fbox: struct { x: f32, y: f32, w: f32, h: f32, r: f32 }, // заливка

    fn transform(p: Prim, ox: f32, oy: f32, s: f32) Prim {
        return switch (p) {
            .seg => |v| .{ .seg = .{ .x0 = ox + v.x0 * s, .y0 = oy + v.y0 * s, .x1 = ox + v.x1 * s, .y1 = oy + v.y1 * s } },
            .arc => |v| blk: {
                const cx = ox + v.cx * s;
                const cy = oy + v.cy * s;
                const r = v.r * s;
                const a0 = v.a0 * TAU / 360.0;
                const a1 = v.a1 * TAU / 360.0;
                break :blk .{ .arc = .{ .cx = cx, .cy = cy, .r = r, .a0 = a0, .a1 = a1, .ends = .{ cx + r * @cos(a0), cy + r * @sin(a0), cx + r * @cos(a1), cy + r * @sin(a1) } } };
            },
            .ring => |v| .{ .ring = .{ .cx = ox + v.cx * s, .cy = oy + v.cy * s, .r = v.r * s } },
            .dot => |v| .{ .dot = .{ .cx = ox + v.cx * s, .cy = oy + v.cy * s, .r = v.r * s } },
            .box => |v| .{ .box = .{ .x = ox + v.x * s, .y = oy + v.y * s, .w = v.w * s, .h = v.h * s, .r = v.r * s } },
            .fbox => |v| .{ .fbox = .{ .x = ox + v.x * s, .y = oy + v.y * s, .w = v.w * s, .h = v.h * s, .r = v.r * s } },
        };
    }

    fn bounds(p: Prim) [4]f32 {
        return switch (p) {
            .seg => |v| .{ @min(v.x0, v.x1), @min(v.y0, v.y1), @max(v.x0, v.x1), @max(v.y0, v.y1) },
            .arc => |v| .{ v.cx - v.r, v.cy - v.r, v.cx + v.r, v.cy + v.r },
            .ring => |v| .{ v.cx - v.r, v.cy - v.r, v.cx + v.r, v.cy + v.r },
            .dot => |v| .{ v.cx - v.r, v.cy - v.r, v.cx + v.r, v.cy + v.r },
            .box => |v| .{ v.x, v.y, v.x + v.w, v.y + v.h },
            .fbox => |v| .{ v.x, v.y, v.x + v.w, v.y + v.h },
        };
    }

    /// Расстояние до примитива с учётом полутолщины линии hw.
    fn dist(p: Prim, x: f32, y: f32, hw: f32) f32 {
        switch (p) {
            .seg => |v| return segDist(x, y, v.x0, v.y0, v.x1, v.y1) - hw,
            .ring => |v| {
                const dx = x - v.cx;
                const dy = y - v.cy;
                return @abs(@sqrt(dx * dx + dy * dy) - v.r) - hw;
            },
            .dot => |v| {
                const dx = x - v.cx;
                const dy = y - v.cy;
                return @sqrt(dx * dx + dy * dy) - v.r;
            },
            .arc => |v| {
                const dx = x - v.cx;
                const dy = y - v.cy;
                var t = atan2(dy, dx) - v.a0;
                t -= TAU * @floor(t / TAU);
                if (t <= v.a1 - v.a0) return @abs(@sqrt(dx * dx + dy * dy) - v.r) - hw;
                const e0x = v.ends[0] - x;
                const e0y = v.ends[1] - y;
                const e1x = v.ends[2] - x;
                const e1y = v.ends[3] - y;
                return @min(@sqrt(e0x * e0x + e0y * e0y), @sqrt(e1x * e1x + e1y * e1y)) - hw;
            },
            .box => |v| return @abs(sdBox(x - v.x - v.w / 2, y - v.y - v.h / 2, v.w / 2, v.h / 2, v.r)) - hw,
            .fbox => |v| return sdBox(x - v.x - v.w / 2, y - v.y - v.h / 2, v.w / 2, v.h / 2, v.r),
        }
    }
};

const Group = struct {
    p: []const Prim,
    hw: f32,
    fn sdf(g: Group, x: f32, y: f32) f32 {
        var d: f32 = 1e9;
        for (g.p) |p| d = @min(d, p.dist(x, y, g.hw));
        return d;
    }
};

// ---------------------------------------------------------------- шрифт
// Цифры нарисованы на сетке 6×10 единиц, линия — STROKE единиц.

pub const STROKE: f32 = 1.45;

fn seg(x0: f32, y0: f32, x1: f32, y1: f32) Prim {
    return .{ .seg = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 } };
}
fn arc(cx: f32, cy: f32, r: f32, a0: f32, a1: f32) Prim {
    return .{ .arc = .{ .cx = cx, .cy = cy, .r = r, .a0 = a0, .a1 = a1 } };
}
fn ring(cx: f32, cy: f32, r: f32) Prim {
    return .{ .ring = .{ .cx = cx, .cy = cy, .r = r } };
}
fn dot(cx: f32, cy: f32, r: f32) Prim {
    return .{ .dot = .{ .cx = cx, .cy = cy, .r = r } };
}
fn box(x: f32, y: f32, w: f32, h: f32, r: f32) Prim {
    return .{ .box = .{ .x = x, .y = y, .w = w, .h = h, .r = r } };
}

/// Точка на дуге (чтобы стыковать отрезки с дугами).
fn ap(cx: f32, cy: f32, r: f32, deg: f32) [2]f32 {
    const a = deg * TAU / 360.0;
    return .{ cx + r * @cos(a), cy + r * @sin(a) };
}

const g0 = [_]Prim{box(0, 0, 6, 10, 3)};
const g1 = [_]Prim{ seg(3.4, 0, 3.4, 10), seg(3.4, 0, 1.0, 2.0) };
const g2 = blk: {
    const e = ap(3, 3, 3, 380);
    break :blk [_]Prim{ arc(3, 3, 3, 165, 380), seg(e[0], e[1], 0, 10), seg(0, 10, 6, 10) };
};
const g3 = [_]Prim{ arc(3, 2.3, 2.3, 200, 450), arc(3, 7.3, 2.7, -90, 160) };
const g4 = [_]Prim{ seg(4.6, 10, 4.6, 0), seg(4.6, 0, 0, 7), seg(0, 7, 6, 7) };
const g5 = blk: {
    const st = ap(3, 6.9, 3.1, -140);
    break :blk [_]Prim{ seg(5.7, 0, 0.8, 0), seg(0.8, 0, st[0], st[1]), arc(3, 6.9, 3.1, -140, 150) };
};
const g6 = [_]Prim{ ring(3, 7, 3), arc(7.24, 7, 7.24, 180, 247.75) };
const g7 = [_]Prim{ seg(0, 0, 6, 0), seg(6, 0, 2.2, 10) };
const g8 = [_]Prim{ ring(3, 2.4, 2.4), ring(3, 7.3, 2.7) };
const g9 = [_]Prim{ ring(3, 3, 3), arc(-1.24, 3, 7.24, 0, 67.75) };
const gcolon = [_]Prim{ dot(1, 3.2, 0.95), dot(1, 7.8, 0.95) };
const gdot = [_]Prim{dot(1, 9.1, 0.95)};

fn glyph(c: u8) ?[]const Prim {
    return switch (c) {
        '0' => &g0,
        '1' => &g1,
        '2' => &g2,
        '3' => &g3,
        '4' => &g4,
        '5' => &g5,
        '6' => &g6,
        '7' => &g7,
        '8' => &g8,
        '9' => &g9,
        ':' => &gcolon,
        '.' => &gdot,
        else => null,
    };
}

fn advance(c: u8) f32 {
    return switch (c) {
        ':', '.' => 4.2,
        ' ' => 4.5,
        else => 9.0,
    };
}

/// Ширина текста в пикселях при высоте цифр `size`.
pub fn textWidth(str: []const u8, size: f32) f32 {
    const s = size / 10.0;
    var w: f32 = 0;
    for (str) |ch| w += advance(ch) * s;
    // у последнего символа нет межбуквенного промежутка
    if (str.len > 0) w -= (advance(str[str.len - 1]) - glyphWidth(str[str.len - 1])) * s;
    return w;
}

fn glyphWidth(c: u8) f32 {
    return switch (c) {
        ':', '.' => 2.0,
        ' ' => 4.5,
        else => 6.0,
    };
}

/// Рисует строку из цифр, ':', '.' и пробелов. (x, y) — левый верхний угол цифр.
pub fn text(c: *Canvas, str: []const u8, x: f32, y: f32, size: f32, color: u32) void {
    const s = size / 10.0;
    var cx = x;
    for (str) |ch| {
        if (glyph(ch)) |g| c.icon(g, cx, y, s, STROKE * s, color);
        cx += advance(ch) * s;
    }
}

// ---------------------------------------------------------------- иконки (сетка 16×16)

pub const icon_wifi_dot = [_]Prim{dot(8, 13, 1.5)};
pub const icon_wifi_arcs = [_][1]Prim{
    .{arc(8, 13, 4.2, 225, 315)},
    .{arc(8, 13, 7.6, 225, 315)},
    .{arc(8, 13, 11.0, 225, 315)},
};
pub const icon_slash = [_]Prim{seg(2.5, 2.5, 13.5, 13.5)};

pub const icon_bt = [_]Prim{
    seg(8, 1.5, 8, 14.5),
    seg(8, 1.5, 11.5, 5),
    seg(11.5, 5, 4.5, 11.5),
    seg(8, 14.5, 11.5, 11),
    seg(11.5, 11, 4.5, 4.5),
};
pub const icon_bt_dots = [_]Prim{ dot(2.2, 8, 1.2), dot(13.8, 8, 1.2) };

pub const icon_wall = [_]Prim{
    box(1, 2.5, 14, 11, 2.5),
    seg(3.8, 11, 6.8, 7.3),
    seg(6.8, 7.3, 9.3, 10),
    seg(9.3, 10, 10.8, 8.5),
    seg(10.8, 8.5, 12.4, 10.2),
    dot(10.8, 5.6, 1.3),
};

pub const icon_apps = blk: {
    var a: [9]Prim = undefined;
    for (0..3) |i| {
        for (0..3) |j| {
            a[i * 3 + j] = dot(3 + 5 * @as(f32, @floatFromInt(j)), 3 + 5 * @as(f32, @floatFromInt(i)), 1.55);
        }
    }
    break :blk a;
};

pub const icon_power = [_]Prim{
    arc(8, 8.8, 5.6, -55, 235),
    seg(8, 1.5, 8, 7.5),
};

/// dwindle: окно слева, справа — два, поделённые пополам
pub const icon_dwindle = [_]Prim{
    box(1.5, 2.5, 13, 11, 2),
    seg(8, 2.5, 8, 13.5),
    seg(8, 8, 14.5, 8),
};

/// scroll: лента колонок, крайние уходят за экран
pub const icon_scroll = [_]Prim{
    box(4.5, 2.5, 7, 11, 1.6),
    seg(1.2, 4, 1.2, 12),
    seg(14.8, 4, 14.8, 12),
};

/// Корпус батареи (заливка уровня рисуется отдельно, fbox по проценту).
pub const icon_battery = [_]Prim{
    box(1, 4.5, 12.5, 7, 1.8),
    .{ .fbox = .{ .x = 14, .y = 6.6, .w = 1.6, .h = 2.8, .r = 0.6 } },
};

/// Молния поверх батареи при зарядке.
pub const icon_bolt = [_]Prim{
    seg(8.2, 5, 5.6, 8.4),
    seg(5.6, 8.4, 8.6, 8.4),
    seg(8.6, 8.4, 6.2, 11.2),
};

// ---------------------------------------------------------------- тесты

const tt = std.testing;

test "SIMD-смешивание совпадает со скалярным бит в бит" {
    var rng = std.Random.DefaultPrng.init(42);
    const r = rng.random();
    for (0..200) |_| {
        const n = r.uintLessThan(usize, 40);
        var a: [40]u32 = undefined;
        var b: [40]u32 = undefined;
        var m: [40]u8 = undefined;
        var src: [40]u32 = undefined;
        for (0..n) |i| {
            a[i] = r.int(u32);
            b[i] = a[i];
            m[i] = switch (r.uintLessThan(u8, 4)) {
                0 => 0,
                1 => 255,
                else => r.int(u8),
            };
            const sa = r.int(u8);
            src[i] = premul((@as(u32, if (r.boolean()) sa else if (r.boolean()) 255 else 0) << 24) | (r.int(u32) & 0xffffff));
        }
        const color = r.int(u32);
        const alpha = color >> 24;
        blendMask(a[0..n], m[0..n], color, alpha);
        for (0..n) |i| if (m[i] != 0) blendPx(&b[i], color, div255(alpha * m[i]));
        try tt.expectEqualSlices(u32, b[0..n], a[0..n]);

        for (0..n) |i| b[i] = a[i];
        overSpan(a[0..n], src[0..n]);
        for (0..n) |i| {
            const p = src[i];
            const sa = p >> 24;
            if (sa == 0) continue;
            b[i] = if (sa == 255) p else p + scalePx(b[i], 255 - sa);
        }
        try tt.expectEqualSlices(u32, b[0..n], a[0..n]);
    }
}

test "отсечение: за пределами прямоугольника ни одного пикселя" {
    var px: [64 * 16]u32 = @splat(0);
    var cv = Canvas{ .px = &px, .w = 64, .h = 16 };
    cv.clip(10, 2, 30, 12);
    cv.fillRect(0, 0, 64, 16, 0xff336699);
    cv.icon(&icon_power, 20, 0, 1, 1.5, 0xffffffff);
    for (0..16) |y| for (0..64) |x| {
        const inside = x >= 10 and x < 30 and y >= 2 and y < 12;
        if (!inside) try tt.expectEqual(@as(u32, 0), px[y * 64 + x]);
    };
    try tt.expect(px[5 * 64 + 15] != 0);
}
