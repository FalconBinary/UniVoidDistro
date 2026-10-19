//! The outputs of a plan: plan.zon (every decision with its rules), plan.env (what the shell
//! installer sources) and plan-report.txt. plan.env is read by a root shell, so every value
//! is checked against a narrow alphabet and single-quoted; nothing read from the firmware
//! (DMI strings, the device tree) ever reaches it.
const std = @import("std");
const vh = @import("vh");
const plan_mod = @import("plan.zig");
const Plan = plan_mod.Plan;
const Item = plan_mod.Item;

pub fn renderZon(p: Plan) []u8 {
    var aw: std.Io.Writer.Allocating = .init(vh.gpa);
    std.zon.stringify.serializeArbitraryDepth(p, .{}, &aw.writer) catch vh.oom();
    aw.writer.writeByte('\n') catch vh.oom();
    return aw.written();
}

pub fn parseZon(text: []const u8, what: []const u8) Plan {
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Plan, .{
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

/// letters, digits and the punctuation of module names, packages, kernel parameters, firmware
/// globs and udev file names; a space separates list items
pub fn safeValue(v: []const u8) bool {
    for (v) |c| {
        const ok = std.ascii.isAlphanumeric(c) or switch (c) {
            '_', '-', '.', ',', ':', '=', '/', '*', '+', '@', ' ' => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

fn known(list: []const []const u8) []const u8 {
    var s: vh.Strv = .{};
    for (list) |x| s.add(x);
    return s.join(" ");
}

fn values(items: []const Item) []const u8 {
    var s: vh.Strv = .{};
    for (items) |x| s.add(x.value);
    return s.join(" ");
}

pub fn renderEnv(p: Plan) []u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(vh.gpa, "# vh-plan: the plan of {s} for the shell installer (install/lib.sh). Every value comes\n", .{if (safeValue(p.machine)) p.machine else "this machine"}) catch vh.oom();
    out.appendSlice(vh.gpa, "# from hwdb/ or is a number; plan-report.txt says which rule put it here.\n") catch vh.oom();
    var tags: vh.Strv = .{};
    for (p.tags) |t| tags.add(t);
    var ack: vh.Strv = .{};
    for (p.acknowledge) |a| ack.add(a);
    var missing: vh.Strv = .{};
    for (p.missing) |x| missing.add(x.id);
    const scalar = struct {
        fn get(pl: Plan, key: []const u8) []const u8 {
            for (pl.scalars) |s| if (vh.eql(s.key, key)) return s.value;
            return "";
        }
    }.get;
    const pairs = [_][2][]const u8{
        .{ "VH_PLAN_ARCH", p.arch },
        .{ "VH_PLAN_TIER", p.tier },
        .{ "VH_PLAN_SECURITY", p.security },
        .{ "VH_PLAN_CLASS", scalar(p, "class") },
        .{ "VH_PLAN_TAGS", tags.join(" ") },
        .{ "VH_PLAN_MISSING", missing.join(" ") },
        .{ "VH_PLAN_ACKNOWLEDGE", ack.join(" ") },
        .{ "VH_PLAN_PACKAGES", values(p.packages) },
        .{ "VH_PLAN_KCONFIG", values(p.kconfig) },
        .{ "VH_PLAN_FEATURES", values(p.features) },
        .{ "VH_PLAN_FIRMWARE", values(p.firmware) },
        .{ "VH_PLAN_CMDLINE", values(p.cmdline) },
        .{ "VH_PLAN_SERVICES", values(p.services) },
        .{ "VH_PLAN_UDEV", values(p.udev) },
        .{ "VH_PLAN_UDEV_KNOWN", known(p.udev_known) },
        .{ "VH_PLAN_DENY", values(p.deny) },
        .{ "VH_PLAN_DRACUT", values(p.dracut) },
        .{ "VH_PLAN_INTERNAL_INPUT", values(p.internal_input) },
        .{ "VH_PLAN_LUKS_CIPHER", p.luks.cipher },
        .{ "VH_PLAN_LUKS_KEY_SIZE", vh.fmt("{d}", .{p.luks.key_size}) },
        .{ "VH_PLAN_LUKS_MEM_KIB", vh.fmt("{d}", .{p.luks.pbkdf_memory_kib}) },
        .{ "VH_PLAN_LUKS_PARALLEL", vh.fmt("{d}", .{p.luks.pbkdf_parallel}) },
        .{ "VH_PLAN_NR_CPUS", vh.fmt("{d}", .{p.kernel.nr_cpus}) },
        .{ "VH_PLAN_MARCH", p.kernel.march },
        .{ "VH_PLAN_RENDERER", scalar(p, "renderer") },
        .{ "VH_PLAN_WATCHDOG", scalar(p, "watchdog") },
    };
    for (pairs) |kv| line(&out, kv[0], kv[1]);
    for (p.exports) |e| line(&out, vh.fmt("VH_PLAN_{s}", .{e.key}), e.value);
    return out.items;
}

fn line(out: *std.ArrayList(u8), key: []const u8, value: []const u8) void {
    if (!safeValue(value)) vh.die("plan.env: {s} has a character outside the allowed set: {s}", .{ key, value });
    out.print(vh.gpa, "{s}='{s}'\n", .{ key, value }) catch vh.oom();
}

test "plan.env values are checked" {
    try std.testing.expect(safeValue("intel_iommu=on iommu.strict=1"));
    try std.testing.expect(safeValue("i915/kbl_* iwlwifi-Qu*"));
    try std.testing.expect(!safeValue("x'; rm -rf /"));
    try std.testing.expect(!safeValue("$(id)"));
    try std.testing.expect(!safeValue("a\nb"));
    const items = [_]Item{ .{ .value = "intel-ucode" }, .{ .value = "iwd" } };
    const env = renderEnv(.{ .machine = "gf63", .arch = "x86_64", .packages = &items });
    try std.testing.expect(std.mem.indexOf(u8, env, "VH_PLAN_PACKAGES='intel-ucode iwd'\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "VH_PLAN_TIER='full'\n") != null);
}
