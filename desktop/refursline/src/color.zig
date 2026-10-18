// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Разбирает цвета вида "#RRGGBB" во внутренний формат 0xAARRGGBB, всегда непрозрачный
//! (AA = ff): прозрачности в RefursLine нет. Та же функция работает при компиляции (config.zig).

pub fn parse(s: []const u8) ?u32 {
    const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (h.len != 6) return null;
    var v: u32 = 0;
    for (h) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = (v << 4) | d;
    }
    return 0xff000000 | v;
}

/// Цвет, проверенный при компиляции: опечатка в config.zig — ошибка сборки.
pub fn hex(comptime s: []const u8) u32 {
    return comptime parse(s) orelse @compileError("invalid color (need #RRGGBB): " ++ s);
}

test "цвета: только #RRGGBB" {
    const std = @import("std");
    try std.testing.expectEqual(@as(?u32, 0xff89b4fa), parse("#89b4fa"));
    try std.testing.expectEqual(@as(?u32, null), parse("#89b4faff"));
    try std.testing.expectEqual(@as(?u32, null), parse("#89b4fg"));
}
