//! thor: the thor command in Zig (docs/18). Built by thor/build.sh after xbps:
//!   zig build -Dxbps-src=XBPS_SOURCE_DIR --prefix DESTDIR/usr
//! Links against the libxbps from the same tree (with the thor policy inside).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe by default (not Debug): bounds and overflow checks plus optimisation
    const optimize = b.option(std.builtin.Optimize, "optimize", "build mode (safe = ReleaseSafe)") orelse .safe;
    const xbps_src = b.option([]const u8, "xbps-src", "the xbps sources after configure and make") orelse
        @panic("-Dxbps-src=DIR is required");

    const vh = b.createModule(.{ .root_source_file = b.path("../zig/lib/vh.zig"), .target = target, .optimize = optimize });
    const rules = b.createModule(.{ .root_source_file = b.path("policy/rules.zig"), .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/thor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
        .omit_frame_pointer = false,
        .strip = true, // no debug info: 4 MB -> ~1 MB; the ReleaseSafe checks stay
    });
    // the libxbps API: the header is translated into a Zig module (instead of @cImport in 0.17)
    const tc = b.addTranslateC(.{ .root_source_file = b.path("src/xbps_c.h"), .target = target, .optimize = optimize });
    tc.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{xbps_src}) });
    mod.addImport("c", tc.createModule());
    mod.addImport("vh", vh);
    mod.addImport("rules", rules);
    mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{xbps_src}) });
    mod.linkSystemLibrary("xbps", .{ .use_pkg_config = .no });
    // the libxbps with the policy comes from the program's own tree (live environment: DESTDIR/usr/lib; system: /usr/lib)
    mod.addRPath(.{ .cwd_relative = "$ORIGIN/../lib" });

    const exe = b.addExecutable(.{ .name = "thor", .root_module = mod });
    exe.pie = true;
    exe.link_z_relro = true;
    exe.link_z_lazy = false;
    b.installArtifact(exe);

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "unit tests").dependOn(&b.addRunArtifact(t).step);
}
