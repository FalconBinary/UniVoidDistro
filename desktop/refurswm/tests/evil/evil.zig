// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! A hostile Wayland client for tests/security.sh and tests/bench.sh: it does what a malicious
//! app would try and prints what happened. One mode per run:
//!   registry          print every global this connection can see
//!   geom              extreme xdg_surface.set_window_geometry values, tiled and floating
//!   layer             extreme layer-shell size, margins and exclusive zone
//!   flood N           N toplevels
//!   popups N          one toplevel with N popups
//!   clip              take the clipboard while another window has the keyboard
//!   copy              take the clipboard while focused (the legitimate case)
//!   paste             map a window and print the clipboard text it is offered
//!   activate          steal the focus with an activation token that names no surface
//!   remint            mint a token while focused, lose the focus, activate with it (legitimate)
//!   mapfocus          map a window and print whether it got the keyboard focus
//!   fullscreen        ask for fullscreen before and after mapping, print whether it was given
//!   selfactivate N    activate the focused window N times, print how many configures that cost
//!   inhibit SECS      an idle inhibitor on a window, kept for SECS seconds
//!   vkey              virtual keyboard sending out-of-range keycodes
//!   keyboard SECS     hold a virtual keyboard (headless has none, so nobody gets keyboard focus)
//!   motion N          N relative pointer motions 1 ms apart (virtual pointer)
const std = @import("std");
const c = @import("c");

var display: *c.struct_wl_display = undefined;
var compositor: ?*c.struct_wl_compositor = null;
var shm: ?*c.struct_wl_shm = null;
var wm_base: ?*c.struct_xdg_wm_base = null;
var seat: ?*c.struct_wl_seat = null;
var ddm: ?*c.struct_wl_data_device_manager = null;
var activation: ?*c.struct_xdg_activation_v1 = null;
var inhibit_mgr: ?*c.struct_zwp_idle_inhibit_manager_v1 = null;
var layer_shell: ?*c.struct_zwlr_layer_shell_v1 = null;
var vkbd_mgr: ?*c.struct_zwp_virtual_keyboard_manager_v1 = null;
var vptr_mgr: ?*c.struct_zwlr_virtual_pointer_manager_v1 = null;
var list_globals = false;

var focused = false;
var enters: u32 = 0;
var leaves: u32 = 0;
var last_serial: u32 = 0;
var configures: u32 = 0;
var fullscreen_seen = false;
/// set the cursor to nothing on pointer enter (no software cursor, so motion needs no new frames)
var hide_cursor = false;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = c.write(1, s.ptr, s.len);
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

/// Dispatches events for `ms` milliseconds. False once the compositor dropped the connection.
fn pump(ms: i64) bool {
    const end = nowMs() + ms;
    while (true) {
        while (c.wl_display_prepare_read(display) != 0) {
            if (c.wl_display_dispatch_pending(display) < 0) return false;
        }
        _ = c.wl_display_flush(display);
        const left = end - nowMs();
        if (left <= 0) {
            c.wl_display_cancel_read(display);
            return c.wl_display_dispatch_pending(display) >= 0;
        }
        var pfd: c.struct_pollfd = .{ .fd = c.wl_display_get_fd(display), .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, @intCast(left)) > 0) {
            if (c.wl_display_read_events(display) < 0) return false;
        } else c.wl_display_cancel_read(display);
        if (c.wl_display_dispatch_pending(display) < 0) return false;
    }
}

/// Pumps until `cond()` holds or `ms` pass.
fn waitFor(ms: i64, comptime cond: fn () bool) bool {
    const end = nowMs() + ms;
    while (!cond()) {
        if (nowMs() >= end or !pump(20)) return false;
    }
    return true;
}

fn alive() bool {
    return c.wl_display_get_error(display) == 0;
}

fn report() void {
    if (alive()) out("connection alive\n", .{}) else out("disconnected: error {d}\n", .{c.wl_display_get_error(display)});
}

// ------------------------------------------------------------------ registry

fn bind(reg: ?*c.struct_wl_registry, name: u32, iface: *const c.struct_wl_interface, version: u32) ?*anyopaque {
    return c.wl_registry_bind(reg, name, iface, version);
}

fn global(_: ?*anyopaque, reg: ?*c.struct_wl_registry, name: u32, iface_c: [*c]const u8, version: u32) callconv(.c) void {
    const iface = std.mem.span(iface_c);
    if (list_globals) out("{s}\n", .{iface});
    const eq = std.mem.eql;
    if (eq(u8, iface, "wl_compositor")) {
        compositor = @ptrCast(bind(reg, name, &c.wl_compositor_interface, @min(version, 4)));
    } else if (eq(u8, iface, "wl_shm")) {
        shm = @ptrCast(bind(reg, name, &c.wl_shm_interface, 1));
    } else if (eq(u8, iface, "xdg_wm_base")) {
        wm_base = @ptrCast(bind(reg, name, &c.xdg_wm_base_interface, 1));
        _ = c.xdg_wm_base_add_listener(wm_base, &wm_base_listener, null);
    } else if (eq(u8, iface, "wl_seat")) {
        seat = @ptrCast(bind(reg, name, &c.wl_seat_interface, 1));
        _ = c.wl_seat_add_listener(seat, &seat_listener, null);
    } else if (eq(u8, iface, "wl_data_device_manager")) {
        ddm = @ptrCast(bind(reg, name, &c.wl_data_device_manager_interface, 1));
    } else if (eq(u8, iface, "xdg_activation_v1")) {
        activation = @ptrCast(bind(reg, name, &c.xdg_activation_v1_interface, 1));
    } else if (eq(u8, iface, "zwp_idle_inhibit_manager_v1")) {
        inhibit_mgr = @ptrCast(bind(reg, name, &c.zwp_idle_inhibit_manager_v1_interface, 1));
    } else if (eq(u8, iface, "zwlr_layer_shell_v1")) {
        layer_shell = @ptrCast(bind(reg, name, &c.zwlr_layer_shell_v1_interface, 1));
    } else if (eq(u8, iface, "zwp_virtual_keyboard_manager_v1")) {
        vkbd_mgr = @ptrCast(bind(reg, name, &c.zwp_virtual_keyboard_manager_v1_interface, 1));
    } else if (eq(u8, iface, "zwlr_virtual_pointer_manager_v1")) {
        vptr_mgr = @ptrCast(bind(reg, name, &c.zwlr_virtual_pointer_manager_v1_interface, 1));
    }
}

fn globalRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}

const registry_listener: c.struct_wl_registry_listener = .{ .global = global, .global_remove = globalRemove };

fn ping(_: ?*anyopaque, b: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void {
    c.xdg_wm_base_pong(b, serial);
}

const wm_base_listener: c.struct_xdg_wm_base_listener = .{ .ping = ping };

// ------------------------------------------------------------------ seat

fn seatCaps(_: ?*anyopaque, s: ?*c.struct_wl_seat, caps: u32) callconv(.c) void {
    if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0) _ = c.wl_keyboard_add_listener(c.wl_seat_get_keyboard(s), &kb_listener, null);
    if (caps & c.WL_SEAT_CAPABILITY_POINTER != 0) _ = c.wl_pointer_add_listener(c.wl_seat_get_pointer(s), &ptr_listener, null);
}

fn seatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.c) void {}

const seat_listener: c.struct_wl_seat_listener = .{ .capabilities = seatCaps, .name = seatName };

fn kbKeymap(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, fd: i32, _: u32) callconv(.c) void {
    _ = c.close(fd);
}

fn kbEnter(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, serial: u32, _: ?*c.struct_wl_surface, _: [*c]c.struct_wl_array) callconv(.c) void {
    focused = true;
    enters += 1;
    last_serial = serial;
}

fn kbLeave(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, serial: u32, _: ?*c.struct_wl_surface) callconv(.c) void {
    focused = false;
    leaves += 1;
    last_serial = serial;
}

fn kbKey(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, serial: u32, _: u32, _: u32, _: u32) callconv(.c) void {
    last_serial = serial;
}

fn kbMods(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
fn kbRepeat(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: i32, _: i32) callconv(.c) void {}

const kb_listener: c.struct_wl_keyboard_listener = .{
    .keymap = kbKeymap,
    .enter = kbEnter,
    .leave = kbLeave,
    .key = kbKey,
    .modifiers = kbMods,
    .repeat_info = kbRepeat,
};

fn ptrEnter(_: ?*anyopaque, p: ?*c.struct_wl_pointer, serial: u32, _: ?*c.struct_wl_surface, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {
    last_serial = serial;
    if (hide_cursor) c.wl_pointer_set_cursor(p, serial, null, 0, 0);
}
fn ptrLeave(_: ?*anyopaque, _: ?*c.struct_wl_pointer, serial: u32, _: ?*c.struct_wl_surface) callconv(.c) void {
    last_serial = serial;
}
fn ptrMotion(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {}
fn ptrButton(_: ?*anyopaque, _: ?*c.struct_wl_pointer, serial: u32, _: u32, _: u32, _: u32) callconv(.c) void {
    last_serial = serial;
}
fn ptrAxis(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, _: c.wl_fixed_t) callconv(.c) void {}
fn ptrFrame(_: ?*anyopaque, _: ?*c.struct_wl_pointer) callconv(.c) void {}
fn ptrAxisSource(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32) callconv(.c) void {}
fn ptrAxisStop(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn ptrAxisDiscrete(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
fn ptrAxisDir(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}

const ptr_listener: c.struct_wl_pointer_listener = .{
    .enter = ptrEnter,
    .leave = ptrLeave,
    .motion = ptrMotion,
    .button = ptrButton,
    .axis = ptrAxis,
    .frame = ptrFrame,
    .axis_source = ptrAxisSource,
    .axis_stop = ptrAxisStop,
    .axis_discrete = ptrAxisDiscrete,
    .axis_value120 = ptrAxisDiscrete,
    .axis_relative_direction = ptrAxisDir,
};

// ------------------------------------------------------------------ windows

fn shmBuffer(w: i32, h: i32, argb: u32) ?*c.struct_wl_buffer {
    const stride = w * 4;
    const size = stride * h;
    const fd = c.memfd_create("evil", c.MFD_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    if (c.ftruncate(fd, size) != 0) return null;
    const p = c.mmap(null, @intCast(size), c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0) orelse return null;
    if (@intFromPtr(p) == std.math.maxInt(usize)) return null;
    const px: [*]u32 = @ptrCast(@alignCast(p));
    @memset(px[0..@intCast(w * h)], argb);
    _ = c.munmap(p, @intCast(size));
    const pool = c.wl_shm_create_pool(shm, fd, size);
    defer c.wl_shm_pool_destroy(pool);
    return c.wl_shm_pool_create_buffer(pool, 0, w, h, stride, c.WL_SHM_FORMAT_ARGB8888);
}

const Window = struct {
    surface: ?*c.struct_wl_surface,
    xdg: ?*c.struct_xdg_surface,
    top: ?*c.struct_xdg_toplevel = null,
    configured: bool = false,
    w: i32 = 64,
    h: i32 = 64,
    color: u32 = 0xff802080,

    fn draw(win: *Window) void {
        c.wl_surface_attach(win.surface, shmBuffer(win.w, win.h, win.color), 0, 0);
        c.wl_surface_damage(win.surface, 0, 0, win.w, win.h);
        c.wl_surface_commit(win.surface);
    }
};

fn xdgConfigure(data: ?*anyopaque, xs: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(data.?));
    c.xdg_surface_ack_configure(xs, serial);
    win.configured = true;
    win.draw();
}

const xdg_surface_listener: c.struct_xdg_surface_listener = .{ .configure = xdgConfigure };

fn topConfigure(data: ?*anyopaque, _: ?*c.struct_xdg_toplevel, w: i32, h: i32, states: [*c]c.struct_wl_array) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(data.?));
    configures += 1;
    if (states != null and states.*.data != null) {
        const n = states.*.size / @sizeOf(u32);
        const st: [*]const u32 = @ptrCast(@alignCast(states.*.data));
        for (st[0..n]) |x| if (x == c.XDG_TOPLEVEL_STATE_FULLSCREEN) {
            fullscreen_seen = true;
        };
    }
    if (w > 0 and h > 0 and w <= 8192 and h <= 8192) {
        win.w = w;
        win.h = h;
    }
}
fn topClose(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel) callconv(.c) void {}
fn topBounds(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
fn topCaps(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: [*c]c.struct_wl_array) callconv(.c) void {}

const toplevel_listener: c.struct_xdg_toplevel_listener = .{
    .configure = topConfigure,
    .close = topClose,
    .configure_bounds = topBounds,
    .wm_capabilities = topCaps,
};

/// `fixed` makes min == max size, which RefursWM floats.
fn newWindow(fixed: bool) *Window {
    const win = std.heap.c_allocator.create(Window) catch @panic("oom");
    const sf = c.wl_compositor_create_surface(compositor);
    win.* = .{ .surface = sf, .xdg = c.xdg_wm_base_get_xdg_surface(wm_base, sf) };
    _ = c.xdg_surface_add_listener(win.xdg, &xdg_surface_listener, win);
    win.top = c.xdg_surface_get_toplevel(win.xdg);
    _ = c.xdg_toplevel_add_listener(win.top, &toplevel_listener, win);
    c.xdg_toplevel_set_app_id(win.top, "evil");
    if (fixed) {
        c.xdg_toplevel_set_min_size(win.top, 100, 100);
        c.xdg_toplevel_set_max_size(win.top, 100, 100);
    }
    c.wl_surface_commit(sf);
    return win;
}

fn mapWindow(fixed: bool) *Window {
    const win = newWindow(fixed);
    const t0 = nowMs();
    while (!win.configured and nowMs() - t0 < 3000) if (!pump(20)) break;
    _ = pump(200);
    return win;
}

// ------------------------------------------------------------------ modes

const MIN = std.math.minInt(i32);
const MAX = std.math.maxInt(i32);

fn modeGeom() u8 {
    const extremes = [_][4]i32{
        .{ MIN, MIN, MAX, MAX },
        .{ MAX, MAX, MAX, MAX },
        .{ MIN, 0, 1, 1 },
        .{ 0, MIN, 1, 1 },
        .{ MAX, 0, 1, 1 },
        .{ 0, MAX, MAX, 1 },
        .{ -MAX, -MAX, MAX, MAX },
    };
    for ([_]bool{ false, true }) |fixed| {
        const win = mapWindow(fixed);
        for (extremes) |g| {
            c.xdg_surface_set_window_geometry(win.xdg, g[0], g[1], g[2], g[3]);
            win.draw();
            if (!pump(100)) break;
        }
    }
    report();
    return 0;
}

fn lsConfigure(_: ?*anyopaque, ls: ?*c.struct_zwlr_layer_surface_v1, serial: u32, _: u32, _: u32) callconv(.c) void {
    c.zwlr_layer_surface_v1_ack_configure(ls, serial);
    configures += 1;
}
fn lsClosed(_: ?*anyopaque, _: ?*c.struct_zwlr_layer_surface_v1) callconv(.c) void {}

const layer_listener: c.struct_zwlr_layer_surface_v1_listener = .{ .configure = lsConfigure, .closed = lsClosed };

fn modeLayer() u8 {
    if (layer_shell == null) return fail("no layer shell");
    const cases = [_][5]i32{
        // exclusive zone, margins top/right/bottom/left
        .{ MAX, MIN, MAX, MIN, MAX },
        .{ MAX, MAX, MAX, MAX, MAX },
        .{ MIN, MIN, MIN, MIN, MIN },
        .{ 1 << 20, 0, 0, 0, 0 },
    };
    for (cases) |k| {
        const sf = c.wl_compositor_create_surface(compositor);
        const ls = c.zwlr_layer_shell_v1_get_layer_surface(layer_shell, sf, null, c.ZWLR_LAYER_SHELL_V1_LAYER_TOP, "evil");
        _ = c.zwlr_layer_surface_v1_add_listener(ls, &layer_listener, null);
        c.zwlr_layer_surface_v1_set_anchor(ls, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
        c.zwlr_layer_surface_v1_set_size(ls, 0, 30);
        c.zwlr_layer_surface_v1_set_exclusive_zone(ls, k[0]);
        c.zwlr_layer_surface_v1_set_margin(ls, k[1], k[2], k[3], k[4]);
        c.wl_surface_commit(sf);
        if (!pump(150)) break;
        c.wl_surface_attach(sf, shmBuffer(16, 30, 0xff208020), 0, 0);
        c.wl_surface_commit(sf);
        if (!pump(150)) break;
    }
    report();
    return 0;
}

fn modeFlood(n: u32) u8 {
    var made: u32 = 0;
    while (made < n) : (made += 1) {
        _ = newWindow(false);
        if (made % 32 == 31 and !pump(10)) break;
    }
    _ = pump(500);
    out("created {d}\n", .{made});
    report();
    return 0;
}

fn popupConfigure(_: ?*anyopaque, _: ?*c.struct_xdg_popup, _: i32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn popupDone(_: ?*anyopaque, _: ?*c.struct_xdg_popup) callconv(.c) void {}
fn popupRepositioned(_: ?*anyopaque, _: ?*c.struct_xdg_popup, _: u32) callconv(.c) void {}

const popup_listener: c.struct_xdg_popup_listener = .{
    .configure = popupConfigure,
    .popup_done = popupDone,
    .repositioned = popupRepositioned,
};

fn modePopups(n: u32) u8 {
    const parent = mapWindow(false);
    var made: u32 = 0;
    while (made < n) : (made += 1) {
        const pos = c.xdg_wm_base_create_positioner(wm_base);
        c.xdg_positioner_set_size(pos, 10, 10);
        c.xdg_positioner_set_anchor_rect(pos, 0, 0, 1, 1);
        const sf = c.wl_compositor_create_surface(compositor);
        const xs = c.xdg_wm_base_get_xdg_surface(wm_base, sf);
        const pp = c.xdg_surface_get_popup(xs, parent.xdg, pos);
        _ = c.xdg_popup_add_listener(pp, &popup_listener, null);
        c.xdg_positioner_destroy(pos);
        if (made % 32 == 31 and !pump(10)) break;
    }
    _ = pump(500);
    out("created {d}\n", .{made});
    report();
    return 0;
}

// clipboard

const evil_text = "EVIL-CLIPBOARD";

fn srcTarget(_: ?*anyopaque, _: ?*c.struct_wl_data_source, _: [*c]const u8) callconv(.c) void {}
fn srcSend(_: ?*anyopaque, _: ?*c.struct_wl_data_source, _: [*c]const u8, fd: i32) callconv(.c) void {
    _ = c.write(fd, evil_text, evil_text.len);
    _ = c.close(fd);
}
fn srcCancelled(_: ?*anyopaque, _: ?*c.struct_wl_data_source) callconv(.c) void {}
fn srcDnd(_: ?*anyopaque, _: ?*c.struct_wl_data_source) callconv(.c) void {}
fn srcAction(_: ?*anyopaque, _: ?*c.struct_wl_data_source, _: u32) callconv(.c) void {}

const source_listener: c.struct_wl_data_source_listener = .{
    .target = srcTarget,
    .send = srcSend,
    .cancelled = srcCancelled,
    .dnd_drop_performed = srcDnd,
    .dnd_finished = srcDnd,
    .action = srcAction,
};

fn notFocused() bool {
    return leaves > 0 and !focused;
}

fn offerClipboard(dev: ?*c.struct_wl_data_device) void {
    const src = c.wl_data_device_manager_create_data_source(ddm);
    _ = c.wl_data_source_add_listener(src, &source_listener, null);
    c.wl_data_source_offer(src, "text/plain;charset=utf-8");
    c.wl_data_source_offer(src, "text/plain");
    c.wl_data_device_set_selection(dev, src, last_serial);
}

fn modeCopy() u8 {
    if (ddm == null) return fail("no data device manager");
    const dev = c.wl_data_device_manager_get_data_device(ddm, seat);
    _ = c.wl_data_device_add_listener(dev, &device_listener, null);
    _ = mapWindow(false);
    if (!waitFor(3000, isFocused)) return fail("never got the focus");
    offerClipboard(dev);
    out("set_selection sent while focused (serial {d})\n", .{last_serial});
    _ = pump(6000);
    return 0;
}

fn modeClip() u8 {
    if (ddm == null) return fail("no data device manager");
    const dev = c.wl_data_device_manager_get_data_device(ddm, seat);
    _ = c.wl_data_device_add_listener(dev, &device_listener, null);
    _ = mapWindow(false);
    // wait until something else takes the keyboard, then grab the clipboard from the background
    if (!waitFor(10_000, notFocused)) return fail("never lost the focus");
    offerClipboard(dev);
    out("set_selection sent while unfocused (serial {d})\n", .{last_serial});
    _ = pump(6000);
    report();
    return 0;
}

var offer: ?*c.struct_wl_data_offer = null;
var offer_text = false;
var got_selection = false;

fn offerMime(_: ?*anyopaque, _: ?*c.struct_wl_data_offer, mime: [*c]const u8) callconv(.c) void {
    if (std.mem.startsWith(u8, std.mem.span(mime), "text/plain")) offer_text = true;
}
fn offerActions(_: ?*anyopaque, _: ?*c.struct_wl_data_offer, _: u32) callconv(.c) void {}

const offer_listener: c.struct_wl_data_offer_listener = .{ .offer = offerMime, .source_actions = offerActions, .action = offerActions };

fn devOffer(_: ?*anyopaque, _: ?*c.struct_wl_data_device, o: ?*c.struct_wl_data_offer) callconv(.c) void {
    offer_text = false;
    _ = c.wl_data_offer_add_listener(o, &offer_listener, null);
}
fn devEnter(_: ?*anyopaque, _: ?*c.struct_wl_data_device, _: u32, _: ?*c.struct_wl_surface, _: c.wl_fixed_t, _: c.wl_fixed_t, _: ?*c.struct_wl_data_offer) callconv(.c) void {}
fn devLeave(_: ?*anyopaque, _: ?*c.struct_wl_data_device) callconv(.c) void {}
fn devMotion(_: ?*anyopaque, _: ?*c.struct_wl_data_device, _: u32, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {}
fn devDrop(_: ?*anyopaque, _: ?*c.struct_wl_data_device) callconv(.c) void {}
fn devSelection(_: ?*anyopaque, _: ?*c.struct_wl_data_device, o: ?*c.struct_wl_data_offer) callconv(.c) void {
    offer = o;
    got_selection = true;
}

const device_listener: c.struct_wl_data_device_listener = .{
    .data_offer = devOffer,
    .enter = devEnter,
    .leave = devLeave,
    .motion = devMotion,
    .drop = devDrop,
    .selection = devSelection,
};

fn hasSelection() bool {
    return got_selection;
}

fn modePaste() u8 {
    if (ddm == null) return fail("no data device manager");
    const dev = c.wl_data_device_manager_get_data_device(ddm, seat);
    _ = c.wl_data_device_add_listener(dev, &device_listener, null);
    _ = mapWindow(false);
    _ = waitFor(2000, hasSelection);
    const o = offer orelse {
        out("clipboard: <empty>\n", .{});
        return 0;
    };
    if (!offer_text) {
        out("clipboard: <no text>\n", .{});
        return 0;
    }
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return fail("pipe");
    c.wl_data_offer_receive(o, "text/plain", fds[1]);
    _ = c.close(fds[1]);
    _ = c.wl_display_roundtrip(display);
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    const t0 = nowMs();
    while (n < buf.len and nowMs() - t0 < 2000) {
        var pfd: c.struct_pollfd = .{ .fd = fds[0], .events = c.POLLIN, .revents = 0 };
        if (c.poll(&pfd, 1, 100) <= 0) {
            _ = c.wl_display_dispatch_pending(display);
            continue;
        }
        const r = c.read(fds[0], &buf[n], buf.len - n);
        if (r <= 0) break;
        n += @intCast(r);
    }
    out("clipboard: {s}\n", .{buf[0..n]});
    return 0;
}

// activation

var token_name: [128]u8 = undefined;
var token_len: usize = 0;
var token_done = false;

fn tokenDone(_: ?*anyopaque, t: ?*c.struct_xdg_activation_token_v1, name: [*c]const u8) callconv(.c) void {
    const s = std.mem.span(name);
    token_len = @min(s.len, token_name.len - 1);
    @memcpy(token_name[0..token_len], s[0..token_len]);
    token_name[token_len] = 0;
    token_done = true;
    c.xdg_activation_token_v1_destroy(t);
}

const token_listener: c.struct_xdg_activation_token_v1_listener = .{ .done = tokenDone };

fn tokenIsDone() bool {
    return token_done;
}

/// Mints a token for `serial`; `surface` may be null.
fn mint(serial: u32, surface: ?*c.struct_wl_surface) bool {
    token_done = false;
    const t = c.xdg_activation_v1_get_activation_token(activation);
    _ = c.xdg_activation_token_v1_add_listener(t, &token_listener, null);
    c.xdg_activation_token_v1_set_serial(t, serial, seat);
    if (surface) |sf| c.xdg_activation_token_v1_set_surface(t, sf);
    c.xdg_activation_token_v1_commit(t);
    return waitFor(2000, tokenIsDone);
}

fn modeActivate() u8 {
    if (activation == null) return fail("no xdg-activation");
    const win = mapWindow(false);
    if (!waitFor(10_000, notFocused)) return fail("never lost the focus");
    if (!mint(last_serial, null)) return fail("no token");
    const before = enters;
    c.xdg_activation_v1_activate(activation, @ptrCast(&token_name), win.surface);
    _ = pump(1000);
    out("{s}\n", .{if (enters > before) "focus: STOLEN" else "focus: kept"});
    return 0;
}

fn isFocused() bool {
    return focused;
}

/// What a notification daemon or a launcher does: the token is minted while focused, used later.
fn modeRemint() u8 {
    if (activation == null) return fail("no xdg-activation");
    const win = mapWindow(false);
    if (!waitFor(3000, isFocused)) return fail("never got the focus");
    if (!mint(last_serial, win.surface)) return fail("no token");
    if (!waitFor(10_000, notFocused)) return fail("never lost the focus");
    const before = enters;
    c.xdg_activation_v1_activate(activation, @ptrCast(&token_name), win.surface);
    _ = pump(1000);
    out("{s}\n", .{if (enters > before) "focus: regained" else "focus: refused"});
    return 0;
}

fn modeMapFocus() u8 {
    _ = mapWindow(false);
    _ = pump(500);
    out("focused on map: {s}\n", .{if (enters > 0) "yes" else "no"});
    return 0;
}

fn modeFullscreen() u8 {
    // after mapping
    const win = mapWindow(false);
    c.xdg_toplevel_set_fullscreen(win.top, null);
    c.wl_surface_commit(win.surface);
    _ = pump(500);
    const after = fullscreen_seen;
    // before the first commit: the request is part of the initial state
    const win2 = std.heap.c_allocator.create(Window) catch @panic("oom");
    const sf = c.wl_compositor_create_surface(compositor);
    win2.* = .{ .surface = sf, .xdg = c.xdg_wm_base_get_xdg_surface(wm_base, sf) };
    _ = c.xdg_surface_add_listener(win2.xdg, &xdg_surface_listener, win2);
    win2.top = c.xdg_surface_get_toplevel(win2.xdg);
    _ = c.xdg_toplevel_add_listener(win2.top, &toplevel_listener, win2);
    c.xdg_toplevel_set_fullscreen(win2.top, null);
    fullscreen_seen = false;
    c.wl_surface_commit(sf);
    _ = pump(800);
    const before = fullscreen_seen;
    // leaving fullscreen must always work: the last configure of the first window must not be fullscreen
    fullscreen_seen = false;
    c.xdg_toplevel_unset_fullscreen(win.top);
    c.wl_surface_commit(win.surface);
    _ = pump(500);
    out("fullscreen after map: {s}, before map: {s}, unset ok: {s}\n", .{ if (after) "yes" else "no", if (before) "yes" else "no", if (fullscreen_seen) "no" else "yes" });
    return 0;
}

fn modeSelfActivate(n: u32) u8 {
    if (activation == null) return fail("no xdg-activation");
    const win = mapWindow(false);
    if (!waitFor(3000, isFocused)) return fail("never got the focus");
    _ = pump(300);
    const serial = last_serial;
    const before = configures;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (!mint(serial, win.surface)) return fail("no token");
        c.xdg_activation_v1_activate(activation, @ptrCast(&token_name), win.surface);
        if (!pump(30)) break;
    }
    _ = pump(300);
    out("configures for {d} activations of the focused window: {d}\n", .{ n, configures - before });
    return 0;
}

fn modeInhibit(secs: u32) u8 {
    if (inhibit_mgr == null) return fail("no idle inhibit");
    const win = mapWindow(false);
    _ = c.zwp_idle_inhibit_manager_v1_create_inhibitor(inhibit_mgr, win.surface);
    _ = pump(@as(i64, secs) * 1000);
    report();
    return 0;
}

const keymap_text =
    \\xkb_keymap {
    \\  xkb_keycodes "evil" { minimum = 8; maximum = 255; <K1> = 38; };
    \\  xkb_types "evil" { type "ONE_LEVEL" { modifiers = none; level_name[Level1] = "Any"; }; };
    \\  xkb_compat "evil" { };
    \\  xkb_symbols "evil" { key <K1> { [ a ] }; };
    \\};
;

fn virtualKeyboard() ?*c.struct_zwp_virtual_keyboard_v1 {
    const kb = c.zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(vkbd_mgr, seat);
    const fd = c.memfd_create("evil-keymap", c.MFD_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    _ = c.write(fd, keymap_text, keymap_text.len + 1);
    c.zwp_virtual_keyboard_v1_keymap(kb, c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, keymap_text.len + 1);
    return kb;
}

/// Headless has no keyboard, so no client would ever get keyboard focus events: hold one.
fn modeKeyboard(secs: u32) u8 {
    if (vkbd_mgr == null) return fail("no virtual keyboard");
    _ = virtualKeyboard() orelse return fail("memfd");
    _ = pump(@as(i64, secs) * 1000);
    return 0;
}

fn modeVkey() u8 {
    if (vkbd_mgr == null) return fail("no virtual keyboard");
    const kb = virtualKeyboard() orelse return fail("memfd");
    for ([_]u32{ 0xfffffff8, 0xffffffff, 0x7fffffff, 0x10000, 1023, 1024 }) |key| {
        c.zwp_virtual_keyboard_v1_modifiers(kb, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff);
        c.zwp_virtual_keyboard_v1_key(kb, 0, key, c.WL_KEYBOARD_KEY_STATE_PRESSED);
        c.zwp_virtual_keyboard_v1_key(kb, 0, key, c.WL_KEYBOARD_KEY_STATE_RELEASED);
        c.zwp_virtual_keyboard_v1_modifiers(kb, 0, 0, 0, 0);
        if (!pump(50)) break;
    }
    _ = pump(300);
    report();
    return 0;
}

/// Moves the pointer inside its own window, which hides the cursor: what remains is the cost of the
/// motion itself (hit test, focus, motion events, idle bookkeeping), not of redrawing a cursor.
fn modeMotion(n: u32) u8 {
    if (vptr_mgr == null) return fail("no virtual pointer");
    hide_cursor = true;
    _ = mapWindow(false);
    const p = c.zwlr_virtual_pointer_manager_v1_create_virtual_pointer(vptr_mgr, seat);
    c.zwlr_virtual_pointer_v1_motion_absolute(p, 0, 1, 1, 2, 2);
    c.zwlr_virtual_pointer_v1_frame(p);
    _ = pump(300);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const d: c.wl_fixed_t = if (i % 2 == 0) 256 * 3 else -256 * 3;
        c.zwlr_virtual_pointer_v1_motion(p, i, d, @divTrunc(d, 3));
        c.zwlr_virtual_pointer_v1_frame(p);
        _ = c.wl_display_flush(display);
        _ = c.usleep(1000);
        if (i % 64 == 0 and c.wl_display_dispatch_pending(display) < 0) break;
    }
    _ = c.wl_display_roundtrip(display);
    report();
    return 0;
}

fn fail(msg: []const u8) u8 {
    out("evil: {s}\n", .{msg});
    return 2;
}

fn usage() u8 {
    out("usage: evil registry|geom|layer|flood N|popups N|clip|copy|paste|activate|remint|mapfocus|selfactivate N|inhibit SECS|vkey|keyboard SECS|motion N\n", .{});
    return 2;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var args = init.args.iterate();
    _ = args.skip();
    const mode = args.next() orelse return usage();
    const num: u32 = if (args.next()) |a| std.fmt.parseInt(u32, a, 10) catch return usage() else 0;
    display = c.wl_display_connect(null) orelse return fail("cannot connect");
    list_globals = std.mem.eql(u8, mode, "registry");
    const reg = c.wl_display_get_registry(display);
    _ = c.wl_registry_add_listener(reg, &registry_listener, null);
    _ = c.wl_display_roundtrip(display);
    _ = c.wl_display_roundtrip(display);
    if (list_globals) return 0;
    if (compositor == null or shm == null or wm_base == null or seat == null) return fail("missing core globals");

    const eq = std.mem.eql;
    if (eq(u8, mode, "geom")) return modeGeom();
    if (eq(u8, mode, "layer")) return modeLayer();
    if (eq(u8, mode, "flood")) return modeFlood(num);
    if (eq(u8, mode, "popups")) return modePopups(num);
    if (eq(u8, mode, "clip")) return modeClip();
    if (eq(u8, mode, "paste")) return modePaste();
    if (eq(u8, mode, "copy")) return modeCopy();
    if (eq(u8, mode, "remint")) return modeRemint();
    if (eq(u8, mode, "mapfocus")) return modeMapFocus();
    if (eq(u8, mode, "fullscreen")) return modeFullscreen();
    if (eq(u8, mode, "activate")) return modeActivate();
    if (eq(u8, mode, "selfactivate")) return modeSelfActivate(num);
    if (eq(u8, mode, "inhibit")) return modeInhibit(num);
    if (eq(u8, mode, "vkey")) return modeVkey();
    if (eq(u8, mode, "keyboard")) return modeKeyboard(num);
    if (eq(u8, mode, "motion")) return modeMotion(num);
    return usage();
}
