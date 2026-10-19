//! void-hardperf-light: the aggregator over every Zig component.
//!   zig build -Dtarget=x86_64-linux --prefix DIR   -- every program of every track into DIR
//!   zig build test                                  -- the unit tests of every component
//! Each track lives in its own directory with its own build.zig and is listed in
//! build.zig.zon as a path dependency. A track adds one line here and one line there;
//! nothing else in the root is shared, so parallel tracks do not conflict.
//! thor is not here: it links against the libxbps built by thor/build.sh (-Dxbps-src).
const std = @import("std");

/// dependency names from build.zig.zon, in build order
const tracks = [_][]const u8{
    "tools", // zig/: the system tools and zig/lib
    "kernel", // track K: vh-kconf
    "init", // init/: vh-stage1 (track I: vh-init, vh-ctl, vh-logd)
    "sched", // track S: vh-sched (the loader; the BPF objects are built inside sched/ by the same Zig)
    // "installer", track N: vh-install
    // "session",   track G: vh-root, vh-game
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux } });
    // ReleaseSafe by default, as in every component (zig/README.md)
    const optimize = b.option(std.builtin.Optimize, "optimize", "build mode (safe = ReleaseSafe)") orelse .safe;

    // [VERIFY] `zig build test` (the build runner driving the test binaries) hangs with the
    // zig/ tests (killed after 15 min in the Void container, 2026-10-19); the binaries pass when
    // run directly. CI and tests/zig/run.sh therefore build them with `tests` and run them.
    const test_step = b.step("test", "unit tests of every component: build and run");
    const tests_step = b.step("tests", "unit tests of every component: build only, into PREFIX/test");
    for (tracks) |name| {
        const dep = b.dependency(name, .{ .target = target, .optimize = optimize });
        // whatever the component installs, the aggregator installs under the same prefix
        b.getInstallStep().dependOn(dep.builder.getInstallStep());
        if (dep.builder.top_level_steps.get("test")) |t| test_step.dependOn(&t.step);
        if (dep.builder.top_level_steps.get("tests")) |t| tests_step.dependOn(&t.step);
    }
}
