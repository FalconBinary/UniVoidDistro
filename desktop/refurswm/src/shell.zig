// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! refurs-shell: what the bar (RefursLine) shows and the few things it may ask for
//! (protocol/refurs-shell-unstable-v1.xml). The global is offered only on connections RefursWM
//! opened for a program with a grant for `.shell`; sandboxes never see it.
//!
//! No polling and no timers: whatever may change the state calls touch(), which schedules one idle
//! callback for the end of the current event-loop round. That callback compares the state with
//! what each bar was last told and sends only the differences, then `done`. A burst of changes
//! (a workspace switch moves focus, re-tiles and changes the title) becomes one message batch.
const std = @import("std");
const wm = @import("wm.zig");
const c = wm.c;
const cfg = wm.cfg;
const T = wm.T;
const client = @import("client.zig");
const policy = @import("policy.zig");
const launcher = @import("launcher.zig");
const outmod = @import("output.zig");
const s = &wm.s;

const VERSION = 1;
/// output objects per bar: one per monitor, generously
const MAX_OUTS = 32;
const STR = 256;

/// A sanitized copy of a client-controlled string (window title, app id), see policy.cleanText.
const Str = struct {
    buf: [STR]u8 = undefined,
    len: usize = 0,

    fn set(x: *Str, raw: ?[*:0]const u8) void {
        x.len = if (raw) |r| policy.cleanText(x.buf[0 .. STR - 1], std.mem.span(r)) else 0;
        x.buf[x.len] = 0;
    }

    fn eql(a: *const Str, b: *const Str) bool {
        return std.mem.eql(u8, a.buf[0..a.len], b.buf[0..b.len]);
    }

    fn z(x: *Str) [*:0]const u8 {
        x.buf[x.len] = 0;
        return @ptrCast(&x.buf);
    }
};

const State = struct {
    occupied: u32 = 0,
    title: Str = .{},
    app_id: Str = .{},
    kb: u32 = 0,
    theme: T.Theme = .dark,
};

const Mgr = struct {
    res: *c.struct_wl_resource,
    /// a new bar: everything is sent on the next flush
    full: bool = true,
};

const Out = struct {
    res: *c.struct_wl_resource,
    mgr: ?*Mgr,
    /// null once the monitor is gone (the object stays inert)
    wlr: ?*c.struct_wlr_output,
    // last sent; maxInt = never
    ws: u32 = std.math.maxInt(u32),
    mode: u32 = std.math.maxInt(u32),
    active: u32 = std.math.maxInt(u32),
};

var mgrs: std.ArrayList(*Mgr) = .empty;
var outs: std.ArrayList(*Out) = .empty;
var sent: State = .{};
var cur: State = .{};
var pending = false;
pub var global: ?*c.struct_wl_global = null;

// ------------------------------------------------------------------ comptime tables

/// "us,ru" -> {"us", "ru"}: the names the bar shows for the xkb groups
const layouts = blk: {
    const all = std.mem.span(cfg.xkb_layout);
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, all, ',');
    while (it.next()) |_| n += 1;
    var out: [n][:0]const u8 = undefined;
    it = std.mem.tokenizeScalar(u8, all, ',');
    var i: usize = 0;
    while (it.next()) |l| : (i += 1) out[i] = std.fmt.comptimePrint("{s}", .{std.mem.trim(u8, l, " ")});
    break :blk out;
};

// ------------------------------------------------------------------ state

fn group() u32 {
    const kb = c.wlr_seat_get_keyboard(s.seat) orelse return 0;
    return kb.*.modifiers.group;
}

fn snapshot(st: *State) void {
    st.occupied = 0;
    for (s.views.items) |v| if (v.mapped and v.ws < 32) {
        st.occupied |= @as(u32, 1) << @intCast(v.ws);
    };
    if (s.focused) |v| {
        st.title.set(v.xdg.title);
        st.app_id.set(v.xdg.app_id);
    } else {
        st.title.set(null);
        st.app_id.set(null);
    }
    st.kb = group();
    st.theme = s.theme;
}

fn sendTheme(res: *c.struct_wl_resource, theme: T.Theme) void {
    c.zrefurs_shell_v1_send_theme(res, @intFromBool(theme == .dark));
}

fn sendLayout(res: *c.struct_wl_resource, g: u32) void {
    const name: [*:0]const u8 = if (g < layouts.len) layouts[g].ptr else "?";
    c.zrefurs_shell_v1_send_keyboard_layout(res, g, name);
}

/// Per-monitor changes of one output object; true if anything was sent.
fn flushOut(o: *Out) bool {
    const wo = o.wlr orelse return false;
    const out = outmod.outputOf(wo) orelse return false;
    var any = false;
    const ws: u32 = out.ws;
    const mode: u32 = @intFromEnum(s.ws[out.ws].mode);
    const active: u32 = @intFromBool(s.mon == out);
    if (ws != o.ws) {
        o.ws = ws;
        c.zrefurs_shell_output_v1_send_workspace(o.res, ws);
        any = true;
    }
    if (mode != o.mode) {
        o.mode = mode;
        c.zrefurs_shell_output_v1_send_mode(o.res, mode);
        any = true;
    }
    if (active != o.active) {
        o.active = active;
        c.zrefurs_shell_output_v1_send_active(o.res, active);
        any = true;
    }
    return any;
}

fn flush(_: ?*anyopaque) callconv(.c) void {
    pending = false;
    if (mgrs.items.len == 0) return;
    snapshot(&cur);
    const d_occ = cur.occupied != sent.occupied;
    const d_focus = !cur.title.eql(&sent.title) or !cur.app_id.eql(&sent.app_id);
    const d_kb = cur.kb != sent.kb;
    const d_theme = cur.theme != sent.theme;
    var dirty: [64]bool = undefined;
    const nm = @min(mgrs.items.len, dirty.len);
    for (mgrs.items[0..nm], dirty[0..nm]) |m, *d| {
        const all = m.full;
        m.full = false;
        d.* = all or d_occ or d_focus or d_kb or d_theme;
        if (all or d_occ) c.zrefurs_shell_v1_send_workspaces(m.res, cur.occupied);
        if (all or d_focus) c.zrefurs_shell_v1_send_focus(m.res, cur.title.z(), cur.app_id.z());
        if (all or d_kb) sendLayout(m.res, cur.kb);
        if (all or d_theme) sendTheme(m.res, cur.theme);
    }
    for (outs.items) |o| {
        if (!flushOut(o)) continue;
        const m = o.mgr orelse continue;
        for (mgrs.items[0..nm], dirty[0..nm]) |x, *d| if (x == m) {
            d.* = true;
        };
    }
    for (mgrs.items[0..nm], dirty[0..nm]) |m, d| if (d) c.zrefurs_shell_v1_send_done(m.res);
    sent = cur;
}

/// Something a bar shows may have changed: compare and send at the end of this event-loop round.
/// Costs a flag test when it is already scheduled or no bar is connected.
pub fn touch() void {
    if (pending or mgrs.items.len == 0) return;
    const loop = c.wl_display_get_event_loop(s.display);
    if (c.wl_event_loop_add_idle(loop, flush, null) != null) pending = true;
}

/// A key binding asks for a bar menu.
pub fn open(menu: T.Menu) void {
    if (mgrs.items.len == 0) return wm.log("no bar is running: menu {s} not opened", .{@tagName(menu)});
    for (mgrs.items) |m| {
        c.zrefurs_shell_v1_send_open(m.res, @intFromEnum(menu));
        c.zrefurs_shell_v1_send_done(m.res);
    }
}

/// The keyboard layout group may have changed (modifier events come with every Shift press).
var last_group: u32 = 0;
pub fn modifiers(g: u32) void {
    if (g == last_group) return;
    last_group = g;
    touch();
}

/// A monitor is going away: its output objects become inert.
pub fn outputGone(wo: *c.struct_wlr_output) void {
    for (outs.items) |o| if (o.wlr == wo) {
        o.wlr = null;
    };
    touch();
}

// ------------------------------------------------------------------ requests

fn mgrOf(res: ?*c.struct_wl_resource) ?*Mgr {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(res)));
}

fn outOf(res: ?*c.struct_wl_resource) ?*Out {
    return @ptrCast(@alignCast(c.wl_resource_get_user_data(res)));
}

fn destroyReq(_: ?*c.struct_wl_client, res: ?*c.struct_wl_resource) callconv(.c) void {
    c.wl_resource_destroy(res);
}

fn getOutput(cl: ?*c.struct_wl_client, res: ?*c.struct_wl_resource, id: u32, out_res: ?*c.struct_wl_resource) callconv(.c) void {
    const m = mgrOf(res) orelse return;
    if (outs.items.len >= MAX_OUTS * @max(mgrs.items.len, 1)) return c.wl_client_post_implementation_error(cl, "too many output objects");
    const r = c.wl_resource_create(cl, &c.zrefurs_shell_output_v1_interface, c.wl_resource_get_version(res), id) orelse
        return c.wl_client_post_no_memory(cl);
    const o = wm.gpa.create(Out) catch {
        c.wl_resource_destroy(r);
        return c.wl_client_post_no_memory(cl);
    };
    o.* = .{ .res = r, .mgr = m, .wlr = c.wlr_output_from_resource(out_res) };
    outs.append(wm.gpa, o) catch {
        wm.gpa.destroy(o);
        c.wl_resource_destroy(r);
        return c.wl_client_post_no_memory(cl);
    };
    c.wl_resource_set_implementation(r, &out_impl, o, onOutDestroy);
    // the new object's state goes out with the next flush, followed by done
    m.full = true;
    touch();
}

fn toggleTheme(_: ?*c.struct_wl_client, _: ?*c.struct_wl_resource) callconv(.c) void {
    if (s.locked) return;
    wm.toggleTheme();
}

fn lock(_: ?*c.struct_wl_client, _: ?*c.struct_wl_resource) callconv(.c) void {
    if (s.locked) return;
    launcher.spawn(cfg.lock_command, false);
}

fn quit(_: ?*c.struct_wl_client, _: ?*c.struct_wl_resource) callconv(.c) void {
    if (s.locked) return;
    c.wl_display_terminate(s.display);
}

/// The monitor of an output object, if it still exists and the session is not locked.
fn target(res: ?*c.struct_wl_resource) ?*wm.Output {
    if (s.locked) return null;
    const o = outOf(res) orelse return null;
    return outmod.outputOf(o.wlr orelse return null);
}

fn workspace(_: ?*c.struct_wl_client, res: ?*c.struct_wl_resource, index: u32) callconv(.c) void {
    const out = target(res) orelse return;
    if (index >= wm.WS) return;
    s.mon = out;
    wm.showWorkspace(@intCast(index));
    touch();
}

fn cycle(_: ?*c.struct_wl_client, res: ?*c.struct_wl_resource, dir: i32) callconv(.c) void {
    const out = target(res) orelse return;
    if (dir == 0) return;
    const step: i32 = if (dir > 0) 1 else -1;
    // the next workspace not shown on another monitor (that would move the focus over there)
    var n: i32 = out.ws;
    for (0..wm.WS) |_| {
        n = @mod(n + step, wm.WS);
        const w = s.ws[@intCast(n)].output;
        if (w == null or w == out) break;
    }
    if (n == out.ws) return;
    s.mon = out;
    wm.showWorkspace(@intCast(n));
    touch();
}

fn toggleMode(_: ?*c.struct_wl_client, res: ?*c.struct_wl_resource) callconv(.c) void {
    const out = target(res) orelse return;
    wm.toggleMode(out.ws);
    touch();
}

const mgr_impl: c.struct_zrefurs_shell_v1_interface = .{
    .destroy = destroyReq,
    .get_output = getOutput,
    .toggle_theme = toggleTheme,
    .lock = lock,
    .quit = quit,
};

const out_impl: c.struct_zrefurs_shell_output_v1_interface = .{
    .destroy = destroyReq,
    .workspace = workspace,
    .cycle = cycle,
    .toggle_mode = toggleMode,
};

fn onMgrDestroy(res: ?*c.struct_wl_resource) callconv(.c) void {
    const m = mgrOf(res) orelse return;
    if (std.mem.indexOfScalar(*Mgr, mgrs.items, m)) |i| _ = mgrs.swapRemove(i);
    for (outs.items) |o| if (o.mgr == m) {
        o.mgr = null;
    };
    wm.gpa.destroy(m);
}

fn onOutDestroy(res: ?*c.struct_wl_resource) callconv(.c) void {
    const o = outOf(res) orelse return;
    if (std.mem.indexOfScalar(*Out, outs.items, o)) |i| _ = outs.swapRemove(i);
    wm.gpa.destroy(o);
}

fn bind(cl: ?*c.struct_wl_client, _: ?*anyopaque, version: u32, id: u32) callconv(.c) void {
    // the global filter already hides it; this is the second lock on the same door
    if (client.sandboxed(cl) or !(wm.testing or client.caps(cl).shell))
        return c.wl_client_post_implementation_error(cl, "refurs-shell is not granted");
    const r = c.wl_resource_create(cl, &c.zrefurs_shell_v1_interface, @intCast(@min(version, VERSION)), id) orelse
        return c.wl_client_post_no_memory(cl);
    const m = wm.gpa.create(Mgr) catch {
        c.wl_resource_destroy(r);
        return c.wl_client_post_no_memory(cl);
    };
    m.* = .{ .res = r };
    mgrs.append(wm.gpa, m) catch {
        wm.gpa.destroy(m);
        c.wl_resource_destroy(r);
        return c.wl_client_post_no_memory(cl);
    };
    c.wl_resource_set_implementation(r, &mgr_impl, m, onMgrDestroy);
    last_group = group();
    touch();
}

pub fn create(dsp: *c.struct_wl_display) ?*c.struct_wl_global {
    global = c.wl_global_create(dsp, &c.zrefurs_shell_v1_interface, VERSION, null, bind);
    return global;
}
