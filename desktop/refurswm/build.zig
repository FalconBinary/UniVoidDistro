// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zig build                    - ReleaseSafe; wlroots, libinput and libseat built from pinned
//!                                sources (build.zig.zon) for Wayland only and linked statically
//! zig build -Dsystem-libs=true - the distribution's shared wlroots/libinput/libseat instead
//! zig build test               - unit tests (pure Zig, run on any host)
//! zig build evil               - hostile test client for tests/security.sh (Linux)
//! zig build sandbox-test       - the compositor's sandbox applied to a test program (Linux)
//! zig build --prefix ~/.local  - install to ~/.local/bin/refurswm (+ share/refurswm/libinput)
const std = @import("std");
const common = @import("deps/common.zig");
const wlroots = @import("deps/wlroots.zig");
const libinput = @import("deps/libinput.zig");
const libseat = @import("deps/libseat.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "build mode (default safe = ReleaseSafe)") orelse .safe;
    const system_libs = b.option(bool, "system-libs", "use the distribution's shared wlroots, libinput and libseat") orelse false;
    const ubsan = b.option(bool, "c-ubsan", "UBSan (trap) in the C dependencies, for debugging") orelse false;

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "unit tests").dependOn(&b.addRunArtifact(tests).step);

    // everything below links Linux libraries
    if (target.result.os.tag != .linux) return;

    const opts = b.addOptions();
    // test builds only: privileged protocols for every unsandboxed client (grim/wtype in CI)
    opts.addOption(bool, "testing", b.option(bool, "testing", "privileged protocols for all unsandboxed clients (tests)") orelse false);

    const tc = b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .single_threaded = true,
        .pic = true,
        .strip = optimize != .debug,
        .stack_protector = true,
    });
    for ([_][]const u8{ "wayland-server", "xkbcommon" }) |lib| mod.linkSystemLibrary(lib, .{});
    // refurs-shell, the bar's protocol (src/shell.zig)
    const shell_xml: common.Xml = .{ .file = b.path("protocol/refurs-shell-unstable-v1.xml") };
    tc.addIncludePath(common.scan(b, "server-header", shell_xml, "refurs-shell-unstable-v1-protocol.h").dirname());
    mod.addCSourceFile(.{ .file = common.scan(b, "private-code", shell_xml, "refurs-shell-unstable-v1-protocol.c") });

    if (system_libs) {
        // wlr_layer_shell_v1.h includes this generated server header
        const layer_h = common.scan(b, "server-header", .{ .file = b.path("protocol/wlr-layer-shell-unstable-v1.xml") }, "wlr-layer-shell-unstable-v1-protocol.h");
        tc.addIncludePath(layer_h.dirname());
        common.pkgIncludes(b, &.{ "wlroots-0.20", "wayland-server", "xkbcommon", "libinput", "pixman-1" }, null, tc);
        for ([_][]const u8{ "wlroots-0.20", "libinput" }) |lib| mod.linkSystemLibrary(lib, .{});
        opts.addOption(bool, "bundled_quirks", false);
    } else {
        const wlr_dep = b.lazyDependency("wlroots", .{}) orelse return;
        const li_dep = b.lazyDependency("libinput", .{}) orelse return;
        const seat_dep = b.lazyDependency("seatd", .{}) orelse return;
        const co: common.Options = .{ .target = target, .optimize = optimize, .ubsan = ubsan };
        const li = libinput.build(b, li_dep, co);
        const seat = libseat.build(b, seat_dep, co);
        const wlr = wlroots.build(b, wlr_dep, co, libinput.include(li_dep), libseat.include(seat_dep), b.path("deps/wlr_nested_stub.c"));
        libinput.installQuirks(b, li_dep);
        for ([_]std.Build.LazyPath{ wlr.gen, wlr.include, libinput.include(li_dep), libseat.include(seat_dep) }) |p| tc.addIncludePath(p);
        common.pkgIncludes(b, &.{ "wayland-server", "xkbcommon", "pixman-1", "libdrm" }, null, tc);
        mod.linkLibrary(wlr.lib);
        mod.linkLibrary(li);
        mod.linkLibrary(seat);
        opts.addOption(bool, "bundled_quirks", true);
    }
    mod.addImport("c", tc.createModule());
    mod.addOptions("build_options", opts);

    const exe = b.addExecutable(.{ .name = "refurswm", .root_module = mod });
    // hardened binary: PIE + full RELRO + immediate binding; unused code of the static libraries goes
    exe.pie = true;
    exe.link_z_relro = true;
    exe.link_z_lazy = false;
    exe.link_gc_sections = true;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "run refurswm").dependOn(&run.step);

    evil(b, target, optimize);

    // the compositor's sandbox applied to a test program (tests/security.sh)
    const st_mod = b.createModule(.{
        .root_source_file = b.path("tests/sandbox_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    st_mod.addImport("landlock", b.createModule(.{ .root_source_file = b.path("src/landlock.zig"), .target = target, .optimize = optimize, .link_libc = true }));
    st_mod.addImport("seccomp", b.createModule(.{ .root_source_file = b.path("src/seccomp.zig"), .target = target, .optimize = optimize }));
    const st = b.addExecutable(.{ .name = "refurs-sandbox-test", .root_module = st_mod });
    b.step("sandbox-test", "build the sandbox test program").dependOn(&b.addInstallArtifact(st, .{}).step);
}

/// tests/evil: a hostile Wayland client used by tests/security.sh and tests/bench.sh.
fn evil(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const protos = [_]struct { name: []const u8, xml: common.Xml }{
        .{ .name = "xdg-shell", .xml = .{ .system = "stable/xdg-shell/xdg-shell.xml" } },
        .{ .name = "xdg-activation-v1", .xml = .{ .system = "staging/xdg-activation/xdg-activation-v1.xml" } },
        .{ .name = "idle-inhibit-unstable-v1", .xml = .{ .system = "unstable/idle-inhibit/idle-inhibit-unstable-v1.xml" } },
        .{ .name = "wlr-layer-shell-unstable-v1", .xml = .{ .file = b.path("protocol/wlr-layer-shell-unstable-v1.xml") } },
        .{ .name = "virtual-keyboard-unstable-v1", .xml = .{ .file = b.path("tests/evil/protocol/virtual-keyboard-unstable-v1.xml") } },
        .{ .name = "wlr-virtual-pointer-unstable-v1", .xml = .{ .file = b.path("tests/evil/protocol/wlr-virtual-pointer-unstable-v1.xml") } },
    };
    const tc = b.addTranslateC(.{ .root_source_file = b.path("tests/evil/c.h"), .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("tests/evil/evil.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (protos) |p| {
        const h = common.scan(b, "client-header", p.xml, b.fmt("{s}-client-protocol.h", .{p.name}));
        tc.addIncludePath(h.dirname());
        mod.addCSourceFile(.{ .file = common.scan(b, "private-code", p.xml, b.fmt("{s}-protocol.c", .{p.name})) });
    }
    mod.addImport("c", tc.createModule());
    mod.linkSystemLibrary("wayland-client", .{});
    const exe = b.addExecutable(.{ .name = "evil", .root_module = mod });
    b.step("evil", "build the hostile test client (tests/evil)").dependOn(&b.addInstallArtifact(exe, .{}).step);
}
