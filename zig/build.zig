//! void-hardperf-light: building the Zig tools (zig/README.md).
//!   zig build -Dtarget=x86_64-linux --prefix DIR   -- every program into DIR/bin
//!   zig build tests -Dtarget=... --prefix DIR       -- the unit tests into DIR/test (not run)
//! The default mode is ReleaseSafe: bounds, overflow and null checks stay in the program.
//! Programs without libc are static PIEs (they do not need the system's glibc).
const std = @import("std");

/// shared modules: name -> lib/NAME.zig
const libs = [_][]const u8{ "vh", "hash", "seccomp" };

/// programs: tools/NAME.zig; libc lists the system libraries a program needs (OpenSSL, libxcrypt)
const Tool = struct { name: []const u8, libc: []const []const u8 = &.{} };
const tools = [_]Tool{
    .{ .name = "vh-seccomp" },
    .{ .name = "vh-pkg" },
    .{ .name = "vh-deep-clean" },
    .{ .name = "vh-usb-udev" },
    .{ .name = "vh-open" },
    .{ .name = "vh-limine-update" },
    .{ .name = "vh-uki-verify" },
    .{ .name = "vh-acpid" },
    .{ .name = "vh-deadman" },
    .{ .name = "vh-wlfilter" },
    .{ .name = "pin-fetch", .libc = &.{ "ssl", "crypto" } },
    .{ .name = "vh-hashpw", .libc = &.{"crypt"} },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux } });
    // ReleaseSafe by default (not Debug): bounds and overflow checks plus optimisation
    const optimize = b.option(std.builtin.Optimize, "optimize", "build mode (safe = ReleaseSafe)") orelse .safe;
    // programs on system libraries (OpenSSL, libxcrypt) only where their headers and
    // libraries exist: in the live environment and the test container, not on a developer machine
    const libc_tools = b.option(bool, "libc-tools", "build pin-fetch and vh-hashpw (need openssl-devel, libxcrypt-devel)") orelse false;

    var mods: [libs.len]*std.Build.Module = undefined;
    for (libs, 0..) |name, i|
        mods[i] = b.createModule(.{ .root_source_file = b.path(b.fmt("lib/{s}.zig", .{name})), .target = target, .optimize = optimize });
    for (mods, 0..) |m, j| for (libs, 0..) |name, i| if (i != j) m.addImport(name, mods[i]);

    const test_step = b.step("test", "unit tests: build and run");
    const tests_step = b.step("tests", "unit tests: build only (tests/zig/run.sh runs them in a container)");

    for (tools) |t| {
        if (t.libc.len > 0 and !libc_tools) continue;
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/{s}.zig", .{t.name})),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .omit_frame_pointer = false,
            .strip = true,
            .link_libc = t.libc.len > 0,
        });
        for (libs, 0..) |name, i| mod.addImport(name, mods[i]);
        for (t.libc) |l| mod.linkSystemLibrary(l, .{ .use_pkg_config = .no });
        const exe = b.addExecutable(.{ .name = t.name, .root_module = mod });
        exe.pie = true;
        exe.link_z_relro = true; // full RELRO: relro + now
        exe.link_z_lazy = false;
        b.installArtifact(exe);
        addTest(b, mod, t.name, test_step, tests_step);
    }
    for (libs, 0..) |name, i| addTest(b, mods[i], name, test_step, tests_step);
}

fn addTest(b: *std.Build, mod: *std.Build.Module, name: []const u8, run: *std.Build.Step, only: *std.Build.Step) void {
    const t = b.addTest(.{ .name = name, .root_module = mod });
    run.dependOn(&b.addRunArtifact(t).step);
    only.dependOn(&b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
}
