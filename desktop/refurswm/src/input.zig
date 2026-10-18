// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Keyboards, pointer, seat requests.
//! Keybindings match the key's symbol in the first layout without modifiers, so Super+Q works
//! the same with "us" or "ru" active and Shift-bindings use the unshifted key name.
const std = @import("std");
const wm = @import("wm.zig");
const c = wm.c;
const cfg = wm.cfg;
const View = wm.View;
const Listener = wm.Listener;
const outmod = @import("output.zig");
const policy = @import("policy.zig");
const shell = @import("shell.zig");
const s = &wm.s;
const zero = std.mem.zeroes(Listener);

const BTN_LEFT = 0x110;
const BTN_RIGHT = 0x111;
/// caps lock and num lock never take part in matching
const IGNORED_MODS: u32 = c.WLR_MODIFIER_CAPS | c.WLR_MODIFIER_MOD2;

var syms: [cfg.binds.len]u32 = undefined;
const plain_binds = for (cfg.binds) |b| {
    if (b.mods == 0) break true;
} else false;
var keymap: ?*c.struct_xkb_keymap = null;
var keyboards: u32 = 0;
/// keys whose press was a binding: their release must not reach the client either
var swallowed: std.StaticBitSet(1024) = .empty;

pub fn init() bool {
    inline for (cfg.binds, 0..) |b, i| {
        syms[i] = c.xkb_keysym_from_name(b.key.ptr, c.XKB_KEYSYM_NO_FLAGS);
        if (syms[i] == 0) wm.log("config: unknown key name \"{s}\"", .{b.key});
    }
    const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return false;
    defer c.xkb_context_unref(ctx);
    const names: c.struct_xkb_rule_names = .{
        .rules = null,
        .model = null,
        .layout = cfg.xkb_layout,
        .variant = cfg.xkb_variant,
        .options = cfg.xkb_options,
    };
    keymap = c.xkb_keymap_new_from_names(ctx, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (keymap == null) {
        wm.log("config: bad xkb layout/options, falling back to the default keymap", .{});
        keymap = c.xkb_keymap_new_from_names(ctx, null, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
    }
    return keymap != null;
}

// ------------------------------------------------------------------ keyboard

const Keyboard = struct {
    wlr: *c.struct_wlr_keyboard,
    l_key: Listener = zero,
    l_mods: Listener = zero,
    l_destroy: Listener = zero,

    fn onMods(k: *Keyboard, _: ?*anyopaque) void {
        c.wlr_seat_set_keyboard(s.seat, k.wlr);
        c.wlr_seat_keyboard_notify_modifiers(s.seat, &k.wlr.modifiers);
        shell.modifiers(k.wlr.modifiers.group);
    }

    fn onKey(k: *Keyboard, data: ?*anyopaque) void {
        const ev = wm.ptr(c.struct_wlr_keyboard_key_event, data);
        activity(ev.time_msec, true);
        const code = ev.keycode;
        // evdev codes end at 0x2ff; a virtual keyboard may send any u32
        if (code > 0xffff) return;
        if (ev.state == c.WL_KEYBOARD_KEY_STATE_PRESSED) {
            if (k.handle(code + 8)) {
                if (code < swallowed.capacity()) swallowed.set(code);
                return;
            }
        } else if (code < swallowed.capacity() and swallowed.isSet(code)) {
            swallowed.unset(code);
            return;
        }
        c.wlr_seat_set_keyboard(s.seat, k.wlr);
        c.wlr_seat_keyboard_notify_key(s.seat, ev.time_msec, code, ev.state);
    }

    fn handle(k: *Keyboard, keycode: u32) bool {
        // no keymap (a virtual keyboard sent a bad one, or shm ran out): nothing to match
        const state = k.wlr.xkb_state orelse return false;
        // Ctrl+Alt+Fn switches VTs even while locked (the locker stays on its VT)
        var tsyms: [*c]const c.xkb_keysym_t = null;
        const nt = c.xkb_state_key_get_syms(state, keycode, &tsyms);
        for (0..@intCast(@max(nt, 0))) |i| {
            const sym = tsyms[i];
            if (sym >= c.XKB_KEY_XF86Switch_VT_1 and sym <= c.XKB_KEY_XF86Switch_VT_12) {
                if (s.session) |sess| _ = c.wlr_session_change_vt(sess, sym - c.XKB_KEY_XF86Switch_VT_1 + 1);
                return true;
            }
        }
        const mods = c.wlr_keyboard_get_modifiers(k.wlr) & ~IGNORED_MODS;
        // plain typing never walks the binding table, unless the config binds a bare key (Print)
        if (mods == 0 and !plain_binds) return false;
        const km = k.wlr.keymap orelse return false;
        var raw: [*c]const c.xkb_keysym_t = null;
        const nr = c.xkb_keymap_key_get_syms_by_level(km, keycode, 0, 0, &raw);
        for (0..@intCast(@max(nr, 0))) |i| {
            const sym = c.xkb_keysym_to_lower(raw[i]);
            inline for (cfg.binds, 0..) |b, bi| {
                if (b.mods == mods and syms[bi] == sym) {
                    // locked: nothing but re-running the locker if it crashed
                    if (s.locked and !(b.action == .lock and s.lock == null)) return true;
                    wm.run(b.action);
                    return true;
                }
            }
        }
        return false;
    }

    fn onDestroy(k: *Keyboard, _: ?*anyopaque) void {
        wm.off(&k.l_key);
        wm.off(&k.l_mods);
        wm.off(&k.l_destroy);
        keyboards -|= 1;
        wm.gpa.destroy(k);
        updateCaps();
    }
};

fn addKeyboard(dev: *c.struct_wlr_input_device, own_keymap: bool) void {
    const kb = c.wlr_keyboard_from_input_device(dev);
    const k = wm.gpa.create(Keyboard) catch return;
    k.* = .{ .wlr = kb };
    // virtual keyboards bring their own keymap
    if (!own_keymap) _ = c.wlr_keyboard_set_keymap(kb, keymap);
    c.wlr_keyboard_set_repeat_info(kb, cfg.repeat_rate, cfg.repeat_delay);
    wm.on(&kb.*.events.key, &k.l_key, wm.cb(Keyboard, "l_key", Keyboard.onKey));
    wm.on(&kb.*.events.modifiers, &k.l_mods, wm.cb(Keyboard, "l_mods", Keyboard.onMods));
    wm.on(&dev.events.destroy, &k.l_destroy, wm.cb(Keyboard, "l_destroy", Keyboard.onDestroy));
    c.wlr_seat_set_keyboard(s.seat, kb);
    keyboards += 1;
}

fn updateCaps() void {
    var caps: u32 = c.WL_SEAT_CAPABILITY_POINTER;
    if (keyboards > 0) caps |= c.WL_SEAT_CAPABILITY_KEYBOARD;
    c.wlr_seat_set_capabilities(s.seat, caps);
}

fn configurePointer(dev: *c.struct_wlr_input_device) void {
    if (!c.wlr_input_device_is_libinput(dev)) return;
    const li = c.wlr_libinput_get_device_handle(dev) orelse return;
    if (c.libinput_device_config_tap_get_finger_count(li) > 0) {
        _ = c.libinput_device_config_tap_set_enabled(li, if (cfg.touchpad_tap) c.LIBINPUT_CONFIG_TAP_ENABLED else c.LIBINPUT_CONFIG_TAP_DISABLED);
        if (c.libinput_device_config_dwt_is_available(li) != 0)
            _ = c.libinput_device_config_dwt_set_enabled(li, if (cfg.touchpad_disable_while_typing) c.LIBINPUT_CONFIG_DWT_ENABLED else c.LIBINPUT_CONFIG_DWT_DISABLED);
        if (c.libinput_device_config_scroll_has_natural_scroll(li) != 0)
            _ = c.libinput_device_config_scroll_set_natural_scroll_enabled(li, @intFromBool(cfg.touchpad_natural_scroll));
    }
}

pub fn onNewInput(data: ?*anyopaque) void {
    const dev = wm.ptr(c.struct_wlr_input_device, data);
    switch (dev.type) {
        c.WLR_INPUT_DEVICE_KEYBOARD => addKeyboard(dev, false),
        c.WLR_INPUT_DEVICE_POINTER => {
            configurePointer(dev);
            c.wlr_cursor_attach_input_device(s.cursor, dev);
        },
        else => {},
    }
    updateCaps();
}

pub fn onVirtualKeyboard(data: ?*anyopaque) void {
    const vk = wm.ptr(c.struct_wlr_virtual_keyboard_v1, data);
    addKeyboard(&vk.keyboard.base, true);
    updateCaps();
}

pub fn onVirtualPointer(data: ?*anyopaque) void {
    const ev = wm.ptr(c.struct_wlr_virtual_pointer_v1_new_pointer_event, data);
    c.wlr_cursor_attach_input_device(s.cursor, &ev.new_pointer.*.pointer.base);
}

// ------------------------------------------------------------------ pointer

const Grab = enum { none, move, resize, tiled_move, tiled_resize };
var grab: Grab = .none;
var grab_view: ?*View = null;
var grab_button: u32 = 0;
var grab_edges: u32 = 0;
var grab_x: f64 = 0;
var grab_y: f64 = 0;
var grab_box: wm.Box = .{};
var last_x: f64 = 0;
var last_y: f64 = 0;
var cursor_default = false;

/// Pointer motion and scrolling come up to 1000 times a second, and every idle notification re-arms
/// its timer on each report. Timeouts are seconds or minutes, so once per 100 ms is plenty. Keys and
/// buttons always count, and the first event after a pause always does, so "resumed" is never late.
var last_activity: u32 = 0;

fn activity(time: u32, always: bool) void {
    if (!always and time -% last_activity < 100) return;
    last_activity = time;
    c.wlr_idle_notifier_v1_notify_activity(s.idle, s.seat);
}

fn setDefaultCursor() void {
    if (cursor_default) return;
    cursor_default = true;
    c.wlr_cursor_set_xcursor(s.cursor, s.xcursor, "default");
}

pub fn beginGrab(v: *View, kind: Grab, edges: u32) void {
    grab = kind;
    grab_view = v;
    grab_edges = if (edges == 0) c.WLR_EDGE_RIGHT | c.WLR_EDGE_BOTTOM else edges;
    grab_x = s.cursor.x;
    grab_y = s.cursor.y;
    last_x = grab_x;
    last_y = grab_y;
    grab_box = v.box;
    cursor_default = false;
    c.wlr_cursor_set_xcursor(s.cursor, s.xcursor, switch (kind) {
        .move, .tiled_move => "grabbing",
        else => "se-resize",
    });
}

fn endGrab() void {
    grab = .none;
    grab_view = null;
    cursor_default = false;
    setDefaultCursor();
}

/// a view going away must not stay the target of a grab or hover
pub fn forget(v: *View) void {
    if (grab_view == v) endGrab();
}

fn px(x: f64) i32 {
    return wm.L.px(x);
}

fn motion(time: u32) void {
    if (drag_icon) |t| c.wlr_scene_node_set_position(&t.node, px(s.cursor.x), px(s.cursor.y));
    const cx = s.cursor.x;
    const cy = s.cursor.y;
    if (grab_view) |v| switch (grab) {
        .move => {
            v.box.x = grab_box.x +| px(cx - grab_x);
            v.box.y = grab_box.y +| px(cy - grab_y);
            return v.place();
        },
        .resize => {
            const dx = px(cx - grab_x);
            const dy = px(cy - grab_y);
            var b = grab_box;
            if (grab_edges & c.WLR_EDGE_LEFT != 0) {
                b.x +|= dx;
                b.w -|= dx;
            } else if (grab_edges & c.WLR_EDGE_RIGHT != 0) b.w +|= dx;
            if (grab_edges & c.WLR_EDGE_TOP != 0) {
                b.y +|= dy;
                b.h -|= dy;
            } else if (grab_edges & c.WLR_EDGE_BOTTOM != 0) b.h +|= dy;
            if (b.w < 60 or b.h < 40) return;
            v.box = b;
            v.configure();
            return v.place();
        },
        .tiled_resize => {
            const dx = px(cx - last_x);
            const dy = px(cy - last_y);
            if (dx == 0 and dy == 0) return;
            last_x = cx;
            last_y = cy;
            return wm.resizeView(v, dx, dy, false);
        },
        .tiled_move => return,
        .none => {},
    };

    const h = wm.hitTest(cx, cy);
    if (s.locked and !h.lock) {
        c.wlr_seat_pointer_clear_focus(s.seat);
        return setDefaultCursor();
    }
    if (cfg.focus_follows_mouse and !s.locked and h.view != s.hover and s.seat.drag == null) {
        if (h.view) |v| if (v != s.focused and (s.layer_focus == null or !s.layer_focus.?.mapped)) wm.focusView(v, false);
    }
    s.hover = h.view;
    if (h.view == null and h.layer == null) {
        // empty desktop: the monitor under the cursor becomes the active one
        if (outmod.outputOf(c.wlr_output_layout_output_at(s.output_layout, cx, cy))) |o| if (s.mon != o) {
            s.mon = o;
            shell.touch();
        };
    }
    if (h.surface) |sf| {
        cursor_default = false;
        c.wlr_seat_pointer_notify_enter(s.seat, sf, h.sx, h.sy);
        c.wlr_seat_pointer_notify_motion(s.seat, time, h.sx, h.sy);
    } else {
        c.wlr_seat_pointer_clear_focus(s.seat);
        setDefaultCursor();
    }
}

pub fn onMotion(data: ?*anyopaque) void {
    const ev = wm.ptr(c.struct_wlr_pointer_motion_event, data);
    activity(ev.time_msec, false);
    c.wlr_relative_pointer_manager_v1_send_relative_motion(s.relptr, s.seat, @as(u64, ev.time_msec) * 1000, ev.delta_x, ev.delta_y, ev.unaccel_dx, ev.unaccel_dy);
    c.wlr_cursor_move(s.cursor, &ev.pointer.*.base, ev.delta_x, ev.delta_y);
    motion(ev.time_msec);
}

pub fn onMotionAbsolute(data: ?*anyopaque) void {
    const ev = wm.ptr(c.struct_wlr_pointer_motion_absolute_event, data);
    activity(ev.time_msec, false);
    c.wlr_cursor_warp_absolute(s.cursor, &ev.pointer.*.base, ev.x, ev.y);
    motion(ev.time_msec);
}

fn modHeld() bool {
    const kb = c.wlr_seat_get_keyboard(s.seat) orelse return false;
    return c.wlr_keyboard_get_modifiers(kb) & cfg.mod != 0;
}

pub fn onButton(data: ?*anyopaque) void {
    const ev = wm.ptr(c.struct_wlr_pointer_button_event, data);
    activity(ev.time_msec, true);
    if (ev.state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
        const h = wm.hitTest(s.cursor.x, s.cursor.y);
        if (s.locked and !h.lock) return;
        if (!s.locked) if (h.view) |v| {
            if (grab == .none and modHeld() and (ev.button == BTN_LEFT or ev.button == BTN_RIGHT)) {
                wm.focusView(v, false);
                grab_button = ev.button;
                const left = ev.button == BTN_LEFT;
                beginGrab(v, if (v.floating) (if (left) .move else .resize) else (if (left) .tiled_move else .tiled_resize), 0);
                return;
            }
            if (v != s.focused) wm.focusView(v, false) else if (v.floating) c.wlr_scene_node_raise_to_top(&v.tree.node);
            if (s.layer_focus) |l| if (l.ls.current.keyboard_interactive == c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_ON_DEMAND) outmod.unfocusLayer();
        };
        if (!s.locked) if (h.layer) |l| if (l.interactive() and s.layer_focus != l) outmod.focusLayer(l);
    } else if (grab != .none and ev.button == grab_button) {
        const v = grab_view;
        const kind = grab;
        endGrab();
        // Super+drag on a tiled window: drop it onto another one to swap them
        if (kind == .tiled_move) if (v) |a| if (wm.hitTest(s.cursor.x, s.cursor.y).view) |b| if (a != b) wm.swapTiled(a, b);
        return;
    }
    _ = c.wlr_seat_pointer_notify_button(s.seat, ev.time_msec, ev.button, ev.state);
}

pub fn onAxis(data: ?*anyopaque) void {
    const ev = wm.ptr(c.struct_wlr_pointer_axis_event, data);
    activity(ev.time_msec, false);
    c.wlr_seat_pointer_notify_axis(s.seat, ev.time_msec, ev.orientation, ev.delta, ev.delta_discrete, ev.source, ev.relative_direction);
}

pub fn onFrame(_: ?*anyopaque) void {
    c.wlr_seat_pointer_notify_frame(s.seat);
}

// ------------------------------------------------------------------ seat requests

pub fn onRequestCursor(data: ?*anyopaque) void {
    const ev = wm.ptr(c.struct_wlr_seat_pointer_request_set_cursor_event, data);
    if (grab != .none) return;
    // only the client under the pointer may set it
    if (ev.seat_client == s.seat.pointer_state.focused_client)
        c.wlr_cursor_set_surface(s.cursor, ev.surface, ev.hotspot_x, ev.hotspot_y);
}

pub fn onCursorShape(data: ?*anyopaque) void {
    const ev = wm.ptr(c.struct_wlr_cursor_shape_manager_v1_request_set_shape_event, data);
    if (grab != .none) return;
    if (ev.seat_client == s.seat.pointer_state.focused_client)
        c.wlr_cursor_set_xcursor(s.cursor, s.xcursor, c.wlr_cursor_shape_v1_name(ev.shape));
}

// clipboard: the request event of wlr_seat does not say which client asked, so the protocol
// logger notes it while the request is dispatched (policy.maySetSelection decides)

var sel_client: ?*c.struct_wl_client = null;
var sel_control = false;

/// Sees every message (wl_display_add_protocol_logger): two string compares per request, nothing
/// for events, no formatting.
pub fn protocolLogger(_: ?*anyopaque, dir: c.enum_wl_protocol_logger_type, m: [*c]const c.struct_wl_protocol_logger_message) callconv(.c) void {
    if (dir != c.WL_PROTOCOL_LOGGER_REQUEST) return;
    const name = std.mem.span(m.*.message.*.name);
    if (!std.mem.eql(u8, name, "set_selection") and !std.mem.eql(u8, name, "set_primary_selection")) return;
    sel_client = c.wl_resource_get_client(m.*.resource);
    sel_control = std.mem.endsWith(u8, std.mem.span(c.wl_resource_get_class(m.*.resource)), "data_control_device_v1");
}

fn selectionAllowed() bool {
    const requester = sel_client;
    const control = sel_control;
    sel_client = null;
    sel_control = false;
    const fc = s.seat.keyboard_state.focused_client;
    const focused: ?*c.struct_wl_client = if (fc != null) fc.*.client else null;
    return policy.maySetSelection(requester, focused, control);
}

pub fn onSetSelection(data: ?*anyopaque) void {
    const ev = wm.ptr(c.struct_wlr_seat_request_set_selection_event, data);
    // refused: the source is cancelled, so the app knows it does not own the clipboard
    if (!selectionAllowed()) return if (ev.source) |src| c.wlr_data_source_destroy(src);
    c.wlr_seat_set_selection(s.seat, ev.source, ev.serial);
}

pub fn onSetPrimary(data: ?*anyopaque) void {
    const ev = wm.ptr(c.struct_wlr_seat_request_set_primary_selection_event, data);
    if (!selectionAllowed()) return if (ev.source) |src| c.wlr_primary_selection_source_destroy(src);
    c.wlr_seat_set_primary_selection(s.seat, ev.source, ev.serial);
}

pub fn onRequestDrag(data: ?*anyopaque) void {
    const ev = wm.ptr(c.struct_wlr_seat_request_start_drag_event, data);
    if (c.wlr_seat_validate_pointer_grab_serial(s.seat, ev.origin, ev.serial)) {
        c.wlr_seat_start_pointer_drag(s.seat, ev.drag, ev.serial);
    } else c.wlr_data_source_destroy(ev.drag.*.source);
}

var drag_icon: ?*c.struct_wlr_scene_tree = null;
var l_icon_destroy: Listener = zero;

pub fn onStartDrag(data: ?*anyopaque) void {
    const drag = wm.ptr(c.struct_wlr_drag, data);
    const icon = drag.icon orelse return;
    drag_icon = c.wlr_scene_drag_icon_create(s.layers.dnd, icon);
    wm.on(&icon.*.events.destroy, &l_icon_destroy, wm.gcb(onIconDestroy));
}

pub fn shutdown() void {
    wm.off(&l_icon_destroy);
}

fn onIconDestroy(_: ?*anyopaque) void {
    wm.off(&l_icon_destroy);
    drag_icon = null;
}
