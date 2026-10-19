//! What vh-plan knows of the machine: hw.zon with every device's modalias taken apart and its
//! modules found, the built-in tags, the memory and the CPUs. No vendor is named here: what a
//! device or a tag means for the machine is decided by the rules of hwdb/.
const std = @import("std");
const vh = @import("vh");
const hw = @import("hw");
const alias = @import("alias");
const mem = std.mem;

pub const Dev = struct {
    d: hw.Device,
    /// PCI: four lowercase hex digits each, the class as six ("030000"); "" when not PCI
    pci_vendor: []const u8 = "",
    pci_device: []const u8 = "",
    pci_class: []const u8 = "",
    /// USB: four lowercase hex digits each, the interface class as two; "" when not USB
    usb_vendor: []const u8 = "",
    usb_product: []const u8 = "",
    usb_class: []const u8 = "",
    /// the ACPI ids of an "acpi:ID:CID:" modalias
    acpi_ids: []const []const u8 = &.{},
    /// the compatible strings of an "of:N..T..C..C.." modalias
    dt_compatible: []const []const u8 = &.{},
    /// the module the running system bound; without one, what the stock kernel's tables name
    modules: []const []const u8 = &.{},
    /// every module that can drive the device: the bound one and all the tables name (a
    /// rule's module condition looks here: the SMBus function is bound to i2c_piix4 and also
    /// carries the sp5100_tco watchdog)
    candidates: []const []const u8 = &.{},
    /// for a display controller: whether it brought the console up
    boot_vga: ?bool = null,
};

pub const Machine = struct {
    hw: hw.Hw,
    arch: []const u8,
    devs: []const Dev,
    /// the built-in tags (hwdb/README.md lists them); the rules add theirs
    tags: vh.Strv,
    ram_mib: u64,
    cpus: u32,
    /// the stock kernel's module tables were there for this architecture
    tables: bool,
};

fn lower(s: []const u8) []const u8 {
    const out = vh.dupe(s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// "pci:v00008086d000006F0sv00008086sd00000034bc02sc80i00": the fields at their fixed places
pub fn parsePci(d: *Dev) void {
    const m = d.d.modalias;
    if (m.len < 53 or !vh.startsWith(m, "pci:v") or m[13] != 'd' or !vh.eql(m[42..44], "bc")) return;
    d.pci_vendor = lower(m[9..13]);
    d.pci_device = lower(m[18..22]);
    d.pci_class = lower(vh.fmt("{s}{s}{s}", .{ m[44..46], m[48..50], m[51..53] }));
}

/// "usb:v8087p0026d0002dcE0dsc01dp01icE0isc01ip01in00"
pub fn parseUsb(d: *Dev) void {
    const m = d.d.modalias;
    if (m.len < 14 or !vh.startsWith(m, "usb:v") or m[9] != 'p') return;
    d.usb_vendor = lower(m[5..9]);
    d.usb_product = lower(m[10..14]);
    if (mem.indexOf(u8, m, "ic")) |i| {
        if (i + 4 <= m.len) d.usb_class = lower(m[i + 2 .. i + 4]);
    }
}

/// "acpi:SYNA3602:PNP0C50:" -> SYNA3602, PNP0C50
pub fn parseAcpi(d: *Dev) void {
    const m = d.d.modalias;
    if (!vh.startsWith(m, "acpi:")) return;
    var ids: vh.Strv = .{};
    var it = mem.tokenizeScalar(u8, m[5..], ':');
    while (it.next()) |id| ids.add(id);
    d.acpi_ids = ids.slice();
}

/// "of:NmmcT(null)Cbrcm,bcm2712-sdhciCbrcm,sdhci-brcmstb" -> the compatible strings
pub fn parseOf(d: *Dev) void {
    const m = d.d.modalias;
    if (!vh.startsWith(m, "of:N")) return;
    const t = mem.indexOfScalarPos(u8, m, 4, 'T') orelse return;
    const c = mem.indexOfScalarPos(u8, m, t, 'C') orelse return;
    var list: vh.Strv = .{};
    var it = mem.tokenizeScalar(u8, m[c + 1 ..], 'C');
    while (it.next()) |x| list.add(x);
    d.dt_compatible = list.slice();
}

/// the modules of a device: the bound one, else the table's loadable and built-in matches;
/// with `all`, the bound one and every match
fn modulesOf(d: hw.Device, table: ?*const alias.Table, all: bool) []const []const u8 {
    var out: vh.Strv = .{};
    const bound = alias.normalize(d.module);
    if (bound.len > 0) {
        out.add(bound);
        if (!all) return out.slice();
    }
    const t = table orelse return out.slice();
    const m = t.match(d.modalias);
    for (m.loadable) |x| if (!out.has(x)) out.add(x);
    for (m.builtin) |x| if (!out.has(x)) out.add(x);
    return out.slice();
}

pub fn build(h: hw.Hw, table: ?*const alias.Table) Machine {
    var devs: std.ArrayList(Dev) = .empty;
    for (h.devices) |d| {
        var x: Dev = .{ .d = d };
        parsePci(&x);
        parseUsb(&x);
        parseAcpi(&x);
        parseOf(&x);
        x.modules = modulesOf(d, table, false);
        x.candidates = modulesOf(d, table, true);
        for (h.displays) |disp| if (vh.eql(disp.name, d.name) and vh.eql(disp.bus, d.bus)) {
            x.boot_vga = disp.boot_vga;
        };
        devs.append(vh.gpa, x) catch vh.oom();
    }
    var m: Machine = .{
        .hw = h,
        .arch = h.archName(),
        .devs = devs.items,
        .tags = .{},
        .ram_mib = h.memory.total_kib / 1024,
        .cpus = if (h.cpu.possible > 0) h.cpu.possible else h.cpu.threads,
        .tables = table != null,
    };
    builtinTags(&m);
    return m;
}

fn tag(m: *Machine, t: []const u8, cond: bool) void {
    if (cond and !m.tags.has(t)) m.tags.add(t);
}

/// facts that hold on any machine, named after what they are, not after a vendor
fn builtinTags(m: *Machine) void {
    const h = m.hw;
    const f = h.firmware;
    tag(m, "efi", f.efi);
    tag(m, "efi64", f.efi and f.efi_bits == 64);
    tag(m, "secure-boot", f.secure_boot != null);
    tag(m, "secure-boot-on", f.secure_boot == true);
    tag(m, "setup-mode", f.setup_mode == true);
    tag(m, "mor", f.mor);
    tag(m, "tpm", f.tpm);
    tag(m, "tpm2", f.tpm and f.tpm_version == 2);
    tag(m, "iommu-active", f.iommu_units > 0);
    tag(m, "acpi", f.acpi_tables.len > 0);
    tag(m, "devicetree", f.dt_compatible.len > 0);
    tag(m, "sys-hypervisor", h.virt.sys_type.len > 0);
    tag(m, "smt", h.cpu.smt);
    tag(m, "epp", h.cpu.epp);
    tag(m, "numa", h.cpu.numa.len > 1);
    var hybrid = false;
    var llcs: vh.Strv = .{};
    for (h.cpu.topology) |t| {
        if (vh.eql(t.kind, "atom")) hybrid = true;
        if (t.llc.len > 0 and !llcs.has(t.llc)) llcs.add(t.llc);
    }
    tag(m, "hybrid", hybrid);
    tag(m, "multi-llc", llcs.len() > 1);
    for (h.power.supplies) |s| {
        tag(m, "battery", vh.eql(s.kind, "Battery"));
        tag(m, "mains", vh.eql(s.kind, "Mains"));
        tag(m, "usb-power", vh.eql(s.kind, "USB"));
    }
    tag(m, "backlight", h.power.backlights.len > 0);
    tag(m, "platform-profile", h.power.profiles.len > 0);
    for (h.net) |n| {
        tag(m, "wifi", n.wireless);
        tag(m, "wired", !n.wireless);
    }
    for (h.blocks) |b| {
        tag(m, "disk", true);
        tag(m, "disk-discard", b.discard and !b.removable);
        tag(m, "disk-rotational", b.rotational and !vh.eql(b.bus, "virtio"));
        // how the disks hang off the machine: their bus, and every module on the way
        tag(m, vh.fmt("disk-{s}", .{b.bus}), b.bus.len > 0);
        for (b.drivers) |l| tag(m, vh.fmt("disk-on-{s}", .{alias.normalize(l.module)}), l.module.len > 0);
    }
    for (h.keyboards) |k| {
        tag(m, "keyboard", true);
        tag(m, vh.fmt("keyboard-{s}", .{k.bus}), true);
    }
    tag(m, "sound", h.sound.len > 0);
    var pci_displays: usize = 0;
    for (h.displays) |d| {
        if (vh.eql(d.bus, "pci")) pci_displays += 1;
    }
    tag(m, "display", h.displays.len > 0);
    tag(m, "displays-2", pci_displays > 1);
    m.tags.sort();
}

test "modalias fields" {
    var p: Dev = .{ .d = .{ .bus = "pci", .name = "x", .modalias = "pci:v00008086d000006F0sv00008086sd00000034bc02sc80i00" } };
    parsePci(&p);
    try std.testing.expectEqualStrings("8086", p.pci_vendor);
    try std.testing.expectEqualStrings("06f0", p.pci_device);
    try std.testing.expectEqualStrings("028000", p.pci_class);
    var u: Dev = .{ .d = .{ .bus = "usb", .name = "x", .modalias = "usb:v8087p0026d0002dcE0dsc01dp01icE0isc01ip01in00" } };
    parseUsb(&u);
    try std.testing.expectEqualStrings("8087", u.usb_vendor);
    try std.testing.expectEqualStrings("0026", u.usb_product);
    try std.testing.expectEqualStrings("e0", u.usb_class);
    var a: Dev = .{ .d = .{ .bus = "i2c", .name = "x", .modalias = "acpi:SYNA3602:PNP0C50:" } };
    parseAcpi(&a);
    try std.testing.expectEqual(@as(usize, 2), a.acpi_ids.len);
    try std.testing.expectEqualStrings("PNP0C50", a.acpi_ids[1]);
    var o: Dev = .{ .d = .{ .bus = "platform", .name = "x", .modalias = "of:NmmcT(null)Cbrcm,bcm2712-sdhciCbrcm,sdhci-brcmstb" } };
    parseOf(&o);
    try std.testing.expectEqual(@as(usize, 2), o.dt_compatible.len);
    try std.testing.expectEqualStrings("brcm,sdhci-brcmstb", o.dt_compatible[1]);
    var junk: Dev = .{ .d = .{ .bus = "pci", .name = "x", .modalias = "pci:short" } };
    parsePci(&junk);
    try std.testing.expectEqualStrings("", junk.pci_vendor);
}
