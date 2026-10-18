// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Compositor state and the window-management core: focus, workspaces, arranging, actions.
//! Single-threaded and purely event-driven: nothing runs unless a client or an input device
//! sends something, so an idle desktop costs zero wakeups. wlr_scene does damage tracking and
//! direct scanout, so only changed pixels are ever redrawn.
const std = @import("std");
pub const c = @import("c");
pub const cfg = @import("config.zig");
pub const T = @import("types.zig");
pub const L = @import("layout.zig");
pub const testing = @import("build_options").testing;
pub const View = @import("view.zig").View;
const launcher = @import("launcher.zig");
const policy = @import("policy.zig");
const client = @import("client.zig");
const view = @import("view.zig");
const outmod = @import("output.zig");
const shell = @import("shell.zig");
pub const Output = outmod.Output;
pub const LayerSurf = outmod.LayerSurf;

pub const gpa = std.heap.c_allocator;
pub const Box = L.Box;

// a wrong config value is a compile error, not a surprise after login
comptime {
    for (cfg.rules) |r| {
        if (r.workspace) |n| if (n < 1 or n > WS) @compileError("config: rule workspace must be 1..9");
    }
    if (cfg.border < 0 or cfg.border > 64) @compileError("config: border must be 0..64");
    if (cfg.gaps_in < 0 or cfg.gaps_out < 0 or cfg.gaps_in > 512 or cfg.gaps_out > 512) @compileError("config: gaps must be 0..512");
    if (cfg.scroll_width <= 0 or cfg.scroll_width > 1) @compileError("config: scroll_width must be within (0, 1]");
    if (cfg.scroll_widths.len == 0) @compileError("config: scroll_widths must not be empty");
    for (cfg.scroll_widths) |w| if (w <= 0 or w > 1) @compileError("config: scroll_widths must be within (0, 1]");
    for (cfg.outputs) |o| if (!(o.scale > 0 and o.scale <= 8)) @compileError("config: output scale must be within (0, 8]");
    if (cfg.repeat_rate < 0 or cfg.repeat_delay < 0) @compileError("config: key repeat must not be negative");
    if (cfg.cursor_size < 8 or cfg.cursor_size > 256) @compileError("config: cursor_size must be 8..256");
    for (cfg.binds) |b| switch (b.action) {
        .workspace, .move_to_workspace => |n| if (n < 1 or n > WS) @compileError("config: workspace binds take 1..9"),
        .spawn => |cmd| if (cmd.len == 0 or cmd.len > 32) @compileError("config: a command needs 1..32 arguments"),
        else => {},
    };
}
pub const Listener = c.struct_wl_listener;
pub const WS = 9;

/// First field of every object whose scene tree carries node.data, so hit tests can tell them apart.
pub const Tag = enum(u8) { view, layer, lock };

pub const Workspace = struct {
    mode: L.Mode = cfg.default_mode,
    dwindle: L.Dwindle(*View) = .{},
    scroll: L.Scroll(*View) = .{},
    output: ?*Output = null,
    fullscreen: ?*View = null,
};

pub const Layers = struct {
    color: *c.struct_wlr_scene_tree = undefined,
    background: *c.struct_wlr_scene_tree = undefined,
    bottom: *c.struct_wlr_scene_tree = undefined,
    tiled: *c.struct_wlr_scene_tree = undefined,
    floating: *c.struct_wlr_scene_tree = undefined,
    top: *c.struct_wlr_scene_tree = undefined,
    fullscreen: *c.struct_wlr_scene_tree = undefined,
    overlay: *c.struct_wlr_scene_tree = undefined,
    dnd: *c.struct_wlr_scene_tree = undefined,
    lock_bg: *c.struct_wlr_scene_tree = undefined,
    lock: *c.struct_wlr_scene_tree = undefined,
};

pub const Server = struct {
    display: *c.struct_wl_display = undefined,
    backend: *c.struct_wlr_backend = undefined,
    session: ?*c.struct_wlr_session = null,
    renderer: *c.struct_wlr_renderer = undefined,
    allocator: *c.struct_wlr_allocator = undefined,
    scene: *c.struct_wlr_scene = undefined,
    scene_layout: *c.struct_wlr_scene_output_layout = undefined,
    output_layout: *c.struct_wlr_output_layout = undefined,
    seat: *c.struct_wlr_seat = undefined,
    cursor: *c.struct_wlr_cursor = undefined,
    xcursor: *c.struct_wlr_xcursor_manager = undefined,
    relptr: *c.struct_wlr_relative_pointer_manager_v1 = undefined,
    idle: *c.struct_wlr_idle_notifier_v1 = undefined,
    tearing: *c.struct_wlr_tearing_control_manager_v1 = undefined,
    activation: *c.struct_wlr_xdg_activation_v1 = undefined,
    security: *c.struct_wlr_security_context_manager_v1 = undefined,
    layers: Layers = .{},

    views: std.ArrayList(*View) = .empty,
    /// most recently focused first
    stack: std.ArrayList(*View) = .empty,
    outputs: std.ArrayList(*Output) = .empty,
    layer_surfaces: std.ArrayList(*LayerSurf) = .empty,
    ws: [WS]Workspace = @splat(.{}),

    focused: ?*View = null,
    /// the monitor new windows and workspace switches go to
    mon: ?*Output = null,
    /// a layer surface (launcher, bar menu) holding the keyboard
    layer_focus: ?*LayerSurf = null,
    /// view under the pointer at the last motion; focus-follows-mouse fires only when it changes
    hover: ?*View = null,
    theme: T.Theme = cfg.theme,

    locked: bool = false,
    lock: ?*c.struct_wlr_session_lock_v1 = null,

    inhibitors: std.ArrayList(*Inhibitor) = .empty,
    idle_inhibited: bool = false,
    /// a lock was requested; `locked` is sent once every output has shown the cover
    lock_pending: bool = false,
    /// globals not offered to every client, see policy.Class
    restricted: std.ArrayList(Restricted) = .empty,
};

pub const Restricted = struct { global: *c.struct_wl_global, class: policy.Class };

pub var s: Server = .{};

// ------------------------------------------------------------------ idle inhibit

/// An idle inhibitor counts only while its surface is visible: a video on a hidden workspace or
/// behind the lock screen must not keep the session from locking itself.
pub const Inhibitor = struct {
    ih: *c.struct_wlr_idle_inhibitor_v1,
    owner: *client.State,
    l_destroy: Listener = std.mem.zeroes(Listener),

    fn onDestroy(x: *Inhibitor, _: ?*anyopaque) void {
        off(&x.l_destroy);
        if (std.mem.indexOfScalar(*Inhibitor, s.inhibitors.items, x)) |i| _ = s.inhibitors.swapRemove(i);
        client.give(x.owner, .inhibitors);
        gpa.destroy(x);
        updateIdle();
    }
};

pub fn onNewInhibitor(data: ?*anyopaque) void {
    const ih = ptr(c.struct_wlr_idle_inhibitor_v1, data);
    const owner = client.take(client.of(ih.resource), .inhibitors) orelse return;
    const x = gpa.create(Inhibitor) catch return client.give(owner, .inhibitors);
    x.* = .{ .ih = ih, .owner = owner };
    s.inhibitors.append(gpa, x) catch {
        gpa.destroy(x);
        return client.give(owner, .inhibitors);
    };
    on(&ih.events.destroy, &x.l_destroy, cb(Inhibitor, "l_destroy", Inhibitor.onDestroy));
    updateIdle();
}

/// Called whenever visibility may have changed (arrange, workspaces, lock); a few inhibitors at most.
pub fn updateIdle() void {
    var on_ = false;
    for (s.inhibitors.items) |x| if (visible(x.ih.surface)) {
        on_ = true;
        break;
    };
    if (on_ == s.idle_inhibited) return;
    s.idle_inhibited = on_;
    c.wlr_idle_notifier_v1_set_inhibited(s.idle, on_);
}

fn visible(surface: *c.struct_wlr_surface) bool {
    var sf = c.wlr_surface_get_root_surface(surface);
    if (s.locked) return c.wlr_session_lock_surface_v1_try_from_wlr_surface(sf) != null;
    // popups: up to the window or layer surface they belong to
    for (0..16) |_| {
        if (c.wlr_xdg_toplevel_try_from_wlr_surface(sf)) |top| {
            const v = view.viewOfToplevel(top) orelse return false;
            return v.mapped and v.enabled and s.ws[v.ws].output != null;
        }
        if (c.wlr_layer_surface_v1_try_from_wlr_surface(sf) != null) return sf.*.mapped;
        const p = c.wlr_xdg_popup_try_from_wlr_surface(sf) orelse return false;
        sf = c.wlr_surface_get_root_surface(p.*.parent orelse return false);
    }
    return false;
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("refurswm: " ++ fmt ++ "\n", args);
}

// ------------------------------------------------------------------ listener glue

pub fn on(sig: *c.struct_wl_signal, l: *Listener, f: c.wl_notify_func_t) void {
    l.notify = f;
    c.wl_signal_add(sig, l);
}

pub fn off(l: *Listener) void {
    if (l.link.next != null) c.wl_list_remove(&l.link);
    l.link = .{ .prev = null, .next = null };
}

/// C callback that recovers the owning object from the embedded listener field.
pub fn cb(comptime O: type, comptime field: []const u8, comptime f: fn (*O, ?*anyopaque) void) c.wl_notify_func_t {
    return &struct {
        fn h(l: [*c]Listener, data: ?*anyopaque) callconv(.c) void {
            const lp: *Listener = @ptrCast(l);
            const self: *O = @alignCast(@fieldParentPtr(field, lp));
            f(self, data);
        }
    }.h;
}

/// C callback for listeners that live in globals.
pub fn gcb(comptime f: fn (?*anyopaque) void) c.wl_notify_func_t {
    return &struct {
        fn h(_: [*c]Listener, data: ?*anyopaque) callconv(.c) void {
            f(data);
        }
    }.h;
}

pub fn ptr(comptime P: type, data: ?*anyopaque) *P {
    return @ptrCast(@alignCast(data.?));
}

pub fn wbox(b: Box) c.struct_wlr_box {
    return .{ .x = b.x, .y = b.y, .width = b.w, .height = b.h };
}

pub fn palette() T.Palette {
    return if (s.theme == .dark) cfg.dark else cfg.light;
}

// ------------------------------------------------------------------ focus

pub fn keyboardEnter(surface: ?*c.struct_wlr_surface) void {
    const sf = surface orelse return c.wlr_seat_keyboard_clear_focus(s.seat);
    if (c.wlr_seat_get_keyboard(s.seat)) |kb| {
        c.wlr_seat_keyboard_notify_enter(s.seat, sf, &kb.*.keycodes, kb.*.num_keycodes, &kb.*.modifiers);
    } else c.wlr_seat_keyboard_notify_enter(s.seat, sf, null, 0, null);
}

fn stackRemove(v: *View) void {
    if (std.mem.indexOfScalar(*View, s.stack.items, v)) |i| _ = s.stack.orderedRemove(i);
}

/// `scroll`: keyboard-driven focus, so a scroll-mode workspace brings the window into view.
pub fn focusView(target: ?*View, scroll: bool) void {
    if (s.locked) return;
    const prev = s.focused;
    const v = target orelse {
        shell.touch();
        s.focused = null;
        if (prev) |p| p.activate(false);
        if (s.layer_focus == null) c.wlr_seat_keyboard_clear_focus(s.seat);
        return;
    };
    if (!v.mapped) return;
    defer shell.touch();
    s.focused = v;
    stackRemove(v);
    s.stack.insert(gpa, 0, v) catch {};
    if (s.ws[v.ws].output) |o| s.mon = o;
    if (prev) |p| if (p != v) p.activate(false);
    v.activate(true);
    // tiled windows never overlap, so only floating ones are raised: re-stacking costs a redraw
    // (a tiled window is raised when it opens a popup, see view.onNewPopup)
    if (v.floating) c.wlr_scene_node_raise_to_top(&v.tree.node);
    if (s.layer_focus == null) keyboardEnter(v.surface());
    if (scroll and !v.floating and s.ws[v.ws].mode == .scroll) arrange(v.ws, v);
}

/// Most recently focused mapped window of workspace `n`, or nothing.
pub fn focusTop(n: u8) void {
    for (s.stack.items) |v| if (v.ws == n and v.mapped) return focusView(v, true);
    focusView(null, false);
}

pub fn unstack(v: *View) void {
    stackRemove(v);
    if (s.hover == v) s.hover = null;
    if (s.focused == v) {
        s.focused = null;
        if (s.ws[v.ws].output != null) focusTop(v.ws);
    }
}

// ------------------------------------------------------------------ arranging

const Emit = struct {
    pub fn emit(_: Emit, v: *View, b: Box) void {
        if (v.fullscreen) return;
        v.box = b;
        v.configure();
        v.place();
    }
};

const Noop = struct {
    pub fn emit(_: Noop, _: *View, _: Box) void {}
};

pub fn area(o: *Output) Box {
    return o.usable.shrink(cfg.gaps_out);
}

pub fn arrange(n: u8, scroll_to: ?*View) void {
    // workspaces, occupancy and modes all pass through here
    shell.touch();
    const ws = &s.ws[n];
    const o = ws.output orelse return;
    switch (ws.mode) {
        .dwindle => ws.dwindle.arrange(area(o), cfg.gaps_in, Emit{}),
        .scroll => ws.scroll.arrange(area(o), cfg.gaps_in, scroll_to, cfg.scroll_center, Emit{}),
    }
    for (s.views.items) |v| if (v.ws == n and v.floating and !v.fullscreen) v.place();
    if (ws.fullscreen) |v| {
        v.box = o.full;
        v.configure();
        v.place();
    }
    updateIdle();
}

pub fn arrangeAll() void {
    for (s.outputs.items) |o| arrange(o.ws, null);
}

pub fn hideWorkspace(n: u8) void {
    for (s.views.items) |v| if (v.ws == n) v.setEnabled(false);
    updateIdle();
}

/// Puts a tiled view into its workspace layout, next to the workspace's last focused tiled view.
pub fn attach(v: *View) void {
    if (v.floating or v.in_layout) return;
    const ws = &s.ws[v.ws];
    var target: ?*View = null;
    for (s.stack.items) |x| if (x != v and x.ws == v.ws and x.in_layout) {
        target = x;
        break;
    };
    (switch (ws.mode) {
        .dwindle => ws.dwindle.insert(gpa, v, target),
        .scroll => ws.scroll.insert(gpa, v, target, cfg.scroll_width),
    }) catch return log("out of memory", .{});
    v.in_layout = true;
}

pub fn detach(v: *View) void {
    const ws = &s.ws[v.ws];
    if (ws.fullscreen == v) ws.fullscreen = null;
    if (!v.in_layout) return;
    switch (ws.mode) {
        .dwindle => ws.dwindle.remove(gpa, v),
        .scroll => ws.scroll.remove(gpa, v),
    }
    v.in_layout = false;
}

// ------------------------------------------------------------------ workspaces

pub fn showWorkspace(n: u8) void {
    const o = s.mon orelse return;
    if (s.ws[n].output) |other| {
        // already on a monitor: just go there
        s.mon = other;
        if (other != o) focusTop(n);
        return;
    }
    const old = o.ws;
    s.ws[old].output = null;
    hideWorkspace(old);
    o.ws = n;
    s.ws[n].output = o;
    arrange(n, null);
    focusTop(n);
}

pub fn moveToWorkspace(v: *View, n: u8) void {
    if (v.ws == n) return;
    const old = v.ws;
    if (v.fullscreen) setFullscreen(v, false);
    detach(v);
    v.ws = n;
    attach(v);
    if (s.ws[n].output == null) v.setEnabled(false);
    arrange(old, null);
    arrange(n, null);
    if (s.focused == v) {
        s.focused = null;
        v.activate(false);
        focusTop(old);
    }
}

pub fn toggleMode(n: u8) void {
    const ws = &s.ws[n];
    var list: std.ArrayList(*View) = .empty;
    defer list.deinit(gpa);
    (switch (ws.mode) {
        .dwindle => ws.dwindle.collect(gpa, &list),
        .scroll => ws.scroll.collect(gpa, &list),
    }) catch return;
    switch (ws.mode) {
        .dwindle => ws.dwindle.clear(gpa),
        .scroll => ws.scroll.clear(gpa),
    }
    ws.mode = if (ws.mode == .dwindle) .scroll else .dwindle;
    const box = if (ws.output) |o| area(o) else Box{ .w = 1920, .h = 1080 };
    var prev: ?*View = null;
    for (list.items) |v| {
        (switch (ws.mode) {
            .dwindle => ws.dwindle.insert(gpa, v, prev),
            .scroll => ws.scroll.insert(gpa, v, prev, cfg.scroll_width),
        }) catch {
            v.in_layout = false;
            continue;
        };
        // dwindle picks split directions from the boxes, so keep them current while rebuilding
        if (ws.mode == .dwindle) ws.dwindle.arrange(box, cfg.gaps_in, Noop{});
        prev = v;
    }
    arrange(n, s.focused);
}

// ------------------------------------------------------------------ window state

pub fn setFullscreen(v: *View, on_: bool) void {
    if (v.fullscreen == on_) return;
    const ws = &s.ws[v.ws];
    if (on_) {
        if (ws.fullscreen) |other| setFullscreen(other, false);
        ws.fullscreen = v;
    } else if (ws.fullscreen == v) ws.fullscreen = null;
    v.fullscreen = on_;
    _ = c.wlr_xdg_toplevel_set_fullscreen(v.xdg, on_);
    c.wlr_scene_node_reparent(&v.tree.node, if (on_) s.layers.fullscreen else if (v.floating) s.layers.floating else s.layers.tiled);
    v.recolor();
    arrange(v.ws, null);
}

pub fn toggleFloat(v: *View) void {
    if (v.fullscreen) return;
    if (v.floating) {
        v.floating = false;
        c.wlr_scene_node_reparent(&v.tree.node, s.layers.tiled);
        _ = c.wlr_xdg_toplevel_set_tiled(v.xdg, c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM | c.WLR_EDGE_LEFT | c.WLR_EDGE_RIGHT);
        attach(v);
    } else {
        detach(v);
        v.floating = true;
        c.wlr_scene_node_reparent(&v.tree.node, s.layers.floating);
        _ = c.wlr_xdg_toplevel_set_tiled(v.xdg, c.WLR_EDGE_NONE);
        if (s.ws[v.ws].output) |o| {
            const a = area(o);
            v.box.w = @divTrunc(a.w * 2, 3);
            v.box.h = @divTrunc(a.h * 2, 3);
            v.box.x = a.x + @divTrunc(a.w - v.box.w, 2);
            v.box.y = a.y + @divTrunc(a.h - v.box.h, 2);
        }
        v.configure();
    }
    arrange(v.ws, v);
}

// ------------------------------------------------------------------ hit testing

pub const Hit = struct {
    surface: ?*c.struct_wlr_surface = null,
    sx: f64 = 0,
    sy: f64 = 0,
    view: ?*View = null,
    layer: ?*LayerSurf = null,
    lock: bool = false,
};

pub fn hitTest(lx: f64, ly: f64) Hit {
    var h: Hit = .{};
    const node = c.wlr_scene_node_at(&s.scene.*.tree.node, lx, ly, &h.sx, &h.sy) orelse return h;
    if (node.*.type == c.WLR_SCENE_NODE_BUFFER) {
        if (c.wlr_scene_surface_try_from_buffer(c.wlr_scene_buffer_from_node(node))) |ss| h.surface = ss.*.surface;
    }
    var tree: ?*c.struct_wlr_scene_tree = node.*.parent;
    while (tree) |tr| : (tree = tr.node.parent) {
        const d = tr.node.data orelse continue;
        const tag: *Tag = @ptrCast(@alignCast(d));
        switch (tag.*) {
            .view => h.view = @alignCast(@fieldParentPtr("tag", tag)),
            .layer => h.layer = @alignCast(@fieldParentPtr("tag", tag)),
            .lock => h.lock = true,
        }
        break;
    }
    return h;
}

// ------------------------------------------------------------------ actions

fn focusDir(d: L.Dir) void {
    const cur = s.focused orelse return if (s.mon) |o| focusTop(o.ws);
    var views: [64]*View = undefined;
    var boxes: [64]Box = undefined;
    var n: usize = 0;
    for (s.views.items) |v| if (v != cur and v.mapped and v.ws == cur.ws and n < views.len) {
        views[n] = v;
        boxes[n] = v.box;
        n += 1;
    };
    if (L.neighbor(cur.box, d, boxes[0..n])) |i| return focusView(views[i], true);
    // nothing that way on this monitor: try the neighbouring monitor
    const o = s.ws[cur.ws].output orelse return;
    const dir: c_uint = switch (d) {
        .left => c.WLR_DIRECTION_LEFT,
        .right => c.WLR_DIRECTION_RIGHT,
        .up => c.WLR_DIRECTION_UP,
        .down => c.WLR_DIRECTION_DOWN,
    };
    const cx: f64 = @floatFromInt(cur.box.x + @divTrunc(cur.box.w, 2));
    const cy: f64 = @floatFromInt(cur.box.y + @divTrunc(cur.box.h, 2));
    const wo = c.wlr_output_layout_adjacent_output(s.output_layout, dir, o.wlr, cx, cy) orelse return;
    for (s.outputs.items) |x| if (x.wlr == wo) {
        s.mon = x;
        focusTop(x.ws);
    };
}

fn moveDir(v: *View, d: L.Dir) void {
    if (v.floating) {
        const step = 40;
        switch (d) {
            .left => v.box.x -|= step,
            .right => v.box.x +|= step,
            .up => v.box.y -|= step,
            .down => v.box.y +|= step,
        }
        return v.place();
    }
    const ws = &s.ws[v.ws];
    switch (ws.mode) {
        .scroll => ws.scroll.move(v, d),
        .dwindle => {
            var views: [64]*View = undefined;
            var boxes: [64]Box = undefined;
            var n: usize = 0;
            for (s.views.items) |x| if (x != v and x.in_layout and x.ws == v.ws and n < views.len) {
                views[n] = x;
                boxes[n] = x.box;
                n += 1;
            };
            const i = L.neighbor(v.box, d, boxes[0..n]) orelse return;
            ws.dwindle.swap(v, views[i]);
        },
    }
    arrange(v.ws, v);
}

pub fn swapTiled(a: *View, b: *View) void {
    if (a.ws != b.ws or !a.in_layout or !b.in_layout) return;
    const ws = &s.ws[a.ws];
    switch (ws.mode) {
        .dwindle => ws.dwindle.swap(a, b),
        .scroll => {
            const pa = ws.scroll.find(a) orelse return;
            const pb = ws.scroll.find(b) orelse return;
            ws.scroll.cols.items[pa.col].wins.items[pa.row] = b;
            ws.scroll.cols.items[pb.col].wins.items[pb.row] = a;
        },
    }
    arrange(a.ws, null);
}

/// grow=true: keyboard (positive = bigger); false: mouse drag (delta moves the edge).
pub fn resizeView(v: *View, dx: i32, dy: i32, grow: bool) void {
    if (v.fullscreen) return;
    if (v.floating) {
        v.box.w = std.math.clamp(v.box.w +| dx, 60, L.LIMIT);
        v.box.h = std.math.clamp(v.box.h +| dy, 40, L.LIMIT);
        v.configure();
        return v.place();
    }
    const ws = &s.ws[v.ws];
    const o = ws.output orelse return;
    switch (ws.mode) {
        .dwindle => ws.dwindle.resize(v, dx, dy, grow),
        .scroll => ws.scroll.resize(v, dx, area(o).w),
    }
    arrange(v.ws, if (grow) v else null);
}

pub fn toggleTheme() void {
    s.theme = if (s.theme == .dark) .light else .dark;
    shell.touch();
    for (s.views.items) |v| v.recolor();
    for (s.outputs.items) |o| c.wlr_scene_rect_set_color(o.bg, &palette().background);
    themeHooks();
}

/// Tells GTK/Qt/portals about the theme (gsettings by default).
pub fn themeHooks() void {
    if (s.theme == .dark) {
        inline for (cfg.theme_hooks_dark) |h| launcher.spawn(h, false);
    } else inline for (cfg.theme_hooks_light) |h| launcher.spawn(h, false);
}

/// A key binding; comptime, so a spawn is just an index into the launcher's command table.
pub fn run(comptime a: T.Action) void {
    const f = s.focused;
    switch (a) {
        .spawn => |cmd| launcher.spawn(cmd, true),
        .quit => c.wl_display_terminate(s.display),
        .lock => launcher.spawn(cfg.lock_command, false),
        .toggle_theme => toggleTheme(),
        .bar => |m| shell.open(m),
        .workspace => |n| if (n >= 1 and n <= WS) showWorkspace(n - 1),
        .toggle_mode => if (s.mon) |o| toggleMode(o.ws),
        .focus => |d| focusDir(d),
        .close => if (f) |v| c.wlr_xdg_toplevel_send_close(v.xdg),
        .move => |d| if (f) |v| moveDir(v, d),
        .resize => |r| if (f) |v| resizeView(v, r[0], r[1], true),
        .toggle_float => if (f) |v| toggleFloat(v),
        .fullscreen => if (f) |v| setFullscreen(v, !v.fullscreen),
        .toggle_split => if (f) |v| if (s.ws[v.ws].mode == .dwindle) {
            s.ws[v.ws].dwindle.toggleSplit(v);
            arrange(v.ws, null);
        },
        .move_to_workspace => |n| if (f) |v| if (n >= 1 and n <= WS) moveToWorkspace(v, n - 1),
        .cycle_width => if (f) |v| if (s.ws[v.ws].mode == .scroll) {
            s.ws[v.ws].scroll.cycleWidth(v, &cfg.scroll_widths);
            arrange(v.ws, v);
        },
        .column_merge => |d| if (f) |v| if (s.ws[v.ws].mode == .scroll) {
            s.ws[v.ws].scroll.merge(gpa, v, d) catch {};
            arrange(v.ws, v);
        },
        .column_expel => if (f) |v| if (s.ws[v.ws].mode == .scroll) {
            s.ws[v.ws].scroll.expel(gpa, v) catch {};
            arrange(v.ws, v);
        },
    }
}
