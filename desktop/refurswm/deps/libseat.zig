// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! libseat from seatd 0.9.3, static, with the seatd backend only (no logind: no libelogind and the
//! D-Bus stack behind it in the compositor). The noop backend stays for root sessions.
const std = @import("std");
const common = @import("common.zig");


pub fn build(b: *std.Build, dep: *std.Build.Dependency, o: common.Options) *std.Build.Step.Compile {
    const lib = common.library(b, "seat", o);
    const m = lib.root_module;
    m.addIncludePath(dep.path(""));
    m.addIncludePath(dep.path("include"));
    m.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &.{
            "libseat/libseat.c",
            "libseat/backend/noop.c",
            "libseat/backend/seatd.c",
            "common/connection.c",
            "common/linked_list.c",
            "common/log.c",
        },
        .flags = common.cflags(b, o.target, &.{
            "-std=c11",
            "-D_XOPEN_SOURCE=700",
            "-DSEATD_VERSION=\"0.9.3\"",
            "-DSEATD_DEFAULTPATH=\"/run/seatd.sock\"",
            "-DSEATD_INSTALLPATH=\"/usr/bin/seatd\"",
            "-DREL_SRC_DIR=\"\"",
            "-DLIBSEAT=1",
            "-DSEATD_ENABLED=1",
            common.prefixMap(b, dep),
        }),
    });
    return lib;
}

pub fn include(dep: *std.Build.Dependency) std.Build.LazyPath {
    return dep.path("include");
}
