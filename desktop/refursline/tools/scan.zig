// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Генератор протоколов: XML Wayland → Zig (zig build запускает его сам).
//!
//!     scan OUT.zig a.xml b.xml ...
//!
//! Для каждого интерфейса получается структура:
//!     pub const wl_surface = struct {
//!         pub const name = "wl_surface";
//!         pub const Req = enum(u16) { destroy, attach, ... };       // номера запросов
//!         pub const Ev = enum(u16) { enter, leave, ..., _ };         // номера событий
//!         pub const sig = [_][]const u8{ "", "?oii", ... };          // типы аргументов запросов
//!         pub const transform = struct { pub const normal: u32 = 0; ... };  // enum'ы протокола
//!     };
//! Буквы сигнатуры как в libwayland: u int32 без знака, i со знаком, f fixed, s строка,
//! o объект, n новый объект, a массив, h дескриптор; ? — может быть null.
//! wl.Conn.req проверяет аргументы по sig при компиляции: неверный номер запроса или
//! тип аргумента — ошибка сборки, а не ошибка протокола у пользователя.

const std = @import("std");

const Arg = struct { kind: u8, nullable: bool, typed_new_id: bool };
const Msg = struct { name: []const u8, args: std.ArrayList(Arg) = .empty };
const Entry = struct { name: []const u8, value: []const u8 };
const Enum = struct { name: []const u8, entries: std.ArrayList(Entry) = .empty };
const Iface = struct {
    name: []const u8,
    version: []const u8,
    reqs: std.ArrayList(Msg) = .empty,
    evs: std.ArrayList(Msg) = .empty,
    enums: std.ArrayList(Enum) = .empty,
};

/// Атрибут name="value" внутри тега.
fn attr(tag: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag, i, key)) |p| {
        i = p + key.len;
        if (p > 0 and tag[p - 1] != ' ' and tag[p - 1] != '\t' and tag[p - 1] != '\n') continue;
        if (i + 1 >= tag.len or tag[i] != '=' or tag[i + 1] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, tag, i + 2, '"') orelse return null;
        return tag[i + 2 .. end];
    }
    return null;
}

fn kindOf(t: []const u8) u8 {
    const map = .{
        .{ "uint", 'u' }, .{ "int", 'i' },   .{ "fixed", 'f' }, .{ "string", 's' },
        .{ "object", 'o' }, .{ "new_id", 'n' }, .{ "array", 'a' }, .{ "fd", 'h' },
    };
    inline for (map) |m| if (std.mem.eql(u8, t, m[0])) return m[1];
    std.debug.panic("unknown argument type {s}", .{t});
}

fn parse(gpa: std.mem.Allocator, xml: []const u8, out: *std.ArrayList(Iface)) !void {
    var i: usize = 0;
    var iface: ?*Iface = null;
    var msg: ?*Msg = null;
    var en: ?*Enum = null;
    while (std.mem.indexOfScalarPos(u8, xml, i, '<')) |lt| {
        if (std.mem.startsWith(u8, xml[lt..], "<!--")) {
            i = (std.mem.indexOfPos(u8, xml, lt, "-->") orelse return error.BadXml) + 3;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, xml, lt, '>') orelse return error.BadXml;
        i = gt + 1;
        var tag = xml[lt + 1 .. gt];
        if (tag.len == 0 or tag[0] == '?') continue;
        const closing = tag[0] == '/';
        if (closing) tag = tag[1..];
        const self_closing = tag.len > 0 and tag[tag.len - 1] == '/';
        const name_end = std.mem.indexOfAny(u8, tag, " \t\n/") orelse tag.len;
        const t = tag[0..name_end];
        const eql = std.mem.eql;
        if (closing) {
            if (eql(u8, t, "interface")) iface = null;
            if (eql(u8, t, "request") or eql(u8, t, "event")) msg = null;
            if (eql(u8, t, "enum")) en = null;
            continue;
        }
        if (eql(u8, t, "interface")) {
            try out.append(gpa, .{ .name = attr(tag, "name").?, .version = attr(tag, "version").? });
            iface = &out.items[out.items.len - 1];
        } else if (eql(u8, t, "request") or eql(u8, t, "event")) {
            const f = iface orelse return error.BadXml;
            const list = if (eql(u8, t, "request")) &f.reqs else &f.evs;
            try list.append(gpa, .{ .name = attr(tag, "name").? });
            msg = if (self_closing) null else &list.items[list.items.len - 1];
        } else if (eql(u8, t, "arg")) {
            const m = msg orelse return error.BadXml;
            const k = kindOf(attr(tag, "type").?);
            const nullable = if (attr(tag, "allow-null")) |v| eql(u8, v, "true") else false;
            // new_id без интерфейса (wl_registry.bind) идёт по проводу как строка, версия и id
            if (k == 'n' and attr(tag, "interface") == null) {
                try m.args.append(gpa, .{ .kind = 's', .nullable = false, .typed_new_id = false });
                try m.args.append(gpa, .{ .kind = 'u', .nullable = false, .typed_new_id = false });
            }
            try m.args.append(gpa, .{ .kind = k, .nullable = nullable, .typed_new_id = k == 'n' });
        } else if (eql(u8, t, "enum")) {
            const f = iface orelse return error.BadXml;
            try f.enums.append(gpa, .{ .name = attr(tag, "name").? });
            en = if (self_closing) null else &f.enums.items[f.enums.items.len - 1];
        } else if (eql(u8, t, "entry")) {
            const e = en orelse return error.BadXml;
            try e.entries.append(gpa, .{ .name = attr(tag, "name").?, .value = attr(tag, "value").? });
        }
    }
}

fn emit(gpa: std.mem.Allocator, w: *std.ArrayList(u8), ifaces: []const Iface) !void {
    try w.appendSlice(gpa, "// Сгенерировано tools/scan.zig из protocol/*.xml — не редактировать.\n\n");
    for (ifaces) |f| {
        try w.print(gpa, "pub const {s} = struct {{\n    pub const name = \"{s}\";\n    pub const version = {s};\n", .{ f.name, f.name, f.version });
        try w.appendSlice(gpa, "    pub const Req = enum(u16) {");
        for (f.reqs.items) |m| try w.print(gpa, " @\"{s}\",", .{m.name});
        try w.appendSlice(gpa, " };\n    pub const Ev = enum(u16) {");
        for (f.evs.items) |m| try w.print(gpa, " @\"{s}\",", .{m.name});
        try w.appendSlice(gpa, " _ };\n    pub const sig = [_][]const u8{");
        for (f.reqs.items) |m| {
            try w.appendSlice(gpa, " \"");
            for (m.args.items) |a| {
                if (a.nullable) try w.append(gpa, '?');
                try w.append(gpa, a.kind);
            }
            try w.appendSlice(gpa, "\",");
        }
        try w.appendSlice(gpa, " };\n");
        for (f.enums.items) |e| {
            try w.print(gpa, "    pub const @\"{s}\" = struct {{", .{e.name});
            for (e.entries.items) |en| try w.print(gpa, " pub const @\"{s}\": u32 = {s};", .{ en.name, en.value });
            try w.appendSlice(gpa, " };\n");
        }
        try w.appendSlice(gpa, "};\n\n");
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) return error.Usage;
    var ifaces: std.ArrayList(Iface) = .empty;
    for (args[2..]) |path| {
        const xml = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20));
        try parse(gpa, xml, &ifaces);
    }
    var out: std.ArrayList(u8) = .empty;
    try emit(gpa, &out, ifaces.items);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = out.items });
}
