// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! RefursWM - a tiling + scrolling Wayland compositor on wlroots.
//! No Xwayland, no IPC socket, no config parser, no timers: the only code that runs is the
//! answer to a client request or an input event.
const std = @import("std");
const wm = @import("wm.zig");
const c = wm.c;
const cfg = wm.cfg;
const view = @import("view.zig");
const output = @import("output.zig");
const input = @import("input.zig");
const client = @import("client.zig");
const launcher = @import("launcher.zig");
const policy = @import("policy.zig");
const sandbox = @import("sandbox.zig");
const shell = @import("shell.zig");
const s = &wm.s;
const zero = std.mem.zeroes(wm.Listener);

var l_new_output = zero;
var l_layout_change = zero;
var l_new_toplevel = zero;
var l_new_popup = zero;
var l_new_layer = zero;
var l_new_deco = zero;
var l_activate = zero;
var l_new_input = zero;
var l_vkbd = zero;
var l_vptr = zero;
var l_motion = zero;
var l_motion_abs = zero;
var l_button = zero;
var l_axis = zero;
var l_frame = zero;
var l_req_cursor = zero;
var l_cursor_shape = zero;
var l_sel = zero;
var l_primary = zero;
var l_req_drag = zero;
var l_start_drag = zero;
var l_new_lock = zero;
var l_new_inhibitor = zero;
var l_new_token = zero;

fn tree(parent: *c.struct_wlr_scene_tree) *c.struct_wlr_scene_tree {
    return c.wlr_scene_tree_create(parent) orelse @panic("out of memory");
}

/// Who sees which global: policy.allowGlobal. Privileged globals reach only connections RefursWM
/// opened for a granted program; layer-shell, lock and idle-notify never reach sandboxes.
fn globalFilter(cl: ?*const c.struct_wl_client, global: ?*const c.struct_wl_global, _: ?*anyopaque) callconv(.c) bool {
    for (s.restricted.items) |r| if (r.global == global)
        return policy.allowGlobal(r.class, client.caps(cl), client.sandboxed(cl), wm.testing);
    return true;
}

fn restrict(g: ?*c.struct_wl_global, class: policy.Class) void {
    if (g) |x| s.restricted.append(wm.gpa, .{ .global = x, .class = class }) catch {};
}

/// Capabilities some grant needs: only their globals exist at all (all of them in test builds).
const granted: wm.T.Caps = blk: {
    var u: u8 = 0;
    for (cfg.grants) |g| u |= @as(u8, @bitCast(g.caps));
    break :blk @bitCast(u);
};

fn setup() !void {
    const dsp = c.wl_display_create() orelse return error.Display;
    s.display = dsp;
    const loop = c.wl_display_get_event_loop(dsp);
    _ = c.wl_event_loop_add_signal(loop, c.SIGTERM, onTerminate, null);
    _ = c.wl_event_loop_add_signal(loop, c.SIGINT, onTerminate, null);
    s.backend = c.wlr_backend_autocreate(loop, &s.session) orelse return error.Backend;
    s.renderer = c.wlr_renderer_autocreate(s.backend) orelse return error.Renderer;
    _ = c.wlr_renderer_init_wl_shm(s.renderer, dsp);
    s.allocator = c.wlr_allocator_autocreate(s.backend, s.renderer) orelse return error.Allocator;

    s.scene = c.wlr_scene_create() orelse return error.Scene;
    // dmabuf feedback lets the scene hand fullscreen/opaque buffers straight to the display (scanout)
    if (c.wlr_renderer_get_texture_formats(s.renderer, c.WLR_BUFFER_CAP_DMABUF) != null) {
        if (c.wlr_linux_dmabuf_v1_create_with_renderer(dsp, 5, s.renderer)) |dmabuf| c.wlr_scene_set_linux_dmabuf_v1(s.scene, dmabuf);
    }
    // explicit sync: clients hand over fences instead of implicit GPU synchronisation (Vulkan, NVK)
    const drm_fd = c.wlr_renderer_get_drm_fd(s.renderer);
    if (drm_fd >= 0 and s.renderer.*.features.timeline and s.backend.*.features.timeline)
        _ = c.wlr_linux_drm_syncobj_manager_v1_create(dsp, 1, drm_fd);
    s.tearing = c.wlr_tearing_control_manager_v1_create(dsp, 1) orelse return error.Tearing;
    _ = c.wlr_compositor_create(dsp, 6, s.renderer);
    _ = c.wlr_subcompositor_create(dsp);
    _ = c.wlr_data_device_manager_create(dsp);
    _ = c.wlr_primary_selection_v1_device_manager_create(dsp);
    _ = c.wlr_viewporter_create(dsp);
    _ = c.wlr_presentation_create(dsp, s.backend, 2);
    _ = c.wlr_fractional_scale_manager_v1_create(dsp, 1);
    _ = c.wlr_single_pixel_buffer_manager_v1_create(dsp);

    s.output_layout = c.wlr_output_layout_create(dsp) orelse return error.Layout;
    _ = c.wlr_xdg_output_manager_v1_create(dsp, s.output_layout);
    s.scene_layout = c.wlr_scene_attach_output_layout(s.scene, s.output_layout) orelse return error.Scene;
    wm.on(&s.output_layout.events.change, &l_layout_change, wm.gcb(output.onLayoutChange));
    wm.on(&s.backend.events.new_output, &l_new_output, wm.gcb(output.onNewOutput));

    // stacking order, bottom to top
    const root = &s.scene.*.tree;
    s.layers = .{
        .color = tree(root),
        .background = tree(root),
        .bottom = tree(root),
        .tiled = tree(root),
        .floating = tree(root),
        .top = tree(root),
        .fullscreen = tree(root),
        .overlay = tree(root),
        .dnd = tree(root),
        .lock_bg = tree(root),
        .lock = tree(root),
    };
    c.wlr_scene_node_set_enabled(&s.layers.lock_bg.*.node, false);

    const xdg = c.wlr_xdg_shell_create(dsp, 6) orelse return error.XdgShell;
    wm.on(&xdg.*.events.new_toplevel, &l_new_toplevel, wm.gcb(view.onNewToplevel));
    wm.on(&xdg.*.events.new_popup, &l_new_popup, wm.gcb(view.onNewPopup));
    const layer = c.wlr_layer_shell_v1_create(dsp, 4) orelse return error.LayerShell;
    wm.on(&layer.*.events.new_surface, &l_new_layer, wm.gcb(output.onNewLayerSurface));
    const deco = c.wlr_xdg_decoration_manager_v1_create(dsp) orelse return error.Decoration;
    wm.on(&deco.*.events.new_toplevel_decoration, &l_new_deco, wm.gcb(view.onNewDecoration));
    s.activation = c.wlr_xdg_activation_v1_create(dsp) orelse return error.Activation;
    wm.on(&s.activation.events.request_activate, &l_activate, wm.gcb(view.onActivate));
    wm.on(&s.activation.events.new_token, &l_new_token, wm.gcb(view.onNewToken));
    // tells input.onSetSelection which client sent the request
    _ = c.wl_display_add_protocol_logger(dsp, input.protocolLogger, null);

    s.cursor = c.wlr_cursor_create() orelse return error.Cursor;
    c.wlr_cursor_attach_output_layout(s.cursor, s.output_layout);
    s.xcursor = c.wlr_xcursor_manager_create(cfg.cursor_theme, cfg.cursor_size) orelse return error.Cursor;
    wm.on(&s.cursor.events.motion, &l_motion, wm.gcb(input.onMotion));
    wm.on(&s.cursor.events.motion_absolute, &l_motion_abs, wm.gcb(input.onMotionAbsolute));
    wm.on(&s.cursor.events.button, &l_button, wm.gcb(input.onButton));
    wm.on(&s.cursor.events.axis, &l_axis, wm.gcb(input.onAxis));
    wm.on(&s.cursor.events.frame, &l_frame, wm.gcb(input.onFrame));
    const shape = c.wlr_cursor_shape_manager_v1_create(dsp, 1) orelse return error.Cursor;
    wm.on(&shape.*.events.request_set_shape, &l_cursor_shape, wm.gcb(input.onCursorShape));
    s.relptr = c.wlr_relative_pointer_manager_v1_create(dsp) orelse return error.Pointer;

    if (!input.init()) return error.Keymap;
    wm.on(&s.backend.events.new_input, &l_new_input, wm.gcb(input.onNewInput));
    s.seat = c.wlr_seat_create(dsp, "seat0") orelse return error.Seat;
    wm.on(&s.seat.events.request_set_cursor, &l_req_cursor, wm.gcb(input.onRequestCursor));
    wm.on(&s.seat.events.request_set_selection, &l_sel, wm.gcb(input.onSetSelection));
    wm.on(&s.seat.events.request_set_primary_selection, &l_primary, wm.gcb(input.onSetPrimary));
    wm.on(&s.seat.events.request_start_drag, &l_req_drag, wm.gcb(input.onRequestDrag));
    wm.on(&s.seat.events.start_drag, &l_start_drag, wm.gcb(input.onStartDrag));

    s.idle = c.wlr_idle_notifier_v1_create(dsp) orelse return error.Idle;
    const inhibit = c.wlr_idle_inhibit_v1_create(dsp) orelse return error.Idle;
    wm.on(&inhibit.*.events.new_inhibitor, &l_new_inhibitor, wm.gcb(wm.onNewInhibitor));
    const lock = c.wlr_session_lock_manager_v1_create(dsp) orelse return error.Lock;
    wm.on(&lock.*.events.new_lock, &l_new_lock, wm.gcb(output.onNewLock));

    s.security = c.wlr_security_context_manager_v1_create(dsp) orelse return error.Security;
    // sandboxes may not draw over everything, fake a lock screen or watch the user's presence
    restrict(layer.*.global, .sandbox_hidden);
    restrict(lock.*.global, .sandbox_hidden);
    restrict(s.idle.global, .sandbox_hidden);
    const all = wm.testing;
    if (granted.screencopy or all) {
        const cls: policy.Class = .{ .privileged = .{ .screencopy = true } };
        restrict(if (c.wlr_screencopy_manager_v1_create(dsp)) |x| x.*.global else null, cls);
        restrict(if (c.wlr_ext_image_copy_capture_manager_v1_create(dsp, 1)) |x| x.*.global else null, cls);
        restrict(if (c.wlr_ext_output_image_capture_source_manager_v1_create(dsp, 1)) |x| x.*.global else null, cls);
    }
    if (granted.data_control or all) {
        const cls: policy.Class = .{ .privileged = .{ .data_control = true } };
        restrict(if (c.wlr_data_control_manager_v1_create(dsp)) |x| x.*.global else null, cls);
        restrict(if (c.wlr_ext_data_control_manager_v1_create(dsp, 1)) |x| x.*.global else null, cls);
    }
    if (granted.virtual_input or all) {
        const cls: policy.Class = .{ .privileged = .{ .virtual_input = true } };
        const vk = c.wlr_virtual_keyboard_manager_v1_create(dsp) orelse return error.VirtualInput;
        wm.on(&vk.*.events.new_virtual_keyboard, &l_vkbd, wm.gcb(input.onVirtualKeyboard));
        restrict(vk.*.global, cls);
        const vp = c.wlr_virtual_pointer_manager_v1_create(dsp) orelse return error.VirtualInput;
        wm.on(&vp.*.events.new_virtual_pointer, &l_vptr, wm.gcb(input.onVirtualPointer));
        restrict(vp.*.global, cls);
    }
    if (granted.shell or all) restrict(shell.create(dsp), .{ .privileged = .{ .shell = true } });
    if (granted.gamma or all) {
        const g = c.wlr_gamma_control_manager_v1_create(dsp) orelse return error.Gamma;
        c.wlr_scene_set_gamma_control_manager_v1(s.scene, g);
        restrict(g.*.global, .{ .privileged = .{ .gamma = true } });
    }
    c.wl_display_set_global_filter(dsp, globalFilter, null);
}

fn ignore(_: c_int) callconv(.c) void {}

/// SIGTERM/SIGINT end the session cleanly (VT and DRM state restored); delivered via signalfd
fn onTerminate(_: c_int, _: ?*anyopaque) callconv(.c) c_int {
    c.wl_display_terminate(s.display);
    return 0;
}

/// $XDG_RUNTIME_DIR/wayland-N-sandbox: its clients are treated like flatpak clients (no
/// layer-shell, lock, idle-notify or privileged globals, no focus stealing). Bind-mount it into
/// bwrap & co instead of the main socket.
fn addSandboxSocket(loop: ?*c.struct_wl_event_loop, name: []const u8) void {
    const dir = std.mem.span(c.getenv("XDG_RUNTIME_DIR") orelse return);
    var addr: std.os.linux.sockaddr.un = .{ .path = @splat(0) };
    const path = std.fmt.bufPrintSentinel(addr.path[0 .. addr.path.len - 1], "{s}/{s}-sandbox", .{ dir, name }, 0) catch
        return wm.log("sandbox socket: path too long", .{});
    _ = c.unlink(path.ptr);
    const lx = std.os.linux;
    const rc = lx.socket(lx.AF.UNIX, lx.SOCK.STREAM | lx.SOCK.CLOEXEC | lx.SOCK.NONBLOCK, 0);
    if (lx.errno(rc) != .SUCCESS) return;
    const fd: c_int = @intCast(rc);
    const old = c.umask(0o077);
    const bound = lx.errno(lx.bind(fd, @ptrCast(&addr), @sizeOf(lx.sockaddr.un))) == .SUCCESS and
        lx.errno(lx.listen(fd, 128)) == .SUCCESS;
    _ = c.umask(old);
    if (!bound or c.wl_event_loop_add_fd(loop, fd, c.WL_EVENT_READABLE, onSandboxClient, null) == null) {
        _ = c.close(fd);
        return wm.log("cannot create the sandbox socket", .{});
    }
}

fn onSandboxClient(fd: c_int, _: u32, _: ?*anyopaque) callconv(.c) c_int {
    const lx = std.os.linux;
    const rc = lx.accept4(fd, null, null, lx.SOCK.CLOEXEC);
    if (lx.errno(rc) != .SUCCESS) return 0;
    const cfd: c_int = @intCast(rc);
    const cl = c.wl_client_create(s.display, cfd) orelse {
        _ = c.close(cfd);
        return 0;
    };
    // marked before its first request is read: it never sees a restricted global
    const st = client.ensure(cl) orelse {
        c.wl_client_destroy(cl);
        return 0;
    };
    st.sandboxed = true;
    return 0;
}

pub fn main() u8 {
    // Zig's stderr (std.debug.print, panic messages) reads the environment once, through a snapshot
    // of the initial block; setenv/unsetenv here and in the launcher would leave a hole in it. Done
    // now, before any change, the cached result keeps logging and panic messages working.
    _ = std.debug.lockStderr(&.{});
    std.debug.unlockStderr();
    // first of all, while the process holds nothing: drop the terminal, fork the launcher
    var sa = std.mem.zeroes(c.struct_sigaction);
    sa.__sigaction_handler.sa_handler = ignore;
    _ = c.sigaction(c.SIGHUP, &sa, null);
    // a dead client socket must not kill us
    _ = c.sigaction(c.SIGPIPE, &sa, null);
    sandbox.detachTty();
    launcher.start();
    // never a nested compositor: an inherited WAYLAND_DISPLAY must not pick wlroots' Wayland backend
    _ = c.unsetenv("WAYLAND_DISPLAY");
    _ = c.unsetenv("WAYLAND_SOCKET");
    // the launcher is the only child; the kernel reaps it
    sa = std.mem.zeroes(c.struct_sigaction);
    sa.sa_flags = c.SA_NOCLDWAIT;
    _ = c.sigaction(c.SIGCHLD, &sa, null);
    sandbox.raiseFdLimit();
    const rt = cfg.realtime and sandbox.realtime();
    sandbox.dropCaps();
    sandbox.noDump();
    sandbox.bundledQuirks();
    sandbox.early();

    c.wlr_log_init(if (c.getenv("REFURS_DEBUG") != null) c.WLR_DEBUG else c.WLR_ERROR, null);

    setup() catch |e| {
        wm.log("startup failed: {s}", .{@errorName(e)});
        return 1;
    };
    const sock = c.wl_display_add_socket_auto(s.display) orelse {
        wm.log("cannot create a Wayland socket", .{});
        return 1;
    };
    if (!c.wlr_backend_start(s.backend)) {
        wm.log("cannot start the backend", .{});
        return 1;
    }
    const name = std.mem.span(sock);
    addSandboxSocket(c.wl_display_get_event_loop(s.display), name);
    wm.log("running on WAYLAND_DISPLAY={s} (sandboxes: {s}-sandbox), realtime: {s}", .{ name, name, if (rt) "on" else "off" });

    launcher.setDisplay(name);
    wm.themeHooks();
    inline for (cfg.autostart) |cmd| launcher.spawn(cmd, false);
    launcher.startup();
    sandbox.late();

    c.wl_display_run(s.display);

    c.wl_display_destroy_clients(s.display);
    // wlroots asserts that nobody still listens to an object it destroys
    for ([_]*wm.Listener{
        &l_new_output, &l_layout_change, &l_new_toplevel,  &l_new_popup, &l_new_layer,
        &l_new_deco,   &l_activate,      &l_new_input,     &l_vkbd,      &l_vptr,
        &l_motion,     &l_motion_abs,    &l_button,        &l_axis,      &l_frame,
        &l_req_cursor, &l_cursor_shape,  &l_sel,           &l_primary,   &l_req_drag,
        &l_start_drag, &l_new_lock,      &l_new_inhibitor, &l_new_token,
    }) |l| wm.off(l);
    output.shutdown();
    input.shutdown();
    c.wlr_backend_destroy(s.backend);
    c.wl_display_destroy(s.display);
    return 0;
}
