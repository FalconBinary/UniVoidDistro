// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! xdg-shell toplevels and popups.
//! A view's scene tree sits at the window-geometry origin: borders are four plain rects around it,
//! the client surfaces are a subsurface tree clipped to the slot, and popups hang off the same tree
//! so they are never clipped and move with the window.
const std = @import("std");
const wm = @import("wm.zig");
const c = wm.c;
const cfg = wm.cfg;
const L = wm.L;
const Box = wm.Box;
const Listener = wm.Listener;
const client = @import("client.zig");
const policy = @import("policy.zig");
const launcher = @import("launcher.zig");
const shell = @import("shell.zig");
const s = &wm.s;
const zero = std.mem.zeroes(Listener);

pub const View = struct {
    tag: wm.Tag = .view,
    xdg: *c.struct_wlr_xdg_toplevel,
    tree: *c.struct_wlr_scene_tree,
    content: *c.struct_wlr_scene_tree = undefined,
    rects: [4]*c.struct_wlr_scene_rect = undefined,
    deco: ?*c.struct_wlr_xdg_toplevel_decoration_v1 = null,
    owner: *client.State,

    ws: u8 = 0,
    mapped: bool = false,
    floating: bool = false,
    fullscreen: bool = false,
    in_layout: bool = false,
    active: bool = false,
    ruled: bool = false,
    enabled: bool = false,
    /// outer box (border included), layout coordinates
    box: Box = .{},
    sent_w: i32 = 0,
    sent_h: i32 = 0,
    last_geo: Box = .{},

    l_map: Listener = zero,
    l_unmap: Listener = zero,
    l_commit: Listener = zero,
    l_destroy: Listener = zero,
    l_move: Listener = zero,
    l_resize: Listener = zero,
    l_fullscreen: Listener = zero,
    l_maximize: Listener = zero,
    l_deco_mode: Listener = zero,
    l_deco_destroy: Listener = zero,
    l_title: Listener = zero,
    l_app_id: Listener = zero,

    pub fn surface(v: *View) *c.struct_wlr_surface {
        return v.xdg.base.*.surface;
    }

    /// The window geometry the client set, clamped: a client may send any i32 (see Box.sanitize).
    fn geometry(v: *View) Box {
        const g = v.xdg.base.*.geometry;
        return (Box{ .x = g.x, .y = g.y, .w = g.width, .h = g.height }).sanitize();
    }

    pub fn setEnabled(v: *View, on: bool) void {
        if (v.enabled == on) return;
        v.enabled = on;
        c.wlr_scene_node_set_enabled(&v.tree.node, on);
    }

    /// Sends the slot size (inside the border) if it changed: no redundant configures.
    pub fn configure(v: *View) void {
        const bw: i32 = if (v.fullscreen) 0 else cfg.border;
        const w = @max(1, v.box.w - 2 * bw);
        const h = @max(1, v.box.h - 2 * bw);
        if (w == v.sent_w and h == v.sent_h) return;
        v.sent_w = w;
        v.sent_h = h;
        _ = c.wlr_xdg_toplevel_set_size(v.xdg, w, h);
    }

    pub fn place(v: *View) void {
        const o = s.ws[v.ws].output orelse return v.setEnabled(false);
        if (!v.mapped) return v.setEnabled(false);
        const bw: i32 = if (v.fullscreen) 0 else cfg.border;
        const inner = v.box.shrink(bw);
        // scroll mode puts columns off-screen; clip them to their monitor so they never spill over
        const bound = if (v.floating) v.box else o.full;
        const vis = L.intersect(v.box, bound);
        if (vis.empty()) return v.setEnabled(false);
        v.setEnabled(true);

        c.wlr_scene_node_set_position(&v.tree.node, inner.x, inner.y);
        const g = v.geometry();
        v.last_geo = g;
        c.wlr_scene_node_set_position(&v.content.node, -g.x, -g.y);
        const cv = L.intersect(inner, bound);
        c.wlr_scene_node_set_enabled(&v.content.node, !cv.empty());
        if (!cv.empty()) {
            var clip: c.struct_wlr_box = .{ .x = g.x +| (cv.x -| inner.x), .y = g.y +| (cv.y -| inner.y), .width = cv.w, .height = cv.h };
            c.wlr_scene_subsurface_tree_set_clip(&v.content.node, &clip);
        }
        v.placeBorder(inner, bw, bound);
    }

    fn placeBorder(v: *View, inner: Box, bw: i32, bound: Box) void {
        const pieces = [4]Box{
            .{ .x = inner.x - bw, .y = inner.y - bw, .w = inner.w + 2 * bw, .h = bw },
            .{ .x = inner.x - bw, .y = inner.y + inner.h, .w = inner.w + 2 * bw, .h = bw },
            .{ .x = inner.x - bw, .y = inner.y, .w = bw, .h = inner.h },
            .{ .x = inner.x + inner.w, .y = inner.y, .w = bw, .h = inner.h },
        };
        for (v.rects, pieces) |r, p| {
            const q = L.intersect(p, bound);
            if (q.empty()) {
                c.wlr_scene_rect_set_size(r, 0, 0);
                continue;
            }
            c.wlr_scene_node_set_position(&r.node, q.x - inner.x, q.y - inner.y);
            c.wlr_scene_rect_set_size(r, q.w, q.h);
        }
    }

    pub fn recolor(v: *View) void {
        const p = wm.palette();
        const col = if (v.active) p.active else p.inactive;
        for (v.rects) |r| c.wlr_scene_rect_set_color(r, &col);
    }

    /// Only real changes reach the client: every set_activated is a configure, and most clients
    /// redraw on each configure.
    pub fn activate(v: *View, on: bool) void {
        if (v.active == on) return;
        v.active = on;
        _ = c.wlr_xdg_toplevel_set_activated(v.xdg, on);
        v.recolor();
    }

    // ------------------------------------------------------------ lifecycle

    fn applyRules(v: *View) void {
        v.ruled = true;
        const app_id: []const u8 = if (v.xdg.app_id) |a| std.mem.span(a) else "";
        const title: []const u8 = if (v.xdg.title) |t| std.mem.span(t) else "";
        // dialogs and fixed-size windows float
        const cur = v.xdg.current;
        if (v.xdg.parent != null or (cur.min_width > 0 and cur.min_width == cur.max_width and cur.min_height == cur.max_height))
            v.floating = true;
        inline for (cfg.rules) |r| {
            if (policy.ruleMatches(r, app_id, title)) {
                if (r.float) |f| v.floating = f;
                if (r.workspace) |n| if (n >= 1 and n <= wm.WS) {
                    v.ws = n - 1;
                };
            }
        }
        if (v.floating) c.wlr_scene_node_reparent(&v.tree.node, s.layers.floating);
    }

    /// First commit, before the client has drawn anything. Tiled windows are inserted into the
    /// layout right here, so their very first buffer already has the final size: no resize flash
    /// and one buffer allocation less per window.
    fn initialCommit(v: *View) void {
        if (!v.ruled) v.applyRules();
        if (v.deco) |d| _ = c.wlr_xdg_toplevel_decoration_v1_set_mode(d, c.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
        _ = c.wlr_xdg_toplevel_set_wm_capabilities(v.xdg, c.WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN);
        // an unmapped toplevel is back in its initial state (xdg-shell): nothing was sent yet
        v.sent_w = 0;
        v.sent_h = 0;
        v.active = false;
        if (v.floating) {
            _ = c.wlr_xdg_toplevel_set_size(v.xdg, 0, 0);
        } else {
            _ = c.wlr_xdg_toplevel_set_tiled(v.xdg, c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM | c.WLR_EDGE_LEFT | c.WLR_EDGE_RIGHT);
            wm.attach(v);
            wm.arrange(v.ws, null);
        }
        // the initial commit must always be answered; repeated schedules coalesce
        _ = c.wlr_xdg_surface_schedule_configure(v.xdg.base);
    }

    fn onCommit(v: *View, _: ?*anyopaque) void {
        if (v.xdg.base.*.initial_commit) return v.initialCommit();
        if (!v.mapped) return;
        const g = v.geometry();
        if (!std.meta.eql(g, v.last_geo)) {
            if (v.floating and !v.fullscreen) {
                v.box.w = g.w + 2 * cfg.border;
                v.box.h = g.h + 2 * cfg.border;
            }
            v.place();
        }
    }

    fn onMap(v: *View, _: ?*anyopaque) void {
        v.mapped = true;
        if (v.floating) {
            const g = v.geometry();
            v.box.w = g.w + 2 * cfg.border;
            v.box.h = g.h + 2 * cfg.border;
            // centre over the parent window, else on the monitor
            var around: Box = if (s.ws[v.ws].output) |o| wm.area(o) else .{ .w = v.box.w, .h = v.box.h };
            if (v.xdg.parent) |p| if (viewOfToplevel(p)) |pv| if (pv.mapped) {
                around = pv.box;
            };
            v.box.x = around.x + @divTrunc(around.w - v.box.w, 2);
            v.box.y = around.y + @divTrunc(around.h - v.box.h, 2);
        }
        s.views.append(wm.gpa, v) catch {};
        v.recolor();
        if (v.xdg.requested.fullscreen and v.mayFullscreen()) wm.setFullscreen(v, true);
        wm.arrange(v.ws, null);
        v.place();
        if (s.ws[v.ws].output != null and v.mayFocusOnMap()) wm.focusView(v, true);
    }

    /// A sandboxed app may not take the keyboard just by opening a window: it could pose as another
    /// app and read what the user types. It gets the focus through activation with a token (apps
    /// RefursWM starts get one), from the user, or for a dialog while its own window has the focus.
    fn mayFocusOnMap(v: *View) bool {
        const cl = client.of(v.xdg.resource);
        if (!client.sandboxed(cl)) return true;
        const f = s.focused orelse return false;
        return client.of(f.xdg.resource) == cl;
    }

    fn onUnmap(v: *View, _: ?*anyopaque) void {
        v.mapped = false;
        @import("input.zig").forget(v);
        if (std.mem.indexOfScalar(*View, s.views.items, v)) |i| _ = s.views.orderedRemove(i);
        wm.detach(v);
        v.setEnabled(false);
        wm.unstack(v);
        wm.arrange(v.ws, null);
    }

    fn onDestroy(v: *View, _: ?*anyopaque) void {
        if (v.mapped) v.onUnmap(null);
        wm.detach(v);
        wm.unstack(v);
        for ([_]*Listener{ &v.l_map, &v.l_unmap, &v.l_commit, &v.l_destroy, &v.l_move, &v.l_resize, &v.l_fullscreen, &v.l_maximize, &v.l_deco_mode, &v.l_deco_destroy, &v.l_title, &v.l_app_id }) |l| wm.off(l);
        c.wlr_scene_node_destroy(&v.tree.node);
        client.give(v.owner, .views);
        wm.gpa.destroy(v);
    }

    fn onMove(v: *View, _: ?*anyopaque) void {
        if (v.floating and v.mapped) @import("input.zig").beginGrab(v, .move, 0);
    }

    fn onResize(v: *View, data: ?*anyopaque) void {
        const ev = wm.ptr(c.struct_wlr_xdg_toplevel_resize_event, data);
        if (v.floating and v.mapped) @import("input.zig").beginGrab(v, .resize, ev.edges);
    }

    fn onFullscreen(v: *View, _: ?*anyopaque) void {
        if (!v.xdg.base.*.initialized) return;
        // a sandbox asking for fullscreen gets a configure with its current state: the request is
        // answered (xdg-shell wants that), but nothing changes. Leaving fullscreen (Esc in a video
        // the user made fullscreen with the bind) is always allowed.
        const want = v.xdg.requested.fullscreen;
        if (v.mapped and (!want or v.mayFullscreen())) wm.setFullscreen(v, want) else _ = c.wlr_xdg_surface_schedule_configure(v.xdg.base);
    }

    fn mayFullscreen(v: *View) bool {
        return policy.mayRequestFullscreen(client.sandboxed(client.of(v.xdg.resource)));
    }

    fn onMaximize(v: *View, _: ?*anyopaque) void {
        // tiling decides sizes; still answer so the client is not left waiting
        if (v.xdg.base.*.initialized) _ = c.wlr_xdg_surface_schedule_configure(v.xdg.base);
    }

    /// The bar shows the focused window's title: other windows may retitle themselves for free.
    fn onTitle(v: *View, _: ?*anyopaque) void {
        if (s.focused == v) shell.touch();
    }

    fn onDecoMode(v: *View, _: ?*anyopaque) void {
        if (v.deco) |d| if (v.xdg.base.*.initialized) {
            _ = c.wlr_xdg_toplevel_decoration_v1_set_mode(d, c.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
        };
    }

    fn onDecoDestroy(v: *View, _: ?*anyopaque) void {
        v.deco = null;
        wm.off(&v.l_deco_mode);
        wm.off(&v.l_deco_destroy);
    }
};

pub fn onNewToplevel(data: ?*anyopaque) void {
    const xdg = wm.ptr(c.struct_wlr_xdg_toplevel, data);
    const owner = client.take(client.of(xdg.resource), .views) orelse return;
    newView(xdg, owner) catch client.give(owner, .views);
}

fn newView(xdg: *c.struct_wlr_xdg_toplevel, owner: *client.State) !void {
    const tree = c.wlr_scene_tree_create(s.layers.tiled) orelse return error.OutOfMemory;
    errdefer c.wlr_scene_node_destroy(&tree.*.node);
    const v = try wm.gpa.create(View);
    errdefer wm.gpa.destroy(v);
    v.* = .{ .xdg = xdg, .tree = tree, .owner = owner, .ws = if (s.mon) |o| o.ws else 0 };
    const black = [4]f32{ 0, 0, 0, 1 };
    for (&v.rects) |*r| r.* = c.wlr_scene_rect_create(tree, 0, 0, &black) orelse return error.OutOfMemory;
    v.content = c.wlr_scene_subsurface_tree_create(tree, xdg.base.*.surface) orelse return error.OutOfMemory;
    tree.*.node.data = &v.tag;
    xdg.base.*.data = tree;
    c.wlr_scene_node_set_enabled(&tree.*.node, false);

    const sf = xdg.base.*.surface;
    wm.on(&sf.*.events.map, &v.l_map, wm.cb(View, "l_map", View.onMap));
    wm.on(&sf.*.events.unmap, &v.l_unmap, wm.cb(View, "l_unmap", View.onUnmap));
    wm.on(&sf.*.events.commit, &v.l_commit, wm.cb(View, "l_commit", View.onCommit));
    wm.on(&xdg.events.destroy, &v.l_destroy, wm.cb(View, "l_destroy", View.onDestroy));
    wm.on(&xdg.events.request_move, &v.l_move, wm.cb(View, "l_move", View.onMove));
    wm.on(&xdg.events.request_resize, &v.l_resize, wm.cb(View, "l_resize", View.onResize));
    wm.on(&xdg.events.request_fullscreen, &v.l_fullscreen, wm.cb(View, "l_fullscreen", View.onFullscreen));
    wm.on(&xdg.events.request_maximize, &v.l_maximize, wm.cb(View, "l_maximize", View.onMaximize));
    wm.on(&xdg.events.set_title, &v.l_title, wm.cb(View, "l_title", View.onTitle));
    wm.on(&xdg.events.set_app_id, &v.l_app_id, wm.cb(View, "l_app_id", View.onTitle));
}

pub fn viewOfToplevel(xdg: *c.struct_wlr_xdg_toplevel) ?*View {
    const tree: *c.struct_wlr_scene_tree = @ptrCast(@alignCast(xdg.base.*.data orelse return null));
    const tag: *wm.Tag = @ptrCast(@alignCast(tree.node.data orelse return null));
    return @alignCast(@fieldParentPtr("tag", tag));
}

pub fn onNewDecoration(data: ?*anyopaque) void {
    const d = wm.ptr(c.struct_wlr_xdg_toplevel_decoration_v1, data);
    if (!cfg.server_side_decorations) return;
    const v = viewOfToplevel(d.toplevel) orelse return;
    v.deco = d;
    wm.on(&d.events.request_mode, &v.l_deco_mode, wm.cb(View, "l_deco_mode", View.onDecoMode));
    wm.on(&d.events.destroy, &v.l_deco_destroy, wm.cb(View, "l_deco_destroy", View.onDecoDestroy));
    if (v.xdg.base.*.initialized) v.onDecoMode(null);
}

/// wlroots has checked the token's serial and, if the token names a surface, that this surface had
/// the focus. A token naming no surface proves nothing about focus: it loses its seat, so it can
/// not take the focus (onActivate). Dropping the seat is safe: wlroots' seat_destroy listener stays.
pub fn onNewToken(data: ?*anyopaque) void {
    const t = wm.ptr(c.struct_wlr_xdg_activation_token_v1, data);
    if (t.surface == null) t.seat = null;
}

/// xdg-activation: honoured for tokens minted from real user input in a focused surface (they keep
/// a seat) and for tokens RefursWM gave to programs it started; a background app cannot steal focus.
pub fn onActivate(data: ?*anyopaque) void {
    const ev = wm.ptr(c.struct_wlr_xdg_activation_v1_request_activate_event, data);
    if (ev.token.*.seat == null and !launcher.ownToken(ev.token)) return;
    const xdg = c.wlr_xdg_toplevel_try_from_wlr_surface(ev.surface) orelse return;
    const v = viewOfToplevel(xdg) orelse return;
    if (!v.mapped) return;
    if (s.ws[v.ws].output == null) wm.showWorkspace(v.ws);
    wm.focusView(v, true);
}

// ------------------------------------------------------------------ popups

const Popup = struct {
    xdg: *c.struct_wlr_xdg_popup,
    owner: *client.State,
    l_commit: Listener = zero,
    l_destroy: Listener = zero,

    fn onCommit(p: *Popup, _: ?*anyopaque) void {
        if (!p.xdg.base.*.initial_commit) return;
        p.unconstrain();
        _ = c.wlr_xdg_surface_schedule_configure(p.xdg.base);
    }

    /// Keep the popup inside the monitor of the window it belongs to.
    fn unconstrain(p: *Popup) void {
        const tree: *c.struct_wlr_scene_tree = @ptrCast(@alignCast(p.xdg.base.*.data orelse return));
        var root: ?*c.struct_wlr_scene_tree = tree.node.parent;
        while (root) |r| : (root = r.node.parent) if (r.node.data != null) break;
        const r = root orelse return;
        var lx: c_int = 0;
        var ly: c_int = 0;
        _ = c.wlr_scene_node_coords(&r.node, &lx, &ly);
        const wo = c.wlr_output_layout_output_at(s.output_layout, @floatFromInt(lx), @floatFromInt(ly)) orelse
            (if (s.mon) |m| m.wlr else return);
        var ob: c.struct_wlr_box = undefined;
        c.wlr_output_layout_get_box(s.output_layout, wo, &ob);
        // scene coordinates of nested popups come from client-controlled positioners
        ob.x -|= lx;
        ob.y -|= ly;
        c.wlr_xdg_popup_unconstrain_from_box(p.xdg, &ob);
    }

    fn onDestroy(p: *Popup, _: ?*anyopaque) void {
        wm.off(&p.l_commit);
        wm.off(&p.l_destroy);
        client.give(p.owner, .popups);
        wm.gpa.destroy(p);
    }
};

pub fn onNewPopup(data: ?*anyopaque) void {
    const xp = wm.ptr(c.struct_wlr_xdg_popup, data);
    const parent = xp.parent orelse return;
    var ptree: ?*anyopaque = null;
    if (c.wlr_xdg_surface_try_from_wlr_surface(parent)) |x| {
        ptree = x.*.data;
    } else if (c.wlr_layer_surface_v1_try_from_wlr_surface(parent)) |ls| {
        ptree = ls.*.data;
    }
    const pt: *c.struct_wlr_scene_tree = @ptrCast(@alignCast(ptree orelse return));
    const owner = client.take(client.of(xp.resource), .popups) orelse return;
    const p = wm.gpa.create(Popup) catch return client.give(owner, .popups);
    const tree = c.wlr_scene_xdg_surface_create(pt, xp.base) orelse {
        wm.gpa.destroy(p);
        return client.give(owner, .popups);
    };
    xp.base.*.data = tree;
    // menus of a tiled window must cover its neighbours
    var up: ?*c.struct_wlr_scene_tree = pt;
    while (up) |u| : (up = u.node.parent) if (u.node.data) |d| {
        const tag: *wm.Tag = @ptrCast(@alignCast(d));
        if (tag.* == .view) c.wlr_scene_node_raise_to_top(&u.node);
        break;
    };
    p.* = .{ .xdg = xp, .owner = owner };
    wm.on(&xp.base.*.surface.*.events.commit, &p.l_commit, wm.cb(Popup, "l_commit", Popup.onCommit));
    wm.on(&xp.events.destroy, &p.l_destroy, wm.cb(Popup, "l_destroy", Popup.onDestroy));
}
