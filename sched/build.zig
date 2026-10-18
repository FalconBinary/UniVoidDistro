//! sched/build.zig: track S, vh-sched.
//!   zig build -Dtarget=x86_64-linux --prefix DIR   -- DIR/bin/vh-sched (the loader, static PIE,
//!                                                     ReleaseSafe) and DIR/bpf/*.o (the BPF
//!                                                     programs: bpfel-freestanding, v3, ReleaseFast)
//!   zig build test                                  -- the unit tests (the loader and the new
//!                                                     zig/lib modules: bpf_uapi, btf, elf)
//!   zig build tests --prefix DIR                    -- the test binaries into DIR/test, not run
//! The BPF programs are built by the same Zig, no clang: one object per program, each
//! struct_ops callback in its own section.
const std = @import("std");

const bpf_programs = [_][]const u8{ "vh_sched", "tcp_ca_probe", "lockdown_probe" };
/// the shared modules from zig/lib (the tools package); bpf_uapi, btf and elf are track S's new files
const libs = [_][]const u8{ "vh", "bpf_uapi", "btf", "elf" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux } });
    const optimize = b.option(std.builtin.Optimize, "optimize", "build mode (safe = ReleaseSafe)") orelse .safe;
    const tools = b.dependency("tools", .{ .target = target, .optimize = optimize });

    var mods: [libs.len]*std.Build.Module = undefined;
    for (libs, 0..) |name, i|
        mods[i] = b.createModule(.{ .root_source_file = tools.path(b.fmt("lib/{s}.zig", .{name})), .target = target, .optimize = optimize });
    for (mods, 0..) |m, j| for (libs, 0..) |name, i| if (i != j) m.addImport(name, mods[i]);

    // the BPF programs: the types they share with the loader come from src/types.zig
    const bpf_target = b.resolveTargetQuery(.{ .cpu_arch = .bpfel, .os_tag = .freestanding, .cpu_model = .{ .explicit = &std.Target.bpf.cpu.v3 } });
    for (bpf_programs) |name| {
        const types = b.createModule(.{ .root_source_file = b.path("src/types.zig"), .target = bpf_target, .optimize = .fast });
        const m = b.createModule(.{ .root_source_file = b.path(b.fmt("bpf/{s}.zig", .{name})), .target = bpf_target, .optimize = .fast, .strip = true });
        m.addImport("types", types);
        const obj = b.addObject(.{ .name = name, .root_module = m });
        b.getInstallStep().dependOn(&b.addInstallFile(obj.getEmittedBin(), b.fmt("bpf/{s}.o", .{name})).step);
    }

    // the loader: static PIE, full RELRO, stripped, as every program of zig/
    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .pic = true, .omit_frame_pointer = false, .strip = true });
    for (libs, 0..) |name, i| exe_mod.addImport(name, mods[i]);
    const exe = b.addExecutable(.{ .name = "vh-sched", .root_module = exe_mod });
    exe.pie = true;
    exe.link_z_relro = true;
    exe.link_z_lazy = false;
    b.installArtifact(exe);

    // tests: the loader (with src/types.zig and loader.zig) and the three new lib modules
    const test_step = b.step("test", "unit tests: build and run");
    const tests_step = b.step("tests", "unit tests: build only, into PREFIX/test");
    const test_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    for (libs, 0..) |name, i| test_mod.addImport(name, mods[i]);
    const t = b.addTest(.{ .name = "vh-sched-test", .root_module = test_mod });
    test_step.dependOn(&b.addRunArtifact(t).step);
    tests_step.dependOn(&b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
    for (libs[1..]) |name| {
        const lm = b.createModule(.{ .root_source_file = tools.path(b.fmt("lib/{s}.zig", .{name})), .target = target, .optimize = optimize });
        const lt = b.addTest(.{ .name = b.fmt("lib-{s}-test", .{name}), .root_module = lm });
        test_step.dependOn(&b.addRunArtifact(lt).step);
        tests_step.dependOn(&b.addInstallArtifact(lt, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);
    }
}
