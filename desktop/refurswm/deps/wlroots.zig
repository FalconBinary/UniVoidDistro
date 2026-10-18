// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! wlroots 0.20.2 built from source by Zig, as RefursWM needs it and nothing more: Wayland only (no
//! X11 backend, no Xwayland, no nested Wayland backend), the DRM, libinput and headless backends,
//! GLES2 and pixman renderers, GBM allocator; no Vulkan, lcms2 or libliftoff. Static, so the linker
//! keeps only the code RefursWM reaches (sections are collected).
//! Sources and flags follow wlroots' meson.build for these options.
const std = @import("std");
const common = @import("common.zig");

const LazyPath = std.Build.LazyPath;

pub const Out = struct {
    lib: *std.Build.Step.Compile,
    /// generated headers (wlr/config.h, wlr/version.h, protocol headers)
    gen: LazyPath,
    include: LazyPath,
};

const version = "0.20.2";

/// wlroots' own protocol directory, then wayland-protocols. xwayland-shell is left out.
const own_protocols = [_][]const u8{
    "drm",                                   "input-method-unstable-v2",
    "server-decoration",                     "virtual-keyboard-unstable-v1",
    "wlr-data-control-unstable-v1",          "wlr-export-dmabuf-unstable-v1",
    "wlr-foreign-toplevel-management-unstable-v1", "wlr-gamma-control-unstable-v1",
    "wlr-layer-shell-unstable-v1",           "wlr-output-management-unstable-v1",
    "wlr-output-power-management-unstable-v1", "wlr-screencopy-unstable-v1",
    "wlr-virtual-pointer-unstable-v1",
};
const system_protocols = [_][]const u8{
    "stable/linux-dmabuf/linux-dmabuf-v1.xml",
    "stable/presentation-time/presentation-time.xml",
    "stable/tablet/tablet-v2.xml",
    "stable/viewporter/viewporter.xml",
    "stable/xdg-shell/xdg-shell.xml",
    "staging/alpha-modifier/alpha-modifier-v1.xml",
    "staging/color-management/color-management-v1.xml",
    "staging/color-representation/color-representation-v1.xml",
    "staging/content-type/content-type-v1.xml",
    "staging/cursor-shape/cursor-shape-v1.xml",
    "staging/drm-lease/drm-lease-v1.xml",
    "staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml",
    "staging/ext-idle-notify/ext-idle-notify-v1.xml",
    "staging/ext-image-capture-source/ext-image-capture-source-v1.xml",
    "staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml",
    "staging/ext-session-lock/ext-session-lock-v1.xml",
    "staging/ext-data-control/ext-data-control-v1.xml",
    "staging/ext-workspace/ext-workspace-v1.xml",
    "staging/fractional-scale/fractional-scale-v1.xml",
    "staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml",
    "staging/security-context/security-context-v1.xml",
    "staging/single-pixel-buffer/single-pixel-buffer-v1.xml",
    "staging/xdg-activation/xdg-activation-v1.xml",
    "staging/xdg-dialog/xdg-dialog-v1.xml",
    "staging/xdg-system-bell/xdg-system-bell-v1.xml",
    "staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml",
    "staging/xdg-toplevel-tag/xdg-toplevel-tag-v1.xml",
    "staging/tearing-control/tearing-control-v1.xml",
    "staging/ext-transient-seat/ext-transient-seat-v1.xml",
    "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml",
    "unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml",
    "unstable/pointer-constraints/pointer-constraints-unstable-v1.xml",
    "unstable/pointer-gestures/pointer-gestures-unstable-v1.xml",
    "unstable/primary-selection/primary-selection-unstable-v1.xml",
    "unstable/relative-pointer/relative-pointer-unstable-v1.xml",
    "unstable/text-input/text-input-unstable-v3.xml",
    "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml",
    "unstable/xdg-foreign/xdg-foreign-unstable-v1.xml",
    "unstable/xdg-foreign/xdg-foreign-unstable-v2.xml",
    "unstable/xdg-output/xdg-output-unstable-v1.xml",
};

const sources = [_][]const u8{
    // backend: DRM, libinput, headless, multi, session
    "backend/backend.c",                      "backend/multi/backend.c",
    "backend/headless/backend.c",             "backend/headless/output.c",
    "backend/session/session.c",              "backend/drm/atomic.c",
    "backend/drm/backend.c",                  "backend/drm/drm.c",
    "backend/drm/fb.c",                       "backend/drm/legacy.c",
    "backend/drm/monitor.c",                  "backend/drm/properties.c",
    "backend/drm/renderer.c",                 "backend/drm/util.c",
    "backend/libinput/backend.c",             "backend/libinput/events.c",
    "backend/libinput/keyboard.c",            "backend/libinput/pointer.c",
    "backend/libinput/switch.c",              "backend/libinput/tablet_pad.c",
    "backend/libinput/tablet_tool.c",         "backend/libinput/touch.c",
    // render: core, EGL + GLES2, pixman, allocators
    "render/color.c",                         "render/dmabuf.c",
    "render/drm_format_set.c",                "render/drm_syncobj_merger.c",
    "render/drm_syncobj.c",                   "render/pass.c",
    "render/pixel_format.c",                  "render/swapchain.c",
    "render/wlr_renderer.c",                  "render/wlr_texture.c",
    "render/dmabuf_linux.c",                  "render/egl.c",
    "render/color_fallback.c",                "render/gles2/pass.c",
    "render/gles2/pixel_format.c",            "render/gles2/renderer.c",
    "render/gles2/texture.c",                 "render/pixman/pass.c",
    "render/pixman/pixel_format.c",           "render/pixman/renderer.c",
    "render/allocator/allocator.c",           "render/allocator/shm.c",
    "render/allocator/drm_dumb.c",            "render/allocator/gbm.c",
    // types
    "types/data_device/wlr_data_device.c",    "types/data_device/wlr_data_offer.c",
    "types/data_device/wlr_data_source.c",    "types/data_device/wlr_drag.c",
    "types/ext_image_capture_source_v1/base.c", "types/ext_image_capture_source_v1/output.c",
    "types/ext_image_capture_source_v1/foreign_toplevel.c", "types/ext_image_capture_source_v1/scene.c",
    "types/output/cursor.c",                  "types/output/output.c",
    "types/output/render.c",                  "types/output/state.c",
    "types/output/swapchain.c",               "types/scene/drag_icon.c",
    "types/scene/subsurface_tree.c",          "types/scene/surface.c",
    "types/scene/wlr_scene.c",                "types/scene/output_layout.c",
    "types/scene/xdg_shell.c",                "types/scene/layer_shell_v1.c",
    "types/seat/wlr_seat_keyboard.c",         "types/seat/wlr_seat_pointer.c",
    "types/seat/wlr_seat_touch.c",            "types/seat/wlr_seat.c",
    "types/tablet_v2/wlr_tablet_v2_pad.c",    "types/tablet_v2/wlr_tablet_v2_tablet.c",
    "types/tablet_v2/wlr_tablet_v2_tool.c",   "types/tablet_v2/wlr_tablet_v2.c",
    "types/xdg_shell/wlr_xdg_popup.c",        "types/xdg_shell/wlr_xdg_positioner.c",
    "types/xdg_shell/wlr_xdg_shell.c",        "types/xdg_shell/wlr_xdg_surface.c",
    "types/xdg_shell/wlr_xdg_toplevel.c",     "types/buffer/buffer.c",
    "types/buffer/client.c",                  "types/buffer/dmabuf.c",
    "types/buffer/readonly_data.c",           "types/buffer/resource.c",
    "types/wlr_alpha_modifier_v1.c",          "types/wlr_color_management_v1.c",
    "types/wlr_color_representation_v1.c",    "types/wlr_compositor.c",
    "types/wlr_content_type_v1.c",            "types/wlr_cursor.c",
    "types/wlr_cursor_shape_v1.c",            "types/wlr_damage_ring.c",
    "types/wlr_data_control_v1.c",            "types/wlr_drm.c",
    "types/wlr_export_dmabuf_v1.c",           "types/wlr_ext_data_control_v1.c",
    "types/wlr_ext_foreign_toplevel_list_v1.c", "types/wlr_ext_image_copy_capture_v1.c",
    "types/wlr_ext_workspace_v1.c",           "types/wlr_fixes.c",
    "types/wlr_foreign_toplevel_management_v1.c", "types/wlr_fractional_scale_v1.c",
    "types/wlr_gamma_control_v1.c",           "types/wlr_idle_inhibit_v1.c",
    "types/wlr_idle_notify_v1.c",             "types/wlr_input_device.c",
    "types/wlr_input_method_v2.c",            "types/wlr_keyboard.c",
    "types/wlr_keyboard_group.c",             "types/wlr_keyboard_shortcuts_inhibit_v1.c",
    "types/wlr_layer_shell_v1.c",             "types/wlr_linux_dmabuf_v1.c",
    "types/wlr_linux_drm_syncobj_v1.c",       "types/wlr_output_layer.c",
    "types/wlr_output_layout.c",              "types/wlr_output_management_v1.c",
    "types/wlr_output_power_management_v1.c", "types/wlr_output_swapchain_manager.c",
    "types/wlr_pointer_constraints_v1.c",     "types/wlr_pointer_gestures_v1.c",
    "types/wlr_pointer.c",                    "types/wlr_presentation_time.c",
    "types/wlr_primary_selection_v1.c",       "types/wlr_primary_selection.c",
    "types/wlr_region.c",                     "types/wlr_relative_pointer_v1.c",
    "types/wlr_screencopy_v1.c",              "types/wlr_security_context_v1.c",
    "types/wlr_server_decoration.c",          "types/wlr_session_lock_v1.c",
    "types/wlr_shm.c",                        "types/wlr_single_pixel_buffer_v1.c",
    "types/wlr_subcompositor.c",              "types/wlr_switch.c",
    "types/wlr_tablet_pad.c",                 "types/wlr_tablet_tool.c",
    "types/wlr_tearing_control_v1.c",         "types/wlr_text_input_v3.c",
    "types/wlr_touch.c",                      "types/wlr_transient_seat_v1.c",
    "types/wlr_viewporter.c",                 "types/wlr_virtual_keyboard_v1.c",
    "types/wlr_virtual_pointer_v1.c",         "types/wlr_xcursor_manager.c",
    "types/wlr_xdg_activation_v1.c",          "types/wlr_xdg_decoration_v1.c",
    "types/wlr_xdg_dialog_v1.c",              "types/wlr_xdg_foreign_v1.c",
    "types/wlr_xdg_foreign_v2.c",             "types/wlr_xdg_foreign_registry.c",
    "types/wlr_xdg_output_v1.c",              "types/wlr_xdg_system_bell_v1.c",
    "types/wlr_xdg_toplevel_icon_v1.c",       "types/wlr_xdg_toplevel_tag_v1.c",
    "types/wlr_drm_lease_v1.c",
    // util, xcursor
    "util/addon.c",                           "util/array.c",
    "util/box.c",                             "util/env.c",
    "util/fd.c",                              "util/global.c",
    "util/log.c",                             "util/matrix.c",
    "util/mem.c",                             "util/rect_union.c",
    "util/region.c",                          "util/set.c",
    "util/shm.c",                             "util/time.c",
    "util/token.c",                           "util/transform.c",
    "util/utf8.c",                            "util/version.c",
    "xcursor/wlr_xcursor.c",                  "xcursor/xcursor.c",
};

const shaders = [_][]const u8{ "common.vert", "quad.frag", "tex_rgba.frag", "tex_rgbx.frag", "tex_external.frag" };

pub fn build(b: *std.Build, dep: *std.Build.Dependency, o: common.Options, libinput_inc: LazyPath, libseat_inc: LazyPath, stub: LazyPath) Out {
    const gen = b.addWriteFiles();
    _ = gen.add("wlr/config.h",
        \\#ifndef WLR_CONFIG_H
        \\#define WLR_CONFIG_H
        \\#define WLR_HAS_DRM_BACKEND 1
        \\#define WLR_HAS_LIBINPUT_BACKEND 1
        \\#define WLR_HAS_X11_BACKEND 0
        \\#define WLR_HAS_GLES2_RENDERER 1
        \\#define WLR_HAS_VULKAN_RENDERER 0
        \\#define WLR_HAS_GBM_ALLOCATOR 1
        \\#define WLR_HAS_UDMABUF_ALLOCATOR 0
        \\#define WLR_HAS_XWAYLAND 0
        \\#define WLR_HAS_SESSION 1
        \\#define WLR_HAS_COLOR_MANAGEMENT 0
        \\#endif
        \\
    );
    _ = gen.add("wlr/version.h", b.fmt(
        \\#ifndef WLR_VERSION_H
        \\#define WLR_VERSION_H
        \\#define WLR_VERSION_STR "{s}"
        \\#define WLR_VERSION_MAJOR 0
        \\#define WLR_VERSION_MINOR 20
        \\#define WLR_VERSION_MICRO 2
        \\#define WLR_VERSION_NUM ((WLR_VERSION_MAJOR << 16) | (WLR_VERSION_MINOR << 8) | WLR_VERSION_MICRO)
        \\int wlr_version_get_major(void);
        \\int wlr_version_get_minor(void);
        \\int wlr_version_get_micro(void);
        \\#endif
        \\
    , .{version}));
    // internal config (include/meson.build and friends)
    _ = gen.add("config.h",
        \\#define HAVE_EVENTFD 1
        \\#define HAVE_LINUX_SYNC_FILE 1
        \\#define HAVE_LIBINPUT_BUSTYPE 1
        \\#define HAVE_LIBINPUT_SWITCH_KEYPAD_SLIDE 1
        \\#define HAVE_XCB_ERRORS 0
        \\#define HAVE_EGL 1
        \\#define HAVE_LIBLIFTOFF 0
        \\#define ICONDIR "/usr/share/icons"
        \\
    );

    const lib = common.library(b, "wlroots", o);
    const m = lib.root_module;

    // protocols: server headers into the generated include dir, private code compiled in
    for (own_protocols) |name| {
        const xml: common.Xml = .{ .file = dep.path(b.fmt("protocol/{s}.xml", .{name})) };
        _ = gen.addCopyFile(common.scan(b, "server-header", xml, "h"), b.fmt("{s}-protocol.h", .{name}));
        m.addCSourceFile(.{ .file = common.scan(b, "private-code", xml, b.fmt("{s}-protocol.c", .{name})), .flags = &.{"-std=c11"} });
    }
    for (system_protocols) |rel| {
        const name = std.fs.path.stem(rel);
        const xml: common.Xml = .{ .system = rel };
        _ = gen.addCopyFile(common.scan(b, "server-header", xml, "h"), b.fmt("{s}-protocol.h", .{name}));
        m.addCSourceFile(.{ .file = common.scan(b, "private-code", xml, b.fmt("{s}-protocol.c", .{name})), .flags = &.{"-std=c11"} });
    }
    // GLES2 shaders become C arrays (render/gles2/shaders/embed.sh)
    for (shaders) |sh| {
        const r = b.addSystemCommand(&.{ "sh", "-eu" });
        r.addFileArg(dep.path("render/gles2/shaders/embed.sh"));
        const var_name = b.allocator.dupe(u8, sh) catch @panic("oom");
        std.mem.replaceScalar(u8, var_name, '.', '_');
        r.addArg(b.fmt("{s}_src", .{var_name}));
        r.setStdIn(.{ .lazy_path = dep.path(b.fmt("render/gles2/shaders/{s}", .{sh})) });
        _ = gen.addCopyFile(r.captureStdOut(.{}), b.fmt("{s}_src.h", .{var_name}));
    }
    // PNP vendor names for monitors (hwdata's pnp.ids, as the DRM backend's meson.build does)
    const pnp = b.addSystemCommand(&.{ "sh", "-c", "exec sh \"$1\" < \"$(pkg-config --variable=pkgdatadir hwdata)/pnp.ids\"", "sh" });
    pnp.addFileArg(dep.path("backend/drm/gen_pnpids.sh"));
    m.addCSourceFile(.{ .file = pnp.captureStdOut(.{ .basename = "pnpids.c" }), .flags = &.{"-std=c11"} });

    const flags = common.cflags(b, o.target, &.{
        "-std=c11",
        "-D_POSIX_C_SOURCE=200809L",
        "-DWLR_USE_UNSTABLE",
        "-DWLR_PRIVATE=",
        "-DWLR_LITTLE_ENDIAN=1",
        "-DWLR_BIG_ENDIAN=0",
        common.prefixMap(b, dep),
    });
    m.addCSourceFiles(.{ .root = dep.path(""), .files = &sources, .flags = flags });
    // the nested Wayland backend is not built; backend.c only asks for it when nested
    m.addCSourceFile(.{ .file = stub, .flags = flags });
    m.addIncludePath(gen.getDirectory());
    m.addIncludePath(dep.path("include"));
    m.addIncludePath(libinput_inc);
    m.addIncludePath(libseat_inc);
    common.pkgIncludes(b, &.{ "libdrm", "pixman-1", "wayland-server", "xkbcommon", "egl", "glesv2", "gbm", "libudev", "libdisplay-info" }, m, null);
    for ([_][]const u8{ "wayland-server", "xkbcommon", "libdrm", "gbm", "egl", "glesv2", "pixman-1", "libudev", "libdisplay-info" }) |l|
        m.linkSystemLibrary(l, .{});
    return .{ .lib = lib, .gen = gen.getDirectory(), .include = dep.path("include") };
}
