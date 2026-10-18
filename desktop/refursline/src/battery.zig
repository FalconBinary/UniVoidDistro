// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Батарея из /sys/class/power_supply: заряд и зарядка. Перечитывается по uevent power_supply
//! (тот же сокет и BPF-фильтр, что у Wi‑Fi/Bluetooth) и вместе с минутным тиком часов — своих
//! пробуждений у батареи нет. Нет батареи — элемент скрыт.

const std = @import("std");
const sys = @import("sys.zig");

pub const State = struct {
    present: bool = false,
    percent: u8 = 0,
    charging: bool = false,
    /// от сети и заряжена (Full / Not charging)
    full: bool = false,

    pub fn eql(a: State, b: State) bool {
        return a.present == b.present and a.percent == b.percent and a.charging == b.charging and a.full == b.full;
    }
};

var name_buf: [32]u8 = undefined;
var name_len: usize = 0;

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Первая батарея системы (type = Battery, scope не Device: мышь или наушники — не она).
fn find() bool {
    var path: [256]u8 = undefined;
    var buf: [32]u8 = undefined;
    if (name_len > 0 and sys.exists(sys.joinZ(&path, &.{ "/sys/class/power_supply/", name_buf[0..name_len], "/capacity" }))) return true;
    name_len = 0;
    var dir = sys.Dir.open("/sys/class/power_supply") orelse return false;
    defer dir.deinit();
    while (dir.next()) |n| {
        if (n.len > name_buf.len) continue;
        const t = sys.readFile(sys.joinZ(&path, &.{ "/sys/class/power_supply/", n, "/type" }), &buf) orelse continue;
        if (!std.mem.eql(u8, trim(t), "Battery")) continue;
        if (sys.readFile(sys.joinZ(&path, &.{ "/sys/class/power_supply/", n, "/scope" }), &buf)) |sc| {
            if (std.mem.eql(u8, trim(sc), "Device")) continue;
        }
        @memcpy(name_buf[0..n.len], n);
        name_len = n.len;
        return true;
    }
    return false;
}

pub fn read() State {
    if (!find()) return .{};
    var path: [256]u8 = undefined;
    var buf: [32]u8 = undefined;
    const base = name_buf[0..name_len];
    const cap = sys.readFile(sys.joinZ(&path, &.{ "/sys/class/power_supply/", base, "/capacity" }), &buf) orelse return .{};
    const pct = std.fmt.parseInt(u8, trim(cap), 10) catch return .{};
    var st = State{ .present = true, .percent = @min(pct, 100) };
    if (sys.readFile(sys.joinZ(&path, &.{ "/sys/class/power_supply/", base, "/status" }), &buf)) |s| {
        const v = trim(s);
        st.charging = std.mem.eql(u8, v, "Charging");
        st.full = std.mem.eql(u8, v, "Full") or std.mem.eql(u8, v, "Not charging");
    }
    return st;
}
