//! vh-plan: the plan of this machine (track A, docs/uni/ROADMAP.md).
//!
//!   vh-plan plan --hw FILE --hwdb DIR [--pins DIR] [--config FILE ...] [--set KEY=VALUE ...]
//!                [--security strict|tiered] --out DIR
//!       hw.zon + the rules of hwdb/ + the configuration -> DIR/plan.zon, DIR/plan.env,
//!       DIR/plan-report.txt; exit 3 when the security gate refuses the machine (the files
//!       are written all the same, so that the installer can show why)
//!   vh-plan explain ITEM --plan FILE [--hwdb DIR]
//!       which rules put ITEM (a package, a firmware pattern, a parameter ...) into the plan
//!   vh-plan env --plan FILE
//!       plan.zon in the form of plan.env, for the shell scripts of the installed system
//!       (vh-audit reads /etc/vh/plan.zon so)
//!   vh-plan version
//!
//! Static PIE, ReleaseSafe, std.os.linux only (zig/README.md).
const std = @import("std");
const vh = @import("vh");
const hw = @import("hw");
const alias = @import("alias");
const rules = @import("rules.zig");
const facts = @import("facts.zig");
const plan = @import("plan.zig");
const emit = @import("emit.zig");

const usage =
    \\usage: vh-plan plan --hw FILE --hwdb DIR [--pins DIR] [--config FILE ...] [--set KEY=VALUE ...] [--security strict|tiered] --out DIR
    \\       vh-plan explain ITEM --plan FILE [--hwdb DIR]
    \\       vh-plan env --plan FILE
    \\       vh-plan version
    \\
;

pub const version = "0.1.0";

pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "vh-plan");
    if (args.len == 0 or vh.eql(args[0], "--help") or vh.eql(args[0], "-h")) {
        vh.outs(usage);
        vh.exit(if (args.len == 0) 2 else 0);
    }
    const cmd = args[0];
    if (vh.eql(cmd, "version")) {
        vh.out("vh-plan {s}\n", .{version});
        vh.exit(0);
    }
    if (vh.eql(cmd, "plan")) vh.exit(cmdPlan(args[1..]));
    if (vh.eql(cmd, "explain")) vh.exit(cmdExplain(args[1..]));
    if (vh.eql(cmd, "env")) vh.exit(cmdEnv(args[1..]));
    vh.warn("unknown command {s}", .{cmd});
    vh.outs(usage);
    vh.exit(2);
}

/// --name VALUE or --name=VALUE; dies when the value is missing
const Args = struct {
    items: []const [:0]const u8,
    i: usize = 0,

    fn next(self: *Args) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        self.i += 1;
        return self.items[self.i - 1];
    }

    fn value(self: *Args, arg: []const u8, opt: []const u8) ?[]const u8 {
        if (vh.eql(arg, opt)) return self.next() orelse vh.die("{s} needs a value", .{opt});
        if (arg.len > opt.len + 1 and vh.startsWith(arg, opt) and arg[opt.len] == '=') return arg[opt.len + 1 ..];
        return null;
    }
};

fn cmdPlan(argv: []const [:0]const u8) u8 {
    var a: Args = .{ .items = argv };
    var hw_path: []const u8 = "";
    var hwdb: []const u8 = "";
    var pins: []const u8 = "";
    var out: []const u8 = "";
    var security: []const u8 = "";
    var config: vh.Kv = .{};
    var sets: vh.Strv = .{};
    while (a.next()) |arg| {
        if (a.value(arg, "--hw")) |v| {
            hw_path = v;
        } else if (a.value(arg, "--hwdb")) |v| {
            hwdb = v;
        } else if (a.value(arg, "--pins")) |v| {
            pins = v;
        } else if (a.value(arg, "--out")) |v| {
            out = v;
        } else if (a.value(arg, "--security")) |v| {
            security = v;
        } else if (a.value(arg, "--config")) |v| {
            if (!vh.pathExists(v)) vh.die("--config {s}: no such file", .{v});
            config.read(v, false);
        } else if (a.value(arg, "--set")) |v| {
            sets.add(v);
        } else vh.die("plan: unknown argument {s}", .{arg});
    }
    if (hw_path.len == 0 or hwdb.len == 0 or out.len == 0) vh.die("plan: --hw FILE, --hwdb DIR and --out DIR are required", .{});
    // --set comes after every --config, whatever the order on the command line
    for (sets.slice()) |s| {
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse vh.die("--set {s}: KEY=VALUE", .{s});
        config.set(s[0..eq], s[eq + 1 ..]);
    }
    const h = hw.load(hw_path);
    const db = rules.load(hwdb);

    // the stock kernel's tables: those of kernel/pins for its architecture (x86_64 under the
    // plain names, aarch64 under names that say so: kernel/pins/README.md); none for another
    var table: alias.Table = .{};
    var have_table = false;
    var fwt: plan.FirmwareTable = .{};
    var have_fw = false;
    if (pins.len > 0) if (alias.pinNames(h.archName())) |names| {
        if (vh.readFile(vh.fmt("{s}/{s}", .{ pins, names.alias }))) |t| {
            table.loadAliases(t);
            have_table = true;
        } else |_| {}
        if (vh.readFile(vh.fmt("{s}/{s}", .{ pins, names.builtin_modinfo }))) |t| table.loadBuiltinModinfo(t) else |_| {}
        if (vh.readFile(vh.fmt("{s}/{s}", .{ pins, names.builtin }))) |t| table.loadBuiltinList(t) else |_| {}
        if (vh.readFile(vh.fmt("{s}/{s}", .{ pins, names.firmware }))) |t| {
            fwt.load(t);
            have_fw = true;
        } else |_| {}
    };
    const r = plan.compute(.{
        .hw = h,
        .db = db,
        .config = &config,
        .security = security,
        .table = if (have_table) &table else null,
        .firmware = if (have_fw) &fwt else null,
    });
    vh.mkdirs(out, 0o755);
    vh.writeAtomic(vh.fmt("{s}/plan.zon", .{out}), emit.renderZon(r.plan), 0o644);
    vh.writeAtomic(vh.fmt("{s}/plan.env", .{out}), emit.renderEnv(r.plan), 0o644);
    vh.writeAtomic(vh.fmt("{s}/plan-report.txt", .{out}), r.report, 0o644);
    vh.out("{s}: {s}, tier {s} ({s}); {d} packages, {d} firmware patterns, {d} kernel classes, {d} services; report in {s}/plan-report.txt\n", .{
        r.plan.machine,    r.plan.arch,          r.plan.tier,         r.plan.security,
        r.plan.packages.len, r.plan.firmware.len, r.plan.kconfig.len, r.plan.services.len,
        out,
    });
    for (r.plan.missing) |x| vh.out("  missing: {s}{s}: {s}\n", .{ x.id, if (x.floor) " (refused in any mode)" else "", if (x.fix.len > 0) x.fix else x.why });
    if (r.status == 3) vh.warn("the security gate refuses this machine in {s} mode (plan-report.txt says why)", .{r.plan.security});
    return r.status;
}

fn cmdExplain(argv: []const [:0]const u8) u8 {
    var a: Args = .{ .items = argv };
    var item: []const u8 = "";
    var plan_path: []const u8 = "";
    var hwdb: []const u8 = "";
    while (a.next()) |arg| {
        if (a.value(arg, "--plan")) |v| {
            plan_path = v;
        } else if (a.value(arg, "--hwdb")) |v| {
            hwdb = v;
        } else if (item.len == 0 and arg.len > 0 and arg[0] != '-') {
            item = arg;
        } else vh.die("explain: unknown argument {s}", .{arg});
    }
    if (item.len == 0 or plan_path.len == 0) vh.die("explain: ITEM and --plan FILE are required", .{});
    const p = emit.parseZon(vh.readFile(plan_path) catch vh.die("{s}: {s}", .{ plan_path, vh.serr() }), plan_path);
    const db: ?rules.Db = if (hwdb.len > 0) rules.load(hwdb) else null;
    const lists = [_]struct { name: []const u8, items: []const plan.Item }{
        .{ .name = "package", .items = p.packages },
        .{ .name = "gaming root package", .items = p.game_packages },
        .{ .name = "kernel class", .items = p.kconfig },
        .{ .name = "kernel feature", .items = p.features },
        .{ .name = "firmware", .items = p.firmware },
        .{ .name = "command line", .items = p.cmdline },
        .{ .name = "service", .items = p.services },
        .{ .name = "udev rule", .items = p.udev },
        .{ .name = "denied module", .items = p.deny },
        .{ .name = "initrd driver", .items = p.dracut },
        .{ .name = "internal input", .items = p.internal_input },
        .{ .name = "module", .items = p.modules },
    };
    var found = false;
    for (lists) |l| for (l.items) |x| {
        if (!vh.eql(x.value, item)) continue;
        found = true;
        vh.out("{s} {s}:\n", .{ l.name, item });
        for (x.rules) |rid| {
            vh.out("  {s}", .{rid});
            if (db) |d| for (d.rules) |r| if (vh.eql(r.id, rid)) vh.out(": {s}", .{r.why});
            vh.out("\n", .{});
        }
    };
    for (p.scalars) |s| if (vh.eql(s.key, item)) {
        found = true;
        vh.out("{s} = {s}: {s}\n", .{ s.key, s.value, s.rule });
    };
    if (!found) {
        vh.warn("{s} is not in {s}", .{ item, plan_path });
        return 1;
    }
    return 0;
}

/// plan.zon as plan.env: the same values, the same checks of their characters
fn cmdEnv(argv: []const [:0]const u8) u8 {
    var a: Args = .{ .items = argv };
    var plan_path: []const u8 = "";
    while (a.next()) |arg| {
        if (a.value(arg, "--plan")) |v| {
            plan_path = v;
        } else vh.die("env: unknown argument {s}", .{arg});
    }
    if (plan_path.len == 0) vh.die("env: --plan FILE is required", .{});
    const p = emit.parseZon(vh.readFile(plan_path) catch vh.die("{s}: {s}", .{ plan_path, vh.serr() }), plan_path);
    vh.outs(emit.renderEnv(p));
    return 0;
}

test {
    _ = rules;
    _ = facts;
    _ = plan;
    _ = emit;
    _ = @import("tests.zig");
}
