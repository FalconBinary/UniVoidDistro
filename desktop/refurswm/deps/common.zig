// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! What the C dependencies built from source share: hardening flags, wayland-scanner, pkg-config.
const std = @import("std");
const LazyPath = std.Build.LazyPath;

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// UBSan in trap mode for the C code: a debugging aid, off in normal builds (an upstream
    /// harmless UB would otherwise end the session)
    ubsan: bool = false,
};

/// A static C library module: PIC (the binary is PIE), stack protector, no UBSan unless asked.
pub fn library(b: *std.Build, name: []const u8, o: Options) *std.Build.Step.Compile {
    return b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = o.target,
            .optimize = o.optimize,
            .link_libc = true,
            .pic = true,
            .stack_protector = true,
            .sanitize_c = if (o.ubsan) .trap else .off,
        }),
    });
}

/// Hardening for C code: bounds-checked libc calls where sizes are known (Zig defines level 2 for
/// release builds with glibc; level 3 also covers dynamic sizes), stack clash probes,
/// zeroed locals (no stale stack data leaks), control-flow protection, and one section per
/// function and object so the linker can drop everything RefursWM does not use.
pub fn cflags(b: *std.Build, target: std.Build.ResolvedTarget, extra: []const []const u8) []const []const u8 {
    var l: std.ArrayList([]const u8) = .empty;
    l.appendSlice(b.allocator, &.{
        "-U_FORTIFY_SOURCE",
        "-D_FORTIFY_SOURCE=3",
        "-fstack-clash-protection",
        "-ftrivial-auto-var-init=zero",
        "-ffunction-sections",
        "-fdata-sections",
        "-fno-strict-aliasing",
        "-Wno-unused-parameter",
        "-Wno-missing-field-initializers",
        "-Wno-sign-compare",
    }) catch @panic("oom");
    switch (target.result.cpu.arch) {
        .x86_64 => l.append(b.allocator, "-fcf-protection=full") catch @panic("oom"),
        .aarch64 => l.append(b.allocator, "-mbranch-protection=standard") catch @panic("oom"),
        else => {},
    }
    l.appendSlice(b.allocator, extra) catch @panic("oom");
    return l.items;
}

/// __FILE__ (log messages, assertions) relative to the package: no build path, and with it no user
/// name, ends up in the binary.
pub fn prefixMap(b: *std.Build, dep: *std.Build.Dependency) []const u8 {
    return b.fmt("-fmacro-prefix-map={s}/=", .{dep.builder.root.root_dir.path orelse "."});
}

/// A protocol XML: a file in this repo or a dependency, or a path inside the wayland-protocols
/// data dir (looked up through pkg-config when the step runs, so nothing else needs the package).
pub const Xml = union(enum) { file: LazyPath, system: []const u8 };

pub fn scan(b: *std.Build, kind: []const u8, xml: Xml, out: []const u8) LazyPath {
    switch (xml) {
        .file => |p| {
            const r = b.addSystemCommand(&.{ "wayland-scanner", kind });
            r.addFileArg(p);
            return r.addOutputFileArg(out);
        },
        .system => |rel| {
            const r = b.addSystemCommand(&.{ "sh", "-c", "exec wayland-scanner \"$1\" \"$(pkg-config --variable=pkgdatadir wayland-protocols)/$2\" \"$3\"", "sh", kind, rel });
            return r.addOutputFileArg(out);
        },
    }
}

/// `pkg-config --cflags-only-I` of `pkgs` added to `mod` (and to `tc` if given), at configure time.
pub fn pkgIncludes(b: *std.Build, pkgs: []const []const u8, mod: ?*std.Build.Module, tc: ?*std.Build.Step.TranslateC) void {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(b.allocator, &.{ "pkg-config", "--cflags-only-I" }) catch @panic("oom");
    argv.appendSlice(b.allocator, pkgs) catch @panic("oom");
    var it = std.mem.tokenizeAny(u8, b.run(argv.items), " \n");
    while (it.next()) |flag| if (std.mem.startsWith(u8, flag, "-I")) {
        const p: LazyPath = .{ .cwd_relative = flag[2..] };
        if (mod) |m| m.addIncludePath(p);
        if (tc) |t| t.addIncludePath(p);
    };
}
