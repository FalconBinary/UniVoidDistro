//! vh-kconf resolve (v1): hw.zon + the stock kernel's alias tables + the profile fragments
//! -> what `make localyesconfig olddefconfig` needs. Not a Kconfig solver: it writes the
//! LSMOD list (every module this machine's modaliases name, plus what was loaded), the merged
//! fragment, the pinned .config with the fragment applied, and a report of every decision.
const std = @import("std");
const vh = @import("vh");
const hw = @import("hw.zig");
const alias = @import("alias.zig");
const kconfig = @import("kconfig.zig");
const mem = std.mem;

pub const Opts = struct {
    hw: []const u8,
    out: []const u8,
    /// the stock kernel's tables; by default those of the kernel the probe ran under
    alias: ?[]const u8 = null,
    builtin: ?[]const u8 = null,
    builtin_list: ?[]const u8 = null,
    /// the pinned .config and the profiles; --repo DIR sets both to DIR/kernel/...
    base: ?[]const u8 = null,
    profiles: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    /// comma-separated feature names, "auto" (from hw.zon), "none"
    features: []const u8 = "usb-common,bluetooth",
};

/// the fragments in the order they are applied; the features follow
const fixed_fragments = [_][]const u8{ "base", "mandatory", "hardening", "perf" };
pub const all_features = [_][]const u8{ "usb-common", "bluetooth", "camera", "virt", "game" };

const Conflict = struct { name: []const u8, first_src: []const u8, first: []const u8, src: []const u8, value: []const u8 };

pub const Result = struct {
    lsmod: vh.Strv = .{},
    fragment: kconfig.DotConfig = .{},
    sources: std.StringHashMapUnmanaged([]const u8) = .empty,
    config: kconfig.DotConfig = .{},
    conflicts: std.ArrayList(Conflict) = .empty,
    report: std.ArrayList(u8) = .empty,
    features: vh.Strv = .{},
    denied: vh.Strv = .{},
    unmatched: usize = 0,
};

pub fn run(o: Opts) u8 {
    const h = hw.load(o.hw);
    const r = resolve(h, o);
    vh.mkdirs(o.out, 0o755);
    vh.writeAtomic(vh.fmt("{s}/lsmod", .{o.out}), vh.fmt("{s}\n", .{r.lsmod.join("\n")}), 0o644);
    vh.writeAtomic(vh.fmt("{s}/fragment.config", .{o.out}), renderFragment(&r), 0o644);
    vh.writeAtomic(vh.fmt("{s}/.config", .{o.out}), r.config.render(), 0o644);
    vh.writeAtomic(vh.fmt("{s}/resolve-report.txt", .{o.out}), r.report.items, 0o644);
    vh.out("{s}: {d} modules in LSMOD, {d} fragment symbols ({d} conflicts), {d} refused; report in {s}/resolve-report.txt\n", .{ o.hw, r.lsmod.len(), r.fragment.count(), r.conflicts.items.len, r.denied.len(), o.out });
    return 0;
}

fn pathOf(o: Opts, explicit: ?[]const u8, under_repo: []const u8, under_modules: ?[]const u8, kernel: []const u8) []const u8 {
    if (explicit) |p| return p;
    if (o.repo) |r| return vh.fmt("{s}/{s}", .{ r, under_repo });
    if (under_modules) |m| {
        if (kernel.len > 0) return vh.fmt("/usr/lib/modules/{s}/{s}", .{ kernel, m });
    }
    vh.die("{s}: give the path, or --repo DIR", .{under_repo});
}

pub fn resolve(h: hw.Hw, o: Opts) Result {
    var r: Result = .{};
    const rep = &r.report;
    const alias_path = pathOf(o, o.alias, "kernel/pins/modules.alias", "modules.alias", h.probe.kernel);
    const builtin_path = pathOf(o, o.builtin, "kernel/pins/modules.builtin.modinfo", "modules.builtin.modinfo", h.probe.kernel);
    const builtin_list_path = pathOf(o, o.builtin_list, "kernel/pins/modules.builtin", "modules.builtin", h.probe.kernel);
    const base_path = pathOf(o, o.base, "kernel/pins/x86_64-dotconfig", null, "");
    const profiles = pathOf(o, o.profiles, "kernel/profiles", null, "");

    var table: alias.Table = .{};
    table.loadAliases(readOrDie(alias_path));
    table.loadBuiltinModinfo(readOrDie(builtin_path));
    if (vh.readFile(builtin_list_path)) |t| table.loadBuiltinList(t) else |_| {}

    // features: explicit, auto-detected from the probe, or none
    r.features = features(h, o.features);
    for (r.features.slice()) |f| {
        var known = false;
        for (all_features) |k| if (vh.eql(k, f)) {
            known = true;
        };
        if (!known) vh.die("unknown feature {s} (known: {s})", .{ f, mem.join(vh.gpa, " ", &all_features) catch vh.oom() });
    }

    // the deny list: modules.deny plus the modules of every feature not selected
    var deny: vh.Strv = .{};
    var deny_why: std.StringHashMapUnmanaged([]const u8) = .empty;
    loadNames(&deny, vh.fmt("{s}/modules.deny", .{profiles}), true);
    for (deny.slice()) |m| deny_why.put(vh.gpa, m, "modules.deny") catch vh.oom();
    for (all_features) |f| {
        if (r.features.has(f)) continue;
        var list: vh.Strv = .{};
        loadNames(&list, vh.fmt("{s}/features/{s}.modules", .{ profiles, f }), false);
        for (list.slice()) |m| if (!deny.has(m)) {
            deny.add(m);
            deny_why.put(vh.gpa, m, vh.fmt("feature {s} not selected", .{f})) catch vh.oom();
        };
    }

    rep.print(vh.gpa, "vh-kconf resolve report\n", .{}) catch vh.oom();
    rep.print(vh.gpa, "hw: {s} (probe source {s}, kernel {s}; {s} {s}, {s}, {d} devices, {d} loaded modules)\n", .{ o.hw, h.probe.source, h.probe.kernel, h.machine.sys_vendor, h.machine.product_name, h.cpu.model_name, h.devices.len, h.modules.len }) catch vh.oom();
    rep.print(vh.gpa, "tables: {s}, {s}\n", .{ alias_path, builtin_path }) catch vh.oom();
    rep.print(vh.gpa, "features: {s}\n\n", .{if (r.features.len() > 0) r.features.join(" ") else "(none)"}) catch vh.oom();

    // 1. modalias -> module. The module the running system bound wins over the other
    //    matches of a device; a device without a driver takes the matches the running
    //    system uses elsewhere (bound to another device, or loaded) if there are any, else
    //    every match; the deny list applies throughout.
    var used: vh.Strv = .{}; // loadable modules the running system had in use
    for (h.devices) |d| {
        const m = alias.normalize(d.module);
        if (m.len > 0 and !table.isBuiltin(m) and !used.has(m)) used.add(m);
    }
    for (h.modules) |m| {
        const n = alias.normalize(m);
        if (!used.has(n)) used.add(n);
    }
    var wanted: vh.Strv = .{};
    var tied: vh.Strv = .{}; // modules tied to a device, for the "loaded but not tied" list
    var builtin_hits: vh.Strv = .{};
    rep.print(vh.gpa, "Devices (bus name modalias -> bound driver [module]: modules taken; alternatives):\n", .{}) catch vh.oom();
    for (h.devices) |d| {
        const m = table.match(d.modalias);
        var taken: vh.Strv = .{};
        var notes: vh.Strv = .{};
        const bound = alias.normalize(d.module);
        if (bound.len > 0 and !table.isBuiltin(bound)) {
            if (deny.has(bound)) notes.add(vh.fmt("{s} refused ({s})", .{ bound, deny_why.get(bound).? })) else taken.add(bound);
        }
        var in_use = false;
        for (m.loadable) |x| if (used.has(x) and !deny.has(x)) {
            in_use = true;
        };
        for (m.loadable) |x| {
            if (taken.has(x)) continue;
            const note: ?[]const u8 = if (deny.has(x))
                vh.fmt("{s} refused ({s})", .{ x, deny_why.get(x).? })
            else if (bound.len > 0 and !table.isBuiltin(bound))
                vh.fmt("{s} not taken: the running system bound {s}", .{ x, bound })
            else if (bound.len > 0)
                vh.fmt("{s} not taken: {s} is built in", .{ x, bound })
            else if (in_use and !used.has(x))
                vh.fmt("{s} not taken: the running system uses another match", .{x})
            else
                null;
            if (note) |n| {
                if (!notes.has(n)) notes.add(n);
            } else taken.add(x);
        }
        for (m.builtin) |x| {
            notes.add(vh.fmt("{s} built in", .{x}));
            if (!builtin_hits.has(x)) builtin_hits.add(x);
        }
        if (bound.len > 0 and table.isBuiltin(bound) and !builtin_hits.has(bound)) builtin_hits.add(bound);
        for (taken.slice()) |x| {
            if (!wanted.has(x)) wanted.add(x);
            if (!tied.has(x)) tied.add(x);
        }
        for (notes.slice()) |n| if (mem.indexOf(u8, n, " refused ") != null) {
            const name = n[0..mem.indexOfScalar(u8, n, ' ').?];
            if (!r.denied.has(name)) r.denied.add(name);
        };
        if (!m.any() and bound.len == 0) r.unmatched += 1;
        rep.print(vh.gpa, "  {s} {s} {s} -> {s}{s}{s}{s}: {s}{s}{s}\n", .{
            d.bus,                                   d.name,                              d.modalias,
            if (d.driver.len > 0) d.driver else "-", if (d.module.len > 0) " [" else "",  d.module,
            if (d.module.len > 0) "]" else "",       if (taken.len() > 0) taken.join(" ") else "-",
            if (notes.len() > 0) "; " else "",       if (notes.len() > 0) notes.join("; ") else "",
        }) catch vh.oom();
    }
    rep.print(vh.gpa, "\nModaliases with no driver, loadable or built in ({d}): normal for ACPI containers, bridges, the CPU and DMI entries; new hardware shows up here.\n", .{r.unmatched}) catch vh.oom();
    for (h.devices) |d| {
        if (d.driver.len > 0 or table.match(d.modalias).any()) continue;
        rep.print(vh.gpa, "  {s} {s} {s}\n", .{ d.bus, d.name, d.modalias }) catch vh.oom();
    }

    // 2. what the running system had loaded: every module, tied to a device or not
    var untied: vh.Strv = .{};
    for (h.modules) |raw| {
        const m = alias.normalize(raw);
        if (deny.has(m)) {
            if (!r.denied.has(m)) r.denied.add(m);
            continue;
        }
        if (!wanted.has(m)) wanted.add(m);
        if (!tied.has(m)) untied.add(m);
    }
    untied.sort();
    rep.print(vh.gpa, "\nLoaded modules not tied to a device ({d}): loaded on request (file systems, crypto, nftables, dependencies of drivers); kept.\n  {s}\n", .{ untied.len(), untied.join(" ") }) catch vh.oom();

    // 3. the modules of the selected features (not loaded at probe time, needed later)
    var extra: vh.Strv = .{};
    for (r.features.slice()) |f| {
        var list: vh.Strv = .{};
        loadNames(&list, vh.fmt("{s}/features/{s}.modules", .{ profiles, f }), false);
        for (list.slice()) |m| {
            if (deny.has(m) or wanted.has(m)) continue;
            if (table.isBuiltin(m)) continue;
            wanted.add(m);
            extra.add(vh.fmt("{s} ({s})", .{ m, f }));
        }
    }
    rep.print(vh.gpa, "\nModules added by the features ({d}):\n  {s}\n", .{ extra.len(), if (extra.len() > 0) extra.join(" ") else "-" }) catch vh.oom();

    // 4. built-in drivers: nothing to list, they are =y in the pinned config
    builtin_hits.sort();
    rep.print(vh.gpa, "\nDrivers already built into the stock kernel ({d}): {s}\n", .{ builtin_hits.len(), if (builtin_hits.len() > 0) builtin_hits.join(" ") else "-" }) catch vh.oom();
    r.denied.sort();
    rep.print(vh.gpa, "\nRefused ({d}):\n", .{r.denied.len()}) catch vh.oom();
    for (r.denied.slice()) |m| rep.print(vh.gpa, "  {s}: {s}\n", .{ m, deny_why.get(m) orelse "modules.deny" }) catch vh.oom();

    // the LSMOD list: one name per line, lsmod style (streamline_config.pl reads column 1)
    for (wanted.slice()) |m| if (!table.isBuiltin(m)) r.lsmod.add(m);
    r.lsmod.sort();

    // 5. the fragments in order; a later value wins and the conflict is recorded
    rep.print(vh.gpa, "\nFragments:\n", .{}) catch vh.oom();
    for (fixed_fragments) |f| applyFragment(&r, vh.fmt("{s}/{s}", .{ profiles, f }), f);
    for (r.features.slice()) |f| applyFragment(&r, vh.fmt("{s}/features/{s}", .{ profiles, f }), vh.fmt("features/{s}", .{f}));
    rep.print(vh.gpa, "Fragment conflicts ({d}): the later fragment wins\n", .{r.conflicts.items.len}) catch vh.oom();
    for (r.conflicts.items) |c| rep.print(vh.gpa, "  CONFIG_{s}: {s}={s}, {s}={s}\n", .{ c.name, c.first_src, c.first, c.src, c.value }) catch vh.oom();

    // 6. the pinned .config with the fragment applied (merge_config.sh -m does the same)
    r.config.parse(readOrDie(base_path));
    var changed: usize = 0;
    var added: usize = 0;
    for (r.fragment.map.keys(), r.fragment.map.values()) |k, v| {
        if (r.config.get(k)) |old| {
            if (!vh.eql(old, v)) changed += 1;
        } else added += 1;
        r.config.set(k, v);
    }
    rep.print(vh.gpa, "\n.config: {s} ({d} symbols) + fragment ({d} symbols): {d} changed, {d} not in the base; the kernel's olddefconfig decides the rest, vh-kconf diff reports it.\n", .{ base_path, r.config.count() - added, r.fragment.count(), changed, added }) catch vh.oom();
    rep.print(vh.gpa, "\nLSMOD ({d}): {s}\n", .{ r.lsmod.len(), r.lsmod.join(" ") }) catch vh.oom();
    return r;
}

fn applyFragment(r: *Result, path: []const u8, src: []const u8) void {
    const text = readOrDie(path);
    var n: usize = 0;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const kv = kconfig.DotConfig.parseLine(vh.strip(raw)) orelse continue;
        n += 1;
        if (r.fragment.get(kv.name)) |old| {
            if (!vh.eql(old, kv.value)) r.conflicts.append(vh.gpa, .{ .name = vh.dupe(kv.name), .first_src = r.sources.get(kv.name).?, .first = old, .src = vh.dupe(src), .value = vh.dupe(kv.value) }) catch vh.oom();
        }
        r.fragment.set(kv.name, kv.value);
        r.sources.put(vh.gpa, vh.dupe(kv.name), vh.dupe(src)) catch vh.oom();
    }
    r.report.print(vh.gpa, "  {s}: {d} symbols\n", .{ src, n }) catch vh.oom();
}

/// the merged fragment with the origin of every symbol ("# from: NAME" before each line)
pub fn renderFragment(r: *const Result) []u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(vh.gpa, "# merged by vh-kconf resolve: base, mandatory, hardening, perf, then the features\n") catch vh.oom();
    for (r.fragment.map.keys(), r.fragment.map.values()) |k, v| {
        out.print(vh.gpa, "# from: {s}\n", .{r.sources.get(k) orelse "?"}) catch vh.oom();
        if (vh.eql(v, "n")) out.print(vh.gpa, "# CONFIG_{s} is not set\n", .{k}) catch vh.oom() else out.print(vh.gpa, "CONFIG_{s}={s}\n", .{ k, v }) catch vh.oom();
    }
    return out.items;
}

/// "a,b", "auto", "none", "auto,game"
fn features(h: hw.Hw, spec: []const u8) vh.Strv {
    var out: vh.Strv = .{};
    var it = mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const f = vh.strip(raw);
        if (f.len == 0 or vh.eql(f, "none")) continue;
        if (vh.eql(f, "auto")) {
            if (!out.has("usb-common")) out.add("usb-common");
            if (detect(h, "bluetooth") and !out.has("bluetooth")) out.add("bluetooth");
            if (detect(h, "camera") and !out.has("camera")) out.add("camera");
            if (detect(h, "virt") and !out.has("virt")) out.add("virt");
            continue;
        }
        if (!out.has(f)) out.add(f);
    }
    return out;
}

/// what the probe shows: the AX201 Bluetooth, a UVC camera, KVM loaded
pub fn detect(h: hw.Hw, feature: []const u8) bool {
    if (vh.eql(feature, "bluetooth")) {
        if (h.hasModule("btusb") or h.hasModule("bluetooth")) return true;
        for (h.devices) |d| if (vh.startsWith(d.modalias, "usb:v8087p0026")) return true;
        return false;
    }
    if (vh.eql(feature, "camera")) {
        if (h.hasModule("uvcvideo")) return true;
        for (h.devices) |d| if (vh.eql(d.bus, "usb") and mem.indexOf(u8, d.modalias, "ic0Eisc01") != null) return true;
        return false;
    }
    if (vh.eql(feature, "virt")) return h.hasModule("kvm_intel") or h.hasModule("kvm");
    return false;
}

/// names from a list file, one per line, "#" comments; normalised
fn loadNames(out: *vh.Strv, path: []const u8, required: bool) void {
    const text = vh.readFile(path) catch {
        if (required) vh.die("{s}: {s}", .{ path, vh.serr() });
        return;
    };
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (mem.indexOfScalar(u8, line, '#')) |i| line = line[0..i];
        const name = vh.strip(line);
        if (name.len == 0) continue;
        const n = alias.normalize(name);
        if (!out.has(n)) out.add(n);
    }
}

fn readOrDie(path: []const u8) []const u8 {
    return vh.readFile(path) catch vh.die("{s}: {s}", .{ path, vh.serr() });
}

// ---------------------------------------------------------------- tests

test "resolve: the GF63 fixture against the pinned tables" {
    const probe = @import("probe.zig");
    const dir = probe.repoPath("tests/kernel/fixtures/gf63") orelse return error.SkipZigTest;
    const repo = probe.repoRoot() orelse return error.SkipZigTest;
    const src: probe.Src = .{ .root = dir };
    const h = probe.run(&src);
    const r = resolve(h, .{ .hw = "fixture", .out = "", .repo = repo, .features = "usb-common,bluetooth" });
    // the Wi-Fi, the Ethernet, the Bluetooth, the touchpad and what was loaded are in LSMOD
    for ([_][]const u8{ "iwlwifi", "iwlmvm", "r8169", "btusb", "i2c_hid_acpi", "hid_multitouch", "dm_crypt", "xfs", "nft_ct", "zram", "snd_hda_codec_alc269", "usb_storage", "exfat" }) |m|
        try std.testing.expect(r.lsmod.has(m));
    // built-in drivers of the stock kernel are not listed (they are =y already)
    try std.testing.expect(!r.lsmod.has("nvme"));
    try std.testing.expect(!r.lsmod.has("i8042"));
    try std.testing.expect(!r.lsmod.has("atkbd"));
    // refused: nouveau for the dGPU, mei_me for the ME, the tiny power button, the camera
    // (feature not selected), the sysfs-bound alternatives of the audio controller not taken
    for ([_][]const u8{ "nouveau", "mei_me", "tiny_power_button", "uvcvideo", "kvm_intel" }) |m|
        try std.testing.expect(!r.lsmod.has(m));
    try std.testing.expect(r.denied.has("nouveau"));
    try std.testing.expect(r.denied.has("tiny_power_button"));
    try std.testing.expect(r.denied.has("uvcvideo"));
    try std.testing.expect(!r.lsmod.has("snd_sof_pci_intel_cnl"));
    try std.testing.expect(r.lsmod.has("snd_hda_intel"));
    try std.testing.expect(r.lsmod.has("tpm_crb"));
    try std.testing.expect(!r.lsmod.has("tpm_tis"));
    // the fragments: base + mandatory + hardening + perf + 2 features, no modules, BTF on
    try std.testing.expectEqualStrings("n", r.fragment.get("MODULES").?);
    try std.testing.expectEqualStrings("y", r.fragment.get("SCHED_CLASS_EXT").?);
    try std.testing.expectEqualStrings("y", r.fragment.get("BT_HCIBTUSB").?);
    try std.testing.expect(r.fragment.get("USB_VIDEO_CLASS") == null);
    try std.testing.expectEqualStrings("mandatory", r.sources.get("RTC_HCTOSYS").?);
    // symbols named in two fragments with the same value are not conflicts
    for (r.conflicts.items) |c| try std.testing.expect(!vh.eql(c.first, c.value));
    try std.testing.expectEqual(@as(usize, 0), r.conflicts.items.len);
    // the merged .config carries the pinned base plus the fragment
    try std.testing.expectEqualStrings("n", r.config.get("MODULES").?);
    try std.testing.expectEqualStrings("\"-vh\"", r.config.get("LOCALVERSION").?);
    try std.testing.expectEqualStrings("m", r.config.get("IWLWIFI").?);
    try std.testing.expect(r.config.count() > 10000);
    try std.testing.expect(mem.indexOf(u8, r.report.items, "0000:00:14.3") != null);
    try std.testing.expect(mem.indexOf(u8, renderFragment(&r), "# from: hardening\n# CONFIG_IO_URING is not set\n") != null);

    // the game feature conflicts with hardening on purpose, and says so
    const g = resolve(h, .{ .hw = "fixture", .out = "", .repo = repo, .features = "usb-common,game" });
    try std.testing.expectEqualStrings("y", g.fragment.get("MODULES").?);
    try std.testing.expectEqualStrings("y", g.fragment.get("IA32_EMULATION").?);
    try std.testing.expect(g.conflicts.items.len >= 3);
    try std.testing.expect(g.denied.has("btusb"));
    // auto detection sees the AX201 Bluetooth and the camera
    try std.testing.expect(detect(h, "bluetooth"));
    try std.testing.expect(detect(h, "camera"));
    try std.testing.expect(!detect(h, "virt"));
    const a = features(h, "auto");
    try std.testing.expect(a.has("bluetooth") and a.has("camera") and a.has("usb-common") and !a.has("game"));
}
