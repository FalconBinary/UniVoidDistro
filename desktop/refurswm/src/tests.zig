// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

//! `zig build test`: everything that runs without Wayland, on any host.
test {
    _ = @import("layout.zig");
    _ = @import("policy.zig");
    _ = @import("seccomp.zig");
    _ = @import("landlock.zig");
}
