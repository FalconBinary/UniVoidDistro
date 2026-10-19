//! The schema of hwdb/*.zon and its loading. A file holds rules and, in security.zon,
//! the requirements of the security gate. Unknown fields are errors: a misspelt condition
//! must not silently match everything. The format is described in hwdb/README.md.
const std = @import("std");
const vh = @import("vh");

/// a device condition: one device of the machine must satisfy every field that is given
pub const DeviceMatch = struct {
    /// the sysfs bus: pci, usb, acpi, platform, hid, sdio, wmi, virtio, serio ...
    bus: []const []const u8 = &.{},
    /// PCI: the vendor and device as four hex digits, the class as a hex prefix ("03",
    /// "0300", "030000")
    pci_vendor: []const []const u8 = &.{},
    pci_device: []const []const u8 = &.{},
    pci_class: []const []const u8 = &.{},
    /// USB: the vendor, the product, the interface class as two hex digits ("e0" Bluetooth)
    usb_vendor: []const []const u8 = &.{},
    usb_product: []const []const u8 = &.{},
    usb_class: []const []const u8 = &.{},
    /// an ACPI id among those of the device ("PNP0C0D", "AMDI0030")
    acpi_id: []const []const u8 = &.{},
    /// a device tree compatible string of the device (glob)
    dt_compatible: []const []const u8 = &.{},
    /// the modalias as a glob
    modalias: []const []const u8 = &.{},
    /// the device's module: the one bound, or what the stock kernel's tables name for it (glob)
    module: []const []const u8 = &.{},
    /// the bound driver (glob)
    driver: []const []const u8 = &.{},
    /// a display controller that did (true) or did not (false) bring the console up
    boot_vga: ?bool = null,
};

/// a value of the user's vh.conf
pub const ConfigMatch = struct {
    key: []const u8,
    any: []const []const u8,
};

/// a DMI field by glob
pub const DmiMatch = struct {
    /// sys_vendor, product_name, product_family, board_vendor, board_name, bios_vendor, chassis_type
    field: []const u8,
    any: []const []const u8,
};

/// Every field that is given must hold; a list field holds when any of its values matches,
/// except cpu_flags and has, which need all of theirs.
pub const When = struct {
    arch: []const []const u8 = &.{},
    cpu_vendor: []const []const u8 = &.{},
    cpu_flags: []const []const u8 = &.{},
    cpu_family: ?u32 = null,
    /// the model is one of these
    cpu_model: []const u32 = &.{},
    cpu_model_min: ?u32 = null,
    cpu_model_max: ?u32 = null,
    /// ARM: "0x41", "0xd0b" as cpuinfo writes them
    arm_implementer: []const []const u8 = &.{},
    arm_part: []const []const u8 = &.{},
    /// the machine's device tree compatible list (glob)
    dt_compatible: []const []const u8 = &.{},
    dmi: []const DmiMatch = &.{},
    /// ACPI table signatures
    acpi_table: []const []const u8 = &.{},
    /// tags: built-in facts and what earlier rules set (every one must be present)
    has: []const []const u8 = &.{},
    /// tags of which none may be present
    lacks: []const []const u8 = &.{},
    ram_min_mib: ?u64 = null,
    ram_max_mib: ?u64 = null,
    cpus_min: ?u32 = null,
    cpus_max: ?u32 = null,
    config: []const ConfigMatch = &.{},
    device: ?DeviceMatch = null,
};

pub const Scalar = struct {
    key: []const u8,
    value: []const u8,
};

/// what a rule exports of the devices it matched, for the installer: KEY = the property of
/// the first matched device (pci_vendor)
pub const Export = struct {
    key: []const u8,
    from: []const u8,
};

pub const Rule = struct {
    id: []const u8,
    why: []const u8,
    when: When = .{},
    /// the rule does not apply when this holds as a whole
    unless: ?When = null,
    /// a scalar set by two rules: the higher priority wins, an equal one is a conflict
    priority: u32 = 0,
    /// tags for later conditions
    sets: []const []const u8 = &.{},
    packages: []const []const u8 = &.{},
    /// kernel class fragments: kernel/profiles/class/NAME
    kconfig: []const []const u8 = &.{},
    /// kernel features: kernel/profiles/features/NAME (their modules are refused when absent)
    features: []const []const u8 = &.{},
    /// firmware patterns kept on disk (paths under /usr/lib/firmware)
    firmware: []const []const u8 = &.{},
    /// the firmware of the matched devices' modules, narrowed to these patterns
    firmware_only: []const []const u8 = &.{},
    /// the matched devices' modules keep no firmware at all
    firmware_none: bool = false,
    cmdline: []const []const u8 = &.{},
    services: []const []const u8 = &.{},
    /// rule files of rootfs/etc/udev/rules.d that are installed only when a rule names them
    udev: []const []const u8 = &.{},
    /// modules refused: never preloaded, never in the kernel
    deny: []const []const u8 = &.{},
    /// drivers the initrd needs
    dracut: []const []const u8 = &.{},
    /// modules the machine needs that no device of the probe names
    modules: []const []const u8 = &.{},
    set: []const Scalar = &.{},
    @"export": []const Export = &.{},
    /// a recommendation for the user
    note: []const u8 = "",
};

pub const Requirement = struct {
    id: []const u8,
    why: []const u8,
    /// the requirement applies only where this holds (an architecture)
    only: ?When = null,
    /// it is met when this holds
    when: When = .{},
    /// refused in tiered mode too
    floor: bool = false,
    /// what is lost when it is not met (shown in tiered mode)
    risk: []const u8 = "",
    /// what makes it met (a firmware setting)
    fix: []const u8 = "",
    /// scalars that take effect when it is not met (tiered mode)
    otherwise: []const Scalar = &.{},
};

pub const File = struct {
    rules: []const Rule = &.{},
    requirements: []const Requirement = &.{},
};

pub const Db = struct {
    /// the rules of every file, files in name order, rules in file order
    rules: []const Rule = &.{},
    /// the file each rule came from, by index
    origin: []const []const u8 = &.{},
    requirements: []const Requirement = &.{},
};

pub fn parse(text: []const u8, what: []const u8) File {
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(File, .{
        .gpa = vh.gpa,
        .arena = vh.gpa,
        .source = vh.z(text),
        .diagnostics = &diag,
        .ignore_unknown_fields = false,
    }) catch |e| switch (e) {
        error.OutOfMemory => vh.oom(),
        error.ParseZon => vh.die("{f}", .{diag.fmt(what)}),
    };
}

/// every DIR/*.zon in name order; rule ids must be unique
pub fn load(dir: []const u8) Db {
    const names = vh.listDir(dir) catch vh.die("{s}: {s}", .{ dir, vh.serr() });
    var files: std.ArrayList([]const u8) = .empty;
    for (names) |n| if (vh.endsWith(n, ".zon")) files.append(vh.gpa, n) catch vh.oom();
    std.mem.sort([]const u8, files.items, {}, vh.lessStr);
    var rules: std.ArrayList(Rule) = .empty;
    var origin: std.ArrayList([]const u8) = .empty;
    var reqs: std.ArrayList(Requirement) = .empty;
    var ids: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (files.items) |n| {
        const path = vh.fmt("{s}/{s}", .{ dir, n });
        const text = vh.readFile(path) catch vh.die("{s}: {s}", .{ path, vh.serr() });
        const f = parse(text, n);
        for (f.rules) |r| {
            if (ids.get(r.id)) |other| vh.die("{s}: rule {s} is also in {s}", .{ n, r.id, other });
            ids.put(vh.gpa, r.id, n) catch vh.oom();
            rules.append(vh.gpa, r) catch vh.oom();
            origin.append(vh.gpa, n) catch vh.oom();
        }
        for (f.requirements) |q| {
            if (ids.get(q.id)) |other| vh.die("{s}: requirement {s} is also in {s}", .{ n, q.id, other });
            ids.put(vh.gpa, q.id, n) catch vh.oom();
            reqs.append(vh.gpa, q) catch vh.oom();
        }
    }
    return .{ .rules = rules.items, .origin = origin.items, .requirements = reqs.items };
}

test "a rule file parses, and a misspelt field is an error" {
    const f = parse(
        \\.{ .rules = .{ .{
        \\    .id = "cpu.intel.microcode",
        \\    .why = "early microcode",
        \\    .when = .{ .cpu_vendor = .{"GenuineIntel"}, .device = .{ .pci_class = .{"03"}, .boot_vga = true } },
        \\    .packages = .{"intel-ucode"},
        \\    .set = .{ .{ .key = "march", .value = "skylake" } },
        \\} } }
    , "test");
    try std.testing.expectEqual(@as(usize, 1), f.rules.len);
    try std.testing.expectEqualStrings("GenuineIntel", f.rules[0].when.cpu_vendor[0]);
    try std.testing.expectEqual(@as(?bool, true), f.rules[0].when.device.?.boot_vga);
    try std.testing.expectEqualStrings("skylake", f.rules[0].set[0].value);
    try std.testing.expect(f.rules[0].unless == null);
}
