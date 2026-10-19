//! track A: vh-plan, the plan of this machine (docs/uni/ROADMAP.md, hwdb/README.md).
//!   zig build -Dtarget=x86_64-linux --prefix DIR   -- DIR/bin/vh-plan (static PIE, ReleaseSafe)
//!   zig build test                                  -- the unit tests: build and run (Linux host)
//!   zig build tests --prefix DIR                    -- the unit tests into DIR/test, not run
//!                                                      (tests/adapt/run.sh runs them in a container)
//! The shared code is read in place, never edited: ../zig/lib/vh.zig, and the hw.zon schema and
//! the modalias tables of track K (../kernel/src/hw.zig, ../kernel/src/alias.zig).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux } });
    // ReleaseSafe by default (zig/README.md): bounds, overflow and null checks stay in the program
    const optimize = b.option(std.builtin.Optimize, "optimize", "build mode (safe = ReleaseSafe)") orelse .safe;

    const vh = b.createModule(.{ .root_source_file = b.path("../zig/lib/vh.zig"), .target = target, .optimize = optimize });
    const hw = b.createModule(.{ .root_source_file = b.path("../kernel/src/hw.zig"), .target = target, .optimize = optimize });
    hw.addImport("vh", vh);
    const alias = b.createModule(.{ .root_source_file = b.path("../kernel/src/alias.zig"), .target = target, .optimize = optimize });
    alias.addImport("vh", vh);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .omit_frame_pointer = false,
        .strip = true,
    });
    mod.addImport("vh", vh);
    mod.addImport("hw", hw);
    mod.addImport("alias", alias);
    const exe = b.addExecutable(.{ .name = "vh-plan", .root_module = mod });
    exe.pie = true;
    exe.link_z_relro = true; // full RELRO: relro + now
    exe.link_z_lazy = false;
    b.installArtifact(exe);

    const test_step = b.step("test", "unit tests: build and run");
    const tests_step = b.step("tests", "unit tests: build only, into PREFIX/test");
    const t = b.addTest(.{ .name = "vh-plan", .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(t).step);
    tests_step.dependOn(&b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
}
