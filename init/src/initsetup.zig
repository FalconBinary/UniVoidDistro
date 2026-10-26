//! vh-init --install / --rollback / --status: vh-init as PID 1 of the next boot. The kernel
//! command line lives inside the signed UKI (/etc/default/dracut-uefi-hook, KERNEL_CMDLINE):
//! --install adds `init=/usr/local/sbin/vh-init` there and says how to rebuild the UKI. The
//! rebuild replaces this kernel version's UKI (vh-limine-update keeps KEEP kernel versions, not
//! builds of one), so right after it there is no runit UKI to fall back to: `init=` typed at
//! Limine's prompt is not possible under Secure Boot either. runit stays installed, and
//! --rollback with the same rebuild brings it back; a boot that does not come up needs the live
//! image. An install through the boot assessment (a trial UKI, docs/uni/kernel.md) is the
//! follow-up. The sv shim: runit's sv becomes sv.runit, vh-ctl is sv.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");
const manager = @import("manager.zig");

pub const hook_conf = "/etc/default/dracut-uefi-hook";
pub const init_param = "init=/usr/local/sbin/vh-init";
pub const sv = "/usr/bin/sv";
pub const sv_runit = "/usr/bin/sv.runit";
pub const vh_ctl = "/usr/local/sbin/vh-ctl";

fn needRoot() void {
    if (linux.geteuid() != 0) vh.die("run as root: doas vh-init ...", .{});
}

/// the KERNEL_CMDLINE="..." line with the parameter added or removed
pub fn editCmdline(text: []const u8, add: bool) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    var found = false;
    var lines = mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) out.append(vh.gpa, '\n') catch vh.oom();
        first = false;
        if (!vh.startsWith(line, "KERNEL_CMDLINE=\"")) {
            out.appendSlice(vh.gpa, line) catch vh.oom();
            continue;
        }
        found = true;
        const close = mem.lastIndexOfScalar(u8, line, '"') orelse {
            out.appendSlice(vh.gpa, line) catch vh.oom();
            continue;
        };
        const inner = line["KERNEL_CMDLINE=\"".len..close];
        var words: std.ArrayList([]const u8) = .empty;
        var it = mem.tokenizeAny(u8, inner, " \t");
        while (it.next()) |w| if (!vh.startsWith(w, "init=")) words.append(vh.gpa, w) catch vh.oom();
        if (add) words.append(vh.gpa, init_param) catch vh.oom();
        out.appendSlice(vh.gpa, "KERNEL_CMDLINE=\"") catch vh.oom();
        for (words.items, 0..) |w, i| {
            if (i > 0) out.append(vh.gpa, ' ') catch vh.oom();
            out.appendSlice(vh.gpa, w) catch vh.oom();
        }
        out.append(vh.gpa, '"') catch vh.oom();
        out.appendSlice(vh.gpa, line[close + 1 ..]) catch vh.oom();
    }
    return if (found) out.items else null;
}

fn kernelName() []const u8 {
    var env: vh.Kv = .{};
    env.read(sys.p("/etc/vh/vh.env"), true);
    return env.get("VH_KERNEL", "linux6.18");
}

pub fn install() u8 {
    needRoot();
    const conf = sys.p(hook_conf);
    const text = vh.readFile(conf) catch vh.die("{s}: {s}", .{ conf, vh.serr() });
    const edited = editCmdline(text, true) orelse vh.die("{s}: no KERNEL_CMDLINE line", .{conf});
    if (mem.indexOf(u8, text, init_param) != null) {
        vh.out("{s} already has {s}\n", .{ hook_conf, init_param });
    } else {
        vh.writeAtomic(conf, edited, 0o644);
        vh.out("{s}: {s} added to KERNEL_CMDLINE\n", .{ hook_conf, init_param });
    }
    // the sv shim
    const svp = sys.p(sv);
    const keep = sys.p(sv_runit);
    const link = vh.readlink(svp) catch "";
    if (vh.eql(link, vh_ctl)) {
        vh.out("{s} is already the vh-ctl shim\n", .{sv});
    } else if (vh.isRegular(svp)) {
        if (!vh.pathExists(keep)) {
            _ = vh.sys(linux.rename(vh.z(svp).ptr, vh.z(keep).ptr)) catch vh.die("{s} -> {s}: {s}", .{ sv, sv_runit, vh.serr() });
            vh.out("kept runit's sv as {s}\n", .{sv_runit});
        } else _ = linux.unlink(vh.z(svp).ptr);
        _ = vh.sys(linux.symlink(vh.z(vh_ctl).ptr, vh.z(svp).ptr)) catch vh.die("{s}: {s}", .{ sv, vh.serr() });
        vh.out("{s} -> {s} (the shim runs sv.runit while runit is PID 1)\n", .{ sv, vh_ctl });
    } else vh.out("no {s}: the sv shim is not installed\n", .{sv});
    vh.mkdirs(sys.p("/etc/vh/services/enabled"), 0o755);
    vh.mkdirs(sys.p("/var/lib/vh/init"), 0o700);
    vh.mkdirs(sys.p("/var/log/vh"), 0o700);
    vh.out("Next: rebuild and sign the UKI: doas xbps-reconfigure -f {s}\n(it replaces this kernel version's UKI: until the rollback no UKI boots runit). Then reboot and check: vh-init --status, doas vh-audit init\nBack to runit as PID 1: doas vh-init --rollback, then the same xbps-reconfigure\n", .{kernelName()});
    return 0;
}

pub fn rollback() u8 {
    needRoot();
    const conf = sys.p(hook_conf);
    const text = vh.readFile(conf) catch vh.die("{s}: {s}", .{ conf, vh.serr() });
    if (editCmdline(text, false)) |edited| {
        if (mem.indexOf(u8, text, "init=") != null) {
            vh.writeAtomic(conf, edited, 0o644);
            vh.out("{s}: init= removed from KERNEL_CMDLINE\n", .{hook_conf});
        } else vh.out("{s}: no init= in KERNEL_CMDLINE\n", .{hook_conf});
    }
    const svp = sys.p(sv);
    const keep = sys.p(sv_runit);
    if (vh.pathExists(keep)) {
        _ = linux.unlink(vh.z(svp).ptr);
        _ = vh.sys(linux.rename(vh.z(keep).ptr, vh.z(svp).ptr)) catch vh.die("{s} -> {s}: {s}", .{ sv_runit, sv, vh.serr() });
        vh.out("runit's sv restored as {s}\n", .{sv});
    }
    vh.out("Rebuild the UKI: doas xbps-reconfigure -f {s}; the next boot runs runit as PID 1 again\n", .{kernelName()});
    return 0;
}

pub fn status() u8 {
    const comm = vh.strip(vh.rd("/proc/1/comm"));
    const exe = vh.readlink("/proc/1/exe") catch "?";
    const is_vh = mem.indexOf(u8, exe, "vh-init") != null;
    vh.out("PID 1: {s} ({s})\n", .{ comm, exe });
    const text = vh.readFile(sys.p(hook_conf)) catch "";
    vh.out("{s}: {s}\n", .{ hook_conf, if (mem.indexOf(u8, text, init_param) != null) "init=/usr/local/sbin/vh-init (the next UKI boots vh-init)" else "no init= (the next UKI boots runit)" });
    const link = vh.readlink(sys.p(sv)) catch "";
    vh.out("{s}: {s}\n", .{ sv, if (vh.eql(link, vh_ctl)) "the vh-ctl shim" else "runit's" });
    if (sys.kernelLog()) |log| {
        var lines = mem.tokenizeScalar(u8, log, '\n');
        while (lines.next()) |l| if (mem.indexOf(u8, l, "vh-init: ") != null) vh.out("kmsg: {s}\n", .{l[(mem.indexOf(u8, l, "] ") orelse 0) + 2 ..]});
    }
    if (is_vh) {
        if (@import("ctl.zig").request("ping")) |r| vh.out("manager: {s}", .{r.body}) else vh.out("manager: not reachable at /run/vh/init.sock\n", .{});
    }
    return if (is_vh) 0 else 1;
}

const testing = std.testing;

test "the cmdline edit adds and removes init=" {
    const text = "# comment\nKERNEL_CMDLINE=\"root=x quiet init=/old\"\nUEFI_BUNDLE_DIR=\"boot/efi/EFI/void/\"\n";
    const added = editCmdline(text, true).?;
    try testing.expectEqualStrings("# comment\nKERNEL_CMDLINE=\"root=x quiet init=/usr/local/sbin/vh-init\"\nUEFI_BUNDLE_DIR=\"boot/efi/EFI/void/\"\n", added);
    const removed = editCmdline(added, false).?;
    try testing.expectEqualStrings("# comment\nKERNEL_CMDLINE=\"root=x quiet\"\nUEFI_BUNDLE_DIR=\"boot/efi/EFI/void/\"\n", removed);
    try testing.expect(editCmdline("nothing here\n", true) == null);
}
