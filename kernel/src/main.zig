//! vh-kconf: the kernel of this machine (track K, kernel/README.md, docs/ROADMAP.md).
//!
//!   vh-kconf probe [--from DIR] [--save DIR] [-o FILE|--stdout]
//!       sysfs and procfs -> /etc/vh/hw.zon (stdout with --from); no serial numbers
//!   vh-kconf resolve --hw FILE --plan FILE --out DIR [--repo DIR] [--features LIST|auto|none]
//!                    [--alias F] [--builtin F] [--builtin-list F] [--base .config] [--profiles DIR]
//!       hw.zon + the machine's plan (vh-plan) + the stock kernel's alias tables + the profile
//!       fragments -> DIR/lsmod, DIR/fragment.config, DIR/.config, DIR/kcflags,
//!       DIR/resolve-report.txt
//!   vh-kconf diff --config .config --requested fragment.config [--lsmod FILE]
//!                 [--kernel DIR] [--oracle localyesconfig|localmodconfig]
//!       after the kernel's olddefconfig: which requests survived and why the others did not
//!       (exit 2 when a mandatory symbol was lost)
//!
//! Static PIE, ReleaseSafe, std.os.linux only (zig/README.md). The kernel's own tools do the
//! Kconfig solving: see .github/workflows/kernel-custom.yml for the order of the calls.
const std = @import("std");
const vh = @import("vh");
const hw = @import("hw.zig");
const probe = @import("probe.zig");
const resolve = @import("resolve.zig");
const diff = @import("diff.zig");

const usage =
    \\usage: vh-kconf probe [--from DIR] [--save DIR] [-o FILE|--stdout]
    \\       vh-kconf resolve --hw FILE --plan FILE --out DIR [--repo DIR] [--features LIST|auto|none] [--alias F] [--builtin F] [--builtin-list F] [--base .config] [--profiles DIR]
    \\       vh-kconf diff --config .config --requested fragment.config [--lsmod FILE] [--kernel DIR] [--oracle localyesconfig|localmodconfig]
    \\       vh-kconf version
    \\
;

pub const version = "0.1.0";

pub fn main(init: std.process.Init.Minimal) void {
    const args = vh.init(init, "vh-kconf");
    if (args.len == 0 or vh.eql(args[0], "--help") or vh.eql(args[0], "-h")) {
        vh.outs(usage);
        vh.exit(if (args.len == 0) 2 else 0);
    }
    const cmd = args[0];
    const rest = args[1..];
    if (vh.eql(cmd, "version")) {
        vh.out("vh-kconf {s}\n", .{version});
        vh.exit(0);
    }
    if (vh.eql(cmd, "probe")) vh.exit(cmdProbe(rest));
    if (vh.eql(cmd, "resolve")) vh.exit(cmdResolve(rest));
    if (vh.eql(cmd, "diff")) vh.exit(cmdDiff(rest));
    if (vh.eql(cmd, "install") or vh.eql(cmd, "fetch") or vh.eql(cmd, "build") or vh.eql(cmd, "check"))
        vh.die("{s}: not in v0.1 (kernel/README.md says what it will do)", .{cmd});
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

    /// the value of option `opt` if `arg` is that option (with "=" or as the next argument)
    fn value(self: *Args, arg: []const u8, opt: []const u8) ?[]const u8 {
        if (vh.eql(arg, opt)) return self.next() orelse vh.die("{s} needs a value", .{opt});
        if (arg.len > opt.len + 1 and vh.startsWith(arg, opt) and arg[opt.len] == '=') return arg[opt.len + 1 ..];
        return null;
    }
};

fn cmdProbe(argv: []const [:0]const u8) u8 {
    var a: Args = .{ .items = argv };
    var src: probe.Src = .{};
    var out_path: ?[]const u8 = null;
    var to_stdout = false;
    while (a.next()) |arg| {
        if (a.value(arg, "--from")) |v| {
            src.root = std.mem.trimEnd(u8, v, "/");
        } else if (a.value(arg, "--save")) |v| {
            src.save = std.mem.trimEnd(u8, v, "/");
        } else if (a.value(arg, "-o")) |v| {
            out_path = v;
        } else if (vh.eql(arg, "--stdout")) {
            to_stdout = true;
        } else vh.die("probe: unknown argument {s}", .{arg});
    }
    const h = probe.run(&src);
    const text = hw.render(h);
    if (src.save) |d| vh.warn("snapshot saved under {s}", .{d});
    if (to_stdout or (out_path == null and src.root.len > 0)) {
        vh.outs(text);
        return 0;
    }
    const path = out_path orelse "/etc/vh/hw.zon";
    vh.mkdirs(probe.dirname(path), 0o755);
    vh.writeAtomic(path, text, 0o644);
    vh.warn("{s}: {d} devices, {d} loaded modules, kernel {s}, {s} {s}", .{ path, h.devices.len, h.modules.len, h.probe.kernel, h.machine.sys_vendor, h.machine.product_name });
    return 0;
}

fn cmdResolve(argv: []const [:0]const u8) u8 {
    var a: Args = .{ .items = argv };
    var o: resolve.Opts = .{ .hw = "", .out = "" };
    while (a.next()) |arg| {
        if (a.value(arg, "--hw")) |v| {
            o.hw = v;
        } else if (a.value(arg, "--out")) |v| {
            o.out = v;
        } else if (a.value(arg, "--repo")) |v| {
            o.repo = v;
        } else if (a.value(arg, "--plan")) |v| {
            o.plan = v;
        } else if (a.value(arg, "--features")) |v| {
            o.features = v;
        } else if (a.value(arg, "--alias")) |v| {
            o.alias = v;
        } else if (a.value(arg, "--builtin")) |v| {
            o.builtin = v;
        } else if (a.value(arg, "--builtin-list")) |v| {
            o.builtin_list = v;
        } else if (a.value(arg, "--base")) |v| {
            o.base = v;
        } else if (a.value(arg, "--profiles")) |v| {
            o.profiles = v;
        } else vh.die("resolve: unknown argument {s}", .{arg});
    }
    if (o.hw.len == 0 or o.out.len == 0) vh.die("resolve: --hw FILE and --out DIR are required", .{});
    return resolve.run(o);
}

fn cmdDiff(argv: []const [:0]const u8) u8 {
    var a: Args = .{ .items = argv };
    var o: diff.Opts = .{ .config = "", .requested = "" };
    while (a.next()) |arg| {
        if (a.value(arg, "--config")) |v| {
            o.config = v;
        } else if (a.value(arg, "--requested")) |v| {
            o.requested = v;
        } else if (a.value(arg, "--lsmod")) |v| {
            o.lsmod = v;
        } else if (a.value(arg, "--kernel")) |v| {
            o.kernel = std.mem.trimEnd(u8, v, "/");
        } else if (a.value(arg, "--oracle")) |v| {
            if (!vh.eql(v, "localyesconfig") and !vh.eql(v, "localmodconfig")) vh.die("--oracle: localyesconfig or localmodconfig", .{});
            o.oracle = v;
        } else vh.die("diff: unknown argument {s}", .{arg});
    }
    if (o.config.len == 0 or o.requested.len == 0) vh.die("diff: --config FILE and --requested FILE are required", .{});
    return diff.run(o);
}

test {
    _ = hw;
    _ = @import("alias.zig");
    _ = @import("kconfig.zig");
    _ = probe;
    _ = resolve;
    _ = diff;
}

test "Args" {
    const argv = [_][:0]const u8{ "--hw", "x.zon", "--out=dir", "--flag" };
    var a: Args = .{ .items = &argv };
    const first = a.next().?;
    try std.testing.expectEqualStrings("x.zon", a.value(first, "--hw").?);
    const second = a.next().?;
    try std.testing.expect(a.value(second, "--hw") == null);
    try std.testing.expectEqualStrings("dir", a.value(second, "--out").?);
    const third = a.next().?;
    try std.testing.expect(a.value(third, "--out") == null);
    try std.testing.expect(a.next() == null);
}
