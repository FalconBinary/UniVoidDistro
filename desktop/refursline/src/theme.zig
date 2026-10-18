// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Тема: две вкомпилированные палитры бара (config.zig). От RefursWM приходит только «тёмная или
//! светлая» — цвета у бара свои и с цветами RefursWM не связаны. Никаких файлов и inotify: бар
//! узнаёт о смене темы событием протокола, меню получают её аргументом при запуске (`d` / `l`).

const std = @import("std");
const cfg = @import("config.zig");

pub var t: cfg.Theme = cfg.dark;
pub var dark = true;

pub fn set(is_dark: bool) void {
    dark = is_dark;
    t = if (is_dark) cfg.dark else cfg.light;
}

/// Аргумент для меню: "d" или "l".
pub fn encode() [:0]const u8 {
    return if (dark) "d" else "l";
}

/// Разбор аргумента меню; что угодно другое — тёмная тема.
pub fn decode(arg: ?[]const u8) void {
    const a = arg orelse return set(true);
    set(!(a.len == 1 and a[0] == 'l'));
}

test "тема для меню: туда и обратно" {
    set(false);
    const s = encode();
    try std.testing.expectEqualStrings("l", s);
    set(true);
    decode(s);
    try std.testing.expect(!dark);
    decode("d../../x");
    try std.testing.expect(dark);
}
