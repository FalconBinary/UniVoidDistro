//! The hardware description of one machine, /etc/vh/hw.zon: vh-kconf probe writes it,
//! resolve reads it. A ZON document, readable by a person and by std.zon. It never carries
//! serial numbers, MAC addresses or UUIDs: it is committed under kernel/hw/ and travels to CI.
const std = @import("std");
const vh = @import("vh");

pub const Device = struct {
    /// the sysfs bus: pci, usb, acpi, platform, hid, serio, hdaudio, cpu, dmi ...
    bus: []const u8,
    /// the entry name in /sys/bus/BUS/devices
    name: []const u8,
    modalias: []const u8,
    /// the bound driver, "" when the device has none
    driver: []const u8 = "",
    /// the module that owns the driver (loadable or built in), "" when sysfs does not say
    module: []const u8 = "",
};

pub const Cache = struct {
    level: u32 = 0,
    /// Data, Instruction, Unified
    kind: []const u8 = "",
    size_kb: u32 = 0,
    /// the CPUs sharing it, as sysfs lists them ("0-11", "0,6")
    shared: []const u8 = "",
};

pub const Cpu = struct {
    vendor: []const u8 = "",
    family: u32 = 0,
    model: u32 = 0,
    stepping: u32 = 0,
    model_name: []const u8 = "",
    microcode: []const u8 = "",
    /// physical cores and logical CPUs present
    cores: u32 = 0,
    threads: u32 = 0,
    smt: bool = false,
    /// the flags line of /proc/cpuinfo
    flags: []const u8 = "",
    caches: []const Cache = &.{},
};

/// DMI strings; the serial numbers and the UUID are deliberately not read
pub const Machine = struct {
    sys_vendor: []const u8 = "",
    product_name: []const u8 = "",
    product_family: []const u8 = "",
    product_version: []const u8 = "",
    board_vendor: []const u8 = "",
    board_name: []const u8 = "",
    bios_vendor: []const u8 = "",
    bios_version: []const u8 = "",
    bios_date: []const u8 = "",
    chassis_type: []const u8 = "",
};

pub const Firmware = struct {
    efi: bool = false,
    efi_bits: u32 = 0,
    /// null when the SecureBoot variable could not be read
    secure_boot: ?bool = null,
    tpm: bool = false,
    tpm_version: u32 = 0,
    tpm_driver: []const u8 = "",
};

pub const Probe = struct {
    format: u32 = 1,
    tool: []const u8 = "vh-kconf",
    /// the kernel the probe ran under (uname -r): the modules.alias to use with this file
    kernel: []const u8 = "",
    /// "live" or the snapshot directory the file was made from
    source: []const u8 = "live",
};

pub const Hw = struct {
    probe: Probe = .{},
    machine: Machine = .{},
    cpu: Cpu = .{},
    firmware: Firmware = .{},
    /// the file system types mounted at probe time, sorted
    filesystems: []const []const u8 = &.{},
    /// the loaded modules (/proc/modules), sorted
    modules: []const []const u8 = &.{},
    /// every device with a modalias, sorted by bus and name
    devices: []const Device = &.{},

    pub fn hasModule(self: *const Hw, name: []const u8) bool {
        for (self.modules) |m| if (vh.eql(m, name)) return true;
        return false;
    }
};

/// the ZON text, pretty-printed, with a final newline
pub fn render(hw: Hw) []u8 {
    var aw: std.Io.Writer.Allocating = .init(vh.gpa);
    std.zon.stringify.serialize(hw, .{}, &aw.writer) catch vh.oom();
    aw.writer.writeByte('\n') catch vh.oom();
    return aw.written();
}

/// parse a hw.zon text; `what` names it in error messages
pub fn parse(text: []const u8, what: []const u8) Hw {
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Hw, .{
        .gpa = vh.gpa,
        .arena = vh.gpa,
        .source = vh.z(text),
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => vh.oom(),
        error.ParseZon => vh.die("{f}", .{diag.fmt(what)}),
    };
}

pub fn load(path: []const u8) Hw {
    const text = vh.readFile(path) catch vh.die("{s}: {s}", .{ path, vh.serr() });
    return parse(text, path);
}

test "hw.zon round trip" {
    const caches = [_]Cache{.{ .level = 3, .kind = "Unified", .size_kb = 12288, .shared = "0-11" }};
    const devs = [_]Device{
        .{ .bus = "pci", .name = "0000:00:14.3", .modalias = "pci:v00008086d000006F0sv00008086sd00000034bc02sc80i00", .driver = "iwlwifi", .module = "iwlwifi" },
        .{ .bus = "usb", .name = "1-14:1.0", .modalias = "usb:v8087p0026d0002dcE0dsc01dp01icE0isc01ip01in00" },
    };
    const fs = [_][]const u8{ "xfs", "vfat" };
    const mods = [_][]const u8{ "iwlmvm", "iwlwifi" };
    const hw: Hw = .{
        .probe = .{ .kernel = "6.18.57_1" },
        .machine = .{ .sys_vendor = "Micro-Star International Co., Ltd.", .product_name = "GF63 Thin 10SCXR" },
        .cpu = .{ .vendor = "GenuineIntel", .family = 6, .model = 165, .cores = 6, .threads = 12, .smt = true, .caches = &caches },
        .firmware = .{ .efi = true, .efi_bits = 64, .secure_boot = true, .tpm = true, .tpm_version = 2, .tpm_driver = "tpm_crb" },
        .filesystems = &fs,
        .modules = &mods,
        .devices = &devs,
    };
    const text = render(hw);
    try std.testing.expect(std.mem.indexOf(u8, text, ".model = 165") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".secure_boot = true") != null);
    const back = parse(text, "test");
    try std.testing.expectEqualStrings("6.18.57_1", back.probe.kernel);
    try std.testing.expectEqual(@as(u32, 165), back.cpu.model);
    try std.testing.expectEqual(@as(usize, 2), back.devices.len);
    try std.testing.expectEqualStrings("iwlwifi", back.devices[0].module);
    try std.testing.expectEqualStrings("", back.devices[1].driver);
    try std.testing.expectEqual(@as(usize, 1), back.cpu.caches.len);
    try std.testing.expectEqual(@as(?bool, true), back.firmware.secure_boot);
    try std.testing.expect(back.hasModule("iwlmvm"));
    try std.testing.expect(!back.hasModule("nouveau"));
    // defaults for what the file does not say, unknown fields tolerated
    const minimal = parse(".{ .probe = .{ .kernel = \"x\" }, .future_field = 1 }", "test");
    try std.testing.expectEqual(@as(usize, 0), minimal.devices.len);
    try std.testing.expectEqual(@as(?bool, null), minimal.firmware.secure_boot);
}
