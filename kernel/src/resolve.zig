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
    /// the machine's plan (vh-plan): its kernel classes, features, deny list, NR_CPUS, -march
    plan: ?[]const u8 = null,
    /// the stock kernel's tables; by default those of the kernel the probe ran under
    alias: ?[]const u8 = null,
    builtin: ?[]const u8 = null,
    builtin_list: ?[]const u8 = null,
    /// the pinned .config and the profiles; --repo DIR sets both to DIR/kernel/...
    base: ?[]const u8 = null,
    profiles: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    /// comma-separated feature names, "auto" (the plan's), "none"
    features: []const u8 = "auto",
};

/// what resolve reads of plan.zon (vh-plan writes more; the rest is ignored)
const PlanItem = struct { value: []const u8 };
pub const PlanView = struct {
    kconfig: []const PlanItem = &.{},
    features: []const PlanItem = &.{},
    deny: []const PlanItem = &.{},
    kernel: struct { nr_cpus: u32 = 0, march: []const u8 = "" } = .{},
};

pub fn loadPlan(path: []const u8) PlanView {
    const text = readOrDie(path);
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(PlanView, .{
        .gpa = vh.gpa,
        .arena = vh.gpa,
        .source = vh.z(text),
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => vh.oom(),
        error.ParseZon => vh.die("{f}", .{diag.fmt(path)}),
    };
}

/// the fragments in the order they are applied; the features follow
const fixed_fragments = [_][]const u8{ "base", "mandatory", "hardening", "perf" };
pub const all_features = [_][]const u8{ "usb-common", "bluetooth", "wifi", "camera", "virt", "game" };

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
    /// the compiler flags for a kernel built elsewhere: -march of the plan, "" without one
    kcflags: []const u8 = "",
};

pub fn run(o: Opts) u8 {
    const h = hw.load(o.hw);
    const r = resolve(h, o);
    vh.mkdirs(o.out, 0o755);
    vh.writeAtomic(vh.fmt("{s}/lsmod", .{o.out}), vh.fmt("{s}\n", .{r.lsmod.join("\n")}), 0o644);
    vh.writeAtomic(vh.fmt("{s}/fragment.config", .{o.out}), renderFragment(&r), 0o644);
    vh.writeAtomic(vh.fmt("{s}/.config", .{o.out}), r.config.render(), 0o644);
    vh.writeAtomic(vh.fmt("{s}/resolve-report.txt", .{o.out}), r.report.items, 0o644);
    vh.writeAtomic(vh.fmt("{s}/kcflags", .{o.out}), vh.fmt("{s}\n", .{r.kcflags}), 0o644);
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

    // the plan: kernel classes, features, deny list, NR_CPUS, -march; without one the kernel
    // has no driver of its disk or its GPU, so it is required
    const plan_path = o.plan orelse vh.die("resolve needs the machine's plan: vh-plan plan --hw FILE --hwdb hwdb --pins kernel/pins --out DIR, then --plan DIR/plan.zon", .{});
    const plan = loadPlan(plan_path);
    // features: explicit, the plan's, or none
    r.features = features(plan, o.features);
    for (r.features.slice()) |f| {
        var known = false;
        for (all_features) |k| if (vh.eql(k, f)) {
            known = true;
        };
        if (!known) vh.die("unknown feature {s} (known: {s})", .{ f, mem.join(vh.gpa, " ", &all_features) catch vh.oom() });
    }

    // the deny list: modules.deny, the plan's, the modules of every feature not selected
    const refused = denyList(plan, r.features, profiles);
    const deny = refused.list;
    const deny_why = refused.why;

    rep.print(vh.gpa, "vh-kconf resolve report\n", .{}) catch vh.oom();
    rep.print(vh.gpa, "hw: {s} (probe source {s}, kernel {s}; {s} {s}, {s}, {d} devices, {d} loaded modules)\n", .{ o.hw, h.probe.source, h.probe.kernel, h.machine.sys_vendor, h.machine.product_name, h.cpu.model_name, h.devices.len, h.modules.len }) catch vh.oom();
    rep.print(vh.gpa, "tables: {s}, {s}\n", .{ alias_path, builtin_path }) catch vh.oom();
    rep.print(vh.gpa, "plan: {s}: {d} kernel classes, {d} refused modules, NR_CPUS {d}, -march {s}\n", .{ plan_path, plan.kconfig.len, plan.deny.len, plan.kernel.nr_cpus, if (plan.kernel.march.len > 0) plan.kernel.march else "(none)" }) catch vh.oom();
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
    for (plan.kconfig) |c| applyFragment(&r, vh.fmt("{s}/class/{s}", .{ profiles, c.value }), vh.fmt("class/{s}", .{c.value}));
    for (r.features.slice()) |f| applyFragment(&r, vh.fmt("{s}/features/{s}", .{ profiles, f }), vh.fmt("features/{s}", .{f}));
    // the machine: its possible CPUs (hotplug included), from the plan, else the probe
    const nr_cpus = if (plan.kernel.nr_cpus > 0) plan.kernel.nr_cpus else if (h.cpu.possible > 0) h.cpu.possible else h.cpu.threads;
    if (nr_cpus > 0) applyText(&r, vh.fmt("CONFIG_NR_CPUS={d}\n", .{@max(nr_cpus, 2)}), "machine");
    if (plan.kernel.march.len > 0) r.kcflags = vh.fmt("-march={s}", .{plan.kernel.march});
    rep.print(vh.gpa, "Fragment conflicts ({d}): the later fragment wins\n", .{r.conflicts.items.len}) catch vh.oom();
    for (r.conflicts.items) |c| rep.print(vh.gpa, "  CONFIG_{s}: {s}={s}, {s}={s}\n", .{ c.name, c.first_src, c.first, c.src, c.value }) catch vh.oom();

    // 6. the pinned .config with the fragment applied, the fragment's lines last, as
    //    merge_config.sh -m does: the kernel's conf takes the last =y member of a choice
    r.config.parse(readOrDie(base_path));
    var changed: usize = 0;
    var added: usize = 0;
    for (r.fragment.map.keys(), r.fragment.map.values()) |k, v| {
        if (r.config.get(k)) |old| {
            if (!vh.eql(old, v)) changed += 1;
        } else added += 1;
        r.config.setLast(k, v);
    }
    rep.print(vh.gpa, "\n.config: {s} ({d} symbols) + fragment ({d} symbols): {d} changed, {d} not in the base; the kernel's olddefconfig decides the rest, vh-kconf diff reports it.\n", .{ base_path, r.config.count() - added, r.fragment.count(), changed, added }) catch vh.oom();
    rep.print(vh.gpa, "\nLSMOD ({d}): {s}\n", .{ r.lsmod.len(), r.lsmod.join(" ") }) catch vh.oom();
    return r;
}

pub const Deny = struct {
    list: vh.Strv = .{},
    /// module -> why: "modules.deny", "the plan", "feature NAME not selected"
    why: std.StringHashMapUnmanaged([]const u8) = .empty,
};

/// The modules a build of this plan leaves out on purpose, in order: kernel/profiles/modules.deny,
/// the plan's deny list, the modules of every feature not among `feats`. vh-kconf check reads
/// the same list on a machine kernel: there the modules are refused by the build, as
/// module_blacklist= refuses them on the stock kernel.
pub fn denyList(plan: PlanView, feats: vh.Strv, profiles: []const u8) Deny {
    var d: Deny = .{};
    loadNames(&d.list, vh.fmt("{s}/modules.deny", .{profiles}), true);
    for (d.list.slice()) |m| d.why.put(vh.gpa, m, "modules.deny") catch vh.oom();
    for (plan.deny) |x| {
        const m = alias.normalize(x.value);
        if (d.list.has(m)) continue;
        d.list.add(m);
        d.why.put(vh.gpa, m, "the plan") catch vh.oom();
    }
    for (all_features) |f| {
        if (feats.has(f)) continue;
        var list: vh.Strv = .{};
        loadNames(&list, vh.fmt("{s}/features/{s}.modules", .{ profiles, f }), false);
        for (list.slice()) |m| if (!d.list.has(m)) {
            d.list.add(m);
            d.why.put(vh.gpa, m, vh.fmt("feature {s} not selected", .{f})) catch vh.oom();
        };
    }
    return d;
}

fn applyFragment(r: *Result, path: []const u8, src: []const u8) void {
    applyText(r, readOrDie(path), src);
}

fn applyText(r: *Result, text: []const u8, src: []const u8) void {
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
    out.appendSlice(vh.gpa, "# merged by vh-kconf resolve: base, mandatory, hardening, perf, the plan's classes, the features, the machine\n") catch vh.oom();
    for (r.fragment.map.keys(), r.fragment.map.values()) |k, v| {
        out.print(vh.gpa, "# from: {s}\n", .{r.sources.get(k) orelse "?"}) catch vh.oom();
        if (vh.eql(v, "n")) out.print(vh.gpa, "# CONFIG_{s} is not set\n", .{k}) catch vh.oom() else out.print(vh.gpa, "CONFIG_{s}={s}\n", .{ k, v }) catch vh.oom();
    }
    return out.items;
}

/// "a,b", "auto" (the plan's features), "none", "auto,game"
pub fn features(plan: PlanView, spec: []const u8) vh.Strv {
    var out: vh.Strv = .{};
    var it = mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const f = vh.strip(raw);
        if (f.len == 0 or vh.eql(f, "none")) continue;
        if (vh.eql(f, "auto")) {
            for (plan.features) |x| if (!out.has(x.value)) out.add(x.value);
            continue;
        }
        if (!out.has(f)) out.add(f);
    }
    return out;
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

test "resolve: the GF63 fixture against the pinned tables and its plan" {
    const probe = @import("probe.zig");
    const dir = probe.repoPath("tests/kernel/fixtures/gf63") orelse return error.SkipZigTest;
    const plan_path = probe.repoPath("tests/adapt/golden/gf63/strict/plan.zon") orelse return error.SkipZigTest;
    const repo = probe.repoRoot() orelse return error.SkipZigTest;
    const src: probe.Src = .{ .root = dir };
    const h = probe.run(&src);
    const r = resolve(h, .{ .hw = "fixture", .out = "", .repo = repo, .plan = plan_path, .features = "usb-common,bluetooth,wifi" });
    // the Wi-Fi, the Ethernet, the Bluetooth, the touchpad and what was loaded are in LSMOD
    for ([_][]const u8{ "iwlwifi", "iwlmvm", "cfg80211", "mac80211", "r8169", "btusb", "i2c_hid_acpi", "hid_multitouch", "dm_crypt", "xfs", "nft_ct", "zram", "snd_hda_codec_alc269", "usb_storage", "exfat" }) |m|
        try std.testing.expect(r.lsmod.has(m));
    // built-in drivers of the stock kernel are not listed (they are =y already)
    try std.testing.expect(!r.lsmod.has("nvme"));
    try std.testing.expect(!r.lsmod.has("i8042"));
    try std.testing.expect(!r.lsmod.has("atkbd"));
    // refused: nouveau and the ME by the plan, the tiny power button by modules.deny, the
    // camera and the card reader by the plan (VH_CAMERA=no, VH_CARDREADER=no), KVM
    for ([_][]const u8{ "nouveau", "mei_me", "tiny_power_button", "uvcvideo", "kvm_intel", "rtsx_pci" }) |m|
        try std.testing.expect(!r.lsmod.has(m));
    try std.testing.expect(r.denied.has("nouveau"));
    try std.testing.expect(r.denied.has("tiny_power_button"));
    try std.testing.expect(r.denied.has("uvcvideo"));
    try std.testing.expect(r.denied.has("rtsx_pci"));
    try std.testing.expect(!r.lsmod.has("snd_sof_pci_intel_cnl"));
    try std.testing.expect(r.lsmod.has("snd_hda_intel"));
    try std.testing.expect(r.lsmod.has("tpm_crb"));
    try std.testing.expect(!r.lsmod.has("tpm_tis"));
    // the fragments: base, mandatory, hardening, perf, the plan's classes, three features, the machine
    try std.testing.expectEqualStrings("n", r.fragment.get("MODULES").?);
    try std.testing.expectEqualStrings("y", r.fragment.get("SCHED_CLASS_EXT").?);
    try std.testing.expectEqualStrings("y", r.fragment.get("BT_HCIBTUSB").?);
    try std.testing.expectEqualStrings("features/wifi", r.sources.get("CFG80211").?);
    try std.testing.expectEqualStrings("y", r.fragment.get("CFG80211_REQUIRE_SIGNED_REGDB").?);
    try std.testing.expect(r.fragment.get("USB_VIDEO_CLASS") == null);
    try std.testing.expectEqualStrings("mandatory", r.sources.get("RTC_HCTOSYS").?);
    try std.testing.expectEqualStrings("class/gpu-i915", r.sources.get("DRM_I915").?);
    try std.testing.expectEqualStrings("class/storage-nvme", r.sources.get("BLK_DEV_NVME").?);
    try std.testing.expectEqualStrings("class/cpu-intel", r.sources.get("X86_INTEL_PSTATE").?);
    try std.testing.expectEqualStrings("class/bt-intel", r.sources.get("BT_INTEL").?);
    try std.testing.expectEqualStrings("12", r.fragment.get("NR_CPUS").?);
    try std.testing.expectEqualStrings("machine", r.sources.get("NR_CPUS").?);
    try std.testing.expectEqualStrings("-march=skylake", r.kcflags);
    // symbols named in two fragments with the same value are not conflicts
    for (r.conflicts.items) |c| try std.testing.expect(!vh.eql(c.first, c.value));
    try std.testing.expectEqual(@as(usize, 0), r.conflicts.items.len);
    // the merged .config carries the pinned base plus the fragment
    try std.testing.expectEqualStrings("n", r.config.get("MODULES").?);
    try std.testing.expectEqualStrings("\"-vh\"", r.config.get("LOCALVERSION").?);
    try std.testing.expectEqualStrings("m", r.config.get("IWLWIFI").?);
    try std.testing.expect(r.config.count() > 10000);
    // the fragment's choice picks come after the base's members (PREEMPT after PREEMPT_VOLUNTARY)
    const keys = r.config.map.keys();
    var i_vol: usize = 0;
    var i_full: usize = 0;
    for (keys, 0..) |k, i| {
        if (vh.eql(k, "PREEMPT_VOLUNTARY")) i_vol = i;
        if (vh.eql(k, "PREEMPT")) i_full = i;
    }
    try std.testing.expect(i_full > i_vol and i_full >= keys.len - r.fragment.count());
    try std.testing.expect(mem.indexOf(u8, r.report.items, "0000:00:14.3") != null);
    try std.testing.expect(mem.indexOf(u8, renderFragment(&r), "# from: hardening\n# CONFIG_IO_URING is not set\n") != null);

    // the game feature conflicts with hardening on purpose, and says so
    const g = resolve(h, .{ .hw = "fixture", .out = "", .repo = repo, .plan = plan_path, .features = "usb-common,game" });
    try std.testing.expectEqualStrings("y", g.fragment.get("MODULES").?);
    try std.testing.expectEqualStrings("y", g.fragment.get("IA32_EMULATION").?);
    try std.testing.expect(g.conflicts.items.len >= 3);
    try std.testing.expect(g.denied.has("btusb"));
    // without the feature wifi the 802.11 stack is refused, although the probe saw cfg80211 loaded
    try std.testing.expect(g.denied.has("cfg80211") and g.denied.has("mac80211"));
    try std.testing.expect(!g.lsmod.has("cfg80211") and !g.lsmod.has("mac80211"));
    try std.testing.expect(g.fragment.get("CFG80211") == null);
    // "auto" takes the plan's features
    const a = resolve(h, .{ .hw = "fixture", .out = "", .repo = repo, .plan = plan_path });
    try std.testing.expect(a.features.has("bluetooth") and a.features.has("usb-common") and a.features.has("wifi") and !a.features.has("game") and !a.features.has("camera"));
}
