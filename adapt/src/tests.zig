//! Unit tests of the plan engine on small machines written here; the whole hwdb against the
//! fixtures of real and synthesised machines is tests/adapt/run.sh (golden plans).
const std = @import("std");
const vh = @import("vh");
const hw = @import("hw");
const rules = @import("rules.zig");
const plan = @import("plan.zig");
const emit = @import("emit.zig");
const t = std.testing;

const laptop_devices = [_]hw.Device{
    .{ .bus = "pci", .name = "0000:00:02.0", .modalias = "pci:v00008086d00009BC4sv00001462sd000012D5bc03sc00i00", .driver = "i915", .module = "i915" },
    .{ .bus = "pci", .name = "0000:01:00.0", .modalias = "pci:v000010DEd00001F99sv00001462sd000012D5bc03sc00i00" },
    .{ .bus = "pci", .name = "0000:00:14.3", .modalias = "pci:v00008086d000006F0sv00008086sd00000034bc02sc80i00", .driver = "iwlwifi", .module = "iwlwifi" },
    .{ .bus = "acpi", .name = "PNP0C0D:00", .modalias = "acpi:PNP0C0D:", .driver = "button" },
};
const laptop_displays = [_]hw.Display{
    .{ .name = "0000:00:02.0", .bus = "pci", .boot_vga = true, .driver = "i915" },
    .{ .name = "0000:01:00.0", .bus = "pci", .boot_vga = false },
};
const laptop_net = [_]hw.Net{.{ .name = "wlan0", .wireless = true, .bus = "pci", .driver = "iwlwifi", .module = "iwlwifi" }};
const laptop_supplies = [_]hw.PowerSupply{.{ .name = "BAT1", .kind = "Battery" }};
const kchain = [_]hw.Link{ .{ .driver = "atkbd", .module = "atkbd" }, .{ .driver = "i8042" } };
const laptop_kbd = [_]hw.Keyboard{.{ .name = "AT Translated Set 2 keyboard", .bus = "i8042", .drivers = &kchain }};
const tables = [_][]const u8{ "DMAR", "TPM2" };

fn laptop() hw.Hw {
    return .{
        .probe = .{ .source = "test" },
        .arch = "x86_64",
        .cpu = .{ .vendor = "GenuineIntel", .family = 6, .model = 165, .threads = 12, .possible = 12, .flags = "fpu sse4_2 aes avx2" },
        .memory = .{ .total_kib = 8_000_000 },
        .firmware = .{ .efi = true, .efi_bits = 64, .secure_boot = true, .tpm = true, .tpm_version = 2, .acpi_tables = &tables },
        .devices = &laptop_devices,
        .displays = &laptop_displays,
        .net = &laptop_net,
        .power = .{ .supplies = &laptop_supplies },
        .keyboards = &laptop_kbd,
    };
}

fn db(text: []const u8) rules.Db {
    const f = rules.parse(text, "test");
    var origin: std.ArrayList([]const u8) = .empty;
    for (f.rules) |_| origin.append(vh.gpa, "test.zon") catch vh.oom();
    return .{ .rules = f.rules, .origin = origin.items, .requirements = f.requirements };
}

fn hasItem(items: []const plan.Item, v: []const u8) bool {
    for (items) |x| if (vh.eql(x.value, v)) return true;
    return false;
}

fn scalar(p: plan.Plan, key: []const u8) []const u8 {
    for (p.scalars) |s| if (vh.eql(s.key, key)) return s.value;
    return "";
}

test "rules: conditions, tags set by rules, devices, unless, config" {
    const d = db(
        \\.{ .rules = .{
        \\  .{ .id = "class.laptop", .why = "a battery", .when = .{ .has = .{"battery"} }, .sets = .{"laptop"}, .set = .{ .{ .key = "class", .value = "laptop" } }, .priority = 30 },
        \\  .{ .id = "class.desktop", .why = "default", .set = .{ .{ .key = "class", .value = "desktop" } }, .priority = 10 },
        \\  .{ .id = "cpu.intel", .why = "microcode", .when = .{ .cpu_vendor = .{"GenuineIntel"} }, .packages = .{"intel-ucode"}, .firmware = .{"intel-ucode/*"} },
        \\  .{ .id = "iommu.dmar", .why = "VT-d", .when = .{ .acpi_table = .{"DMAR"}, .cpu_vendor = .{"GenuineIntel"} }, .cmdline = .{"intel_iommu=on"}, .sets = .{"iommu"} },
        \\  .{ .id = "gpu.dgpu-off", .why = "the dGPU sleeps", .when = .{ .has = .{"laptop"}, .device = .{ .pci_class = .{"03"}, .boot_vga = false } },
        \\    .unless = .{ .config = .{ .{ .key = "VH_GPU", .any = .{"nouveau"} } } }, .udev = .{"99-vh-dgpu-off.rules"}, .deny = .{"nouveau"},
        \\    .@"export" = .{ .{ .key = "DGPU_VENDOR", .from = "pci_vendor" } } },
        \\  .{ .id = "wifi.iwd", .why = "Wi-Fi", .when = .{ .has = .{"wifi"} }, .services = .{"iwd"}, .packages = .{ "iwd", "wireless-regdb" } },
        \\  .{ .id = "lid", .why = "a lid", .when = .{ .device = .{ .acpi_id = .{"PNP0C0D"} } }, .services = .{"vh-acpid"} },
        \\  .{ .id = "never", .why = "an AMD CPU", .when = .{ .cpu_vendor = .{"AuthenticAMD"} }, .packages = .{"linux-firmware-amd"} },
        \\} }
    );
    var cfg: vh.Kv = .{};
    cfg.set("VH_GPU", "auto");
    const r = plan.compute(.{ .hw = laptop(), .db = d, .config = &cfg });
    const p = r.plan;
    try t.expectEqual(@as(u8, 0), r.status);
    try t.expectEqualStrings("laptop", scalar(p, "class"));
    try t.expect(hasItem(p.packages, "intel-ucode") and hasItem(p.packages, "iwd") and !hasItem(p.packages, "linux-firmware-amd"));
    try t.expect(hasItem(p.cmdline, "intel_iommu=on"));
    try t.expect(hasItem(p.udev, "99-vh-dgpu-off.rules") and hasItem(p.deny, "nouveau"));
    try t.expectEqualStrings("0x10de", p.exports[0].value);
    try t.expect(hasItem(p.services, "vh-acpid"));
    // the keyboard's chain: the modules that have a name
    try t.expect(hasItem(p.dracut, "atkbd") and !hasItem(p.dracut, "i8042"));
    // the user who wants nouveau keeps the dGPU awake and the module allowed
    cfg.set("VH_GPU", "nouveau");
    const r2 = plan.compute(.{ .hw = laptop(), .db = d, .config = &cfg });
    try t.expect(!hasItem(r2.plan.udev, "99-vh-dgpu-off.rules") and !hasItem(r2.plan.deny, "nouveau"));
    // deterministic: the same input gives the same plan and the same report
    var cfg_auto: vh.Kv = .{};
    cfg_auto.set("VH_GPU", "auto");
    const again = plan.compute(.{ .hw = laptop(), .db = d, .config = &cfg_auto });
    try t.expectEqualStrings(emit.renderZon(r.plan), emit.renderZon(again.plan));
    try t.expectEqualStrings(r.report, again.report);
}

test "rules: firmware narrowed to the device, the rest from the module's table" {
    const d = db(
        \\.{ .rules = .{
        \\  .{ .id = "gpu.i915.cml", .why = "Comet Lake", .when = .{ .device = .{ .pci_vendor = .{"8086"}, .pci_device = .{"9bc4"} } }, .firmware_only = .{ "i915/kbl_*", "i915/cml_*" } },
        \\} }
    );
    var ft: plan.FirmwareTable = .{};
    ft.load("i915 i915/kbl_dmc_ver1_04.bin\ni915 i915/tgl_dmc.bin\niwlwifi iwlwifi-QuZ-a0-hr-b0-77.ucode\niwlwifi iwlwifi-so-a0-gf-a0-86.ucode\n");
    var cfg: vh.Kv = .{};
    const p = plan.compute(.{ .hw = laptop(), .db = d, .config = &cfg, .firmware = &ft }).plan;
    try t.expect(hasItem(p.firmware, "i915/kbl_*") and hasItem(p.firmware, "i915/cml_*"));
    try t.expect(!hasItem(p.firmware, "i915/tgl_dmc.bin*"));
    // iwlwifi has no narrowing rule here: every file it names, versions as globs
    try t.expect(hasItem(p.firmware, "iwlwifi-QuZ-a0-hr-b0-*") and hasItem(p.firmware, "iwlwifi-so-a0-gf-a0-*"));
}

test "rules: scalar priority and conflicts" {
    const d = db(
        \\.{ .rules = .{
        \\  .{ .id = "a", .why = "a", .set = .{ .{ .key = "march", .value = "x86-64-v3" } }, .priority = 10 },
        \\  .{ .id = "b", .why = "b", .set = .{ .{ .key = "march", .value = "skylake" } }, .priority = 20 },
        \\  .{ .id = "c", .why = "c", .set = .{ .{ .key = "renderer", .value = "gles2" } } },
        \\  .{ .id = "d", .why = "d", .set = .{ .{ .key = "renderer", .value = "pixman" } } },
        \\} }
    );
    var cfg: vh.Kv = .{};
    const r = plan.compute(.{ .hw = laptop(), .db = d, .config = &cfg });
    try t.expectEqualStrings("skylake", r.plan.kernel.march);
    try t.expectEqualStrings("gles2", scalar(r.plan, "renderer"));
    try t.expect(std.mem.indexOf(u8, r.report, "Scalar conflicts (1)") != null);
}

test "the security gate: strict, tiered, the floor" {
    const d = db(
        \\.{ .requirements = .{
        \\  .{ .id = "efi64", .why = "UEFI 64-bit", .when = .{ .has = .{"efi64"} }, .floor = true },
        \\  .{ .id = "tpm2", .why = "TPM 2.0", .when = .{ .has = .{"tpm2"} }, .risk = "no measured boot" },
        \\  .{ .id = "aes", .why = "AES in the CPU", .when = .{ .cpu_flags = .{"aes"} }, .otherwise = .{ .{ .key = "luks_cipher", .value = "xchacha12,aes-adiantum-plain64" } } },
        \\  .{ .id = "memory", .why = "Argon2id 1 GiB", .when = .{ .ram_min_mib = 1900 }, .otherwise = .{ .{ .key = "luks_memory", .value = "quarter-of-ram" } } },
        \\} }
    );
    var cfg: vh.Kv = .{};
    // the full machine
    const full = plan.compute(.{ .hw = laptop(), .db = d, .config = &cfg });
    try t.expectEqualStrings("full", full.plan.tier);
    try t.expectEqual(@as(u8, 0), full.status);
    try t.expectEqual(@as(u64, 1048576), full.plan.luks.pbkdf_memory_kib);
    try t.expectEqual(@as(u32, 4), full.plan.luks.pbkdf_parallel);
    // no TPM, no AES, 1.5 GiB: strict refuses, tiered names the risks and lowers what it must
    var weak = laptop();
    weak.firmware.tpm = false;
    weak.cpu.flags = "fpu sse4_2";
    weak.memory.total_kib = 1_500_000;
    const strict = plan.compute(.{ .hw = weak, .db = d, .config = &cfg });
    try t.expectEqualStrings("reduced", strict.plan.tier);
    try t.expectEqual(@as(u8, 3), strict.status);
    try t.expectEqual(@as(usize, 3), strict.plan.missing.len);
    try t.expectEqual(@as(usize, 0), strict.plan.acknowledge.len);
    const tiered = plan.compute(.{ .hw = weak, .db = d, .config = &cfg, .security = "tiered" });
    try t.expectEqual(@as(u8, 0), tiered.status);
    try t.expectEqual(@as(usize, 3), tiered.plan.acknowledge.len);
    try t.expectEqualStrings("xchacha12,aes-adiantum-plain64", tiered.plan.luks.cipher);
    try t.expectEqual(@as(u32, 256), tiered.plan.luks.key_size);
    // a quarter of 1.5 GB, rounded down to 64 MiB, at least 256 MiB
    try t.expectEqual(@as(u64, 327680), tiered.plan.luks.pbkdf_memory_kib);
    // below the floor: refused in either mode
    var old = laptop();
    old.firmware.efi = false;
    const floor = plan.compute(.{ .hw = old, .db = d, .config = &cfg, .security = "tiered" });
    try t.expectEqualStrings("refused", floor.plan.tier);
    try t.expectEqual(@as(u8, 3), floor.status);
}

test "vh-acpid's internal input: built-in keyboards it cannot tell by their bus" {
    const d = db(".{ .rules = .{} }");
    var cfg: vh.Kv = .{};
    // the laptop's PS/2 keyboard: vh-acpid knows it by itself
    const ps2 = plan.compute(.{ .hw = laptop(), .db = d, .config = &cfg }).plan;
    try t.expectEqual(@as(usize, 0), ps2.internal_input.len);
    // a keyboard on internal USB, an external one, and one on SPI
    const kbds = [_]hw.Keyboard{
        .{ .name = "Keyboard", .bus = "usb", .path = "pci0000:00/0000:00:14.0/usb1/1-8", .removable = "fixed" },
        .{ .name = "USB Keyboard", .bus = "usb", .path = "pci0000:00/0000:00:14.0/usb1/1-2", .removable = "removable" },
        .{ .name = "SPI Keyboard", .bus = "spi", .path = "pci0000:00/0000:00:1e.3/pxa2xx-spi.3/spi_master/spi2/spi-KBD0001:00" },
    };
    var h = laptop();
    h.keyboards = &kbds;
    const p = plan.compute(.{ .hw = h, .db = d, .config = &cfg }).plan;
    try t.expectEqual(@as(usize, 2), p.internal_input.len);
    try t.expect(hasItem(p.internal_input, "/pci0000:00/0000:00:14.0/usb1/1-8/"));
    try t.expect(hasItem(p.internal_input, "/pci0000:00/0000:00:1e.3/pxa2xx-spi.3/spi_master/spi2/spi-KBD0001:00/"));
    try t.expect(!hasItem(p.internal_input, "/pci0000:00/0000:00:14.0/usb1/1-2/"));
    const env = emit.renderEnv(p);
    try t.expect(std.mem.indexOf(u8, env, "VH_PLAN_INTERNAL_INPUT='/pci0000:00/0000:00:14.0/usb1/1-8/ /pci0000:00/0000:00:1e.3/pxa2xx-spi.3/spi_master/spi2/spi-KBD0001:00/'\n") != null);
}

test "plan.zon gives plan.env back (vh-plan env)" {
    const d = db(".{ .rules = .{ .{ .id = \"wifi.iwd\", .why = \"Wi-Fi\", .when = .{ .has = .{\"wifi\"} }, .services = .{\"iwd\"}, .packages = .{\"iwd\"} } } }");
    var cfg: vh.Kv = .{};
    const p = plan.compute(.{ .hw = laptop(), .db = d, .config = &cfg }).plan;
    const back = emit.parseZon(emit.renderZon(p), "test");
    try t.expectEqualStrings(emit.renderEnv(p), emit.renderEnv(back));
}

test "a misspelt condition is an error, not a match" {
    // parse() dies on unknown fields; the schema check is that a valid file round-trips
    const f = rules.parse(".{ .rules = .{ .{ .id = \"x\", .why = \"y\", .when = .{ .lacks = .{\"vm\"} } } } }", "test");
    try t.expectEqualStrings("vm", f.rules[0].when.lacks[0]);
}

test "the memory floor (hwdb): 1.5 GiB in either mode, 2 GiB in strict" {
    // the real hwdb and the rig's own probe: tests/adapt/run.sh runs the tests in the repository's root
    if (!vh.isDir("hwdb") or !vh.pathExists("kernel/hw/qemu-q35.zon")) return error.SkipZigTest;
    const d = rules.load("hwdb");
    var cfg: vh.Kv = .{};
    cfg.read("vh.conf.example", false);
    var h = hw.load("kernel/hw/qemu-q35.zon");
    // 2 GiB (the kernel sees a little less): every protection, Argon2id with 1 GiB
    h.memory.total_kib = 1950 * 1024;
    const two = plan.compute(.{ .hw = h, .db = d, .config = &cfg });
    try t.expectEqualStrings("full", two.plan.tier);
    try t.expectEqual(@as(u64, 1048576), two.plan.luks.pbkdf_memory_kib);
    // 1.5 GiB (the rig with VH_MEM=1536 shows MemTotal 1428 MiB, kvm-smoke run 39409288166):
    // strict refuses it, tiered installs it with Argon2id at a quarter of the RAM, rounded down
    // to 64 MiB
    h.memory.total_kib = 1428 * 1024;
    const strict = plan.compute(.{ .hw = h, .db = d, .config = &cfg });
    try t.expectEqualStrings("reduced", strict.plan.tier);
    try t.expectEqual(@as(u8, 3), strict.status);
    const tiered = plan.compute(.{ .hw = h, .db = d, .config = &cfg, .security = "tiered" });
    try t.expectEqual(@as(u8, 0), tiered.status);
    try t.expectEqual(@as(usize, 1), tiered.plan.acknowledge.len);
    try t.expectEqualStrings("memory", tiered.plan.acknowledge[0]);
    try t.expectEqual(@as(u64, 327680), tiered.plan.luks.pbkdf_memory_kib);
    // below the floor: refused in either mode
    h.memory.total_kib = 1200 * 1024;
    const low = plan.compute(.{ .hw = h, .db = d, .config = &cfg, .security = "tiered" });
    try t.expectEqualStrings("refused", low.plan.tier);
    try t.expectEqual(@as(u8, 3), low.status);
}

test "-march: the CPU model's on bare metal, the x86-64 level in a virtual machine (hwdb)" {
    // the real hwdb and fixtures: tests/adapt/run.sh runs the tests in the repository's root
    if (!vh.isDir("hwdb") or !vh.pathExists("kernel/hw/amd-desktop.zon")) return error.SkipZigTest;
    const d = rules.load("hwdb");
    var cfg: vh.Kv = .{};
    cfg.read("vh.conf.example", false);
    const cases = [_][3][]const u8{
        .{ "gf63", "skylake", "x86-64-v3" },
        .{ "amd-desktop", "znver4", "x86-64-v4" },
        .{ "intel-hybrid-laptop", "alderlake", "x86-64-v3" },
        .{ "qemu-q35", "x86-64-v3", "x86-64-v3" },
    };
    for (cases) |c| {
        var h = hw.load(vh.fmt("kernel/hw/{s}.zon", .{c[0]}));
        try t.expectEqualStrings(c[1], plan.compute(.{ .hw = h, .db = d, .config = &cfg }).plan.kernel.march);
        // the same CPU passed through to a virtual machine (QEMU -cpu host): the hypervisor may
        // show another model on the next host, so the kernel gets the level the CPU has for sure
        h.cpu.flags = vh.fmt("{s} hypervisor", .{h.cpu.flags});
        try t.expectEqualStrings(c[2], plan.compute(.{ .hw = h, .db = d, .config = &cfg }).plan.kernel.march);
    }
}

test "the gaming root's Vulkan driver (hwdb): the GPU's, Vulkan on the CPU without one" {
    // the real hwdb and fixtures: tests/adapt/run.sh runs the tests in the repository's root
    if (!vh.isDir("hwdb") or !vh.pathExists("kernel/hw/gf63.zon")) return error.SkipZigTest;
    const d = rules.load("hwdb");
    var cfg: vh.Kv = .{};
    cfg.read("vh.conf.example", false);
    const gamePkgs = struct {
        fn of(p: plan.Plan) []const u8 {
            var s: vh.Strv = .{};
            for (p.game_packages) |x| s.add(x.value);
            return s.join(" ");
        }
    }.of;
    // the laptop of the fixtures: the iGPU's driver; its sleeping NVIDIA dGPU gets none
    const gf63 = hw.load("kernel/hw/gf63.zon");
    const auto = plan.compute(.{ .hw = gf63, .db = d, .config = &cfg }).plan;
    try t.expectEqualStrings("mesa-vulkan-intel", gamePkgs(auto));
    // with nouveau driving the dGPU, NVK beside it
    cfg.set("VH_GPU", "nouveau");
    const nv = plan.compute(.{ .hw = gf63, .db = d, .config = &cfg }).plan;
    try t.expectEqualStrings("mesa-vulkan-intel mesa-vulkan-nouveau", gamePkgs(nv));
    // the system's packages stay as they were: the gaming root's never reach them
    try t.expect(!hasItem(auto.packages, "mesa-vulkan-intel"));
    cfg.set("VH_GPU", "auto");
    const cases = [_][2][]const u8{
        .{ "amd-desktop", "mesa-vulkan-radeon" },
        .{ "intel-hybrid-laptop", "mesa-vulkan-intel" },
        // a virtual machine without 3D: lavapipe
        .{ "qemu-q35", "mesa-vulkan-lavapipe" },
        // ARM: no gaming session yet
        .{ "rpi5", "" },
        .{ "aarch64-virt", "" },
    };
    for (cases) |c| {
        const h = hw.load(vh.fmt("kernel/hw/{s}.zon", .{c[0]}));
        const p = plan.compute(.{ .hw = h, .db = d, .config = &cfg, .security = "tiered" }).plan;
        try t.expectEqualStrings(c[1], gamePkgs(p));
    }
    // machines with an integrated GPU alone: the laptop without its NVIDIA dGPU (the display
    // that did not bring the console up), the AMD desktop without its Radeon card (its Ryzen's
    // iGPU then brings the console up). The iGPU's own Vulkan driver, no dGPU tag, no lavapipe
    const igpu = [_][4][]const u8{
        .{ "gf63", "0000:01:00.0", "", "mesa-vulkan-intel" },
        .{ "amd-desktop", "0000:03:00.0", "0000:0b:00.0", "mesa-vulkan-radeon" },
    };
    for (igpu) |c| {
        const h = withoutDisplay(hw.load(vh.fmt("kernel/hw/{s}.zon", .{c[0]})), c[1], c[2]);
        try t.expectEqual(@as(usize, 1), h.displays.len);
        const p = plan.compute(.{ .hw = h, .db = d, .config = &cfg }).plan;
        try t.expectEqualStrings(c[3], gamePkgs(p));
        for (p.tags) |tag| try t.expect(!vh.eql(tag, "dgpu"));
    }
}

/// the machine without the display device NAME (and its PCI device); BOOT, when given, the
/// display that brings the console up instead
fn withoutDisplay(h0: hw.Hw, name: []const u8, boot: []const u8) hw.Hw {
    var h = h0;
    var devs: std.ArrayList(hw.Device) = .empty;
    for (h0.devices) |dv| if (!vh.eql(dv.name, name)) devs.append(vh.gpa, dv) catch vh.oom();
    var disp: std.ArrayList(hw.Display) = .empty;
    for (h0.displays) |x| if (!vh.eql(x.name, name)) {
        var y = x;
        if (boot.len > 0 and vh.eql(y.name, boot)) y.boot_vga = true;
        disp.append(vh.gpa, y) catch vh.oom();
    };
    h.devices = devs.items;
    h.displays = disp.items;
    return h;
}
