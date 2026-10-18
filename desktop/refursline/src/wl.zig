// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Протокол Wayland на сокете, без libwayland: запросы сериализуем, события разбираем сами.
//! Номера запросов и типы аргументов берутся из protocol/*.xml (tools/scan.zig → модуль proto):
//! `conn.req(id, p.wl_surface, .attach, .{ buf, 0, 0 })` проверяется при компиляции.

const std = @import("std");
const sys = @import("sys.zig");
pub const p = @import("proto");

pub const MAX_IDS = 1024;

/// Аргумент-дескриптор (передаётся через SCM_RIGHTS).
pub const Fd = struct { fd: i32 };
/// Строковый аргумент (null — пустая/NULL строка).
pub const Str = struct { s: ?[]const u8 };
pub fn str(s: []const u8) Str {
    return .{ .s = s };
}

pub const Event = struct {
    obj: u32,
    op: u16,
    args: Args,
};

/// Последовательное чтение аргументов события.
pub const Args = struct {
    d: []const u8,
    p: usize = 0,

    pub fn uint(self: *Args) u32 {
        if (self.p + 4 > self.d.len) return 0;
        const v = std.mem.readInt(u32, self.d[self.p..][0..4], .little);
        self.p += 4;
        return v;
    }
    pub fn int(self: *Args) i32 {
        return @bitCast(self.uint());
    }
    /// fixed 24.8 -> f32
    pub fn fixed(self: *Args) f32 {
        return @as(f32, @floatFromInt(self.int())) / 256.0;
    }
    pub fn string(self: *Args) []const u8 {
        const len: usize = self.uint();
        if (len == 0) return "";
        // считаем в usize и сравниваем с остатком — никакого переполнения на «злых» длинах
        const rest = self.d.len - self.p;
        if (len > rest) {
            self.p = self.d.len;
            return "";
        }
        const padded = @min((len + 3) & ~@as(usize, 3), rest);
        const s = self.d[self.p .. self.p + len - 1]; // без завершающего нуля
        self.p += padded;
        return s;
    }
};

// Буферы соединения — отдельные глобальные массивы: так они попадают в .bss (не занимают
// места в файле и памяти, пока их не тронули). Внутри структуры с другими значениями по
// умолчанию они целиком уходили в .data. Соединение с Wayland в процессе одно.
var out_buf: [16384]u8 = undefined;
var in_buf: [65536]u8 = undefined;
var free_buf: [MAX_IDS]u32 = undefined;

pub const Conn = struct {
    fd: i32 = -1,
    out: *[16384]u8 = &out_buf,
    olen: usize = 0,
    ofds: [8]i32 = undefined,
    nofds: usize = 0,
    in: *[65536]u8 = &in_buf,
    ilen: usize = 0,
    ipos: usize = 0,
    in_fds: [8]i32 = undefined,
    nin_fds: usize = 0,
    next_id: u32 = 2, // 1 — wl_display
    free_ids: *[MAX_IDS]u32 = &free_buf,
    nfree: usize = 0,

    /// Соединение, которое RefursWM открыл для бара сам (WAYLAND_SOCKET=fd): только на нём есть
    /// refurs-shell. Переменная проверяется строго (одно десятичное число ≥ 3, это сокет),
    /// дескриптор получает CLOEXEC: ни одна запущенная программа его не унаследует.
    pub fn connectSocket(self: *Conn) !void {
        const v = sys.getenv("WAYLAND_SOCKET") orelse return error.NoSocket;
        if (v.len == 0 or v.len > 4) return error.NoSocket;
        const fd = std.fmt.parseInt(i32, v, 10) catch return error.NoSocket;
        if (fd < 3 or !sys.isSocket(fd)) return error.NoSocket;
        sys.setCloexec(fd);
        self.fd = fd;
    }

    pub fn connect(self: *Conn) !void {
        const disp = sys.getenv("WAYLAND_DISPLAY") orelse "wayland-0";
        var buf: [256]u8 = undefined;
        const path = if (disp.len > 0 and disp[0] == '/')
            disp
        else blk: {
            const rt = sys.getenv("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
            break :blk sys.joinZ(&buf, &.{ rt, "/", disp });
        };
        self.fd = try sys.connectUnix(path);
    }

    pub fn newId(self: *Conn) u32 {
        if (self.nfree > 0) {
            // взять наименьший освобождённый id
            var best: usize = 0;
            for (self.free_ids[0..self.nfree], 0..) |id, i| {
                if (id < self.free_ids[best]) best = i;
            }
            const id = self.free_ids[best];
            self.free_ids[best] = self.free_ids[self.nfree - 1];
            self.nfree -= 1;
            return id;
        }
        if (self.next_id >= MAX_IDS) {
            sys.log("ran out of object ids", .{});
            sys.exit(1);
        }
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Вызывается на wl_display.delete_id — id можно использовать снова.
    pub fn releaseId(self: *Conn, id: u32) void {
        if (id == 0 or id >= MAX_IDS or self.nfree >= MAX_IDS) return;
        self.free_ids[self.nfree] = id;
        self.nfree += 1;
    }

    /// Сериализует запрос. Аргументы — кортеж из u32 / i32 / Str / Fd
    /// (целые литералы считаются u32).
    pub fn send(self: *Conn, obj: u32, op: u16, args: anytype) void {
        if (self.out.len - self.olen < 1024) self.flush() catch fatal();
        const start = self.olen;
        self.olen += 8;
        inline for (args) |a| {
            const T = @TypeOf(a);
            if (T == u32) {
                self.put32(a);
            } else if (T == i32) {
                self.put32(@bitCast(a));
            } else if (T == comptime_int) {
                self.put32(if (a < 0) @bitCast(@as(i32, a)) else @as(u32, a));
            } else if (T == Str) {
                self.putStr(a.s);
            } else if (T == Fd) {
                if (self.nofds >= self.ofds.len) self.flush() catch fatal();
                self.ofds[self.nofds] = a.fd;
                self.nofds += 1;
            } else {
                @compileError("unsupported argument type: " ++ @typeName(T));
            }
        }
        const size: u32 = @intCast(self.olen - start);
        std.mem.writeInt(u32, self.out[start..][0..4], obj, .little);
        std.mem.writeInt(u32, self.out[start + 4 ..][0..4], (size << 16) | op, .little);
    }

    /// Запрос `r` интерфейса `I` (структура из proto). Число и типы аргументов сверяются с XML
    /// при компиляции: u — u32, i и f — i32, s — Str, o и n — u32 (id), h — Fd.
    pub inline fn req(self: *Conn, obj: u32, comptime I: type, comptime r: I.Req, args: anytype) void {
        comptime checkArgs(I.name ++ "." ++ @tagName(r), I.sig[@intFromEnum(r)], @TypeOf(args));
        self.send(obj, @intFromEnum(r), args);
    }

    fn put32(self: *Conn, v: u32) void {
        std.mem.writeInt(u32, self.out[self.olen..][0..4], v, .little);
        self.olen += 4;
    }

    fn putStr(self: *Conn, s: ?[]const u8) void {
        const v = s orelse {
            self.put32(0);
            return;
        };
        const len: u32 = @intCast(v.len + 1);
        self.put32(len);
        @memcpy(self.out[self.olen..][0..v.len], v);
        const padded = (len + 3) & ~@as(u32, 3);
        @memset(self.out[self.olen + v.len .. self.olen + padded], 0);
        self.olen += padded;
    }

    pub fn flush(self: *Conn) !void {
        var off: usize = 0;
        while (off < self.olen) {
            const n = try sys.sendmsgFds(self.fd, self.out[off..self.olen], self.ofds[0..self.nofds]);
            self.nofds = 0; // дескрипторы ушли с первым куском
            off += n;
        }
        self.olen = 0;
    }

    /// Дочитать данные из сокета. false — соединение закрыто.
    pub fn fill(self: *Conn) !bool {
        if (self.ipos > 0) {
            const rest = self.ilen - self.ipos;
            std.mem.copyForwards(u8, self.in[0..rest], self.in[self.ipos..self.ilen]);
            self.ilen = rest;
            self.ipos = 0;
        }
        if (self.ilen == self.in.len) return error.BufferFull;
        var fds: [8]i32 = undefined;
        var nfds: usize = 0;
        const n = try sys.recvmsgFds(self.fd, self.in[self.ilen..], &fds, &nfds);
        for (fds[0..nfds]) |f| {
            if (self.nin_fds < self.in_fds.len) {
                self.in_fds[self.nin_fds] = f;
                self.nin_fds += 1;
            } else sys.close(f);
        }
        if (n == 0) return false;
        self.ilen += n;
        return true;
    }

    /// Забрать дескриптор, пришедший с событием (например, wl_keyboard.keymap).
    pub fn takeFd(self: *Conn) ?i32 {
        if (self.nin_fds == 0) return null;
        const f = self.in_fds[0];
        std.mem.copyForwards(i32, self.in_fds[0 .. self.nin_fds - 1], self.in_fds[1..self.nin_fds]);
        self.nin_fds -= 1;
        return f;
    }

    /// Следующее полностью прочитанное событие (или null).
    pub fn next(self: *Conn) ?Event {
        const avail = self.ilen - self.ipos;
        if (avail < 8) return null;
        const m = self.in[self.ipos..];
        const obj = std.mem.readInt(u32, m[0..4], .little);
        const hdr = std.mem.readInt(u32, m[4..8], .little);
        const size = hdr >> 16;
        if (size < 8) {
            sys.log("malformed message from the compositor", .{});
            sys.exit(1);
        }
        if (avail < size) return null;
        self.ipos += size;
        return .{ .obj = obj, .op = @truncate(hdr), .args = .{ .d = m[8..size] } };
    }

    /// Непрозрачная область поверхности (применяется со следующим commit): весь прямоугольник w×h.
    /// Под непрозрачной областью компоновщик ничего не рисует и не смешивает.
    /// Объект области событий не получает, поэтому записи в таблице объектов программы ему не нужно.
    pub noinline fn setOpaque(self: *Conn, compositor: u32, surface: u32, w: u32, h: u32) void {
        const region = self.newId();
        self.req(compositor, p.wl_compositor, .create_region, .{region});
        self.req(region, p.wl_region, .add, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(w)), @as(i32, @intCast(h)) });
        self.req(surface, p.wl_surface, .set_opaque_region, .{region});
        self.req(region, p.wl_region, .destroy, .{}); // у поверхности своя копия
    }

    fn fatal() noreturn {
        sys.log("error writing to the Wayland socket", .{});
        sys.exit(1);
    }
};

/// Аргументы запроса против сигнатуры из XML — ошибка компиляции при несовпадении.
fn checkArgs(comptime what: []const u8, comptime sig: []const u8, comptime A: type) void {
    const types = @typeInfo(A).@"struct".field_types;
    var n: usize = 0;
    for (sig) |ch| {
        if (ch == '?') continue;
        if (n >= types.len) @compileError(what ++ ": мало аргументов");
        const T = types[n];
        const ok = switch (ch) {
            'u', 'o', 'n' => T == u32 or T == comptime_int,
            'i', 'f' => T == i32 or T == comptime_int,
            's' => T == Str,
            'h' => T == Fd,
            else => false,
        };
        if (!ok) @compileError(what ++ ": аргумент " ++ std.fmt.comptimePrint("{d}", .{n}) ++ " типа " ++ @typeName(T) ++ ", а в протоколе '" ++ [_]u8{ch} ++ "'");
        n += 1;
    }
    if (n != types.len) @compileError(what ++ ": лишние аргументы");
}

/// Событие интерфейса I по номеру (незнакомые номера — `_`, не паника).
pub inline fn ev(comptime I: type, op: u16) I.Ev {
    return @enumFromInt(op);
}
