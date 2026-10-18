// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! libinput 1.31.3, static, without libwacom (and with it glib, gobject, pcre2) and without the Lua
//! plugin engine: tablets are not supported by RefursWM, and no interpreter runs in the compositor.
//! Device quirks of this very version are installed with RefursWM (<prefix>/share/refurswm/libinput)
//! and passed to libinput at start (sandbox.bundledQuirks), so nothing depends on the distribution's
//! libinput package. The compiled-in default below is the distribution's path.
const std = @import("std");
const common = @import("common.zig");


pub const quirks_subdir = "share/refurswm/libinput";

pub fn build(b: *std.Build, dep: *std.Build.Dependency, o: common.Options) *std.Build.Step.Compile {
    const gen = b.addWriteFiles();
    _ = gen.add("config.h",
        \\#define _GNU_SOURCE 1
        \\#define HTTP_DOC_LINK "https://wayland.freedesktop.org/libinput/doc/1.31.3"
        \\#define HAVE_VERSIONSORT 1
        \\#define HAVE_LOCALE_H 1
        \\#define HAVE_MTDEV 1
        \\#define LIBINPUT_QUIRKS_DIR "/usr/share/libinput"
        \\#define LIBINPUT_QUIRKS_OVERRIDE_FILE "/etc/libinput/local-overrides.quirks"
        \\#define LIBINPUT_QUIRKS_SRCDIR "/usr/share/libinput"
        \\#define LIBINPUT_PLUGIN_LIBDIR "/usr/lib/libinput/plugins"
        \\#define LIBINPUT_PLUGIN_ETCDIR "/etc/libinput/plugins"
        \\
    );
    _ = gen.add("libinput-version.h",
        \\#ifndef LIBINPUT_VERSION_H
        \\#define LIBINPUT_VERSION_H
        \\#define LIBINPUT_VERSION_MAJOR 1
        \\#define LIBINPUT_VERSION_MINOR 31
        \\#define LIBINPUT_VERSION_MICRO 3
        \\#define LIBINPUT_VERSION "1.31.3"
        \\#endif
        \\
    );

    const lib = common.library(b, "input", o);
    const m = lib.root_module;
    m.addIncludePath(gen.getDirectory());
    // "src/evdev-frame.h": the package root is an include dir too
    m.addIncludePath(dep.path(""));
    m.addIncludePath(dep.path("include"));
    m.addIncludePath(dep.path("src"));
    m.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = &.{
            "util-files.c",                          "util-list.c",
            "util-ratelimit.c",                      "util-strings.c",
            "util-prop-parsers.c",                   "filter.c",
            "filter-custom.c",                       "filter-flat.c",
            "filter-low-dpi.c",                      "filter-mouse.c",
            "filter-touchpad.c",                     "filter-touchpad-flat.c",
            "filter-touchpad-x230.c",                "filter-tablet.c",
            "filter-trackpoint.c",                   "filter-trackpoint-flat.c",
            "quirks.c",                              "libinput.c",
            "libinput-plugin.c",                     "libinput-plugin-button-debounce.c",
            "libinput-plugin-mouse-wheel.c",         "libinput-plugin-mouse-wheel-lowres.c",
            "libinput-plugin-tablet-double-tool.c",  "libinput-plugin-tablet-eraser-button.c",
            "libinput-plugin-tablet-forced-tool.c",  "libinput-plugin-tablet-proximity-timer.c",
            "libinput-private-config.c",             "evdev.c",
            "evdev-fallback.c",                      "evdev-plugin.c",
            "evdev-totem.c",                         "evdev-middle-button.c",
            "evdev-mt-touchpad.c",                   "evdev-mt-touchpad-tap.c",
            "evdev-mt-touchpad-thumb.c",             "evdev-mt-touchpad-buttons.c",
            "evdev-mt-touchpad-edge-scroll.c",       "evdev-mt-touchpad-gestures.c",
            "evdev-tablet.c",                        "evdev-tablet-pad.c",
            "evdev-tablet-pad-leds.c",               "path-seat.c",
            "udev-seat.c",                           "timer.c",
            "util-libinput.c",                       "libinput-plugin-mtdev.c",
        },
        .flags = common.cflags(b, o.target, &.{ "-std=gnu99", common.prefixMap(b, dep) }),
    });
    common.pkgIncludes(b, &.{"libevdev"}, m, null);
    for ([_][]const u8{ "udev", "libevdev", "mtdev" }) |l| m.linkSystemLibrary(l, .{});
    return lib;
}

/// The device quirks (keyboards, touchpads, ...) next to the binary.
pub fn installQuirks(b: *std.Build, dep: *std.Build.Dependency) void {
    b.installDirectory(.{
        .source_dir = dep.path("quirks"),
        .install_dir = .prefix,
        .install_subdir = quirks_subdir,
        .exclude_extensions = &.{".md"},
    });
}

pub fn include(dep: *std.Build.Dependency) std.Build.LazyPath {
    return dep.path("src");
}
