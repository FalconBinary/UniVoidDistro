//! The plan of one machine: hw.zon, hwdb/ and the user's vh.conf -> every decision with the
//! rules that made it, and the security gate. Deterministic: rules are evaluated in hwdb file
//! order, then rule order; every list is sorted on output.
const std = @import("std");
const vh = @import("vh");
const hw = @import("hw");
const alias = @import("alias");
const rules = @import("rules.zig");
const facts = @import("facts.zig");
const mem = std.mem;

pub const Item = struct {
    value: []const u8,
    /// the ids of the rules that put it here, in rule order
    rules: []const []const u8 = &.{},
};

pub const ScalarItem = struct {
    key: []const u8,
    value: []const u8,
    rule: []const u8,
};

pub const Missing = struct {
    id: []const u8,
    why: []const u8,
    risk: []const u8 = "",
    fix: []const u8 = "",
    floor: bool = false,
};

pub const Luks = struct {
    cipher: []const u8 = "aes-xts-plain64",
    key_size: u32 = 512,
    pbkdf_memory_kib: u64 = 1048576,
    pbkdf_parallel: u32 = 4,
};

pub const Kernel = struct {
    /// what NR_CPUS of a kernel for this machine covers
    nr_cpus: u32 = 0,
    /// the compiler's -march for a kernel built elsewhere (CI); "" when no rule names one
    march: []const u8 = "",
};

pub const Plan = struct {
    format: u32 = 1,
    tool: []const u8 = "vh-plan",
    /// the probe's source: "live" or the fixture's name
    machine: []const u8 = "",
    arch: []const u8 = "",
    /// full, reduced or refused
    tier: []const u8 = "full",
    /// strict or tiered
    security: []const u8 = "strict",
    tags: []const []const u8 = &.{},
    /// the requirements the machine does not meet
    missing: []const Missing = &.{},
    /// what the user confirms in tiered mode: the ids of the missing requirements
    acknowledge: []const []const u8 = &.{},
    scalars: []const ScalarItem = &.{},
    packages: []const Item = &.{},
    kconfig: []const Item = &.{},
    features: []const Item = &.{},
    firmware: []const Item = &.{},
    cmdline: []const Item = &.{},
    services: []const Item = &.{},
    udev: []const Item = &.{},
    deny: []const Item = &.{},
    dracut: []const Item = &.{},
    /// the modules the machine's devices need, after the deny list
    modules: []const Item = &.{},
    /// the built-in keyboards vh-acpid cannot tell by their bus (it knows i8042 and I2C): the
    /// place of each under /sys/devices, "/pci0000:00/0000:00:14.0/usb1/1-8/" (acpi.conf's
    /// INTERNAL_INPUT, the physical input of its idle watchdog)
    internal_input: []const Item = &.{},
    exports: []const ScalarItem = &.{},
    notes: []const Item = &.{},
    luks: Luks = .{},
    kernel: Kernel = .{},
    /// devices with no driver, no module in the tables and no rule: new hardware shows up here
    unknown: []const []const u8 = &.{},
    /// every udev rule file a rule of hwdb can name: the installer removes those not in udev
    udev_known: []const []const u8 = &.{},
};

pub const Opts = struct {
    hw: hw.Hw,
    db: rules.Db,
    /// the KEY=VALUE configuration (vh.conf.example, then vh.conf, then --set)
    config: *const vh.Kv,
    /// strict or tiered; "" takes VH_SECURITY of the configuration
    security: []const u8 = "",
    /// the stock kernel's tables, null when there are none for this architecture
    table: ?*const alias.Table = null,
    /// module -> firmware files (kernel/pins/modules.firmware)
    firmware: ?*const FirmwareTable = null,
};

/// module -> the firmware files it names
pub const FirmwareTable = struct {
    map: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,

    /// "MODULE FILE" lines, "#" comments
    pub fn load(self: *FirmwareTable, text: []const u8) void {
        var lines = mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = vh.strip(raw);
            if (line.len == 0 or line[0] == '#') continue;
            var it = mem.tokenizeAny(u8, line, " \t");
            const m = alias.normalize(it.next() orelse continue);
            const f = it.next() orelse continue;
            const gop = self.map.getOrPut(vh.gpa, m) catch vh.oom();
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.append(vh.gpa, vh.dupe(f)) catch vh.oom();
        }
    }

    pub fn of(self: *const FirmwareTable, module: []const u8) []const []const u8 {
        return if (self.map.get(module)) |l| l.items else &.{};
    }
};

/// A firmware file a module names, as a pattern of what to keep: the version of an iwlwifi-style
/// "NAME-77.ucode" becomes "*" (the driver walks down from the newest API it knows), and "*" is
/// appended for the compressed ".zst" Void ships.
pub fn firmwarePattern(file: []const u8) []const u8 {
    if (vh.endsWith(file, ".ucode")) {
        const stem = file[0 .. file.len - ".ucode".len];
        if (mem.lastIndexOfScalar(u8, stem, '-')) |dash| {
            var digits = stem.len > dash + 1;
            for (stem[dash + 1 ..]) |c| digits = digits and std.ascii.isDigit(c);
            if (digits) return vh.fmt("{s}-*", .{stem[0..dash]});
        }
    }
    return vh.fmt("{s}*", .{file});
}

/// an ordered set of values, each with the rules that named it
const Bag = struct {
    map: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,

    fn add(self: *Bag, value: []const u8, rule: []const u8) void {
        const gop = self.map.getOrPut(vh.gpa, value) catch vh.oom();
        if (!gop.found_existing) {
            gop.key_ptr.* = vh.dupe(value);
            gop.value_ptr.* = .empty;
        }
        for (gop.value_ptr.items) |r| if (vh.eql(r, rule)) return;
        gop.value_ptr.append(vh.gpa, rule) catch vh.oom();
    }

    fn has(self: *const Bag, value: []const u8) bool {
        return self.map.contains(value);
    }

    /// the items, sorted by value (sorted = false keeps the order they came in)
    fn items(self: *const Bag, sorted: bool) []const Item {
        var out: std.ArrayList(Item) = .empty;
        for (self.map.keys(), self.map.values()) |k, v| out.append(vh.gpa, .{ .value = k, .rules = v.items }) catch vh.oom();
        if (sorted) mem.sort(Item, out.items, {}, struct {
            fn less(_: void, a: Item, b: Item) bool {
                return mem.order(u8, a.value, b.value) == .lt;
            }
        }.less);
        return out.items;
    }
};

pub const Result = struct {
    plan: Plan,
    /// the human report, every line deterministic
    report: []const u8,
    /// exit status: 0, or 3 when the gate refuses the machine
    status: u8,
};

// ---------------------------------------------------------------- matching

fn anyGlob(patterns: []const []const u8, s: []const u8) bool {
    for (patterns) |p| if (alias.fnmatch(p, s)) return true;
    return false;
}

fn anyEqualFold(values: []const []const u8, s: []const u8) bool {
    for (values) |v| if (std.ascii.eqlIgnoreCase(v, s)) return true;
    return false;
}

fn dmiField(h: hw.Hw, field: []const u8) ?[]const u8 {
    const m = h.machine;
    if (vh.eql(field, "sys_vendor")) return m.sys_vendor;
    if (vh.eql(field, "product_name")) return m.product_name;
    if (vh.eql(field, "product_family")) return m.product_family;
    if (vh.eql(field, "product_version")) return m.product_version;
    if (vh.eql(field, "board_vendor")) return m.board_vendor;
    if (vh.eql(field, "board_name")) return m.board_name;
    if (vh.eql(field, "bios_vendor")) return m.bios_vendor;
    if (vh.eql(field, "chassis_type")) return m.chassis_type;
    return null;
}

fn hasFlag(flags: []const u8, flag: []const u8) bool {
    var it = mem.tokenizeScalar(u8, flags, ' ');
    while (it.next()) |f| if (vh.eql(f, flag)) return true;
    return false;
}

fn deviceHolds(d: facts.Dev, w: rules.DeviceMatch) bool {
    if (w.bus.len > 0 and !anyEqualFold(w.bus, d.d.bus)) return false;
    if (w.pci_vendor.len > 0 and !anyEqualFold(w.pci_vendor, d.pci_vendor)) return false;
    if (w.pci_device.len > 0 and !anyEqualFold(w.pci_device, d.pci_device)) return false;
    if (w.pci_class.len > 0) {
        if (d.pci_class.len == 0) return false;
        var ok = false;
        for (w.pci_class) |c| ok = ok or (c.len <= d.pci_class.len and std.ascii.eqlIgnoreCase(c, d.pci_class[0..c.len]));
        if (!ok) return false;
    }
    if (w.usb_vendor.len > 0 and !anyEqualFold(w.usb_vendor, d.usb_vendor)) return false;
    if (w.usb_product.len > 0 and !anyEqualFold(w.usb_product, d.usb_product)) return false;
    if (w.usb_class.len > 0 and !anyEqualFold(w.usb_class, d.usb_class)) return false;
    if (w.acpi_id.len > 0) {
        var ok = false;
        for (d.acpi_ids) |id| ok = ok or anyEqualFold(w.acpi_id, id);
        if (!ok) return false;
    }
    if (w.dt_compatible.len > 0) {
        var ok = false;
        for (d.dt_compatible) |c| ok = ok or anyGlob(w.dt_compatible, c);
        if (!ok) return false;
    }
    if (w.modalias.len > 0 and !anyGlob(w.modalias, d.d.modalias)) return false;
    if (w.module.len > 0) {
        var ok = false;
        for (d.candidates) |m| ok = ok or anyGlob(w.module, m);
        if (!ok) return false;
    }
    if (w.driver.len > 0 and (d.d.driver.len == 0 or !anyGlob(w.driver, d.d.driver))) return false;
    if (w.boot_vga) |want| {
        const got = d.boot_vga orelse return false;
        if (got != want) return false;
    }
    return true;
}

const Ctx = struct {
    m: *const facts.Machine,
    config: *const vh.Kv,
    tags: *const vh.Strv,
};

/// whether `w` holds; the indexes of the devices that satisfy its device condition go to `matched`
fn holds(c: Ctx, w: rules.When, matched: ?*std.ArrayList(usize)) bool {
    const m = c.m;
    const h = m.hw;
    if (w.arch.len > 0 and !anyEqualFold(w.arch, m.arch)) return false;
    if (w.cpu_vendor.len > 0 and !anyEqualFold(w.cpu_vendor, h.cpu.vendor)) return false;
    for (w.cpu_flags) |f| if (!hasFlag(h.cpu.flags, f)) return false;
    if (w.cpu_family) |f| if (h.cpu.family != f) return false;
    if (w.cpu_model.len > 0 and mem.indexOfScalar(u32, w.cpu_model, h.cpu.model) == null) return false;
    if (w.cpu_model_min) |x| if (h.cpu.model < x) return false;
    if (w.cpu_model_max) |x| if (h.cpu.model > x) return false;
    if (w.arm_implementer.len > 0 and !anyEqualFold(w.arm_implementer, h.cpu.implementer)) return false;
    if (w.arm_part.len > 0 and !anyEqualFold(w.arm_part, h.cpu.part)) return false;
    if (w.dt_compatible.len > 0) {
        var ok = false;
        for (h.firmware.dt_compatible) |x| ok = ok or anyGlob(w.dt_compatible, x);
        if (!ok) return false;
    }
    for (w.dmi) |d| {
        const v = dmiField(h, d.field) orelse vh.die("hwdb: unknown DMI field {s}", .{d.field});
        if (!anyGlob(d.any, v)) return false;
    }
    if (w.acpi_table.len > 0) {
        var ok = false;
        for (h.firmware.acpi_tables) |t| ok = ok or anyEqualFold(w.acpi_table, t);
        if (!ok) return false;
    }
    for (w.has) |t| if (!c.tags.has(t)) return false;
    for (w.lacks) |t| if (c.tags.has(t)) return false;
    if (w.ram_min_mib) |x| if (m.ram_mib < x) return false;
    if (w.ram_max_mib) |x| if (m.ram_mib > x) return false;
    if (w.cpus_min) |x| if (m.cpus < x) return false;
    if (w.cpus_max) |x| if (m.cpus > x) return false;
    for (w.config) |k| {
        var ok = false;
        for (k.any) |v| ok = ok or vh.eql(c.config.get(k.key, ""), v);
        if (!ok) return false;
    }
    if (w.device) |dm| {
        var any = false;
        for (m.devs, 0..) |d, i| {
            if (!deviceHolds(d, dm)) continue;
            any = true;
            if (matched) |list| list.append(vh.gpa, i) catch vh.oom();
        }
        if (!any) return false;
    }
    return true;
}

fn applies(c: Ctx, r: rules.Rule, matched: ?*std.ArrayList(usize)) bool {
    if (!holds(c, r.when, matched)) return false;
    if (r.unless) |u| {
        if (holds(c, u, null)) {
            if (matched) |list| list.clearRetainingCapacity();
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------- the plan

fn sameSet(a: *const vh.Strv, b: *const vh.Strv) bool {
    if (a.len() != b.len()) return false;
    for (a.slice()) |x| if (!b.has(x)) return false;
    return true;
}

/// the tags: the built-in ones, then what the rules set, until nothing changes. A pass
/// starts from the built-in tags again, so a rule whose `unless` or `lacks` undoes another's
/// tag shows as a cycle instead of a result that depends on the order.
fn settleTags(m: *const facts.Machine, db: rules.Db, config: *const vh.Kv) vh.Strv {
    var tags: vh.Strv = .{};
    for (m.tags.slice()) |t| tags.add(t);
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var next: vh.Strv = .{};
        for (m.tags.slice()) |t| next.add(t);
        const c: Ctx = .{ .m = m, .config = config, .tags = &tags };
        for (db.rules) |r| {
            if (r.sets.len == 0 or !applies(c, r, null)) continue;
            for (r.sets) |t| if (!next.has(t)) next.add(t);
        }
        next.sort();
        if (sameSet(&next, &tags)) return next;
        tags = next;
    }
    vh.die("hwdb: the tags do not settle after 8 passes (a rule's unless or lacks undoes the tag of another)", .{});
}

const ScalarState = struct { value: []const u8, priority: u32, rule: []const u8 };

const Narrow = struct {
    priority: u32,
    /// pattern, rule
    patterns: std.ArrayList([2][]const u8) = .empty,
    /// the rule that leaves the module no firmware, "" when none does
    none_rule: []const u8 = "",
};

pub fn compute(o: Opts) Result {
    const m = facts.build(o.hw, o.table);
    var rep: std.ArrayList(u8) = .empty;
    const w = struct {
        fn line(r: *std.ArrayList(u8), comptime f: []const u8, args: anytype) void {
            r.print(vh.gpa, f ++ "\n", args) catch vh.oom();
        }
    }.line;

    const security = if (o.security.len > 0) o.security else o.config.get("VH_SECURITY", "strict");
    if (!vh.eql(security, "strict") and !vh.eql(security, "tiered")) vh.die("VH_SECURITY must be strict or tiered, not {s}", .{security});

    var tags = settleTags(&m, o.db, o.config);
    const c: Ctx = .{ .m = &m, .config = o.config, .tags = &tags };

    var packages: Bag = .{};
    var kconfig: Bag = .{};
    var features: Bag = .{};
    var fw: Bag = .{};
    var cmdline: Bag = .{};
    var services: Bag = .{};
    var udev: Bag = .{};
    var deny: Bag = .{};
    var dracut: Bag = .{};
    var extra_modules: Bag = .{};
    var notes: Bag = .{};
    var scalars: std.StringArrayHashMapUnmanaged(ScalarState) = .empty;
    var conflicts: std.ArrayList([]const u8) = .empty;
    var exports: std.ArrayList(ScalarItem) = .empty;
    // module -> the narrowing patterns of its firmware, with the rule; only the rules of the
    // highest priority count, so a rule for one device overrides the module's general one
    var narrow: std.StringArrayHashMapUnmanaged(Narrow) = .empty;
    var claimed: std.AutoHashMapUnmanaged(usize, void) = .empty;
    var applied: std.ArrayList(usize) = .empty;

    for (o.db.rules, 0..) |r, ri| {
        var matched: std.ArrayList(usize) = .empty;
        if (!applies(c, r, &matched)) continue;
        applied.append(vh.gpa, ri) catch vh.oom();
        for (matched.items) |i| claimed.put(vh.gpa, i, {}) catch vh.oom();
        for (r.packages) |x| packages.add(x, r.id);
        for (r.kconfig) |x| kconfig.add(x, r.id);
        for (r.features) |x| features.add(x, r.id);
        for (r.firmware) |x| fw.add(x, r.id);
        for (r.cmdline) |x| cmdline.add(x, r.id);
        for (r.services) |x| services.add(x, r.id);
        for (r.udev) |x| udev.add(x, r.id);
        for (r.deny) |x| deny.add(alias.normalize(x), r.id);
        for (r.dracut) |x| dracut.add(alias.normalize(x), r.id);
        for (r.modules) |x| extra_modules.add(alias.normalize(x), r.id);
        if (r.note.len > 0) notes.add(r.note, r.id);
        if (r.firmware_only.len > 0 or r.firmware_none) {
            if (matched.items.len == 0) vh.die("hwdb: rule {s} narrows firmware but matches no device", .{r.id});
            for (matched.items) |i| for (m.devs[i].modules) |mod| {
                const gop = narrow.getOrPut(vh.gpa, mod) catch vh.oom();
                if (!gop.found_existing) gop.value_ptr.* = .{ .priority = r.priority };
                const n = gop.value_ptr;
                if (r.priority < n.priority) continue;
                if (r.priority > n.priority) {
                    n.priority = r.priority;
                    n.patterns.clearRetainingCapacity();
                    n.none_rule = "";
                }
                for (r.firmware_only) |p| n.patterns.append(vh.gpa, .{ p, r.id }) catch vh.oom();
                if (r.firmware_none) n.none_rule = r.id;
            };
        }
        for (r.@"export") |e| {
            if (matched.items.len == 0) continue;
            const d = m.devs[matched.items[0]];
            const v = if (vh.eql(e.from, "pci_vendor")) vh.fmt("0x{s}", .{d.pci_vendor}) else if (vh.eql(e.from, "pci_device")) vh.fmt("0x{s}", .{d.pci_device}) else if (vh.eql(e.from, "name")) d.d.name else vh.die("hwdb: rule {s} exports unknown property {s}", .{ r.id, e.from });
            exports.append(vh.gpa, .{ .key = e.key, .value = v, .rule = r.id }) catch vh.oom();
        }
        for (r.set) |s| setScalar(&scalars, &conflicts, s, r.priority, r.id);
    }

    // the modules of the machine: every device's, then what rules add, minus the deny list
    var modules: Bag = .{};
    var unknown: vh.Strv = .{};
    for (m.devs, 0..) |d, i| {
        for (d.modules) |mod| {
            if (deny.has(mod)) continue;
            modules.add(mod, vh.fmt("device {s} {s}", .{ d.d.bus, d.d.name }));
        }
        if (d.modules.len == 0 and d.d.driver.len == 0 and !claimed.contains(i)) unknown.add(vh.fmt("{s} {s} {s}", .{ d.d.bus, d.d.name, d.d.modalias }));
    }
    for (extra_modules.items(false)) |x| if (!deny.has(x.value)) for (x.rules) |r| modules.add(x.value, r);

    // the firmware: what each module names, narrowed where a rule knows the device
    var not_narrowed: vh.Strv = .{};
    for (modules.items(true)) |x| {
        if (narrow.get(x.value)) |n| {
            for (n.patterns.items) |pr| fw.add(pr[0], pr[1]);
            continue;
        }
        const ft = o.firmware orelse continue;
        const files = ft.of(x.value);
        if (files.len == 0) continue;
        for (files) |f| fw.add(firmwarePattern(f), vh.fmt("module {s}", .{x.value}));
        if (files.len > 8) not_narrowed.add(vh.fmt("{s} ({d} files)", .{ x.value, files.len }));
    }

    // the initrd: every driver on the way from a keyboard to its controller
    for (m.hw.keyboards) |k| for (k.drivers) |l| {
        if (l.module.len == 0) continue;
        dracut.add(alias.normalize(l.module), vh.fmt("keyboard {s}", .{k.bus}));
    };
    // vh-acpid's idle watchdog counts the input of built-in devices only; it knows the i8042
    // and I2C ones by their bus. A keyboard on internal USB (the kernel calls its USB device
    // fixed), on SPI or on the host bus is built in as well: its place goes to INTERNAL_INPUT
    var internal: Bag = .{};
    for (m.hw.keyboards) |k| {
        if (k.path.len == 0) continue;
        if (vh.eql(k.bus, "usb") and vh.eql(k.removable, "fixed")) {
            internal.add(vh.fmt("/{s}/", .{k.path}), "keyboard usb, fixed");
        } else if (vh.eql(k.bus, "spi") or vh.eql(k.bus, "host")) {
            internal.add(vh.fmt("/{s}/", .{k.path}), vh.fmt("keyboard {s}", .{k.bus}));
        }
    }

    // the security gate
    var missing: std.ArrayList(Missing) = .empty;
    var refused = false;
    for (o.db.requirements) |q| {
        if (q.only) |only| if (!holds(c, only, null)) continue;
        if (holds(c, q.when, null)) continue;
        missing.append(vh.gpa, .{ .id = q.id, .why = q.why, .risk = q.risk, .fix = q.fix, .floor = q.floor }) catch vh.oom();
        if (q.floor) refused = true;
    }
    const tier: []const u8 = if (refused) "refused" else if (missing.items.len > 0) "reduced" else "full";
    var acknowledge: vh.Strv = .{};
    if (vh.eql(tier, "reduced") and vh.eql(security, "tiered")) {
        for (o.db.requirements) |q| for (missing.items) |x| if (vh.eql(x.id, q.id)) {
            acknowledge.add(q.id);
            for (q.otherwise) |s| setScalar(&scalars, &conflicts, s, 1000, vh.fmt("requirement {s}", .{q.id}));
        };
    }

    // LUKS: AES-XTS with 1 GiB of Argon2id memory unless a requirement says otherwise
    var luks: Luks = .{};
    if (scalars.get("luks_cipher")) |s| {
        luks.cipher = s.value;
        if (!vh.eql(s.value, "aes-xts-plain64")) luks.key_size = 256;
    }
    if (scalars.get("luks_memory")) |s| {
        if (vh.eql(s.value, "quarter-of-ram")) {
            const quarter = (m.hw.memory.total_kib / 4) / 65536 * 65536;
            luks.pbkdf_memory_kib = @max(@min(quarter, 1048576), 262144);
        }
    }
    luks.pbkdf_parallel = @intCast(@max(@min(m.hw.cpu.threads, 4), 1));

    var scalar_items: std.ArrayList(ScalarItem) = .empty;
    for (scalars.keys(), scalars.values()) |k, v| scalar_items.append(vh.gpa, .{ .key = k, .value = v.value, .rule = v.rule }) catch vh.oom();
    mem.sort(ScalarItem, scalar_items.items, {}, struct {
        fn less(_: void, a: ScalarItem, b: ScalarItem) bool {
            return mem.order(u8, a.key, b.key) == .lt;
        }
    }.less);

    var plan: Plan = .{
        .machine = m.hw.probe.source,
        .arch = m.arch,
        .tier = tier,
        .security = security,
        .tags = tags.slice(),
        .missing = missing.items,
        .acknowledge = acknowledge.slice(),
        .scalars = scalar_items.items,
        .packages = packages.items(true),
        .kconfig = kconfig.items(true),
        .features = features.items(true),
        .firmware = fw.items(true),
        .cmdline = cmdline.items(false),
        .services = services.items(true),
        .udev = udev.items(true),
        .deny = deny.items(true),
        .dracut = dracut.items(true),
        .modules = modules.items(true),
        .internal_input = internal.items(true),
        .exports = exports.items,
        .notes = notes.items(false),
        .luks = luks,
        .kernel = .{ .nr_cpus = m.cpus, .march = if (scalars.get("march")) |s| s.value else "" },
        .unknown = unknown.slice(),
    };
    unknown.sort();
    plan.unknown = unknown.slice();
    var known: vh.Strv = .{};
    for (o.db.rules) |r| for (r.udev) |u| if (!known.has(u)) known.add(u);
    known.sort();
    plan.udev_known = known.slice();

    // the report
    w(&rep, "vh-plan report", .{});
    w(&rep, "machine: {s} ({s} {s}; {s}), arch {s}, {d} MiB, {d} CPUs", .{ plan.machine, m.hw.machine.sys_vendor, m.hw.machine.product_name, m.hw.cpu.model_name, m.arch, m.ram_mib, m.cpus });
    w(&rep, "module tables: {s}", .{if (m.tables) "the pinned stock kernel's" else "none for this architecture: only the drivers the running system bound"});
    w(&rep, "security: {s}; tier: {s}", .{ security, tier });
    w(&rep, "tags: {s}", .{tags.join(" ")});
    w(&rep, "", .{});
    w(&rep, "Rules that apply ({d}):", .{applied.items.len});
    for (applied.items) |ri| {
        const r = o.db.rules[ri];
        w(&rep, "  {s} [{s}]: {s}", .{ r.id, o.db.origin[ri], r.why });
    }
    if (missing.items.len > 0) {
        w(&rep, "", .{});
        w(&rep, "Requirements not met ({d}):", .{missing.items.len});
        for (missing.items) |x| {
            w(&rep, "  {s}{s}: {s}", .{ x.id, if (x.floor) " (refused in any mode)" else "", x.why });
            if (x.risk.len > 0) w(&rep, "    residual risk: {s}", .{x.risk});
            if (x.fix.len > 0) w(&rep, "    fix: {s}", .{x.fix});
        }
    }
    const lists = [_]struct { name: []const u8, items: []const Item }{
        .{ .name = "packages", .items = plan.packages },
        .{ .name = "kernel class fragments", .items = plan.kconfig },
        .{ .name = "kernel features", .items = plan.features },
        .{ .name = "firmware kept", .items = plan.firmware },
        .{ .name = "command line", .items = plan.cmdline },
        .{ .name = "services", .items = plan.services },
        .{ .name = "udev rules", .items = plan.udev },
        .{ .name = "denied modules", .items = plan.deny },
        .{ .name = "initrd drivers", .items = plan.dracut },
        .{ .name = "internal input (vh-acpid)", .items = plan.internal_input },
        .{ .name = "notes", .items = plan.notes },
    };
    for (lists) |l| {
        w(&rep, "", .{});
        w(&rep, "{s} ({d}):", .{ l.name, l.items.len });
        for (l.items) |x| w(&rep, "  {s}  <- {s}", .{ x.value, mem.join(vh.gpa, ", ", x.rules) catch vh.oom() });
    }
    w(&rep, "", .{});
    w(&rep, "scalars ({d}):", .{plan.scalars.len});
    for (plan.scalars) |s| w(&rep, "  {s} = {s}  <- {s}", .{ s.key, s.value, s.rule });
    for (plan.exports) |e| w(&rep, "  export {s} = {s}  <- {s}", .{ e.key, e.value, e.rule });
    w(&rep, "", .{});
    w(&rep, "LUKS: {s}, {d}-bit key, Argon2id {d} KiB, {d} threads", .{ luks.cipher, luks.key_size, luks.pbkdf_memory_kib, luks.pbkdf_parallel });
    w(&rep, "kernel: NR_CPUS {d}, -march {s}", .{ plan.kernel.nr_cpus, if (plan.kernel.march.len > 0) plan.kernel.march else "(none: generic)" });
    w(&rep, "modules of the devices ({d}): {s}", .{ plan.modules.len, joinValues(plan.modules) });
    if (not_narrowed.len() > 0) w(&rep, "firmware not narrowed to the device (every file the module names is kept): {s}", .{not_narrowed.join(", ")});
    if (conflicts.items.len > 0) {
        w(&rep, "", .{});
        w(&rep, "Scalar conflicts ({d}): the first value stays", .{conflicts.items.len});
        for (conflicts.items) |x| w(&rep, "  {s}", .{x});
    }
    w(&rep, "", .{});
    w(&rep, "Devices no driver, table or rule knows ({d}):", .{plan.unknown.len});
    for (plan.unknown) |x| w(&rep, "  {s}", .{x});

    const refuse = vh.eql(tier, "refused") or (vh.eql(tier, "reduced") and vh.eql(security, "strict"));
    return .{ .plan = plan, .report = rep.items, .status = if (refuse) 3 else 0 };
}

fn joinValues(items: []const Item) []const u8 {
    var s: vh.Strv = .{};
    for (items) |x| s.add(x.value);
    return s.join(" ");
}

fn setScalar(scalars: *std.StringArrayHashMapUnmanaged(ScalarState), conflicts: *std.ArrayList([]const u8), s: rules.Scalar, priority: u32, rule: []const u8) void {
    const gop = scalars.getOrPut(vh.gpa, s.key) catch vh.oom();
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .value = s.value, .priority = priority, .rule = rule };
        return;
    }
    const cur = gop.value_ptr.*;
    if (priority > cur.priority) {
        gop.value_ptr.* = .{ .value = s.value, .priority = priority, .rule = rule };
    } else if (priority == cur.priority and !vh.eql(cur.value, s.value)) {
        conflicts.append(vh.gpa, vh.fmt("{s}: {s} = {s}, {s} = {s}", .{ s.key, cur.rule, cur.value, rule, s.value })) catch vh.oom();
    }
}

test "firmware patterns" {
    try std.testing.expectEqualStrings("iwlwifi-QuZ-a0-hr-b0-*", firmwarePattern("iwlwifi-QuZ-a0-hr-b0-77.ucode"));
    try std.testing.expectEqualStrings("i915/kbl_dmc_ver1_04.bin*", firmwarePattern("i915/kbl_dmc_ver1_04.bin"));
    try std.testing.expectEqualStrings("rtl_nic/rtl8168h-2.fw*", firmwarePattern("rtl_nic/rtl8168h-2.fw"));
    try std.testing.expectEqualStrings("some-thing.ucode*", firmwarePattern("some-thing.ucode"));
}
