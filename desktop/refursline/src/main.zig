// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! RefursLine — бар для RefursWM на чистом Zig, без libc и без libwayland.
//!
//! Один бинарник, режим — первым аргументом:
//!   refursline                 — бар и обои (запускает RefursWM, см. README)
//!   refursline run|wifi|bt|wall|power|cal  ТЕМА  — меню (их запускает broker бара)
//!   refursline wifi toggle, bt toggle       — радио вкл/выкл без окна
//! Код общий, страницы файла в памяти — тоже: меню, открытое при работающем баре, почти не
//! добавляет памяти, а на диске один файл вместо восьми.

const std = @import("std");
const sys = @import("sys.zig");
const rt = @import("rt.zig");

pub const panic = rt.panic;
pub const std_options = rt.std_options;

pub fn main(init: std.process.Init.Minimal) void {
    sys.init(init);
    const mode = sys.argAt(1) orelse @import("bar.zig").main();
    const eql = std.mem.eql;
    if (eql(u8, mode, "run")) @import("run.zig").main();
    if (eql(u8, mode, "wifi")) @import("wifi.zig").main();
    if (eql(u8, mode, "bt")) @import("bt.zig").main();
    if (eql(u8, mode, "wall")) @import("wall.zig").main();
    if (eql(u8, mode, "power")) @import("power.zig").main();
    if (eql(u8, mode, "cal")) @import("cal.zig").main();
    sys.say(&.{ "неизвестный режим: ", mode, " (run, wifi, bt, wall, power, cal)" });
    sys.exit(2);
}

test {
    _ = @import("draw.zig");
    _ = @import("theme.zig");
    _ = @import("desktop.zig");
    _ = @import("broker.zig");
    _ = @import("bar.zig");
    _ = @import("ui.zig");
}
