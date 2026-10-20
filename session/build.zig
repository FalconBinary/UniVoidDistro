//! track G: vh-root, vh-game and vh-game-enter, the gaming session (session/README.md).
//!   zig build -Dtarget=x86_64-linux --prefix DIR   -- DIR/bin/{vh-root,vh-game,vh-game-enter}
//!   zig build test                                  -- the unit tests: build and run (Linux host)
//!   zig build tests --prefix DIR                    -- the unit tests into DIR/test, not run
//!                                                      (tests/session/run.sh runs them in a container)
//! Static PIEs without libc, ReleaseSafe, full RELRO, stripped (zig/README.md). The shared code
//! is read in place, never edited: ../zig/lib/vh.zig. The root profiles are compiled in
//! (profiles/*.zon).
const std = @import("std");

const programs = [_][2][]const u8{
    .{ "vh-root", "src/root.zig" },
    .{ "vh-game", "src/game.zig" },
    .{ "vh-game-enter", "src/enter.zig" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux } });
    // ReleaseSafe by default (zig/README.md): bounds, overflow and null checks stay in the program
    const optimize = b.option(std.builtin.Optimize, "optimize", "build mode (safe = ReleaseSafe)") orelse .safe;

    const vh = b.createModule(.{ .root_source_file = b.path("../zig/lib/vh.zig"), .target = target, .optimize = optimize });
    const profiles = b.createModule(.{ .root_source_file = b.path("profiles/profiles.zig"), .target = target, .optimize = optimize });

    for (programs) |p| {
        const mod = module(b, p[1], target, optimize, vh, profiles);
        const exe = b.addExecutable(.{ .name = p[0], .root_module = mod });
        exe.pie = true;
        exe.link_z_relro = true; // full RELRO: relro + now
        exe.link_z_lazy = false;
        b.installArtifact(exe);
    }

    const test_step = b.step("test", "unit tests: build and run");
    const tests_step = b.step("tests", "unit tests: build only, into PREFIX/test");
    const t = b.addTest(.{ .name = "vh-session", .root_module = module(b, "src/tests.zig", target, optimize, vh, profiles) });
    test_step.dependOn(&b.addRunArtifact(t).step);
    tests_step.dependOn(&b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
}

fn module(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, vh: *std.Build.Module, profiles: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .omit_frame_pointer = false,
        .strip = true,
        .link_libc = false,
    });
    mod.addImport("vh", vh);
    mod.addImport("profiles", profiles);
    return mod;
}
