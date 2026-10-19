//! zig/lib/input.zig: the input devices built into the machine, by what sysfs shows of each
//! (docs/uni/runtime.md, "Built-in input"). vh-acpid's idle watchdog counts the input of these
//! devices only, and vh-deadman's alarm combination listens to their keys only: a keyboard
//! plugged in from outside and a virtual device (uinput) never count.
const std = @import("std");
const mem = std.mem;

/// Is the input device with this phys and this real sysfs path built into the machine: on the
/// PS/2 controller (i8042, by its phys), on I2C away from USB (by its path), or at one of the
/// places the installer named from the probe (INTERNAL_INPUT in /etc/vh/acpi.conf: parts of the
/// real path, the built-in keyboards on internal USB, SPI or the host bus). Never a virtual
/// device.
pub fn isBuiltin(phys: []const u8, real: []const u8, places: []const []const u8) bool {
    if (mem.indexOf(u8, real, "/virtual/") != null) return false; // uinput and the like: not physical input
    if (mem.startsWith(u8, phys, "isa0060/serio")) return true;
    if (mem.indexOf(u8, real, "/i2c-") != null and mem.indexOf(u8, real, "/usb") == null) return true;
    for (places) |p| if (p.len > 0 and mem.indexOf(u8, real, p) != null) return true;
    return false;
}

/// Does an input device report this key: its sysfs capabilities/key is the kernel's bitmap as
/// hexadecimal words, the highest first, the leading zero words left out. A word is 64 bits:
/// the kernel is 64-bit on both architectures of the distribution.
pub fn hasKey(bitmap: []const u8, code: u16) bool {
    var words = mem.splitBackwardsScalar(u8, mem.trim(u8, bitmap, " \n"), ' ');
    var i: usize = 0;
    while (words.next()) |w| : (i += 1) {
        if (i < code / 64) continue;
        const bits = std.fmt.parseUnsigned(u64, w, 16) catch return false;
        return bits & (@as(u64, 1) << @intCast(code % 64)) != 0;
    }
    return false;
}

test "isBuiltin: PS/2, I2C and the places of the probe; never USB from outside or uinput" {
    const none: []const []const u8 = &.{};
    try std.testing.expect(isBuiltin("isa0060/serio0/input0", "/sys/devices/platform/i8042/serio0/input/input0", none));
    // the touchpad on the PS/2 controller's other port is built in too
    try std.testing.expect(isBuiltin("isa0060/serio1/input0", "/sys/devices/platform/i8042/serio1/input/input4", none));
    try std.testing.expect(isBuiltin("i2c-XYZ0001:00", "/sys/devices/pci0000:00/0000:00:15.0/i2c_designware.0/i2c-0/i2c-XYZ0001:00/0018:1234:5678.0001/input/input7", none));
    // I2C behind a USB bridge is on USB, not built in
    try std.testing.expect(!isBuiltin("", "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-2/1-2:1.0/0003:1234:5678.0002/i2c-5/5-0020/input/input9", none));
    // uinput may claim any phys
    try std.testing.expect(!isBuiltin("isa0060/serio0", "/sys/devices/virtual/input/input12", none));
    const usb = "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-8/1-8:1.0/0003:1234:5678.0003/input/input5";
    const external = "/sys/devices/pci0000:00/0000:00:14.0/usb1/1-2/1-2:1.0/0003:1234:5678.0004/input/input6";
    try std.testing.expect(!isBuiltin("usb-0000:00:14.0-8/input0", usb, none));
    const places: []const []const u8 = &.{ "/pci0000:00/0000:00:14.0/usb1/1-8/", "/pci0000:00/0000:00:1e.3/pxa2xx-spi.3/spi_master/spi2/spi-XYZ0002:00/" };
    try std.testing.expect(isBuiltin("usb-0000:00:14.0-8/input0", usb, places));
    try std.testing.expect(!isBuiltin("usb-0000:00:14.0-2/input0", external, places));
    try std.testing.expect(isBuiltin("", "/sys/devices/pci0000:00/0000:00:1e.3/pxa2xx-spi.3/spi_master/spi2/spi-XYZ0002:00/input/input3", places));
    try std.testing.expect(!isBuiltin("", "/sys/devices/virtual/input/input13", places));
    // an empty place names nothing
    try std.testing.expect(!isBuiltin("usb-0000:00:14.0-2/input0", external, &.{""}));
}

test "hasKey: the words of capabilities/key, the lowest last" {
    const keyboard = "402000000 3803078f800d001 feffffdfffefffff fffffffffffffffe\n";
    try std.testing.expect(hasKey(keyboard, 1)); // KEY_ESC
    try std.testing.expect(hasKey(keyboard, 97) and hasKey(keyboard, 100) and hasKey(keyboard, 107)); // KEY_RIGHTCTRL, KEY_RIGHTALT, KEY_END
    try std.testing.expect(!hasKey(keyboard, 0) and !hasKey(keyboard, 84));
    try std.testing.expect(!hasKey(keyboard, 0x2ff)); // beyond the words written
    const touchpad = "e520 10000 0 0 0 0";
    try std.testing.expect(hasKey(touchpad, 0x110)); // BTN_LEFT
    try std.testing.expect(!hasKey(touchpad, 97) and !hasKey(touchpad, 107));
    try std.testing.expect(!hasKey("0", 97) and !hasKey("", 1) and !hasKey("zz 1", 64));
}
