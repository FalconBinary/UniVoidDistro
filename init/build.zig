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
    // -Dstrip=false keeps the symbols: a ReleaseSafe panic then prints its stack trace (debugging in the container)
    const strip = b.option(bool, "strip", "strip the binaries (default true)") orelse true;

    const vh = b.createModule(.{ .root_source_file = b.path("../zig/lib/vh.zig"), .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/stage1.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .omit_frame_pointer = false,
        .strip = strip,
        .link_libc = false,
    });
    mod.addImport("vh", vh);

    const exe = b.addExecutable(.{ .name = "vh-stage1", .root_module = mod });
    exe.pie = true;
    exe.link_z_relro = true; // full RELRO: relro + now
    exe.link_z_lazy = false;
    b.installArtifact(exe);

    // v0.2: vh-init (PID 1 and the manager) and vh-ctl (the client, the sv shim), the same
    // sources as vh-stage1 plus src/{init,pid1,manager,...}.zig
    const roots = [_]struct { name: []const u8, file: []const u8 }{ .{ .name = "vh-init", .file = "src/init.zig" }, .{ .name = "vh-ctl", .file = "src/ctl.zig" } };
    var mods: [roots.len]*std.Build.Module = undefined;
    for (roots, 0..) |r, i| {
        const m = b.createModule(.{ .root_source_file = b.path(r.file), .target = target, .optimize = optimize, .pic = true, .omit_frame_pointer = false, .strip = strip, .link_libc = false });
        m.addImport("vh", vh);
        const e = b.addExecutable(.{ .name = r.name, .root_module = m });
        e.pie = true;
        e.link_z_relro = true;
        e.link_z_lazy = false;
        b.installArtifact(e);
        mods[i] = m;
    }

    const test_step = b.step("test", "unit tests: build and run");
    const tests_step = b.step("tests", "unit tests: build only, into PREFIX/test");
    const t = b.addTest(.{ .name = "vh-stage1", .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(t).step);
    tests_step.dependOn(&b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
    const ti = b.addTest(.{ .name = "vh-init", .root_module = mods[0] });
    test_step.dependOn(&b.addRunArtifact(ti).step);
    tests_step.dependOn(&b.addInstallArtifact(ti, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
}
