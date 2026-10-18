// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! zig build                       — ReleaseSafe (проверки границ на месте), один статический
//!                                   бинарник без libc: zig-out/bin/refursline
//! zig build -Doptimize=fast       — без проверок времени выполнения (быстрее, но не безопаснее)
//! zig build -Dtrace=true          — с замерами: REFURSLINE_TRACE=1 печатает пробуждения и кадры
//! zig build test                  — модульные тесты (на любой машине)
//! zig build --prefix /usr/local   — установка в /usr/local/bin/refursline (путь из grant RefursWM)
//! Цель как обычно: -Dtarget=x86_64-linux, -Dcpu=x86_64_v3 (AVX2 для SIMD) и т. п.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.Optimize, "optimize", "режим сборки (по умолчанию safe = ReleaseSafe)") orelse .safe;
    const release = optimize != .debug;
    const trace = b.option(bool, "trace", "замеры: REFURSLINE_TRACE=1 печатает пробуждения и время кадров") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "trace", trace);

    // протоколы Wayland → Zig: генератор собирается и работает на машине сборки
    const scan = b.addExecutable(.{
        .name = "scan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/scan.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const run_scan = b.addRunArtifact(scan);
    const proto_zig = run_scan.addOutputFileArg("proto.zig");
    for ([_][]const u8{
        "protocol/wayland.xml",
        "protocol/wlr-layer-shell-unstable-v1.xml",
        "protocol/viewporter.xml",
        "protocol/fractional-scale-v1.xml",
        "protocol/cursor-shape-v1.xml",
        "protocol/single-pixel-buffer-v1.xml",
        "protocol/refurs-shell-unstable-v1.xml",
    }) |x| run_scan.addFileArg(b.path(x));

    const proto = b.createModule(.{ .root_source_file = proto_zig });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .single_threaded = true,
        // без отладочной информации и таблиц раскрутки: бинарник меньше
        .strip = if (release) true else null,
        .unwind_tables = if (release) .none else null,
    });
    mod.addImport("proto", proto);
    mod.addOptions("build_options", opts);
    const exe = b.addExecutable(.{ .name = "refursline", .root_module = mod });
    // PIE: адрес кода случайный при каждом запуске (ASLR) — по памяти не стоит ничего (замерено)
    exe.pie = b.option(bool, "pie", "position-independent executable (по умолчанию да)") orelse true;
    b.installArtifact(exe);

    const tmod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    tmod.addImport("proto", proto);
    tmod.addOptions("build_options", opts);
    const tests = b.addTest(.{ .root_module = tmod });
    b.step("test", "модульные тесты").dependOn(&b.addRunArtifact(tests).step);
}
