//! track K: vh-kconf, the kernel of this machine (kernel/README.md, docs/ROADMAP.md).
//!   zig build -Dtarget=x86_64-linux --prefix DIR   -- DIR/bin/vh-kconf (static PIE, ReleaseSafe)
//!   zig build test                                  -- the unit tests: build and run (Linux host)
//!   zig build tests --prefix DIR                    -- the unit tests into DIR/test, not run
//!                                                      (tests/kernel/run.sh runs them in a container)
//! The shared code comes from ../zig/lib/vh.zig, read in place: a track never edits it.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux } });
    // ReleaseSafe by default (zig/README.md): bounds, overflow and null checks stay in the program
    const optimize = b.option(std.builtin.Optimize, "optimize", "build mode (safe = ReleaseSafe)") orelse .safe;

    const vh = b.createModule(.{ .root_source_file = b.path("../zig/lib/vh.zig"), .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .omit_frame_pointer = false,
        .strip = true,
    });
    mod.addImport("vh", vh);
    const exe = b.addExecutable(.{ .name = "vh-kconf", .root_module = mod });
    exe.pie = true;
    exe.link_z_relro = true; // full RELRO: relro + now
    exe.link_z_lazy = false;
    b.installArtifact(exe);

    const test_step = b.step("test", "unit tests: build and run");
    const tests_step = b.step("tests", "unit tests: build only, into PREFIX/test");
    const t = b.addTest(.{ .name = "vh-kconf", .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(t).step);
    tests_step.dependOn(&b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
}
