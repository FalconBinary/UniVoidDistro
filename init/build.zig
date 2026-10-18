//! void-hardperf-light, track I: vh-stage1 (init/README.md).
//!   zig build -Dtarget=x86_64-linux --prefix DIR   -- DIR/bin/vh-stage1
//!   zig build test                                  -- the unit tests, built and run
//!   zig build tests --prefix DIR                    -- the unit tests into DIR/test (not run)
//! ReleaseSafe by default; a static PIE without libc, full RELRO, stripped (zig/README.md).
//! The shared code comes from zig/lib (read only: no file there is edited by this track).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux } });
    const optimize = b.option(std.builtin.Optimize, "optimize", "build mode (safe = ReleaseSafe)") orelse .safe;

    const vh = b.createModule(.{ .root_source_file = b.path("../zig/lib/vh.zig"), .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/stage1.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .omit_frame_pointer = false,
        .strip = true,
        .link_libc = false,
    });
    mod.addImport("vh", vh);

    const exe = b.addExecutable(.{ .name = "vh-stage1", .root_module = mod });
    exe.pie = true;
    exe.link_z_relro = true; // full RELRO: relro + now
    exe.link_z_lazy = false;
    b.installArtifact(exe);

    const test_step = b.step("test", "unit tests: build and run");
    const tests_step = b.step("tests", "unit tests: build only, into PREFIX/test");
    const t = b.addTest(.{ .name = "vh-stage1", .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(t).step);
    tests_step.dependOn(&b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
}
