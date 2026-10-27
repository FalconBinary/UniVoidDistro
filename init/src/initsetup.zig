//! vh-init --install / --rollback / --status: vh-init as PID 1 through the boot assessment
//! (docs/uni/kernel.md). The kernel command line lives inside the signed UKI, and under Secure
//! Boot nothing can be typed at Limine's prompt, so vh-init needs a UKI of its own: --install
//! writes the marker /etc/vh/init-boot and runs vh-limine-update, which gives the newest stock
//! UKI a twin with `init=/usr/local/sbin/vh-init` appended to its command line (the same kernel
//! and initrd, zig/lib/twin.zig), signs it, puts it after the machine entries of Limine's menu as
//! "Void Linux VER (vh-init)" and on trial: the next boot tries it once through Limine's one-shot
//! entry, a boot that does not reach its end leaves the one after to the stock UKI, and after
//! MACHINE_BOOTS good boots it is Limine's default. The stock UKI, which boots runit, is not
//! touched and heads the menu as the fallback; /etc/default/dracut-uefi-hook is not edited. A
//! stock kernel update makes the new kernel's twin and puts it on trial by itself (the hook runs
//! vh-limine-update). --rollback demotes the twin, removes the marker and runs vh-limine-update,
//! which deletes the twin and forgets its trial; runit boots again. The sv shim: runit's sv
//! becomes sv.runit, vh-ctl is sv; --rollback puts runit's back.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");
const sys = @import("sys.zig");
const manager = @import("manager.zig");

pub const hook_conf = "/etc/default/dracut-uefi-hook";
pub const init_param = "init=/usr/local/sbin/vh-init";
/// the marker vh-limine-update reads: while it exists, the newest stock UKI has its twin with
/// init= (zig/tools/vh-limine-update.zig)
pub const marker = "/etc/vh/init-boot";
const marker_text =
    \\# vh-init --install (init/README.md): vh-init is wanted as PID 1. While this file exists,
    \\# vh-limine-update gives the newest stock UKI a twin whose command line ends in
    \\# init=/usr/local/sbin/vh-init, "Void Linux VER (vh-init)" in Limine's menu, and the boot
    \\# assessment makes it Limine's default after MACHINE_BOOTS good boots (docs/uni/kernel.md);
    \\# the stock UKI, which boots runit, stays as it is and heads the menu as the fallback.
    \\# vh-init --rollback removes this file; the twin and its entry go with it.
    \\
;
pub const limine_update = "/usr/local/sbin/vh-limine-update";
/// the state of the boot assessment (zig/lib/assess.zig renders it; read here, never written)
pub const assess_state = "/var/lib/vh/boot-assess";
pub const boot_conf = "/etc/vh/boot.conf";
const esp = "/boot/efi";
pub const sv = "/usr/bin/sv";
pub const sv_runit = "/usr/bin/sv.runit";
pub const vh_ctl = "/usr/local/sbin/vh-ctl";
/// while the shim is /usr/bin/sv, an update of runit must not extract its sv over it; the same
/// mechanism keeps runit-void's ctrlaltdel out (rootfs/etc/xbps.d/30-vh-noextract.conf).
/// xbps-pkgdb -a reports the hash mismatch of /usr/bin/sv meanwhile: that is the shim
pub const noextract_conf = "/etc/xbps.d/31-vh-init.conf";
const noextract_text = "# vh-init --install: /usr/bin/sv is the vh-ctl shim (init/README.md); runit's own sv is\n# /usr/bin/sv.runit. An update of runit must not put it back; --rollback removes this file.\nnoextract=/usr/bin/sv\n";

fn needRoot() void {
    if (linux.geteuid() != 0) vh.die("run as root: doas vh-init ...", .{});
}

/// the init twin of a stock UKI, as vh-limine-update names it (zig/lib/assess.zig): the stock
/// UKI's name with -vh-init before .efi
pub fn isInitUki(name: []const u8) bool {
    return vh.endsWith(name, "-vh-init.efi");
}

/// "linux-6.18.58_1-vh-init.efi" -> "6.18.58_1", the stock kernel's version
pub fn stockVersion(name: []const u8) []const u8 {
    const v = if (vh.startsWith(name, "linux-") and vh.endsWith(name, "-vh-init.efi") and name.len > 18) name[6 .. name.len - 12] else name;
    return v;
}

/// the boot assessment's state, the fields --install, --rollback and --status read
pub const Assess = struct {
    default: []const u8 = "",
    trial: []const u8 = "",
    failed: bool = false,
    good: i64 = 0,
    armed: bool = false,
    reason: []const u8 = "",
    boots: i64 = 3,

    pub fn read(state_text: []const u8, conf_text: []const u8) Assess {
        var a: Assess = .{};
        var kv: vh.Kv = .{};
        kv.parse(state_text, false);
        a.default = kv.get("DEFAULT", "");
        a.trial = kv.get("TRIAL", "");
        a.failed = vh.eql(kv.get("TRIAL_STATE", "trying"), "failed");
        a.good = kv.int("TRIAL_GOOD", "0");
        a.armed = kv.get("TRIAL_ARMED", "").len > 0;
        a.reason = kv.get("TRIAL_REASON", "");
        var c: vh.Kv = .{};
        c.parse(conf_text, false);
        a.boots = c.int("MACHINE_BOOTS", "3");
        return a;
    }

    /// vh-init's standing in the assessment, one line
    pub fn initLine(a: Assess, wanted: bool) []const u8 {
        if (isInitUki(a.default)) return vh.fmt("Limine's default: {s} (vh-init on the stock kernel {s} passed its {d} boots; the stock UKI heads the menu)", .{ a.default, stockVersion(a.default), a.boots });
        if (isInitUki(a.trial)) {
            if (a.failed) return vh.fmt("failed its trial: {s}: {s} (doas vh-limine-update --retry {s})", .{ a.trial, a.reason, a.trial });
            return vh.fmt("on trial: {s}, {d} of {d} good boots, {s}", .{ a.trial, a.good, a.boots, if (a.armed) "set for the next boot (Limine's one-shot entry)" else if (a.reason.len > 0) a.reason else "not set yet" });
        }
        if (wanted) return vh.fmt("{s} exists, but no UKI with vh-init is on trial or the default: doas vh-limine-update --status (and doas vh-limine-update with {s} mounted makes the twin)", .{ marker, esp });
        return "no UKI with vh-init (doas vh-init --install)";
    }
};

fn readAssess() Assess {
    return Assess.read(vh.readFile(sys.p(assess_state)) catch "", vh.readFile(sys.p(boot_conf)) catch "");
}

/// the hook's KERNEL_CMDLINE names an init=: an earlier vh-init --install edited it, and the
/// stock UKI itself boots vh-init at its next rebuild, with no runit UKI left
fn hookHasInit(text: []const u8) bool {
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!vh.startsWith(line, "KERNEL_CMDLINE=")) continue;
        var it = mem.tokenizeAny(u8, line["KERNEL_CMDLINE=".len..], " \t\"");
        while (it.next()) |w| if (vh.startsWith(w, "init=")) return true;
    }
    return false;
}

const hook_warning = "{s}: KERNEL_CMDLINE carries init= (an earlier vh-init --install edited it): the stock UKI itself boots vh-init at its next rebuild and no runit UKI is left. Take init= out by hand and rebuild it: doas xbps-reconfigure -f {s}";

/// vh-limine-update with the ESP mounted: it is noauto in fstab (docs/03), so it is mounted
/// for the run and unmounted after it, as the kernel hooks do (05-vh-esp, 99-vh-esp)
fn limineUpdate() u8 {
    const mounted = !sys.isMountpoint(esp);
    if (mounted and vh.run(&.{ "/usr/bin/mount", esp }) != 0) vh.die("{s} could not be mounted: nothing changed", .{esp});
    const rc = vh.run(&.{limine_update});
    if (mounted) {
        linux.sync();
        _ = vh.run(&.{ "/usr/bin/umount", esp });
    }
    return rc;
}

fn kernelName() []const u8 {
    var env: vh.Kv = .{};
    env.read(sys.p("/etc/vh/vh.env"), true);
    return env.get("VH_KERNEL", "linux6.18");
}

/// with VH_MAC=selinux the new files take their labels now, whatever kernel runs (the stock
/// kernel labels nothing; the shim was file_t to the machine kernel, kvm-smoke run 40383056402)
fn label(paths: []const []const u8) void {
    if (!vh.isRegular(sys.p("/etc/vh/selinux/file_contexts")) or !vh.isRegular(sys.p("/usr/local/sbin/vh-selabel"))) return;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(vh.gpa, "/usr/local/sbin/vh-selabel") catch vh.oom();
    for (paths) |p| if (vh.pathExists(sys.p(p))) argv.append(vh.gpa, p) catch vh.oom();
    _ = vh.run(argv.items);
}

pub fn install() u8 {
    needRoot();
    if (!vh.isRegular(sys.p(limine_update))) vh.die("{s}: missing: the boot chain of this system is not installed", .{limine_update});
    if (hookHasInit(vh.readFile(sys.p(hook_conf)) catch "")) vh.die(hook_warning, .{ hook_conf, kernelName() });
    const a = readAssess();
    if (a.trial.len > 0 and !a.failed and !isInitUki(a.trial))
        vh.die("the machine kernel {s} is on trial ({d} of {d} good boots; vh-limine-update --status): let it pass or fail, then install vh-init", .{ a.trial, a.good, a.boots });
    if (a.default.len > 0 and !isInitUki(a.default))
        vh.warn("the machine kernel {s} is Limine's default: once vh-init passes its trial, the stock kernel with vh-init is the default and {s} an ordinary entry of the menu. A machine UKI with vh-init: vh-kconf install takes the stock UKI's command line, without init= (docs/uni/kernel.md)", .{ a.default, a.default });
    // the UKI first: a failure here leaves the system as it was
    const mark = sys.p(marker);
    const had_marker = vh.pathExists(mark);
    vh.writeAtomic(mark, marker_text, 0o644);
    const rc = limineUpdate();
    if (rc != 0) {
        if (!had_marker) {
            vh.unlink(mark) catch {};
            _ = limineUpdate();
        }
        vh.die("vh-limine-update failed ({d}): vh-init is not installed{s}", .{ rc, if (had_marker) "" else "; the marker is removed and limine.conf as it was" });
    }
    vh.out("{s}: vh-init is wanted as PID 1 (the marker vh-limine-update reads)\n", .{marker});
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
    if (vh.eql(vh.readlink(svp) catch "", vh_ctl)) {
        vh.writeAtomic(sys.p(noextract_conf), noextract_text, 0o644);
        vh.out("{s}: noextract=/usr/bin/sv (an update of runit keeps the shim; xbps-pkgdb -a reports the mismatch meanwhile)\n", .{noextract_conf});
    }
    vh.mkdirs(sys.p("/etc/vh/services/enabled"), 0o755);
    vh.mkdirs(sys.p("/var/lib/vh/init"), 0o700);
    vh.mkdirs(sys.p("/var/log/vh"), 0o700);
    label(&.{ marker, sv, sv_runit, noextract_conf, "/etc/vh/services/enabled", "/var/lib/vh/init", "/var/log/vh" });
    const after = readAssess();
    vh.out("vh-init: {s}\nNext: reboot. The stock UKI (runit) is untouched: it heads Limine's menu and boots when a trial boot does not reach its end. Check: vh-init --status, vh-limine-update --status, doas vh-audit init\nBack to runit as PID 1: doas vh-init --rollback\n", .{after.initLine(true)});
    return 0;
}

pub fn rollback() u8 {
    needRoot();
    const a = readAssess();
    if (isInitUki(a.default)) {
        // the variable first: the next boot is the stock UKI's whatever follows
        if (vh.run(&.{ limine_update, "--demote" }) != 0) vh.warn("vh-limine-update --demote failed: the twin's removal below clears the default as well", .{});
    }
    const mark = sys.p(marker);
    const had_marker = vh.pathExists(mark);
    if (had_marker) vh.unlink(mark) catch vh.die("{s}: {s}", .{ marker, vh.serr() });
    if (vh.isRegular(sys.p(limine_update))) {
        // the twin and its entry go, its trial is forgotten and the one-shot entry deleted
        const rc = limineUpdate();
        if (rc != 0) {
            if (had_marker) vh.writeAtomic(mark, marker_text, 0o644);
            vh.die("vh-limine-update failed ({d}): the UKI with vh-init stays in the menu{s}; fix the cause and run doas vh-init --rollback again", .{ rc, if (had_marker) ", the marker is back" else "" });
        }
        vh.out("{s} removed: the UKI with vh-init and its entry are gone, the stock UKI is Limine's default\n", .{marker});
    } else if (had_marker) vh.out("{s} removed\n", .{marker});
    if (hookHasInit(vh.readFile(sys.p(hook_conf)) catch "")) vh.warn(hook_warning, .{ hook_conf, kernelName() });
    const svp = sys.p(sv);
    const keep = sys.p(sv_runit);
    if (vh.pathExists(keep)) {
        _ = linux.unlink(vh.z(svp).ptr);
        _ = vh.sys(linux.rename(vh.z(keep).ptr, vh.z(svp).ptr)) catch vh.die("{s} -> {s}: {s}", .{ sv_runit, sv, vh.serr() });
        vh.out("runit's sv restored as {s}\n", .{sv});
    }
    if (vh.pathExists(sys.p(noextract_conf))) {
        _ = linux.unlink(vh.z(sys.p(noextract_conf)).ptr);
        vh.out("{s} removed\n", .{noextract_conf});
    }
    vh.outs("The next boot runs runit as PID 1; vh-init stays installed (doas vh-init --install puts it on trial again)\n");
    return 0;
}

pub fn status() u8 {
    const comm = vh.strip(vh.rd("/proc/1/comm"));
    const exe = vh.readlink("/proc/1/exe") catch "?";
    const is_vh = mem.indexOf(u8, exe, "vh-init") != null;
    vh.out("PID 1: {s} ({s})\n", .{ comm, exe });
    const wanted = vh.pathExists(sys.p(marker));
    vh.out("{s}: {s}\n", .{ marker, if (wanted) "present (vh-init is wanted: the newest stock UKI has its twin with init=)" else "absent (runit is wanted)" });
    vh.out("boot assessment: {s}\n", .{readAssess().initLine(wanted)});
    if (hookHasInit(vh.readFile(sys.p(hook_conf)) catch "")) vh.out("WARNING: " ++ hook_warning ++ "\n", .{ hook_conf, kernelName() });
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

test "the hook's init= is noticed, never edited" {
    try testing.expect(hookHasInit("# comment\nKERNEL_CMDLINE=\"root=x quiet init=/usr/local/sbin/vh-init\"\n"));
    try testing.expect(hookHasInit("KERNEL_CMDLINE=\"init=/old\"\n"));
    try testing.expect(!hookHasInit("KERNEL_CMDLINE=\"root=x rd.init=x initcall_debug\"\nUEFI_BUNDLE_DIR=\"boot/efi/EFI/void/\"\n"));
    try testing.expect(!hookHasInit("nothing here\n"));
}

test "the assessment's state as --status tells it" {
    const conf = "KEEP=2\nMACHINE_BOOTS=3\n";
    const none = Assess.read("", conf);
    try testing.expectEqualStrings("no UKI with vh-init (doas vh-init --install)", none.initLine(false));
    try testing.expect(mem.indexOf(u8, none.initLine(true), "no UKI with vh-init is on trial") != null);
    const trying = Assess.read("DEFAULT=\nTRIAL=linux-6.18.58_1-vh-init.efi\nTRIAL_STATE=trying\nTRIAL_GOOD=1\nTRIAL_ARMED=boot-1\nTRIAL_REASON=\n", conf);
    try testing.expectEqualStrings("on trial: linux-6.18.58_1-vh-init.efi, 1 of 3 good boots, set for the next boot (Limine's one-shot entry)", trying.initLine(true));
    const failed = Assess.read("TRIAL=linux-6.18.58_1-vh-init.efi\nTRIAL_STATE=failed\nTRIAL_GOOD=0\nTRIAL_ARMED=\nTRIAL_REASON=it broke\n", conf);
    try testing.expectEqualStrings("failed its trial: linux-6.18.58_1-vh-init.efi: it broke (doas vh-limine-update --retry linux-6.18.58_1-vh-init.efi)", failed.initLine(true));
    const dflt = Assess.read("DEFAULT=linux-6.18.58_1-vh-init.efi\nTRIAL=\n", "");
    try testing.expectEqualStrings("Limine's default: linux-6.18.58_1-vh-init.efi (vh-init on the stock kernel 6.18.58_1 passed its 3 boots; the stock UKI heads the menu)", dflt.initLine(true));
    // a machine kernel's trial or default is not vh-init's
    const machine = Assess.read("DEFAULT=linux-6.18.57-vh_1.efi\nTRIAL=linux-6.18.58-vh_1.efi\nTRIAL_STATE=trying\n", conf);
    try testing.expect(!isInitUki(machine.default) and !isInitUki(machine.trial));
    try testing.expectEqualStrings("no UKI with vh-init (doas vh-init --install)", machine.initLine(false));
    try testing.expectEqualStrings("6.18.58_1", stockVersion("linux-6.18.58_1-vh-init.efi"));
}
