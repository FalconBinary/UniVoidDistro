//! vh-kconf diff: after the kernel's own localyesconfig and olddefconfig, which requested
//! symbols survived and why the others did not. The oracle is the kernel (its conf knows the
//! toolchain macros); the Kconfig tree, when given, supplies the reasons.
const std = @import("std");
const vh = @import("vh");
const kconfig = @import("kconfig.zig");
const alias = @import("alias.zig");
const mem = std.mem;

pub const Opts = struct {
    /// the final .config
    config: []const u8,
    /// the merged fragment written by resolve (with its "# from:" lines)
    requested: []const u8,
    /// the LSMOD list written by resolve
    lsmod: ?[]const u8 = null,
    /// the kernel source tree: Kconfig for the reasons, Kbuild for module -> symbol
    kernel: ?[]const u8 = null,
    /// localyesconfig (modules expected =y) or localmodconfig (=y or =m)
    oracle: []const u8 = "localyesconfig",
};

pub const Result = struct {
    text: std.ArrayList(u8) = .empty,
    survived: usize = 0,
    failed: usize = 0,
    mandatory_failed: usize = 0,
    modules_ok: usize = 0,
    modules_failed: usize = 0,
};

pub fn run(o: Opts) u8 {
    const r = diff(o);
    vh.outs(r.text.items);
    vh.flush();
    return if (r.mandatory_failed > 0) 2 else 0;
}

pub fn diff(o: Opts) Result {
    var r: Result = .{};
    const out = &r.text;
    var final: kconfig.DotConfig = .{};
    final.parse(readOrDie(o.config));
    var tree: ?kconfig.Tree = null;
    var kbuild: ?kconfig.Kbuild = null;
    if (o.kernel) |k| {
        tree = kconfig.Tree.load(k);
        if (o.lsmod != null) kbuild = kconfig.Kbuild.load(k);
    }
    out.print(vh.gpa, "vh-kconf diff: {s} against the requests of {s} (oracle: {s})\n", .{ o.config, o.requested, o.oracle }) catch vh.oom();
    if (tree) |t| out.print(vh.gpa, "kernel tree: {s} ({d} Kconfig files, {d} symbols{s})\n", .{ o.kernel.?, t.files, t.syms.count(), if (kbuild) |kb| vh.fmt(", {d} Makefiles", .{kb.files}) else "" }) catch vh.oom();
    const modules_on = final.tri("MODULES") != 0;
    out.print(vh.gpa, "CONFIG_MODULES={s}\n\n", .{kconfig.show(final.get("MODULES"))}) catch vh.oom();

    // requested symbols
    const req_text = readOrDie(o.requested);
    var from: []const u8 = "?";
    var failures: std.ArrayList(u8) = .empty;
    var lines = mem.tokenizeScalar(u8, req_text, '\n');
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        if (vh.startsWith(line, "# from: ")) {
            from = vh.dupe(line[8..]);
            continue;
        }
        const kv = kconfig.DotConfig.parseLine(line) orelse continue;
        const got = final.get(kv.name);
        const ok = sameValue(kv.value, got);
        if (ok) {
            r.survived += 1;
            continue;
        }
        r.failed += 1;
        // the plan's classes and the machine fragment are as binding as mandatory: they carry
        // the drivers of this machine's disk, GPU and CPU
        const mandatory = vh.eql(from, "mandatory") or vh.startsWith(from, "class/") or vh.eql(from, "machine");
        if (mandatory) r.mandatory_failed += 1;
        const why = kconfig.explain(if (tree) |*t| t else null, &final, kv.name);
        failures.print(vh.gpa, "  {s}CONFIG_{s}: requested {s} ({s}), final {s}: {s}\n", .{ if (mandatory) "MANDATORY " else "", kv.name, kv.value, from, kconfig.show(got), why }) catch vh.oom();
    }
    out.print(vh.gpa, "Requested symbols: {d} survived, {d} did not ({d} of them mandatory).\n", .{ r.survived, r.failed, r.mandatory_failed }) catch vh.oom();
    if (failures.items.len > 0) out.appendSlice(vh.gpa, failures.items) catch vh.oom();

    // the modules of the LSMOD list: their symbols are =y (localyesconfig) in the final config
    if (o.lsmod) |lp| {
        out.print(vh.gpa, "\nLSMOD modules ({s}): expected {s}\n", .{ lp, if (vh.eql(o.oracle, "localmodconfig")) "=y or =m" else "=y" }) catch vh.oom();
        var mod_failures: std.ArrayList(u8) = .empty;
        var no_rule: vh.Strv = .{};
        var mlines = mem.tokenizeScalar(u8, readOrDie(lp), '\n');
        while (mlines.next()) |raw| {
            var it = mem.tokenizeAny(u8, raw, " \t");
            const name = alias.normalize(it.next() orelse continue);
            if (vh.eql(name, "Module")) continue;
            const kb = kbuild orelse {
                r.modules_ok += 1;
                continue;
            };
            const syms = kb.symbolsOf(name);
            if (syms.len == 0) {
                no_rule.add(name);
                continue;
            }
            var hit: ?[]const u8 = null;
            for (syms) |s| {
                const v = final.tri(s);
                if (v == 2 or (v == 1 and vh.eql(o.oracle, "localmodconfig"))) hit = s;
            }
            if (hit != null) {
                r.modules_ok += 1;
                continue;
            }
            r.modules_failed += 1;
            var reasons: vh.Strv = .{};
            for (syms) |s| {
                const v = final.get(s);
                const note = if (v != null and vh.eql(v.?, "m") and !modules_on) "=m with MODULES=n: dropped" else kconfig.explain(if (tree) |*t| t else null, &final, s);
                reasons.add(vh.fmt("CONFIG_{s}={s}: {s}", .{ s, kconfig.show(v), note }));
            }
            mod_failures.print(vh.gpa, "  {s}: {s}\n", .{ name, reasons.join("; ") }) catch vh.oom();
        }
        out.print(vh.gpa, "  {d} built in, {d} not, {d} without an obj-$(CONFIG_*) rule in the tree.\n", .{ r.modules_ok, r.modules_failed, no_rule.len() }) catch vh.oom();
        if (mod_failures.items.len > 0) out.appendSlice(vh.gpa, mod_failures.items) catch vh.oom();
        if (no_rule.len() > 0) out.print(vh.gpa, "  no rule (a directory rule, a renamed object, or not a module of this tree): {s}\n", .{no_rule.join(" ")}) catch vh.oom();
    }
    out.print(vh.gpa, "\nResult: {s}\n", .{if (r.mandatory_failed > 0) "FAIL (a mandatory symbol did not survive)" else if (r.failed > 0 or r.modules_failed > 0) "ok with differences (see above)" else "ok"}) catch vh.oom();
    return r;
}

/// "y" asked and "y" found; "n" asked and "n" or nothing found; strings compared as written
fn sameValue(asked: []const u8, got: ?[]const u8) bool {
    const g = got orelse "n";
    return vh.eql(asked, g);
}

fn readOrDie(path: []const u8) []const u8 {
    return vh.readFile(path) catch vh.die("{s}: {s}", .{ path, vh.serr() });
}

test "diff: survivors, failures, mandatory, modules" {
    const linux = std.os.linux;
    const dir = vh.fmt("/tmp/vh-kconf-diff-{d}", .{linux.getpid()});
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    vh.mkdirs(vh.fmt("{s}/k/drivers/net", .{dir}), 0o755);
    vh.writeAtomic(vh.fmt("{s}/final.config", .{dir}), "CONFIG_A=y\n# CONFIG_B is not set\nCONFIG_C=m\nCONFIG_S=\"x\"\n# CONFIG_MODULES is not set\nCONFIG_R8169=y\nCONFIG_IWLWIFI=m\n", 0o644);
    vh.writeAtomic(vh.fmt("{s}/req.config", .{dir}), "# from: base\nCONFIG_A=y\n# from: mandatory\nCONFIG_B=y\n# from: hardening\n# CONFIG_C is not set\nCONFIG_S=\"x\"\n# from: perf\nCONFIG_D=y\n# CONFIG_E is not set\n", 0o644);
    vh.writeAtomic(vh.fmt("{s}/lsmod", .{dir}), "r8169\niwlwifi\nnothere\n", 0o644);
    vh.writeAtomic(vh.fmt("{s}/k/Kconfig", .{dir}), "config A\n\tbool \"a\"\nconfig B\n\tbool \"b\"\n\tdepends on A && Q\nconfig C\n\ttristate \"c\"\nconfig D\n\tbool\n", 0o644);
    vh.writeAtomic(vh.fmt("{s}/k/Makefile", .{dir}), "obj-y += drivers/\n", 0o644);
    vh.writeAtomic(vh.fmt("{s}/k/drivers/net/Makefile", .{dir}), "obj-$(CONFIG_R8169) += r8169.o\nobj-$(CONFIG_IWLWIFI) += iwlwifi.o\n", 0o644);
    const r = diff(.{
        .config = vh.fmt("{s}/final.config", .{dir}),
        .requested = vh.fmt("{s}/req.config", .{dir}),
        .lsmod = vh.fmt("{s}/lsmod", .{dir}),
        .kernel = vh.fmt("{s}/k", .{dir}),
    });
    const t = r.text.items;
    try std.testing.expectEqual(@as(usize, 3), r.survived); // A, S, E (absent counts as n)
    try std.testing.expectEqual(@as(usize, 3), r.failed); // B, C, D
    try std.testing.expectEqual(@as(usize, 1), r.mandatory_failed);
    try std.testing.expect(mem.indexOf(u8, t, "MANDATORY CONFIG_B: requested y (mandatory), final n: bool; at Kconfig:3 unmet: \"A && Q\" [Q=n]") != null);
    try std.testing.expect(mem.indexOf(u8, t, "CONFIG_C: requested n (hardening), final m: tristate; dependencies satisfied") != null);
    try std.testing.expect(mem.indexOf(u8, t, "CONFIG_D: requested y (perf), final n: bool, no prompt") != null);
    try std.testing.expectEqual(@as(usize, 1), r.modules_ok);
    try std.testing.expectEqual(@as(usize, 1), r.modules_failed);
    try std.testing.expect(mem.indexOf(u8, t, "iwlwifi: CONFIG_IWLWIFI=m: =m with MODULES=n: dropped") != null);
    try std.testing.expect(mem.indexOf(u8, t, "no rule (") != null and mem.indexOf(u8, t, "nothere") != null);
    try std.testing.expect(mem.indexOf(u8, t, "Result: FAIL") != null);
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
}
