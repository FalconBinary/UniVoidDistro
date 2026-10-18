// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Types the config is written in. Kept apart from config.zig so the config stays short.
const std = @import("std");
const layout = @import("layout.zig");

pub const Dir = layout.Dir;
pub const Mode = layout.Mode;

/// Modifier bits, same values as WLR_MODIFIER_*.
pub const Mod = struct {
    pub const shift: u32 = 1;
    pub const ctrl: u32 = 4;
    pub const alt: u32 = 8;
    pub const super: u32 = 64;
};

/// A command is argv, run directly with posix_spawnp: no shell, no string parsing.
pub const Cmd = []const [*:0]const u8;

/// Privileged protocols. A client gets one only if RefursWM started it through a matching Grant.
pub const Caps = packed struct(u8) {
    /// read the screen: wlr-screencopy, ext-image-copy-capture
    screencopy: bool = false,
    /// read and set the clipboard in the background: wlr/ext data-control
    data_control: bool = false,
    /// type and move the pointer as the user: virtual keyboard, virtual pointer
    virtual_input: bool = false,
    /// change the monitor gamma: wlr-gamma-control
    gamma: bool = false,
    /// the bar: workspaces, focused window, layout and theme; switching workspaces, lock, quit
    /// (refurs-shell, protocol/refurs-shell-unstable-v1.xml)
    shell: bool = false,
    _: u3 = 0,

    pub fn any(a: Caps, b: Caps) bool {
        return @as(u8, @bitCast(a)) & @as(u8, @bitCast(b)) != 0;
    }
};

pub const Grant = struct {
    /// absolute path of the program; started by its path, never looked up in $PATH
    path: [:0]const u8,
    caps: Caps,
};

pub const Action = union(enum) {
    spawn: Cmd,
    close,
    quit,
    /// spawns `config.lock_command`; also allowed while locked if the locker died
    lock,
    focus: Dir,
    move: Dir,
    /// grow the focused window by {dx, dy} px (negative shrinks); scroll mode changes the column width
    resize: [2]i32,
    toggle_float,
    fullscreen,
    /// dwindle <-> scroll for the current workspace
    toggle_mode,
    /// dwindle: flip the split of the focused window's parent
    toggle_split,
    workspace: u8,
    move_to_workspace: u8,
    /// scroll: cycle the column through `scroll_widths`
    cycle_width,
    /// scroll: move the window into the left/right column / back out into its own column
    column_merge: Dir,
    column_expel,
    /// dark <-> light: border/background colours + `theme_hooks`
    toggle_theme,
    /// a menu of the bar (RefursLine): the bar opens it, nothing happens without a bar
    bar: Menu,
};

/// Bar menus, same values as zrefurs_shell_v1.menu.
pub const Menu = enum(u32) { run, commands, wifi, bluetooth, wallpaper, power, calendar };

pub const Bind = struct {
    mods: u32,
    /// xkb key name of the first layout, unshifted: "Return", "q", "1", "Left", "XF86AudioMute"
    key: [:0]const u8,
    action: Action,
};

/// Always opaque: alpha is 1.
pub const Color = [4]f32;

/// "#RRGGBB" checked at compile time: a typo in config.zig is a build error. No alpha on purpose.
pub fn hex(comptime s: []const u8) Color {
    comptime {
        const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
        if (h.len != 6) @compileError("config: colour must be #RRGGBB: " ++ s);
        const v = std.fmt.parseInt(u24, h, 16) catch @compileError("config: bad colour: " ++ s);
        return .{
            @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255.0,
            @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255.0,
            @as(f32, @floatFromInt(v & 0xff)) / 255.0,
            1.0,
        };
    }
}

pub const Palette = struct {
    active: Color,
    inactive: Color,
    background: Color,
};

pub const Theme = enum { dark, light };

pub const Rule = struct {
    /// exact match; null matches anything
    app_id: ?[]const u8 = null,
    /// app_id starts with this (void-hardened: windows vh-wlfilter tagged "vh-sandbox[.app]")
    app_id_prefix: ?[]const u8 = null,
    title: ?[]const u8 = null,
    float: ?bool = null,
    /// 1..9
    workspace: ?u8 = null,
};

pub const OutputCfg = struct {
    name: []const u8,
    scale: f32 = 1.0,
    /// 0 = preferred mode
    width: i32 = 0,
    height: i32 = 0,
    /// mHz, 0 = any
    refresh: i32 = 0,
    /// null = place automatically
    x: ?i32 = null,
    y: ?i32 = null,
    /// variable refresh rate (FreeSync/G-Sync compatible): less stutter and latency in games;
    /// some panels flicker with it, so it is opt-in per monitor
    vrr: bool = false,
};
