//! The hardware description of one machine, /etc/vh/hw.zon: vh-kconf probe writes it,
//! resolve and vh-plan read it. A ZON document, readable by a person and by std.zon. It never
//! carries serial numbers, MAC addresses or UUIDs: it is committed as a fixture and travels to CI.
//!
//! Format 2 adds what a plan needs on any machine: the architecture, the memory, the topology
//! of every CPU, the disks, the network interfaces, the power supplies, the displays, the
//! keyboards, the sound cards, the ACPI tables and the device tree. A format 1 file still
//! parses: what it does not say takes the defaults.
const std = @import("std");
const vh = @import("vh");

/// the format this code writes
pub const format: u32 = 2;

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

/// one driver on the way from a device up to its bus
pub const Link = struct {
    driver: []const u8 = "",
    /// the module that owns the driver as sysfs names it (built-in drivers have one too);
    /// "" when sysfs does not say
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

/// where one logical CPU sits
pub const CpuTopo = struct {
    cpu: u32 = 0,
    package: u32 = 0,
    die: u32 = 0,
    cluster: u32 = 0,
    core: u32 = 0,
    /// the SMT siblings of this CPU, as sysfs lists them ("0,6")
    siblings: []const u8 = "",
    /// the CPUs sharing its last-level cache, and the size of that cache
    llc: []const u8 = "",
    llc_kb: u32 = 0,
    /// cpufreq's cpuinfo_max_freq; 0 without cpufreq
    max_khz: u32 = 0,
    /// cpu_capacity (ARM big.LITTLE, some hybrid x86); 0 when the kernel does not say
    capacity: u32 = 0,
    /// "core" or "atom" on a hybrid Intel CPU, "" elsewhere
    kind: []const u8 = "",
};

pub const Vulnerability = struct {
    name: []const u8 = "",
    /// the kernel's own words: "Not affected", "Mitigation: ...", "Vulnerable ..."
    state: []const u8 = "",
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
    /// the flags line of /proc/cpuinfo (on ARM the Features line)
    flags: []const u8 = "",
    /// the caches of cpu0
    caches: []const Cache = &.{},
    /// ARM: "CPU implementer" and "CPU part" of the first CPU, as cpuinfo writes them
    implementer: []const u8 = "",
    part: []const u8 = "",
    /// the possible CPUs, hotplug included: what NR_CPUS of a kernel for this machine covers
    possible: u32 = 0,
    /// cpufreq: the scaling driver, and whether it offers energy-performance preferences
    freq_driver: []const u8 = "",
    epp: bool = false,
    /// every present CPU, by number
    topology: []const CpuTopo = &.{},
    /// the CPU list of every NUMA node, in node order
    numa: []const []const u8 = &.{},
    vulnerabilities: []const Vulnerability = &.{},
};

pub const Memory = struct {
    /// MemTotal of /proc/meminfo: what the kernel can use, a little less than the RAM installed
    total_kib: u64 = 0,
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
    /// null when the SetupMode variable could not be read; true: keys can be enrolled now
    setup_mode: ?bool = null,
    /// the MemoryOverwriteRequestControl variable exists: the firmware clears RAM on request
    mor: bool = false,
    /// the signatures of the ACPI tables, sorted (DMAR, IVRS, IORT, TPM2 ...); none without ACPI
    acpi_tables: []const []const u8 = &.{},
    /// the IOMMU units the probed kernel drives (/sys/class/iommu)
    iommu_units: u32 = 0,
    /// the device tree of a board without ACPI: the model and the compatible list, most
    /// specific first
    dt_model: []const u8 = "",
    dt_compatible: []const []const u8 = &.{},
};

pub const Virt = struct {
    /// /sys/hypervisor/type (Xen), "" otherwise; the CPU flag "hypervisor" and DMI say the rest
    sys_type: []const u8 = "",
};

pub const Block = struct {
    name: []const u8 = "",
    /// how the disk is attached, from its sysfs path: nvme, ata, usb, mmc, virtio, scsi, other
    bus: []const u8 = "",
    rotational: bool = false,
    removable: bool = false,
    logical_block: u32 = 0,
    physical_block: u32 = 0,
    /// the device accepts discard (TRIM)
    discard: bool = false,
    size_mib: u64 = 0,
    model: []const u8 = "",
    /// the drivers from the disk up to its controller, nearest first
    drivers: []const Link = &.{},
};

pub const Net = struct {
    name: []const u8 = "",
    wireless: bool = false,
    /// the bus of the device: pci, usb, virtio, mmc, platform, other
    bus: []const u8 = "",
    /// the device's path under /sys/devices: its place in the topology, never its address
    path: []const u8 = "",
    driver: []const u8 = "",
    module: []const u8 = "",
};

pub const PowerSupply = struct {
    name: []const u8 = "",
    /// Battery, Mains, USB, UPS, Wireless
    kind: []const u8 = "",
    /// System, or Device (the battery of a mouse); "" when the kernel does not say
    scope: []const u8 = "",
};

pub const Backlight = struct {
    name: []const u8 = "",
    /// raw, platform, firmware
    kind: []const u8 = "",
};

pub const Power = struct {
    supplies: []const PowerSupply = &.{},
    backlights: []const Backlight = &.{},
    /// the ACPI platform profiles the firmware offers ("low-power", "balanced", "performance")
    profiles: []const []const u8 = &.{},
};

pub const Display = struct {
    /// the sysfs name of the device: a PCI address, or a platform device on a board
    name: []const u8 = "",
    bus: []const u8 = "",
    /// the firmware brought the console up on it (PCI boot_vga)
    boot_vga: bool = false,
    driver: []const u8 = "",
    module: []const u8 = "",
    /// its DRM connectors and their state, "HDMI-A-1 connected"
    connectors: []const []const u8 = &.{},
};

pub const Keyboard = struct {
    name: []const u8 = "",
    /// the input bus: i8042, usb, i2c, host, spi, other (Bluetooth and virtual devices are
    /// not recorded: neither can type the LUKS passphrase in the initrd)
    bus: []const u8 = "",
    /// the drivers from the keyboard up to its controller, nearest first: what the initrd needs
    drivers: []const Link = &.{},
};

pub const Sound = struct {
    card: []const u8 = "",
    bus: []const u8 = "",
    driver: []const u8 = "",
    module: []const u8 = "",
};

pub const Probe = struct {
    format: u32 = format,
    tool: []const u8 = "vh-kconf",
    /// the kernel the probe ran under (uname -r): the modules.alias to use with this file
    kernel: []const u8 = "",
    /// "live" or the snapshot directory the file was made from
    source: []const u8 = "live",
};

pub const Hw = struct {
    probe: Probe = .{},
    /// the machine name of the probed kernel: x86_64, aarch64; "" in a format 1 file
    arch: []const u8 = "",
    machine: Machine = .{},
    cpu: Cpu = .{},
    memory: Memory = .{},
    firmware: Firmware = .{},
    virt: Virt = .{},
    /// the file system types mounted at probe time, sorted
    filesystems: []const []const u8 = &.{},
    /// the loaded modules (/proc/modules), sorted
    modules: []const []const u8 = &.{},
    /// every device with a modalias, sorted by bus and name
    devices: []const Device = &.{},
    /// disks, by name
    blocks: []const Block = &.{},
    /// network interfaces backed by a device, by name
    net: []const Net = &.{},
    power: Power = .{},
    /// display controllers, by name
    displays: []const Display = &.{},
    keyboards: []const Keyboard = &.{},
    sound: []const Sound = &.{},

    pub fn hasModule(self: *const Hw, name: []const u8) bool {
        for (self.modules) |m| if (vh.eql(m, name)) return true;
        return false;
    }

    /// the architecture; a format 1 file was written on x86_64 only
    pub fn archName(self: *const Hw) []const u8 {
        return if (self.arch.len > 0) self.arch else "x86_64";
    }
};

/// the ZON text, pretty-printed, with a final newline
pub fn render(hw: Hw) []u8 {
    var aw: std.Io.Writer.Allocating = .init(vh.gpa);
    // serialize() proves at comptime that the type is not recursive, which runs out of the
    // default branch quota on a type of this size; Hw holds nothing that points back to itself
    std.zon.stringify.serializeArbitraryDepth(hw, .{}, &aw.writer) catch vh.oom();
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
    try std.testing.expect(std.mem.indexOf(u8, text, ".format = 2") != null);
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
    try std.testing.expectEqualStrings("x86_64", minimal.archName());
}

test "hw.zon format 2 round trip" {
    const topo = [_]CpuTopo{
        .{ .cpu = 0, .core = 0, .siblings = "0-1", .llc = "0-15", .llc_kb = 98304, .max_khz = 5759000, .kind = "" },
        .{ .cpu = 1, .core = 0, .siblings = "0-1", .llc = "0-15", .llc_kb = 98304, .max_khz = 5759000 },
    };
    const chain = [_]Link{ .{ .driver = "nvme", .module = "nvme" }, .{ .driver = "pcieport" } };
    const blocks = [_]Block{.{ .name = "nvme0n1", .bus = "nvme", .logical_block = 512, .physical_block = 512, .discard = true, .size_mib = 953869, .drivers = &chain }};
    const nets = [_]Net{.{ .name = "wlan0", .wireless = true, .bus = "pci", .path = "pci0000:00/0000:00:14.3", .driver = "iwlwifi", .module = "iwlwifi" }};
    const supplies = [_]PowerSupply{ .{ .name = "ADP1", .kind = "Mains" }, .{ .name = "BAT1", .kind = "Battery", .scope = "" } };
    const conns = [_][]const u8{"eDP-1 connected"};
    const displays = [_]Display{.{ .name = "0000:00:02.0", .bus = "pci", .boot_vga = true, .driver = "i915", .module = "i915", .connectors = &conns }};
    const kchain = [_]Link{ .{ .driver = "atkbd", .module = "atkbd" }, .{ .driver = "i8042" } };
    const kbds = [_]Keyboard{.{ .name = "AT Translated Set 2 keyboard", .bus = "i8042", .drivers = &kchain }};
    const tables = [_][]const u8{ "DMAR", "TPM2" };
    const hw: Hw = .{
        .arch = "x86_64",
        .cpu = .{ .vendor = "AuthenticAMD", .possible = 32, .topology = &topo, .freq_driver = "amd-pstate-epp", .epp = true },
        .memory = .{ .total_kib = 65_000_000 },
        .firmware = .{ .efi = true, .efi_bits = 64, .setup_mode = false, .mor = true, .acpi_tables = &tables, .iommu_units = 2 },
        .blocks = &blocks,
        .net = &nets,
        .power = .{ .supplies = &supplies },
        .displays = &displays,
        .keyboards = &kbds,
    };
    const back = parse(render(hw), "test");
    try std.testing.expectEqualStrings("x86_64", back.archName());
    try std.testing.expectEqual(@as(u32, 32), back.cpu.possible);
    try std.testing.expectEqual(@as(usize, 2), back.cpu.topology.len);
    try std.testing.expectEqual(@as(u32, 98304), back.cpu.topology[1].llc_kb);
    try std.testing.expectEqual(@as(u64, 65_000_000), back.memory.total_kib);
    try std.testing.expectEqual(@as(?bool, false), back.firmware.setup_mode);
    try std.testing.expectEqualStrings("TPM2", back.firmware.acpi_tables[1]);
    try std.testing.expectEqualStrings("pcieport", back.blocks[0].drivers[1].driver);
    try std.testing.expectEqualStrings("", back.blocks[0].drivers[1].module);
    try std.testing.expect(back.net[0].wireless);
    try std.testing.expectEqualStrings("Battery", back.power.supplies[1].kind);
    try std.testing.expect(back.displays[0].boot_vga);
    try std.testing.expectEqualStrings("eDP-1 connected", back.displays[0].connectors[0]);
    try std.testing.expectEqualStrings("i8042", back.keyboards[0].drivers[1].driver);
}
