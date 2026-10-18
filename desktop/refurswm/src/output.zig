// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! Monitors, layer-shell surfaces (bars, launchers, wallpapers) and ext-session-lock.
//! A monitor draws only when wlr_scene has damage for it: no damage, no frame, no GPU work.
const std = @import("std");
const wm = @import("wm.zig");
const c = wm.c;
const cfg = wm.cfg;
const Box = wm.Box;
const Listener = wm.Listener;
const client = @import("client.zig");
const shell = @import("shell.zig");
const s = &wm.s;
const zero = std.mem.zeroes(Listener);

pub const Output = struct {
    wlr: *c.struct_wlr_output,
    so: *c.struct_wlr_scene_output,
    bg: *c.struct_wlr_scene_rect,
    lock_bg: *c.struct_wlr_scene_rect,
    ws: u8,
    full: Box = .{},
    usable: Box = .{},
    lock_surf: ?*LockSurf = null,
    /// waiting for a presented frame that shows the lock cover (see onNewLock)
    lock_wait: bool = false,
    lock_seq: u32 = 0,
    l_frame: Listener = zero,
    l_request_state: Listener = zero,
    l_destroy: Listener = zero,
    l_present: Listener = zero,

    fn onFrame(o: *Output, _: ?*anyopaque) void {
        if (c.wlr_scene_output_needs_frame(o.so)) o.commit();
        var now: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);
        c.wlr_scene_output_send_frame_done(o.so, &now);
    }

    /// wlr_scene_output_commit, plus tearing: a fullscreen window that asked for async presentation
    /// (games with vsync off) gets immediate page flips; if the driver refuses, vsync as usual.
    fn commit(o: *Output) void {
        var st: c.struct_wlr_output_state = undefined;
        c.wlr_output_state_init(&st);
        defer c.wlr_output_state_finish(&st);
        if (!c.wlr_scene_output_build_state(o.so, &st, null)) return;
        if (cfg.allow_tearing and o.wantsTearing()) {
            st.tearing_page_flip = true;
            if (!c.wlr_output_test_state(o.wlr, &st)) st.tearing_page_flip = false;
        }
        _ = c.wlr_output_commit_state(o.wlr, &st);
    }

    fn wantsTearing(o: *Output) bool {
        const v = s.ws[o.ws].fullscreen orelse return false;
        return c.wlr_tearing_control_manager_v1_surface_hint_from_surface(s.tearing, v.surface()) ==
            c.WP_TEARING_CONTROL_V1_PRESENTATION_HINT_ASYNC;
    }

    fn onRequestState(o: *Output, data: ?*anyopaque) void {
        const ev = wm.ptr(c.struct_wlr_output_event_request_state, data);
        _ = c.wlr_output_commit_state(o.wlr, ev.state);
        updateGeometry(o);
    }

    fn onDestroy(o: *Output, _: ?*anyopaque) void {
        wm.off(&o.l_frame);
        wm.off(&o.l_request_state);
        wm.off(&o.l_destroy);
        shell.outputGone(o.wlr);
        if (o.lock_surf) |l| l.output = null;
        if (o.lock_wait) o.stopLockWait();
        // layer surfaces die with their monitor (their destroy handlers unlink them)
        var i: usize = s.layer_surfaces.items.len;
        while (i > 0) {
            i -= 1;
            const l = s.layer_surfaces.items[i];
            if (l.output == o) c.wlr_layer_surface_v1_destroy(l.ls);
        }
        if (std.mem.indexOfScalar(*Output, s.outputs.items, o)) |j| _ = s.outputs.orderedRemove(j);
        s.ws[o.ws].output = null;
        wm.hideWorkspace(o.ws);
        if (s.mon == o) s.mon = if (s.outputs.items.len > 0) s.outputs.items[0] else null;
        c.wlr_scene_node_destroy(&o.bg.node);
        c.wlr_scene_node_destroy(&o.lock_bg.node);
        wm.gpa.destroy(o);
        if (s.focused) |v| if (s.ws[v.ws].output == null) wm.focusView(null, false);
        lockShown();
    }

    /// The next commit of this output shows the lock cover; `locked` waits until it is presented.
    fn startLockWait(o: *Output) void {
        if (!o.wlr.enabled or o.lock_wait) return;
        o.lock_wait = true;
        o.lock_seq = o.wlr.commit_seq +% 1;
        wm.on(&o.wlr.events.present, &o.l_present, wm.cb(Output, "l_present", Output.onPresent));
        c.wlr_output_schedule_frame(o.wlr);
    }

    fn stopLockWait(o: *Output) void {
        o.lock_wait = false;
        wm.off(&o.l_present);
    }

    fn onPresent(o: *Output, data: ?*anyopaque) void {
        const ev = wm.ptr(c.struct_wlr_output_event_present, data);
        // a frame committed before the lock is no proof
        if (ev.commit_seq -% o.lock_seq >= 1 << 31) return;
        // dropped (VT switch, failed flip): damage the cover again for one more frame
        if (!ev.presented) return redamageLock();
        o.stopLockWait();
        lockShown();
    }
};

fn findCfg(name: []const u8) ?wm.T.OutputCfg {
    for (cfg.outputs) |oc| if (std.mem.eql(u8, oc.name, name)) return oc;
    return null;
}

/// Exact mode from the config, highest refresh when the rate is not given.
fn pickMode(wo: *c.struct_wlr_output, oc: wm.T.OutputCfg) ?*c.struct_wlr_output_mode {
    var best: ?*c.struct_wlr_output_mode = null;
    const head = &wo.modes;
    var link = head.next;
    while (link != head) : (link = link.*.next) {
        const m: *c.struct_wlr_output_mode = @fieldParentPtr("link", @as(*c.struct_wl_list, @ptrCast(link)));
        if (m.width != oc.width or m.height != oc.height) continue;
        if (oc.refresh > 0 and @abs(m.refresh - oc.refresh) > 500) continue;
        if (best == null or m.refresh > best.?.refresh) best = m;
    }
    return best;
}

pub fn onNewOutput(data: ?*anyopaque) void {
    const wo = wm.ptr(c.struct_wlr_output, data);
    if (!c.wlr_output_init_render(wo, s.allocator, s.renderer)) return wm.log("output {s}: cannot init renderer", .{wo.name});
    const name = std.mem.span(wo.name);
    const oc = findCfg(name);

    // the config as given; then without VRR (not every monitor has it); then the preferred mode
    const attempts: u8 = if (oc == null) 1 else 3;
    for (0..attempts) |attempt| {
        var st: c.struct_wlr_output_state = undefined;
        c.wlr_output_state_init(&st);
        defer c.wlr_output_state_finish(&st);
        c.wlr_output_state_set_enabled(&st, true);
        if (oc != null and attempt < 2) {
            const x = oc.?;
            if (x.width > 0) {
                if (pickMode(wo, x)) |m| c.wlr_output_state_set_mode(&st, m) else c.wlr_output_state_set_custom_mode(&st, x.width, x.height, x.refresh);
            } else if (c.wlr_output_preferred_mode(wo)) |m| c.wlr_output_state_set_mode(&st, m);
            c.wlr_output_state_set_scale(&st, x.scale);
            if (x.vrr and attempt == 0) c.wlr_output_state_set_adaptive_sync_enabled(&st, true);
        } else if (c.wlr_output_preferred_mode(wo)) |m| c.wlr_output_state_set_mode(&st, m);
        if (c.wlr_output_commit_state(wo, &st)) break;
        wm.log("output {s}: configuration {d} failed", .{ std.mem.span(wo.name), attempt + 1 });
    }

    var ws: u8 = 0;
    while (ws < wm.WS and s.ws[ws].output != null) ws += 1;
    if (ws == wm.WS) return wm.log("output {s}: no free workspace", .{name});

    const lo = if (oc != null and oc.?.x != null)
        c.wlr_output_layout_add(s.output_layout, wo, oc.?.x.?, oc.?.y orelse 0)
    else
        c.wlr_output_layout_add_auto(s.output_layout, wo);
    const so = c.wlr_scene_output_create(s.scene, wo) orelse return;
    c.wlr_scene_output_layout_add_output(s.scene_layout, lo, so);

    const black = [4]f32{ 0, 0, 0, 1 };
    const bg = c.wlr_scene_rect_create(s.layers.color, 0, 0, &wm.palette().background) orelse return;
    const lock_bg = c.wlr_scene_rect_create(s.layers.lock_bg, 0, 0, &black) orelse return;
    const o = wm.gpa.create(Output) catch return;
    o.* = .{ .wlr = wo, .so = so, .bg = bg, .lock_bg = lock_bg, .ws = ws };
    s.outputs.append(wm.gpa, o) catch {};
    s.ws[ws].output = o;
    if (s.mon == null) s.mon = o;

    wm.on(&wo.events.frame, &o.l_frame, wm.cb(Output, "l_frame", Output.onFrame));
    wm.on(&wo.events.request_state, &o.l_request_state, wm.cb(Output, "l_request_state", Output.onRequestState));
    wm.on(&wo.events.destroy, &o.l_destroy, wm.cb(Output, "l_destroy", Output.onDestroy));
    updateGeometry(o);
    shell.touch();
    if (s.lock_pending) o.startLockWait();
    wm.log("output {s}: {d}x{d} workspace {d}", .{ name, o.full.w, o.full.h, ws + 1 });
}

pub fn updateGeometry(o: *Output) void {
    var b: c.struct_wlr_box = undefined;
    c.wlr_output_layout_get_box(s.output_layout, o.wlr, &b);
    o.full = .{ .x = b.x, .y = b.y, .w = b.width, .h = b.height };
    for ([_]*c.struct_wlr_scene_rect{ o.bg, o.lock_bg }) |r| {
        c.wlr_scene_node_set_position(&r.node, b.x, b.y);
        c.wlr_scene_rect_set_size(r, b.width, b.height);
    }
    if (o.lock_surf) |l| l.place();
    arrangeLayers(o);
}

pub fn onLayoutChange(_: ?*anyopaque) void {
    for (s.outputs.items) |o| updateGeometry(o);
}

pub fn outputOf(wo: ?*c.struct_wlr_output) ?*Output {
    for (s.outputs.items) |o| if (o.wlr == wo) return o;
    return null;
}

// ------------------------------------------------------------------ layer shell

pub const LayerSurf = struct {
    tag: wm.Tag = .layer,
    ls: *c.struct_wlr_layer_surface_v1,
    scene: *c.struct_wlr_scene_layer_surface_v1,
    output: *Output,
    owner: *client.State,
    layer: c_uint,
    mapped: bool = false,
    l_map: Listener = zero,
    l_unmap: Listener = zero,
    l_commit: Listener = zero,
    l_destroy: Listener = zero,

    pub fn interactive(l: *LayerSurf) bool {
        return l.ls.current.keyboard_interactive != c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE;
    }

    fn onCommit(l: *LayerSurf, _: ?*anyopaque) void {
        if (!l.ls.initialized) return;
        const committed = l.ls.current.committed;
        if (l.ls.current.layer != l.layer) {
            l.layer = l.ls.current.layer;
            c.wlr_scene_node_reparent(&l.scene.tree.*.node, layerTree(l.layer));
        }
        if (l.ls.initial_commit or committed != 0) arrangeLayers(l.output);
    }

    fn onMap(l: *LayerSurf, _: ?*anyopaque) void {
        l.mapped = true;
        arrangeLayers(l.output);
        if (l.interactive() and l.layer >= c.ZWLR_LAYER_SHELL_V1_LAYER_TOP and !s.locked) focusLayer(l);
        wm.updateIdle();
    }

    fn onUnmap(l: *LayerSurf, _: ?*anyopaque) void {
        l.mapped = false;
        if (s.layer_focus == l) unfocusLayer();
        arrangeLayers(l.output);
        wm.updateIdle();
    }

    fn onDestroy(l: *LayerSurf, _: ?*anyopaque) void {
        if (s.layer_focus == l) unfocusLayer();
        for ([_]*Listener{ &l.l_map, &l.l_unmap, &l.l_commit, &l.l_destroy }) |x| wm.off(x);
        if (std.mem.indexOfScalar(*LayerSurf, s.layer_surfaces.items, l)) |i| _ = s.layer_surfaces.orderedRemove(i);
        const o = l.output;
        client.give(l.owner, .layers);
        wm.gpa.destroy(l);
        arrangeLayers(o);
    }
};

fn layerTree(layer: c_uint) *c.struct_wlr_scene_tree {
    return switch (layer) {
        c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND => s.layers.background,
        c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM => s.layers.bottom,
        c.ZWLR_LAYER_SHELL_V1_LAYER_TOP => s.layers.top,
        else => s.layers.overlay,
    };
}

pub fn focusLayer(l: *LayerSurf) void {
    s.layer_focus = l;
    wm.keyboardEnter(l.ls.surface);
}

pub fn unfocusLayer() void {
    s.layer_focus = null;
    if (s.locked) return;
    if (s.focused) |v| wm.keyboardEnter(v.surface()) else c.wlr_seat_keyboard_clear_focus(s.seat);
}

pub fn onNewLayerSurface(data: ?*anyopaque) void {
    const ls = wm.ptr(c.struct_wlr_layer_surface_v1, data);
    if (ls.output == null) {
        const m = s.mon orelse return c.wlr_layer_surface_v1_destroy(ls);
        ls.output = m.wlr;
    }
    const o = outputOf(ls.output) orelse return c.wlr_layer_surface_v1_destroy(ls);
    const owner = client.take(client.of(ls.resource), .layers) orelse return;
    const layer = ls.pending.layer;
    const l = wm.gpa.create(LayerSurf) catch {
        client.give(owner, .layers);
        return c.wlr_layer_surface_v1_destroy(ls);
    };
    const scene = c.wlr_scene_layer_surface_v1_create(layerTree(layer), ls) orelse {
        wm.gpa.destroy(l);
        client.give(owner, .layers);
        return c.wlr_layer_surface_v1_destroy(ls);
    };
    l.* = .{ .ls = ls, .scene = scene, .output = o, .owner = owner, .layer = layer };
    scene.*.tree.*.node.data = &l.tag;
    ls.data = scene.*.tree;
    s.layer_surfaces.append(wm.gpa, l) catch {};
    const sf = ls.surface;
    wm.on(&sf.*.events.map, &l.l_map, wm.cb(LayerSurf, "l_map", LayerSurf.onMap));
    wm.on(&sf.*.events.unmap, &l.l_unmap, wm.cb(LayerSurf, "l_unmap", LayerSurf.onUnmap));
    wm.on(&sf.*.events.commit, &l.l_commit, wm.cb(LayerSurf, "l_commit", LayerSurf.onCommit));
    wm.on(&ls.events.destroy, &l.l_destroy, wm.cb(LayerSurf, "l_destroy", LayerSurf.onDestroy));
}

/// Exclusive zones first (bars shrink the usable area), then everything else; then re-tile.
pub fn arrangeLayers(o: *Output) void {
    const full = wm.wbox(o.full);
    var usable = full;
    const order = [_]c_uint{
        c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
        c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
        c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
    };
    for ([_]bool{ true, false }) |exclusive| for (order) |layer| for (s.layer_surfaces.items) |l| {
        if (l.output != o or l.layer != layer or !l.ls.initialized) continue;
        if ((l.ls.current.exclusive_zone > 0) != exclusive) continue;
        c.wlr_scene_layer_surface_v1_configure(l.scene, &full, &usable);
    };
    // wlroots derives the usable area from client-set margins and exclusive zones: keep it on the output
    var nu = wm.L.intersect(.{ .x = usable.x, .y = usable.y, .w = usable.width, .h = usable.height }, o.full);
    if (nu.empty()) nu = o.full;
    if (!std.meta.eql(nu, o.usable)) {
        o.usable = nu;
        wm.arrange(o.ws, null);
    }
}

// ------------------------------------------------------------------ session lock

const LockSurf = struct {
    tag: wm.Tag = .lock,
    ls: *c.struct_wlr_session_lock_surface_v1,
    tree: *c.struct_wlr_scene_tree,
    output: ?*Output,
    l_map: Listener = zero,
    l_destroy: Listener = zero,

    /// Covers its output; again whenever the output's geometry changes.
    fn place(l: *LockSurf) void {
        const o = l.output orelse return;
        c.wlr_scene_node_set_position(&l.tree.node, o.full.x, o.full.y);
        _ = c.wlr_session_lock_surface_v1_configure(l.ls, @intCast(@max(1, o.full.w)), @intCast(@max(1, o.full.h)));
    }

    fn onMap(l: *LockSurf, _: ?*anyopaque) void {
        if (s.lock != null) wm.keyboardEnter(l.ls.surface);
    }

    fn onDestroy(l: *LockSurf, _: ?*anyopaque) void {
        wm.off(&l.l_map);
        wm.off(&l.l_destroy);
        if (l.output) |o| if (o.lock_surf == l) {
            o.lock_surf = null;
        };
        wm.gpa.destroy(l);
    }
};

var l_lock_surface: Listener = zero;
var l_unlock: Listener = zero;
var l_lock_destroy: Listener = zero;

fn setLockBg(on: bool) void {
    c.wlr_scene_node_set_enabled(&s.layers.lock_bg.*.node, on);
}

/// Locking covers every monitor with an opaque rect above all windows; input then reaches only lock
/// surfaces. The locker is told "locked" only once every enabled monitor has presented a frame with
/// that cover (ext-session-lock): suspend right after it can never resume onto the open desktop.
pub fn onNewLock(data: ?*anyopaque) void {
    const lock = wm.ptr(c.struct_wlr_session_lock_v1, data);
    if (s.lock != null) return c.wlr_session_lock_v1_destroy(lock);
    s.lock = lock;
    s.locked = true;
    setLockBg(true);
    s.layer_focus = null;
    c.wlr_seat_keyboard_clear_focus(s.seat);
    c.wlr_seat_pointer_clear_focus(s.seat);
    wm.on(&lock.events.new_surface, &l_lock_surface, wm.gcb(onLockSurface));
    wm.on(&lock.events.unlock, &l_unlock, wm.gcb(onUnlock));
    wm.on(&lock.events.destroy, &l_lock_destroy, wm.gcb(onLockDestroy));
    s.lock_pending = true;
    for (s.outputs.items) |o| o.startLockWait();
    lockShown();
    wm.updateIdle();
}

/// Sends `locked` when no output is still waiting for its cover frame.
fn lockShown() void {
    if (!s.lock_pending) return;
    for (s.outputs.items) |o| if (o.lock_wait) return;
    s.lock_pending = false;
    const lock = s.lock orelse return;
    c.wlr_session_lock_v1_send_locked(lock);
    wm.log("session locked: every output shows the lock cover", .{});
}

/// Re-enabling the cover damages every output, so each one renders it once more.
fn redamageLock() void {
    c.wlr_scene_node_set_enabled(&s.layers.lock_bg.*.node, false);
    c.wlr_scene_node_set_enabled(&s.layers.lock_bg.*.node, true);
}

fn onLockSurface(data: ?*anyopaque) void {
    const ls = wm.ptr(c.struct_wlr_session_lock_surface_v1, data);
    const o = outputOf(ls.output) orelse return;
    const tree = c.wlr_scene_subsurface_tree_create(s.layers.lock, ls.surface) orelse return;
    const l = wm.gpa.create(LockSurf) catch return c.wlr_scene_node_destroy(&tree.*.node);
    l.* = .{ .ls = ls, .tree = tree, .output = o };
    tree.*.node.data = &l.tag;
    o.lock_surf = l;
    l.place();
    wm.on(&ls.surface.*.events.map, &l.l_map, wm.cb(LockSurf, "l_map", LockSurf.onMap));
    wm.on(&ls.events.destroy, &l.l_destroy, wm.cb(LockSurf, "l_destroy", LockSurf.onDestroy));
}

fn dropLock() void {
    wm.off(&l_lock_surface);
    wm.off(&l_unlock);
    wm.off(&l_lock_destroy);
    s.lock = null;
    s.lock_pending = false;
    for (s.outputs.items) |o| if (o.lock_wait) o.stopLockWait();
}

fn onUnlock(_: ?*anyopaque) void {
    dropLock();
    s.locked = false;
    setLockBg(false);
    if (s.focused) |v| wm.keyboardEnter(v.surface()) else if (s.mon) |o| wm.focusTop(o.ws);
    wm.updateIdle();
}

/// The locker died without unlocking: stay locked (screen stays blank); a new locker may take over.
fn onLockDestroy(_: ?*anyopaque) void {
    dropLock();
}

pub fn shutdown() void {
    dropLock();
}
