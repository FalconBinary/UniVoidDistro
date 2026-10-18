const std = @import("std");
const vh = @import("vh");
pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "vh-kconf");
    vh.out("{d}\n", .{args.len});
    vh.flush();
}
