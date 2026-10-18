//! vh-stage1: 02-udev.sh. eudev is unavoidable (the device manager itself): udevd,
//! udevadm trigger and udevadm settle are run by argv, never through a shell. Three
//! steps, so the kmsg summary shows the cost of each (the settle is the long one).
const vh = @import("vh");
const sys = @import("sys.zig");

var udevd: ?[]const u8 = null;

pub fn start() void {
    if (vh.pathExists("/usr/lib/systemd/systemd-udevd")) {
        udevd = "/usr/lib/systemd/systemd-udevd";
    } else if (sys.inPath("udevd")) {
        udevd = "udevd";
    } else {
        sys.warn("cannot find udevd!", .{});
        return;
    }
    sys.msg("Starting udev and waiting for devices to settle...", .{});
    const rc = sys.exec(&.{ udevd.?, "--daemon" });
    if (rc != 0) {
        sys.fail("udevd --daemon returned {d}", .{rc});
        udevd = null;
    }
}

pub fn trigger() void {
    if (udevd == null) return;
    if (sys.exec(&.{ "udevadm", "trigger", "--action=add", "--type=subsystems" }) != 0) sys.fail("udevadm trigger --type=subsystems failed", .{});
    if (sys.exec(&.{ "udevadm", "trigger", "--action=add", "--type=devices" }) != 0) sys.fail("udevadm trigger --type=devices failed", .{});
}

pub fn settle() void {
    if (udevd == null) return;
    if (sys.exec(&.{ "udevadm", "settle" }) != 0) sys.fail("udevadm settle failed", .{});
}
