//! vh-kconf install: a machine kernel of the kernel-custom workflow becomes a machine UKI on the
//! ESP, on trial (kernel/README.md, "install"; docs/uni/kernel.md, "The boot assessment").
//!
//!   vh-kconf install DIR [--dry-run] [--hw FILE] [--plan FILE] [--repo DIR] [--root DIR]
//!
//! DIR holds the files of one machine of a run (its release, or its artifact). In order:
//!   1. verify: every file used is in DIR/SHA256SUMS and matches it; BUILD names the commit and
//!      the hw.zon the kernel was resolved from, which must be this machine's /etc/vh/hw.zon byte
//!      for byte; the kernel image of the hw.zon's architecture (bzImage-vh-KVER on x86_64,
//!      Image-vh-KVER on aarch64) reports the release of a machine kernel (A.B.C-vh): the
//!      bzImage in its setup header, the arm64 Image in its banner, which BUILD records too;
//!   2. the final .config (config-vh-KVER) has what the UKI needs: the EFI stub, an initrd in
//!      dracut's compression, the firmware loader for the files' compression (dracut checks
//!      none of it with --no-kernel);
//!   3. the firmware of the initrd: the files on disk that a firmware pattern of the plan keeps
//!      (the image's plan and the installation's), and regulatory.db with a built-in cfg80211;
//!      on x86_64 the CPU's microcode goes into dracut's early cpio, as for the stock UKI (the
//!      early cpio is x86's: an arm64 UKI has none);
//!   4. the command line: the newest stock UKI's, without module_blacklist= and module.* when the
//!      kernel has no loadable modules, without the parameters of modules it does not have (its
//!      modules.builtin), with the modprobe.d options of its built-in modules;
//!   5. dracut --no-kernel --kver A.B.C-vh --kernel-image FILE --uefi into a temporary file,
//!      checked (.linux is the verified kernel image, .cmdline the command line of 4), then
//!      /boot/efi/EFI/void/linux-A.B.C-vh_N.efi, N counting the installs of A.B.C-vh;
//!   6. vh-limine-update --new A.B.C-vh_N signs it as every UKI of the menu (after vh-uki-verify
//!      with offline keys), adds it after the stock entries and puts it on trial.
//! The gaming kernel (vh-game kernel build, docs/uni/game.md, G3b), whose bzImage reports
//! A.B.C-vh-game, goes the same way into the gaming series instead: the gaming boot must be on
//! (/etc/vh/game-boot); its UKI is /boot/efi/EFI/vh-game/linux-A.B.C-vh-game_N.efi; its command
//! line keeps the module parameters (the kernel has loadable modules) and turns ia32 on
//! (ia32_emulation=1); vh-limine-update makes it the gaming entry, never the default and no trial.
//! Programs run by argv, never through a shell (zig/README.md).
const std = @import("std");
const vh = @import("vh");
const hw = @import("hw.zig");
const alias = @import("alias.zig");
const kconfig = @import("kconfig.zig");
const check = @import("check.zig");
const uki = @import("uki.zig");
const linux = std.os.linux;
const mem = std.mem;

pub const Opts = struct {
    /// the files of the run: SHA256SUMS, BUILD, bzImage-vh-KVER or Image-vh-KVER, config-vh-KVER ...
    dir: []const u8,
    /// the system's files under this directory (tests): /etc, /usr/lib, /boot/efi, /var/lib/vh,
    /// and the programs dracut and vh-limine-update; nothing is mounted then
    root: []const u8 = "",
    /// this machine's probe, which the image must have been built from; ROOT/etc/vh/hw.zon
    hw: ?[]const u8 = null,
    /// the installation's plan (its firmware patterns); ROOT/etc/vh/plan.zon
    plan: ?[]const u8 = null,
    /// the repository copy: kernel/pins/modules.firmware, for what the drivers name; ROOT/root/vh
    repo: ?[]const u8 = null,
    /// everything up to dracut, then the command it would run: nothing is written
    dry_run: bool = false,
};

/// why the install stops: one message, said once by run()
pub const Diag = struct {
    msg: []const u8 = "",

    fn refuse(d: *Diag, comptime f: []const u8, args: anytype) error{Refused} {
        d.msg = vh.fmt(f, args);
        return error.Refused;
    }
};

const Refused = error{Refused};

/// the kernel's COMMAND_LINE_SIZE on x86 and on arm64 (2048 with the NUL)
const cmdline_max = 2047;

// ---------------------------------------------------------------- 1. verify

pub const Sum = struct { name: []const u8, hex: []const u8 };

/// sha256sum's lines, "HEX  NAME" (text mode) or "HEX *NAME" (binary mode); null for any other
pub fn parseSums(text: []const u8) ?[]const Sum {
    var out: std.ArrayList(Sum) = .empty;
    var it = mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = mem.trimEnd(u8, raw, "\r");
        if (vh.strip(line).len == 0) continue;
        if (line.len < 67 or line[64] != ' ' or (line[65] != ' ' and line[65] != '*')) return null;
        const hex = vh.dupe(line[0..64]);
        for (hex) |*c| {
            if (!std.ascii.isHex(c.*)) return null;
            c.* = std.ascii.toLower(c.*);
        }
        out.append(vh.gpa, .{ .name = vh.dupe(line[66..]), .hex = hex }) catch vh.oom();
    }
    return out.items;
}

fn sumOf(sums: []const Sum, name: []const u8) ?[]const u8 {
    for (sums) |s| if (vh.eql(s.name, name)) return s.hex;
    return null;
}

pub fn sha256Hex(data: []const u8) []const u8 {
    var d: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return vh.fmt("{x}", .{&d});
}

/// BUILD of the kernel-custom workflow:
///   kernel-custom NAME: linux-KVER, features FEATURES, commit SHA, run N
///   hw.zon: kernel/hw/NAME.zon sha256 HEX
///   KBUILD_BUILD_TIMESTAMP=... KCFLAGS=... LLVM=1 clang version ...
///   Linux version A.B.C-vh (vh@ci) (clang ...) #1 SMP ...
/// (the second line since vh-kconf install; without it the hw.zon is NAME.zon; the last one,
/// the banner `strings` finds in the image, where there is one: the uncompressed arm64 Image
/// carries it, a bzImage's is compressed)
pub const Build = struct {
    name: []const u8 = "",
    kver: []const u8 = "",
    features: []const u8 = "",
    commit: []const u8 = "",
    run: []const u8 = "",
    hw_path: []const u8 = "",
    hw_sha: []const u8 = "",
    /// the release of the banner line, "" without one
    linux_version: []const u8 = "",

    /// the hw.zon's name in the run's files
    pub fn hwFile(b: Build) []const u8 {
        if (b.hw_path.len > 0) return b.hw_path[if (mem.lastIndexOfScalar(u8, b.hw_path, '/')) |i| i + 1 else 0..];
        return vh.fmt("{s}.zon", .{b.name});
    }
};

pub fn parseBuild(text: []const u8) Build {
    var b: Build = .{};
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        if (vh.startsWith(line, "kernel-custom ")) {
            const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
            b.name = vh.dupe(vh.strip(line["kernel-custom ".len..colon]));
            // the features hold commas without a space: the fields are separated by ", "
            var it = mem.splitSequence(u8, line[colon + 1 ..], ", ");
            while (it.next()) |f0| {
                const f = vh.strip(f0);
                if (vh.startsWith(f, "linux-")) b.kver = vh.dupe(f["linux-".len..]);
                if (vh.startsWith(f, "features ")) b.features = vh.dupe(f["features ".len..]);
                if (vh.startsWith(f, "commit ")) b.commit = vh.dupe(f["commit ".len..]);
                if (vh.startsWith(f, "run ")) b.run = vh.dupe(f["run ".len..]);
            }
        } else if (vh.startsWith(line, "hw.zon: ")) {
            var it = mem.tokenizeScalar(u8, line["hw.zon: ".len..], ' ');
            const path = it.next() orelse continue;
            const kw = it.next() orelse continue;
            const hex = it.next() orelse continue;
            if (!vh.eql(kw, "sha256")) continue;
            b.hw_path = vh.dupe(path);
            b.hw_sha = vh.dupe(hex);
        } else if (vh.startsWith(line, "Linux version ") and b.linux_version.len == 0) {
            var it = mem.tokenizeScalar(u8, line["Linux version ".len..], ' ');
            if (it.next()) |rel| b.linux_version = vh.dupe(rel);
        }
    }
    return b;
}

/// the kernel image of an architecture, as the kernel-custom workflow names the file
/// (KIMG-vh-KVER): the x86_64 bzImage, the arm64 Image (uncompressed, with an EFI stub)
pub fn kernelImage(arch: []const u8) []const u8 {
    return if (vh.eql(arch, "aarch64")) "Image" else "bzImage";
}

/// a file name the run may give: letters, digits, "._-", not starting with a dot
fn safeName(s: []const u8) bool {
    if (s.len == 0 or s.len > 200 or s[0] == '.') return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
    return true;
}

/// A.B.C: what the UKI names of vh-limine-update take
fn isVersion(s: []const u8) bool {
    var it = mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (p.len == 0 or p.len > 9) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return n == 3;
}

/// what the run's files say, once verified
pub const Image = struct {
    dir: []const u8,
    build: Build,
    /// the architecture of the run's hw.zon: x86_64, aarch64
    arch: []const u8,
    /// what the kernel image is called: bzImage, Image (kernelImage)
    kind: []const u8,
    /// the kernel image: its file name in DIR, its bytes, their SHA-256
    kernel_file: []const u8,
    kernel: []const u8,
    kernel_sha: []const u8,
    /// the arm64 Image's header; null for a bzImage
    header: ?uki.ImageHeader,
    /// uname -r of the kernel: A.B.C-vh, or A.B.C-vh-game for the gaming kernel
    release: []const u8,
    /// the gaming kernel (vh-game kernel build): its release ends in -vh-game
    game: bool = false,
    config: kconfig.DotConfig,
    /// the kernel's built-in modules (its modules.builtin and modules.builtin.modinfo)
    builtin: ModSet,
    lsmod: []const []const u8,
    /// the drivers built into the stock kernel that resolve names (they are built in here too)
    stock_builtin: []const []const u8,
    plan: []const u8,
    /// every file checked against SHA256SUMS, and BUILD and SHA256SUMS as read (for the record)
    verified: []const []const u8,
    build_text: []const u8,
    sums_text: []const u8,
};

fn readVerified(dir: []const u8, name: []const u8, sums: []const Sum, d: *Diag) Refused![]const u8 {
    const path = vh.fmt("{s}/{s}", .{ dir, name });
    const want = sumOf(sums, name) orelse return d.refuse("{s} is not in {s}/SHA256SUMS: the run's files are incomplete, or not those of one run", .{ name, dir });
    const data = vh.readFile(path) catch return d.refuse("{s}: {s} (download every file of the release: docs/runbook-gf63.md, 1.5)", .{ path, vh.serr() });
    const got = sha256Hex(data);
    if (!vh.eql(got, want)) return d.refuse("{s}: sha256 {s}, SHA256SUMS says {s}: a damaged or replaced file", .{ path, got, want });
    return data;
}

/// The run's files in DIR against its SHA256SUMS and against this machine's probe.
pub fn verify(dir: []const u8, my_hw: []const u8, d: *Diag) Refused!Image {
    const sums_path = vh.fmt("{s}/SHA256SUMS", .{dir});
    const sums_text = vh.readFile(sums_path) catch return d.refuse("{s}: {s}: DIR is the directory of the run's files (bzImage-vh-KVER or Image-vh-KVER, BUILD, SHA256SUMS ...)", .{ sums_path, vh.serr() });
    const sums = parseSums(sums_text) orelse return d.refuse("{s}: not the output of sha256sum", .{sums_path});
    var verified: vh.Strv = .{};
    const build_text = try readVerified(dir, "BUILD", sums, d);
    verified.add("BUILD");
    const b = parseBuild(build_text);
    if (b.name.len == 0 or b.kver.len == 0 or b.commit.len == 0)
        return d.refuse("{s}/BUILD does not name the machine, the kernel version and the commit (kernel-custom NAME: linux-KVER, ..., commit SHA, ...)", .{dir});
    if (!safeName(b.name) or !isVersion(b.kver)) return d.refuse("{s}/BUILD: machine {s}, kernel {s}: not a name and an A.B.C version", .{ dir, b.name, b.kver });
    const hw_file = b.hwFile();
    if (!safeName(hw_file)) return d.refuse("{s}/BUILD names the hw.zon {s}: not a file name", .{ dir, hw_file });
    // the hw.zon first: its architecture names the kernel image of the run
    const hw_text = try readVerified(dir, hw_file, sums, d);
    if (b.hw_sha.len > 0 and !vh.eql(sha256Hex(hw_text), std.ascii.allocLowerString(vh.gpa, b.hw_sha) catch vh.oom()))
        return d.refuse("{s}/{s} is not the hw.zon BUILD names (sha256 {s})", .{ dir, hw_file, b.hw_sha });
    const arch = vh.dupe(hw.parse(hw_text, vh.fmt("{s}/{s}", .{ dir, hw_file })).archName());
    const arm64 = vh.eql(arch, "aarch64");
    const kind = kernelImage(arch);

    var files: [8][]const u8 = undefined;
    const names = [_][]const u8{ "-vh-", "config-vh-", "modules.builtin-vh-", "modules.builtin.modinfo-vh-" };
    for (names, 0..) |n, i| files[i] = vh.fmt("{s}{s}{s}", .{ if (i == 0) kind else "", n, b.kver });
    files[4] = "lsmod";
    files[5] = "resolve-report.txt";
    files[6] = "plan.zon";
    files[7] = hw_file;
    var data: [8][]const u8 = undefined;
    for (files, 0..) |f, i| {
        data[i] = if (i == 7) hw_text else readVerified(dir, f, sums, d) catch |e| {
            if (i == 2 or i == 3) if (sumOf(sums, f) == null)
                return d.refuse("{s} is not among the run's files: the run is older than vh-kconf install (the kernel-custom workflow uploads the kernel's modules.builtin since); build the kernel again", .{f});
            return e;
        };
        verified.add(f);
    }

    // the kernel itself: the release it reports
    var header: ?uki.ImageHeader = null;
    const release = if (arm64) blk: {
        const h = uki.imageHeader(data[0]) orelse return d.refuse("{s}/{s}: not an arm64 Image (no ARM\\x64 magic at offset 56): the hw.zon is an aarch64 machine's, the file is not the kernel-custom workflow's Image", .{ dir, files[0] });
        if (h.bigEndian()) return d.refuse("{s}/{s}: a big-endian kernel; this system is little-endian", .{ dir, files[0] });
        if (!h.efi) return d.refuse("{s}/{s}: no PE header behind the arm64 header: the kernel has no EFI stub (CONFIG_EFI_STUB), which the UKI's stub starts it through", .{ dir, files[0] });
        if (h.image_size < data[0].len) return d.refuse("{s}/{s}: the header's image_size ({d} bytes) is less than the file ({d} bytes): not a whole Image", .{ dir, files[0], h.image_size, data[0].len });
        header = h;
        break :blk uki.imageRelease(data[0]) orelse return d.refuse("{s}/{s}: no \"Linux version\" banner in the Image: not an uncompressed kernel image", .{ dir, files[0] });
    } else uki.bzRelease(data[0]) orelse return d.refuse("{s}/{s}: not a bzImage (no setup header with a kernel version)", .{ dir, files[0] });
    const game = vh.eql(release, vh.fmt("{s}-vh-game", .{b.kver}));
    if (!game and !vh.eql(release, vh.fmt("{s}-vh", .{b.kver})))
        return d.refuse("{s}/{s} reports the kernel {s}, not {s}-vh (or the gaming kernel's {s}-vh-game): not the machine kernel BUILD names (CONFIG_LOCALVERSION=\"-vh\", kernel/profiles/base)", .{ dir, files[0], release, b.kver, b.kver });
    // the banner BUILD recorded from the image the run built, where it did: the same kernel
    if (b.linux_version.len > 0 and !vh.eql(b.linux_version, release))
        return d.refuse("{s}/BUILD records Linux version {s}, {s} reports {s}: not the kernel of this run", .{ dir, b.linux_version, files[0], release });
    if (game and arm64) return d.refuse("{s}/{s} reports the gaming kernel {s}: the gaming session is x86_64's (docs/uni/game.md)", .{ dir, files[0], release });

    try checkHw(data[7], vh.fmt("{s}/{s}", .{ dir, hw_file }), my_hw, d);

    var img: Image = .{
        .dir = dir,
        .build = b,
        .arch = arch,
        .kind = kind,
        .kernel_file = files[0],
        .kernel = data[0],
        .kernel_sha = sha256Hex(data[0]),
        .header = header,
        .release = vh.dupe(release),
        .game = game,
        .config = .{},
        .builtin = .{},
        .lsmod = namesOf(data[4]),
        .stock_builtin = reportBuiltins(data[5]),
        .plan = data[6],
        .verified = verified.slice(),
        .build_text = build_text,
        .sums_text = sums_text,
    };
    img.config.parse(data[1]);
    // the gaming kernel is the one with loadable modules and ia32 (kernel/profiles/features/game)
    if (game and (img.config.tri("MODULES") != 2 or img.config.tri("IA32_EMULATION") != 2))
        return d.refuse("{s}/{s} reports the gaming kernel {s}, but its configuration lacks CONFIG_MODULES or CONFIG_IA32_EMULATION (kernel/profiles/features/game)", .{ dir, files[0], release });
    img.builtin.addPaths(data[2]);
    img.builtin.addModinfo(data[3]);
    if (img.builtin.names.count() == 0) return d.refuse("{s}/{s} names no built-in module: not the kernel's modules.builtin", .{ dir, files[2] });
    return img;
}

/// the image's hw.zon against this machine's probe: the same bytes, or the reason why not
fn checkHw(img_hw: []const u8, img_name: []const u8, mine_path: []const u8, d: *Diag) Refused!void {
    const mine = vh.readFile(mine_path) catch
        return d.refuse("{s}: {s}: this machine has no probe to compare the image with (doas vh-kconf probe)", .{ mine_path, vh.serr() });
    if (vh.eql(sha256Hex(mine), sha256Hex(img_hw))) return;
    const was = hw.parse(img_hw, img_name);
    const now = hw.parse(mine, mine_path);
    const other = check.machineDiff(was, now);
    if (other.len > 0) {
        return d.refuse("the image was built for another machine than this one ({s} against {s}): {s}. Probe this machine, commit its hw.zon and build its kernel (docs/runbook-gf63.md, 1.2 to 1.5)", .{
            img_name, mine_path, mem.join(vh.gpa, "; ", other) catch vh.oom(),
        });
    }
    return d.refuse("the image was built from another probe of this machine: {s} ({d} devices, {d} loaded modules) is not {s} ({d} devices, {d} loaded modules), the probe this system was planned from. Commit the current one as kernel/hw/NAME.zon and build the kernel again (docs/runbook-gf63.md, 1.3 to 1.5); --hw FILE names another probe of this machine", .{
        img_name, was.devices.len, was.modules.len, mine_path, now.devices.len, now.modules.len,
    });
}

/// the first word of every line (the LSMOD list is in lsmod format)
fn namesOf(text: []const u8) []const []const u8 {
    var out: vh.Strv = .{};
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = mem.tokenizeAny(u8, raw, " \t");
        const n = it.next() orelse continue;
        if (n[0] == '#' or vh.eql(n, "Module")) continue;
        out.add(alias.normalize(n));
    }
    return out.slice();
}

/// "Drivers already built into the stock kernel (N): a b c" of resolve-report.txt
fn reportBuiltins(text: []const u8) []const []const u8 {
    const key = "Drivers already built into the stock kernel (";
    const at = mem.indexOf(u8, text, key) orelse return &.{};
    const rest = text[at..];
    const whole = rest[0 .. mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
    const colon = mem.indexOf(u8, whole, "): ") orelse return &.{};
    const line = whole[colon + 3 ..];
    var out: vh.Strv = .{};
    var it = mem.tokenizeScalar(u8, line, ' ');
    while (it.next()) |m| if (!vh.eql(m, "-")) out.add(alias.normalize(m));
    return out.slice();
}

// ---------------------------------------------------------------- modules

/// the module names of a kernel, "-" and "_" alike (kmod's rule)
pub const ModSet = struct {
    names: std.StringHashMapUnmanaged(void) = .empty,

    pub fn add(s: *ModSet, name: []const u8) void {
        s.names.put(vh.gpa, alias.normalize(name), {}) catch vh.oom();
    }

    pub fn has(s: *const ModSet, name: []const u8) bool {
        return s.names.contains(alias.normalize(name));
    }

    /// modules.builtin ("kernel/dir/name.ko") and modules.dep ("kernel/dir/name.ko.zst: deps")
    pub fn addPaths(s: *ModSet, text: []const u8) void {
        var lines = mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const path = vh.strip(raw[0 .. mem.indexOfScalar(u8, raw, ':') orelse raw.len]);
            const base = path[if (mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0..];
            const ko = mem.indexOf(u8, base, ".ko") orelse continue;
            if (ko > 0) s.add(base[0..ko]);
        }
    }

    /// modules.builtin.modinfo: NUL-separated "MODULE.key=value" records; every record names one
    pub fn addModinfo(s: *ModSet, bytes: []const u8) void {
        var recs = mem.tokenizeScalar(u8, bytes, 0);
        while (recs.next()) |rec| {
            const dot = mem.indexOfScalar(u8, rec, '.') orelse continue;
            if (dot > 0 and mem.indexOfScalarPos(u8, rec, dot, '=') != null) s.add(rec[0..dot]);
        }
    }
};

/// a release of the stock kernel (A.B.C_N), not a machine kernel's
fn stockRelease(s: []const u8) bool {
    const us = mem.lastIndexOfScalar(u8, s, '_') orelse return false;
    if (!isVersion(s[0..us]) or us + 1 >= s.len) return false;
    for (s[us + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// every module of the stock kernels in MODDIR (loadable or built in): a command-line parameter
/// MOD.x of one of them belongs to a module; the dotted rest (rd.*, iommu.*) to the core or the initrd
fn stockModules(moddir: []const u8, pkg: []const u8, d: *Diag) Refused!ModSet {
    var s: ModSet = .{};
    var n: usize = 0;
    for (vh.listDir(moddir) catch &.{}) |rel| {
        if (!stockRelease(rel)) continue;
        const dep = vh.readFile(vh.fmt("{s}/{s}/modules.dep", .{ moddir, rel })) catch continue;
        s.addPaths(dep);
        if (vh.readFile(vh.fmt("{s}/{s}/modules.builtin", .{ moddir, rel }))) |t| s.addPaths(t) else |_| {}
        n += 1;
    }
    if (n == 0) return d.refuse("{s}: no stock kernel's modules.dep: the stock kernel is the fallback of every machine kernel (xbps-install -f {s})", .{ moddir, pkg });
    return s;
}

// ---------------------------------------------------------------- 4. the command line

/// The words of a kernel command line as the kernel splits them (lib/cmdline.c, next_arg): at
/// white space outside double quotes; each word as written, its quotes included.
pub fn splitArgs(s: []const u8) []const []const u8 {
    var out: vh.Strv = .{};
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and vh.isSpace(s[i])) i += 1;
        if (i >= s.len) break;
        const start = i;
        var quoted = false;
        while (i < s.len and (quoted or !vh.isSpace(s[i]))) : (i += 1) {
            if (s[i] == '"') quoted = !quoted;
        }
        out.add(s[start..i]);
    }
    return out.slice();
}

/// a parameter's name: the word up to "=", a leading quote dropped
fn paramName(w: []const u8) []const u8 {
    const v = if (w.len > 0 and w[0] == '"') w[1..] else w;
    return v[0 .. mem.indexOfScalar(u8, v, '=') orelse v.len];
}

/// an "options MODULE ARGS" line of modprobe.d, one argument each
pub const ModOption = struct { module: []const u8, arg: []const u8, file: []const u8 };

/// The options lines of one modprobe.d file, kmod's way: a line ending in "\" goes on in the
/// next one, a line starting with "#" is a comment, the arguments are the rest of the line.
pub fn parseOptions(text: []const u8, file: []const u8, out: *std.ArrayList(ModOption)) void {
    var joined: std.ArrayList(u8) = .empty;
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = mem.trimEnd(u8, raw, "\r");
        if (l.len > 0 and l[l.len - 1] == '\\') {
            joined.appendSlice(vh.gpa, l[0 .. l.len - 1]) catch vh.oom();
            continue;
        }
        joined.appendSlice(vh.gpa, l) catch vh.oom();
        const line = vh.strip(joined.items);
        defer joined.clearRetainingCapacity();
        if (line.len == 0 or line[0] == '#') continue;
        var it = mem.tokenizeAny(u8, line, " \t");
        const cmd = it.next() orelse continue;
        if (!vh.eql(cmd, "options")) continue;
        const m = it.next() orelse continue;
        for (splitArgs(it.rest())) |a| out.append(vh.gpa, .{ .module = alias.normalize(m), .arg = a, .file = vh.dupe(file) }) catch vh.oom();
    }
}

/// The modprobe.d files kmod reads, in its order: *.conf of /etc/modprobe.d,
/// /usr/local/lib/modprobe.d, /usr/lib/modprobe.d and /lib/modprobe.d, sorted by name, the
/// first directory winning for a name. /run/modprobe.d is left out: a UKI does not depend on
/// what one boot wrote.
fn modprobeOptions(root: []const u8) []const ModOption {
    const dirs = [_][]const u8{ "/etc/modprobe.d", "/usr/local/lib/modprobe.d", "/usr/lib/modprobe.d", "/lib/modprobe.d" };
    var seen: vh.Strv = .{};
    var paths: std.ArrayList([2][]const u8) = .empty;
    for (dirs) |dir| {
        const full = vh.fmt("{s}{s}", .{ root, dir });
        for (vh.listDir(full) catch &.{}) |n| {
            if (!vh.endsWith(n, ".conf") or n[0] == '.' or seen.has(n)) continue;
            seen.add(n);
            paths.append(vh.gpa, .{ vh.dupe(n), vh.fmt("{s}/{s}", .{ full, n }) }) catch vh.oom();
        }
    }
    mem.sort([2][]const u8, paths.items, {}, struct {
        fn lt(_: void, a: [2][]const u8, b: [2][]const u8) bool {
            return vh.lessStr({}, a[0], b[0]);
        }
    }.lt);
    var out: std.ArrayList(ModOption) = .empty;
    for (paths.items) |p| {
        const text = vh.readFile(p[1]) catch continue;
        parseOptions(text, p[1][root.len..], &out);
    }
    return out.items;
}

pub const Change = struct { word: []const u8, why: []const u8 };

pub const Cmdline = struct {
    text: []const u8,
    removed: []const Change = &.{},
    added: []const Change = &.{},
    /// modprobe.d options left where they are: their module is not built into this kernel
    stayed: []const Change = &.{},
};

/// vh-init as PID 1 (vh-init --install, init/README.md): while its marker exists, the machine
/// UKI's command line ends in init= as the stock UKI's twin does (vh-limine-update), so the
/// machine kernel boots vh-init too; the stock UKI itself never carries it. Not the gaming
/// kernel's: the gaming boot is runit's stage 2 (docs/uni/game.md).
pub const init_mark = "/etc/vh/init-boot";
pub const init_param = "init=/usr/local/sbin/vh-init";

/// the command line with init= appended (before a "--" tail, init's arguments; an init= of the
/// stock line, which an older vh-init --install put into the hook, gives way)
pub fn withInit(cl: Cmdline) Cmdline {
    var out = cl;
    var words: vh.Strv = .{};
    var tail: vh.Strv = .{};
    for (splitArgs(cl.text)) |w| {
        if (tail.len() > 0 or vh.eql(w, "--")) {
            tail.add(w);
            continue;
        }
        if (vh.startsWith(w, "init=")) continue;
        words.add(w);
    }
    words.add(init_param);
    for (tail.slice()) |w| words.add(w);
    out.text = words.join(" ");
    var added: std.ArrayList(Change) = .empty;
    added.appendSlice(vh.gpa, cl.added) catch vh.oom();
    added.append(vh.gpa, .{ .word = init_param, .why = "vh-init is wanted as PID 1 (" ++ init_mark ++ ", vh-init --install)" }) catch vh.oom();
    out.added = added.items;
    return out;
}

/// The machine kernel's command line from the stock UKI's: the same parameters, so that the
/// sysctl loader, vh-kconf check and vh-audit see one system, but
///   - without module_blacklist= and module.* when the kernel has no loadable modules (an
///     unknown parameter without a dot would reach PID 1 as an environment variable);
///   - without MOD.x where MOD is a module of the stock kernel that this one does not have;
///   - with "MOD.x" for every modprobe.d option of a module built into it (modprobe never sees
///     a built-in module, the command line reaches it), after the stock parameters, as kmod puts
///     the files' options after those of the command line.
pub fn machineCmdline(stock: []const u8, modules: bool, builtin: *const ModSet, stock_mods: *const ModSet, options: []const ModOption) Cmdline {
    var words: vh.Strv = .{};
    var tail: vh.Strv = .{}; // "--" and what follows: init's arguments
    var removed: std.ArrayList(Change) = .empty;
    var added: std.ArrayList(Change) = .empty;
    var stayed: std.ArrayList(Change) = .empty;
    for (splitArgs(stock)) |w| {
        if (tail.len() > 0 or vh.eql(w, "--")) {
            tail.add(w);
            continue;
        }
        const name = paramName(w);
        if (!modules and (vh.eql(name, "module_blacklist") or vh.startsWith(name, "module."))) {
            removed.append(vh.gpa, .{ .word = w, .why = "this kernel has no loadable modules (CONFIG_MODULES is not set)" }) catch vh.oom();
            continue;
        }
        if (mem.indexOfScalar(u8, name, '.')) |dot| {
            const m = name[0..dot];
            if (dot > 0 and stock_mods.has(m) and !builtin.has(m)) {
                removed.append(vh.gpa, .{ .word = w, .why = vh.fmt("{s} is not in this kernel", .{alias.normalize(m)}) }) catch vh.oom();
                continue;
            }
        }
        words.add(w);
    }
    for (options) |o| {
        const w = vh.fmt("{s}.{s}", .{ o.module, o.arg });
        if (!builtin.has(o.module)) {
            stayed.append(vh.gpa, .{ .word = vh.fmt("options {s} {s}", .{ o.module, o.arg }), .why = vh.fmt("{s}: {s} is not built into this kernel", .{ o.file, o.module }) }) catch vh.oom();
            continue;
        }
        if (words.has(w)) continue;
        words.add(w);
        added.append(vh.gpa, .{ .word = w, .why = vh.fmt("options {s} {s} ({s})", .{ o.module, o.arg, o.file }) }) catch vh.oom();
    }
    for (tail.slice()) |w| words.add(w);
    return .{ .text = words.join(" "), .removed = removed.items, .added = added.items, .stayed = stayed.items };
}

/// the gaming boot's marker (vh-game boot on): the gaming kernel is installed only while it is on
const game_mark = "/etc/vh/game-boot";

/// The gaming kernel's command line: the machine kernel's with ia32 on. The kernel reads every
/// ia32_emulation= in turn and the last one decides, and the gaming kernel has ia32 off by
/// default (CONFIG_IA32_EMULATION_DEFAULT_DISABLED): each one becomes ia32_emulation=1, and
/// one is added when there is none.
pub fn gameCmdline(text: []const u8) []const u8 {
    var words: vh.Strv = .{};
    var tail: vh.Strv = .{};
    var seen = false;
    for (splitArgs(text)) |w| {
        if (tail.len() > 0 or vh.eql(w, "--")) {
            tail.add(w);
            continue;
        }
        if (vh.eql(paramName(w), "ia32_emulation")) {
            if (!seen) words.add("ia32_emulation=1");
            seen = true;
            continue;
        }
        words.add(w);
    }
    if (!seen) words.add("ia32_emulation=1");
    for (tail.slice()) |w| words.add(w);
    return words.join(" ");
}

/// the parameter the kernel would take, or why not: printable ASCII within COMMAND_LINE_SIZE
fn cmdlineProblem(text: []const u8) ?[]const u8 {
    if (text.len > cmdline_max) return vh.fmt("{d} bytes, more than the kernel's {d}", .{ text.len, cmdline_max });
    for (text) |c| if (c < 0x20 or c > 0x7e) return "a byte that is not printable ASCII";
    return null;
}

// ---------------------------------------------------------------- 2. the final .config

/// the compressor of dracut's configuration: the last compress= in dracut's order (dracut.conf,
/// then the *.conf of /etc/dracut.conf.d and /usr/lib/dracut/dracut.conf.d by name, /etc winning
/// for a name); its first word without a directory; "" when no file sets it
pub fn dracutCompress(root: []const u8) []const u8 {
    var files: std.ArrayList([2][]const u8) = .empty;
    var seen: vh.Strv = .{};
    for ([_][]const u8{ "/etc/dracut.conf.d", "/usr/lib/dracut/dracut.conf.d" }) |dir| {
        const full = vh.fmt("{s}{s}", .{ root, dir });
        for (vh.listDir(full) catch &.{}) |n| {
            if (!vh.endsWith(n, ".conf") or seen.has(n)) continue;
            seen.add(n);
            files.append(vh.gpa, .{ vh.dupe(n), vh.fmt("{s}/{s}", .{ full, n }) }) catch vh.oom();
        }
    }
    mem.sort([2][]const u8, files.items, {}, struct {
        fn lt(_: void, a: [2][]const u8, b: [2][]const u8) bool {
            return vh.lessStr({}, a[0], b[0]);
        }
    }.lt);
    var comp: []const u8 = "";
    const first = vh.fmt("{s}/etc/dracut.conf", .{root});
    if (vh.readFile(first)) |t| comp = compressOf(t) orelse comp else |_| {}
    for (files.items) |f| if (vh.readFile(f[1])) |t| {
        comp = compressOf(t) orelse comp;
    } else |_| {};
    return comp;
}

/// the last compress= of one configuration file (a shell assignment, quotes optional)
fn compressOf(text: []const u8) ?[]const u8 {
    var last: ?[]const u8 = null;
    var lines = mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        if (!vh.startsWith(line, "compress=")) continue;
        const v = mem.trim(u8, vh.strip(line["compress=".len..]), "\"'");
        var it = mem.tokenizeAny(u8, v, " \t");
        const prog = it.next() orelse "";
        last = vh.dupe(prog[if (mem.lastIndexOfScalar(u8, prog, '/')) |i| i + 1 else 0..]);
    }
    return last;
}

/// the compressor a dracut option names (--zstd, --compress=X, --no-compress ...); null for none
pub fn compressOption(words: []const []const u8) ?[]const u8 {
    var comp: ?[]const u8 = null;
    for (words, 0..) |w, i| {
        if (vh.eql(w, "--no-compress")) return "cat";
        if (vh.startsWith(w, "--compress=")) comp = w["--compress=".len..];
        if (vh.eql(w, "--compress") and i + 1 < words.len) comp = words[i + 1];
        for ([_][2][]const u8{ .{ "--zstd", "zstd" }, .{ "--lz4", "lz4" }, .{ "--xz", "xz" }, .{ "--lzma", "lzma" }, .{ "--gzip", "gzip" }, .{ "--bzip2", "bzip2" }, .{ "--lzo", "lzop" } }) |o|
            if (vh.eql(w, o[0])) {
                comp = o[1];
            };
    }
    const c = comp orelse return null;
    var it = mem.tokenizeAny(u8, mem.trim(u8, c, "\"'"), " \t");
    const prog = it.next() orelse return null;
    return prog[if (mem.lastIndexOfScalar(u8, prog, '/')) |j| j + 1 else 0..];
}

/// the initrd decompressor a kernel needs for dracut's compressor (dracut's own table,
/// check_kernel_compress_support, which --no-kernel skips); "" for none, null when unknown
pub fn rdSymbol(comp: []const u8) ?[]const u8 {
    const table = [_][2][]const u8{
        .{ "zstd", "RD_ZSTD" }, .{ "lz4", "RD_LZ4" },   .{ "xz", "RD_XZ" },       .{ "lzma", "RD_LZMA" },
        .{ "gzip", "RD_GZIP" }, .{ "pigz", "RD_GZIP" }, .{ "bzip2", "RD_BZIP2" }, .{ "lbzip2", "RD_BZIP2" },
        .{ "lzop", "RD_LZO" },  .{ "cat", "" },
    };
    for (table) |t| if (vh.eql(t[0], comp)) return t[1];
    return null;
}

/// What a UKI needs of its kernel, against the final .config: problems stop the install, notes
/// are said in the report. The same on both architectures but for the microcode, x86's.
pub fn checkConfig(cfg: *const kconfig.DotConfig, comp: []const u8, firmware: []const []const u8, arch: []const u8, problems: *vh.Strv, notes: *vh.Strv) void {
    if (cfg.tri("EFI_STUB") != 2) problems.add("CONFIG_EFI_STUB is not set: systemd-stub cannot start this kernel");
    if (cfg.tri("BLK_DEV_INITRD") != 2) problems.add("CONFIG_BLK_DEV_INITRD is not set: the kernel would not unpack the initrd (LUKS, the firmware)");
    const c = if (comp.len > 0) comp else "zstd"; // dracut's first choice when nothing sets it
    if (rdSymbol(c)) |sym| {
        if (sym.len > 0 and cfg.tri(sym) != 2) problems.add(vh.fmt("dracut compresses the initrd with {s}, and CONFIG_{s} is not set: the kernel could not unpack it (compress= of /etc/dracut.conf.d/10-vh.conf, VH_INITRD_COMPRESS)", .{ c, sym }));
    } else notes.add(vh.fmt("dracut's compressor {s} is not one the kernel's CONFIG_RD_* names: not checked", .{c}));
    var zst = false;
    var xz = false;
    for (firmware) |f| {
        zst = zst or vh.endsWith(f, ".zst");
        xz = xz or vh.endsWith(f, ".xz");
    }
    if (firmware.len > 0 and cfg.tri("FW_LOADER") != 2) problems.add("CONFIG_FW_LOADER is not set: no built-in driver can load its firmware");
    if (zst and cfg.tri("FW_LOADER_COMPRESS_ZSTD") != 2) problems.add("firmware files are zstd-compressed and CONFIG_FW_LOADER_COMPRESS_ZSTD is not set");
    if (xz and cfg.tri("FW_LOADER_COMPRESS_XZ") != 2) problems.add("firmware files are xz-compressed and CONFIG_FW_LOADER_COMPRESS_XZ is not set");
    if (vh.eql(arch, "x86_64") and cfg.tri("MICROCODE") != 2) notes.add("CONFIG_MICROCODE is not set: the early microcode of the initrd is not loaded");
}

// ---------------------------------------------------------------- 3. the firmware

pub const FwItem = struct { value: []const u8, rules: []const []const u8 = &.{} };
const PlanFirmware = struct { firmware: []const FwItem = &.{} };

/// the firmware patterns of a plan.zon (vh-plan writes more; the rest is ignored)
pub fn planFirmware(text: []const u8, what: []const u8) []const FwItem {
    var diag: std.zon.parse.Diagnostics = undefined;
    const p = std.zon.parse.fromSlice(PlanFirmware, .{
        .gpa = vh.gpa,
        .arena = vh.gpa,
        .source = vh.z(text),
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => vh.oom(),
        error.ParseZon => vh.die("{f}", .{diag.fmt(what)}),
    };
    return p.firmware;
}

/// The plan's firmware patterns that belong in an initrd: all but the microcode's (the rules
/// whose id ends in ".microcode", hwdb/README.md), which dracut's early cpio carries for this
/// CPU only. `left` gets the patterns left out.
pub fn initrdPatterns(items: []const FwItem, out: *vh.Strv, left: *vh.Strv) void {
    for (items) |it| {
        var microcode = it.rules.len > 0;
        for (it.rules) |r| microcode = microcode and vh.endsWith(r, ".microcode");
        if (microcode) {
            if (!left.has(it.value)) left.add(it.value);
        } else if (!out.has(it.value)) out.add(it.value);
    }
}

/// every file under DIR, regular or a symbolic link, relative to it, sorted
fn listTree(dir: []const u8) []const []const u8 {
    var out: vh.Strv = .{};
    walk(dir, "", &out, 0);
    out.sort();
    return out.slice();
}

fn walk(dir: []const u8, rel: []const u8, out: *vh.Strv, depth: u32) void {
    if (depth > 16) return;
    const here = if (rel.len > 0) vh.fmt("{s}/{s}", .{ dir, rel }) else dir;
    for (vh.listDir(here) catch return) |n| {
        const r = if (rel.len > 0) vh.fmt("{s}/{s}", .{ rel, n }) else n;
        const st = vh.stat(vh.fmt("{s}/{s}", .{ here, n }), false) catch continue;
        if (vh.S.isDir(st.mode)) walk(dir, r, out, depth + 1) else if (vh.S.isReg(st.mode) or vh.S.isLnk(st.mode)) out.add(r);
    }
}

/// the files a pattern matches (fnmatch, as xbps matches noextract= and vh-kconf check the
/// firmware it keeps), and the `extra` names that are among the files
pub fn selectFirmware(files: []const []const u8, patterns: []const []const u8, extra: []const []const u8) []const []const u8 {
    var out: vh.Strv = .{};
    for (files) |f| {
        var hit = false;
        for (patterns) |p| hit = hit or alias.fnmatch(p, f);
        for (extra) |e| hit = hit or vh.eql(e, f);
        if (hit) out.add(f);
    }
    return out.slice();
}

/// A firmware file a driver names, as a pattern of the files that serve it, as vh-plan's
/// firmwarePattern makes it (adapt/src/plan.zig): any API version of an iwlwifi-style
/// "NAME-77.ucode", and the compressed ".zst" or ".xz" Void ships.
pub fn namedPattern(file: []const u8) []const u8 {
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

/// The drivers of this kernel (the LSMOD list and the stock kernel's built-in drivers) that
/// name firmware in kernel/pins/modules.firmware and get none of it in the initrd: a device
/// probed before the root is mounted would go without (its driver may give the device up).
pub fn firmwareGaps(table: []const u8, drivers: []const []const u8, chosen: []const []const u8) []const []const u8 {
    var out: vh.Strv = .{};
    var named: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var lines = mem.tokenizeScalar(u8, table, '\n');
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        if (line.len == 0 or line[0] == '#') continue;
        var it = mem.tokenizeAny(u8, line, " \t");
        const m = alias.normalize(it.next() orelse continue);
        const f = it.next() orelse continue;
        const gop = named.getOrPut(vh.gpa, m) catch vh.oom();
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(vh.gpa, vh.dupe(f)) catch vh.oom();
    }
    for (drivers) |m| {
        const files = (named.get(m) orelse continue).items;
        var served = false;
        for (files) |f| {
            const p = namedPattern(f);
            for (chosen) |c| served = served or alias.fnmatch(p, c);
        }
        if (!served and !out.has(m)) out.add(vh.fmt("{s} ({d} file(s), for example {s})", .{ m, files.len, files[0] }));
    }
    return out.slice();
}

// ---------------------------------------------------------------- the ESP and the series

/// the machine UKI names of the release, "linux-REL_N.efi": N, or null
pub fn installNumber(name: []const u8, release: []const u8) ?u32 {
    const pre = vh.fmt("linux-{s}_", .{release});
    if (!vh.startsWith(name, pre) or !vh.endsWith(name, ".efi")) return null;
    const n = name[pre.len .. name.len - 4];
    if (n.len == 0 or n.len > 9) return null;
    for (n) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, n, 10) catch null;
}

/// N of the next install of RELEASE: one more than any N the ESP, the install records
/// (/var/lib/vh/kernels) or the boot assessment's state still know, so that a name never
/// comes back for another kernel
pub fn nextNumber(release: []const u8, esp_names: []const []const u8, records: []const []const u8, state: []const u8) u32 {
    var n: u32 = 0;
    for (esp_names) |e| if (installNumber(e, release)) |x| {
        n = @max(n, x);
    };
    for (records) |r| if (installNumber(vh.fmt("linux-{s}.efi", .{r}), release)) |x| {
        n = @max(n, x);
    };
    var lines = mem.tokenizeScalar(u8, state, '\n');
    while (lines.next()) |raw| {
        const line = vh.strip(raw);
        for ([_][]const u8{ "DEFAULT=", "TRIAL=" }) |k| if (vh.startsWith(line, k)) {
            if (installNumber(line[k.len..], release)) |x| n = @max(n, x);
        };
    }
    return n + 1;
}

/// the stock UKIs, linux-A.B.C_D.efi, newest first (vh-limine-update's order)
pub fn stockUkis(names: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |n| {
        if (!vh.startsWith(n, "linux-") or !vh.endsWith(n, ".efi")) continue;
        if (stockRelease(n["linux-".len .. n.len - 4])) out.append(vh.gpa, n) catch vh.oom();
    }
    mem.sort([]const u8, out.items, {}, struct {
        fn gt(_: void, a: []const u8, b: []const u8) bool {
            const va = versionOf(a);
            const vb = versionOf(b);
            for (0..4) |i| if (va[i] != vb[i]) return va[i] > vb[i];
            return mem.order(u8, a, b) == .gt;
        }
    }.gt);
    return out.items;
}

fn versionOf(name: []const u8) [4]u64 {
    var v = [4]u64{ 0, 0, 0, 0 };
    var it = mem.tokenizeAny(u8, name["linux-".len .. name.len - 4], "._");
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        if (i >= 4) break;
        v[i] = std.fmt.parseInt(u64, p, 10) catch 0;
    }
    return v;
}

/// the stock kernel's package (VH_KERNEL of /etc/vh/vh.env), for the messages
fn kernelPackage(root: []const u8) []const u8 {
    var env: vh.Kv = .{};
    env.read(vh.fmt("{s}/etc/vh/vh.env", .{root}), false);
    return env.get("VH_KERNEL", "the kernel package");
}

fn isMount(path: []const u8) bool {
    const a = vh.stat(path, false) catch return false;
    if (vh.S.isLnk(a.mode)) return false;
    const b = vh.stat(vh.fmt("{s}/..", .{path}), false) catch return false;
    return a.dev_major != b.dev_major or a.dev_minor != b.dev_minor or a.ino == b.ino;
}

/// the key situation vh-limine-update will meet when it signs (its sign()): refused before the
/// build when it would refuse after it
fn keysProblem(root: []const u8) ?[]const u8 {
    var conf: vh.Kv = .{};
    conf.read(vh.fmt("{s}/etc/vh/boot.conf", .{root}), false);
    if (vh.pathExists(vh.fmt("{s}/var/lib/sbctl/keys/db/db.key", .{root}))) return null;
    if (vh.eql(conf.get("KEYS_OFFLINE", "no"), "yes"))
        return "the key media is not attached (/var/lib/sbctl/keys/db/db.key): vh-limine-update could not sign the UKI. Attach it first: doas vh-keys mount (optional/sb-offline-keys)";
    const dir = vh.fmt("{s}/sys/firmware/efi/efivars", .{root});
    for (vh.listDir(dir) catch &.{}) |n| if (vh.startsWith(n, "SecureBoot-")) {
        const d = vh.readFile(vh.fmt("{s}/{s}", .{ dir, n })) catch continue;
        if (d.len > 4 and d[4] == 1) return "Secure Boot is on and the db key is missing (/var/lib/sbctl/keys/db/db.key): the firmware would not start an unsigned UKI";
    };
    return null;
}

/// mkdtemp: a 0700 directory with a random suffix
fn mkdtemp(prefix: []const u8) []const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for (0..100) |_| {
        var r: [8]u8 = undefined;
        _ = linux.getrandom(&r, r.len, 0);
        var s: [8]u8 = undefined;
        for (r, 0..) |b, i| s[i] = alphabet[b % alphabet.len];
        const p = vh.fmt("{s}{s}", .{ prefix, s });
        if (vh.sys(linux.mkdir(vh.z(p).ptr, 0o700))) |_| return p else |_| if (vh.errno != .EXIST) break;
    }
    vh.die("mkdtemp {s}: {s}", .{ prefix, vh.serr() });
}

/// a new file on the ESP: written beside it, synced, renamed into place (FAT keeps no modes)
fn writeNew(path: []const u8, data: []const u8, d: *Diag) Refused!void {
    const tmp = vh.fmt("{s}.new", .{path});
    vh.unlink(tmp) catch {};
    const fd = vh.openFd(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600) catch
        return d.refuse("{s}: {s}", .{ tmp, vh.serr() });
    vh.writeAllFd(fd, data) catch {
        const why = vh.serr();
        vh.close(fd);
        vh.unlink(tmp) catch {};
        return d.refuse("{s}: {s} (the UKI is {d} MiB: is the ESP full?)", .{ tmp, why, data.len >> 20 });
    };
    _ = vh.sys(linux.fsync(fd)) catch {};
    vh.close(fd);
    _ = vh.sys(linux.rename(vh.z(tmp).ptr, vh.z(path).ptr)) catch {
        const why = vh.serr();
        vh.unlink(tmp) catch {};
        return d.refuse("{s}: {s}", .{ path, why });
    };
}

// ---------------------------------------------------------------- the install

/// what the UKI of the build must be: the verified kernel image (`kind` names it) and the
/// computed command line; true when an early cpio with x86 microcode is in the initrd
pub fn checkUki(efi: []const u8, kernel: []const u8, kind: []const u8, cmdline: []const u8, d: *Diag) Refused!bool {
    const s = uki.peSections(efi) orelse return d.refuse("dracut wrote no PE image", .{});
    const linux_sec = uki.section(s, ".linux") orelse return d.refuse("the UKI has no .linux section", .{});
    if (linux_sec.len < kernel.len or !mem.eql(u8, linux_sec[0..kernel.len], kernel)) return d.refuse("the UKI's .linux section is not the verified {s}", .{kind});
    for (linux_sec[kernel.len..]) |c| if (c != 0) return d.refuse("the UKI's .linux section is not the verified {s}", .{kind});
    const c = uki.section(s, ".cmdline") orelse return d.refuse("the UKI has no .cmdline section", .{});
    const got = vh.strip(mem.trimEnd(u8, c, "\x00"));
    if (!vh.eql(got, cmdline)) return d.refuse("the UKI's command line is not the one checked (a kernel_cmdline= of dracut's configuration adds to it?):\n  checked: {s}\n  UKI:     {s}", .{ cmdline, got });
    const initrd = uki.section(s, ".initrd") orelse return d.refuse("the UKI has no .initrd section", .{});
    if (initrd.len == 0) return d.refuse("the UKI's initrd is empty", .{});
    // the early cpio of the CPU's microcode, when dracut made one (kernel/x86/microcode/...)
    for (uki.cpioNames(initrd)) |n| if (vh.startsWith(n, "kernel/x86/microcode/") and n.len > "kernel/x86/microcode/".len) return true;
    return false;
}

const Plan = struct {
    stock_uki: []const u8,
    stock_cmdline: []const u8,
    cmdline: Cmdline,
    firmware: []const []const u8,
    firmware_bytes: u64,
    patterns: []const []const u8,
    left_out: []const []const u8,
    missing: []const []const u8,
    gaps: ?[]const []const u8,
    compress: []const u8,
    notes: []const []const u8,
    number: u32,
    version: []const u8,
};

/// the report: what was verified, what goes into the UKI and why
fn report(img: *const Image, p: *const Plan, my_hw: []const u8) []const u8 {
    var t: std.ArrayList(u8) = .empty;
    const w = struct {
        fn f(b: *std.ArrayList(u8), comptime fm: []const u8, args: anytype) void {
            b.print(vh.gpa, fm ++ "\n", args) catch vh.oom();
        }
    }.f;
    const b = img.build;
    w(&t, "vh-kconf install: the machine kernel of {s}", .{img.dir});
    w(&t, "image: kernel-custom {s}, linux-{s}, features {s}, commit {s}, run {s}", .{ b.name, b.kver, if (b.features.len > 0) b.features else "?", b.commit, if (b.run.len > 0) b.run else "?" });
    w(&t, "verified: {d} files against SHA256SUMS ({s}); {s} is this machine's {s}", .{ img.verified.len, mem.join(vh.gpa, " ", img.verified) catch vh.oom(), b.hwFile(), my_hw });
    w(&t, "kernel: {s} ({s}, sha256 {s}); CONFIG_MODULES={s}; initrd {s}", .{ img.release, img.kernel_file, img.kernel_sha, kconfig.show(img.config.get("MODULES")), if (p.compress.len > 0) p.compress else "zstd (dracut's default)" });
    if (img.header) |h| w(&t, "  arm64 Image: {d} KiB, image_size {d} KiB, text_offset 0x{x}, {s}, little-endian, loadable anywhere: {s}, EFI stub: yes", .{
        img.kernel.len >> 10, h.image_size >> 10, h.text_offset, if (h.pageSize()) |ps| vh.fmt("{d} KiB pages", .{ps >> 10}) else "page size unspecified", if (h.anywhere()) "yes" else "no",
    });
    for (p.notes) |n| w(&t, "  note: {s}", .{n});
    w(&t, "firmware for the initrd: {d} file(s), {d} KiB, by the plan's patterns: {s}", .{ p.firmware.len, p.firmware_bytes >> 10, if (p.patterns.len > 0) mem.join(vh.gpa, " ", p.patterns) catch vh.oom() else "-" });
    if (p.left_out.len > 0) w(&t, "  left out: {s} (the microcode: dracut's early cpio carries this CPU's)", .{mem.join(vh.gpa, " ", p.left_out) catch vh.oom()});
    for (p.missing) |m| w(&t, "  not on disk: {s}", .{m});
    if (p.gaps) |g| {
        for (g) |m| w(&t, "  warning: {s} names firmware and gets none of it in the initrd", .{m});
    } else w(&t, "  the firmware the drivers name is not checked: no kernel/pins/modules.firmware (--repo)", .{});
    w(&t, "command line: from {s}", .{p.stock_uki});
    for (p.cmdline.removed) |c| w(&t, "  - {s}: {s}", .{ c.word, c.why });
    for (p.cmdline.added) |c| w(&t, "  + {s}: {s}", .{ c.word, c.why });
    for (p.cmdline.stayed) |c| w(&t, "  = {s}: {s}", .{ c.word, c.why });
    w(&t, "  {s}", .{p.cmdline.text});
    w(&t, "UKI: /boot/efi/EFI/void/linux-{s}.efi", .{p.version});
    return t.items;
}

pub fn run(o: Opts) u8 {
    var d: Diag = .{};
    const rc = install(o, &d) catch {
        vh.warn("{s}", .{d.msg});
        return 1;
    };
    return rc;
}

fn install(o: Opts, d: *Diag) Refused!u8 {
    const root = mem.trimEnd(u8, o.root, "/");
    const dir = mem.trimEnd(u8, o.dir, "/");
    if (root.len == 0) {
        if (linux.geteuid() != 0) return d.refuse("root is required (the ESP, the state of the boot assessment): doas vh-kconf install{s} {s}", .{ if (o.dry_run) " --dry-run" else "", dir });
        vh.setenv("PATH", "/usr/bin");
    }
    const my_hw = o.hw orelse vh.fmt("{s}/etc/vh/hw.zon", .{root});
    const plan_path = o.plan orelse vh.fmt("{s}/etc/vh/plan.zon", .{root});
    const repo = o.repo orelse vh.fmt("{s}/root/vh", .{root});
    const pkg = kernelPackage(root);
    // one install at a time: the number N, the ESP
    var lock: ?vh.fd_t = null;
    defer {
        if (lock) |fd| vh.close(fd);
    }
    if (!o.dry_run) {
        vh.mkdirs(vh.fmt("{s}/var/lib/vh", .{root}), 0o700);
        const lock_path = vh.fmt("{s}/var/lib/vh/kconf-install.lock", .{root});
        const fd = vh.openFd(lock_path, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true }, 0o600) catch return d.refuse("{s}: {s}", .{ lock_path, vh.serr() });
        lock = fd;
        _ = vh.sysRetry(linux.flock, .{ fd, @as(i32, 2 | 4) }) catch return d.refuse("another vh-kconf install is running ({s})", .{lock_path}); // LOCK_EX | LOCK_NB
    }

    // 1. verify
    var img = try verify(dir, my_hw, d);
    const modules = img.config.tri("MODULES") != 0;
    // the gaming kernel boots from the gaming entry alone, which the gaming boot makes
    if (img.game and !vh.pathExists(vh.fmt("{s}{s}", .{ root, game_mark })))
        return d.refuse("{s} is the gaming kernel, and the gaming boot is off: doas vh-game boot on (docs/uni/game.md)", .{img.release});

    // the ESP: the stock UKI's command line, the names of the machine series
    const esp = vh.fmt("{s}/boot/efi", .{root});
    var mounted = false;
    if (root.len == 0 and !isMount(esp)) {
        // noauto in fstab (docs/03): mounted for the install, as the kernel.d hooks do
        const rc = if (o.dry_run) vh.run(&.{ "mount", "-o", "ro", "/boot/efi" }) else vh.run(&.{ "mount", "/boot/efi" });
        if (rc != 0 or !isMount(esp)) return d.refuse("/boot/efi could not be mounted", .{});
        mounted = true;
    }
    defer {
        if (mounted) {
            linux.sync();
            _ = vh.run(&.{ "umount", "/boot/efi" });
        }
    }
    const stock_dir = vh.fmt("{s}/EFI/void", .{esp});
    const uki_dir = if (img.game) vh.fmt("{s}/EFI/vh-game", .{esp}) else stock_dir;
    const esp_names = vh.listDir(uki_dir) catch &.{};
    const stock = stockUkis(vh.listDir(stock_dir) catch &.{});
    if (stock.len == 0) return d.refuse("no stock UKI in {s}: the stock UKI is the fallback of every machine kernel and its command line the machine kernel's (xbps-reconfigure -f {s})", .{ stock_dir, pkg });
    const stock_path = vh.fmt("{s}/{s}", .{ stock_dir, stock[0] });
    const stock_c = (uki.fileSection(stock_path, ".cmdline") catch return d.refuse("{s}: {s}", .{ stock_path, vh.serr() })) orelse
        return d.refuse("{s}: no .cmdline section: not a UKI of dracut-uefi", .{stock_path});
    const stock_cmdline = vh.strip(mem.trimEnd(u8, stock_c, "\x00"));
    if (stock_cmdline.len == 0) return d.refuse("{s}: an empty command line", .{stock_path});

    // 2. the kernel's configuration; 3. the firmware
    var problems: vh.Strv = .{};
    var notes: vh.Strv = .{};
    var patterns: vh.Strv = .{};
    var left_out: vh.Strv = .{};
    initrdPatterns(planFirmware(img.plan, vh.fmt("{s}/plan.zon", .{dir})), &patterns, &left_out);
    if (vh.readFile(plan_path)) |t| initrdPatterns(planFirmware(t, plan_path), &patterns, &left_out) else |_| notes.add(vh.fmt("{s}: no plan of the installation: the image's plan alone names the firmware", .{plan_path}));
    const fwdir = vh.fmt("{s}/usr/lib/firmware", .{root});
    const on_disk = listTree(fwdir);
    // a built-in cfg80211 reads the regulatory database from the initrd: without it, it stays in
    // the world domain (CFG80211_REQUIRE_SIGNED_REGDB takes the signature too)
    const regdb = [_][]const u8{ "regulatory.db", "regulatory.db.p7s" };
    const cfg80211 = img.config.tri("CFG80211") == 2;
    const firmware = selectFirmware(on_disk, patterns.slice(), if (cfg80211) &regdb else &.{});
    var missing: vh.Strv = .{};
    for (patterns.slice()) |p| {
        var any = false;
        for (firmware) |f| any = any or alias.fnmatch(p, f);
        if (!any) missing.add(vh.fmt("{s} (a pattern of the plan without a file)", .{p}));
    }
    if (cfg80211) for (regdb) |r| {
        var have = false;
        for (firmware) |f| have = have or vh.eql(f, r);
        if (!have) missing.add(vh.fmt("{s} (cfg80211 is built in: it stays in the world domain without; xbps-install wireless-regdb)", .{r}));
    };
    var bytes: u64 = 0;
    for (firmware) |f| {
        const st = vh.stat(vh.fmt("{s}/{s}", .{ fwdir, f }), true) catch continue;
        bytes += st.size;
    }
    // the stock UKI's dracut run: the hook's DRACUT_OPTIONS (word-split, as the hook expands
    // them) and dracut's configuration, whose compressor an option may override
    var hook: vh.Kv = .{};
    hook.read(vh.fmt("{s}/etc/default/dracut-uefi-hook", .{root}), false);
    const dracut_opts = splitArgs(hook.get("DRACUT_OPTIONS", ""));
    const comp = compressOption(dracut_opts) orelse dracutCompress(root);
    checkConfig(&img.config, comp, firmware, img.arch, &problems, &notes);
    const gaps: ?[]const []const u8 = if (vh.readFile(vh.fmt("{s}/kernel/pins/modules.firmware", .{repo}))) |table| blk: {
        var drivers: vh.Strv = .{};
        for (img.lsmod) |m| drivers.add(m);
        for (img.stock_builtin) |m| if (!drivers.has(m)) drivers.add(m);
        break :blk firmwareGaps(table, drivers.slice(), firmware);
    } else |_| null;

    // 4. the command line
    const stock_mods = try stockModules(vh.fmt("{s}/usr/lib/modules", .{root}), pkg, d);
    var cl = machineCmdline(stock_cmdline, modules, &img.builtin, &stock_mods, modprobeOptions(root));
    if (img.game) cl.text = gameCmdline(cl.text);
    if (!img.game and vh.pathExists(vh.fmt("{s}{s}", .{ root, init_mark }))) cl = withInit(cl);
    if (cmdlineProblem(cl.text)) |why| problems.add(vh.fmt("the command line: {s}", .{why}));
    const hook_cmdline = hook.get("KERNEL_CMDLINE", "");
    if (hook_cmdline.len > 0 and !vh.eql(mem.join(vh.gpa, " ", splitArgs(hook_cmdline)) catch vh.oom(), mem.join(vh.gpa, " ", splitArgs(stock_cmdline)) catch vh.oom()))
        notes.add(vh.fmt("{s} was built from another KERNEL_CMDLINE than /etc/default/dracut-uefi-hook holds now: the machine UKI takes the stock UKI's; rebuild the stock UKI (xbps-reconfigure -f {s}) and install again to take the new one", .{ stock[0], pkg }));

    // the name: N counts the installs of this release
    const records_dir = vh.fmt("{s}/var/lib/vh/kernels", .{root});
    const state = vh.readFile(vh.fmt("{s}/var/lib/vh/boot-assess", .{root})) catch "";
    const number = nextNumber(img.release, esp_names, vh.listDir(records_dir) catch &.{}, state);
    const version = vh.fmt("{s}_{d}", .{ img.release, number });

    const p: Plan = .{
        .stock_uki = stock[0],
        .stock_cmdline = stock_cmdline,
        .cmdline = cl,
        .firmware = firmware,
        .firmware_bytes = bytes,
        .patterns = patterns.slice(),
        .left_out = left_out.slice(),
        .missing = missing.slice(),
        .gaps = gaps,
        .compress = comp,
        .notes = notes.slice(),
        .number = number,
        .version = version,
    };
    const rep = report(&img, &p, my_hw);
    vh.outs(rep);
    if (problems.len() > 0) {
        for (problems.slice()) |x| vh.out("  problem: {s}\n", .{x});
        return d.refuse("{d} problem(s) above: no UKI was built", .{problems.len()});
    }
    if (!o.dry_run) if (keysProblem(root)) |why| return d.refuse("{s}", .{why});

    // 5. dracut: into a temporary directory first, then checked
    const kernel_path = vh.fmt("{s}/{s}", .{ dir, img.kernel_file });
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(vh.gpa, &.{ vh.fmt("{s}/usr/bin/dracut", .{root}), "--force" }) catch vh.oom();
    argv.appendSlice(vh.gpa, dracut_opts) catch vh.oom();
    argv.appendSlice(vh.gpa, &.{ "--no-kernel", "--kver", img.release, "--kernel-image", kernel_path, "--uefi", vh.fmt("--kernel-cmdline={s}", .{cl.text}) }) catch vh.oom();
    const shown = argv.items.len;
    for (firmware) |f| argv.appendSlice(vh.gpa, &.{ "--include", vh.fmt("{s}/{s}", .{ fwdir, f }), vh.fmt("/usr/lib/firmware/{s}", .{f}) }) catch vh.oom();
    if (o.dry_run) {
        vh.out("dry run: the firmware of the initrd ({d} files, each --include FILE FILE):\n", .{firmware.len});
        for (firmware) |f| vh.out("  /usr/lib/firmware/{s}\n", .{f});
        vh.out("dry run: dracut would run as\n  {s} [--include ...] /var/tmp/vh-kconf.XXXXXXXX/linux-{s}.efi\nnothing was written\n", .{ mem.join(vh.gpa, " ", argv.items[0..shown]) catch vh.oom(), version });
        return 0;
    }
    vh.mkdirs(vh.fmt("{s}/var/tmp", .{root}), 0o1777);
    const td = mkdtemp(vh.fmt("{s}/var/tmp/vh-kconf.", .{root}));
    const out_tmp = vh.fmt("{s}/linux-{s}.efi", .{ td, version });
    defer {
        vh.unlink(out_tmp) catch {};
        _ = linux.rmdir(vh.z(td).ptr);
    }
    argv.append(vh.gpa, out_tmp) catch vh.oom();
    vh.out("  + dracut --no-kernel --kver {s} --kernel-image {s} --uefi ({d} firmware files) {s}\n", .{ img.release, kernel_path, firmware.len, out_tmp });
    const drc = vh.run(argv.items);
    if (drc != 0) return d.refuse("dracut failed ({d}): no UKI was installed", .{drc});
    const efi = vh.readFile(out_tmp) catch return d.refuse("{s}: {s}: dracut wrote no UKI", .{ out_tmp, vh.serr() });
    const microcode = try checkUki(efi, img.kernel, img.kind, cl.text, d);
    vh.out("  the UKI: {d} MiB; .linux is the verified {s}, .cmdline the command line above; early microcode: {s}\n", .{
        efi.len >> 20, img.kind, if (microcode) "yes" else if (vh.eql(img.arch, "x86_64")) "none (no microcode for this CPU on disk, or early_microcode=no)" else "none (the early cpio is x86's)",
    });

    // onto the ESP, into the menu: a machine kernel on trial, the gaming kernel as the gaming entry
    const name = vh.fmt("linux-{s}.efi", .{version});
    const dst = vh.fmt("{s}/{s}", .{ uki_dir, name });
    if (vh.pathExists(dst)) return d.refuse("{s} exists already", .{dst});
    vh.mkdirs(uki_dir, 0o755);
    try writeNew(dst, efi, d);
    const lu = vh.fmt("{s}/usr/local/sbin/vh-limine-update", .{root});
    vh.out("  + vh-limine-update{s}{s}\n", .{ if (img.game) "" else " --new ", if (img.game) "" else version });
    const lrc = if (img.game) vh.run(&.{lu}) else vh.run(&.{ lu, "--new", version });
    if (lrc != 0) {
        // a UKI that limine.conf does not name is removed: the ESP is as it was
        const conf = vh.readFile(vh.fmt("{s}/EFI/BOOT/limine.conf", .{esp})) catch "";
        if (mem.indexOf(u8, conf, vh.fmt("/EFI/{s}/{s}#", .{ if (img.game) "vh-game" else "void", name })) == null) {
            vh.unlink(dst) catch {};
            return d.refuse("vh-limine-update --new {s} failed ({d}): the UKI was removed, the ESP is as it was", .{ version, lrc });
        }
        return d.refuse("vh-limine-update --new {s} failed ({d}) after it wrote limine.conf: the UKI stays in the menu, not on trial; doas vh-limine-update --retry {s} once the cause is fixed", .{ version, lrc, name });
    }

    // the record of the install: what this machine UKI is, and the numbers taken
    const rec = vh.fmt("{s}/{s}", .{ records_dir, version });
    vh.mkdirs(rec, 0o700);
    vh.writeAtomic(vh.fmt("{s}/report.txt", .{rec}), rep, 0o600);
    vh.writeAtomic(vh.fmt("{s}/cmdline", .{rec}), vh.fmt("{s}\n", .{cl.text}), 0o600);
    vh.writeAtomic(vh.fmt("{s}/firmware", .{rec}), vh.fmt("{s}\n", .{mem.join(vh.gpa, "\n", firmware) catch vh.oom()}), 0o600);
    vh.writeAtomic(vh.fmt("{s}/BUILD", .{rec}), img.build_text, 0o600);
    vh.writeAtomic(vh.fmt("{s}/SHA256SUMS", .{rec}), img.sums_text, 0o600);
    vh.out("vh-kconf install: {s} installed; the record is {s}\n", .{ name, rec[root.len..] });
    return 0;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const probe = @import("probe.zig");

test "install: SHA256SUMS and BUILD" {
    const h = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const s = parseSums(h ++ "  BUILD\n" ++ "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD *bzImage-vh-6.18.57\n\n").?;
    try testing.expectEqual(@as(usize, 2), s.len);
    try testing.expectEqualStrings(h, sumOf(s, "bzImage-vh-6.18.57").?);
    try testing.expect(sumOf(s, "lsmod") == null);
    try testing.expect(parseSums(h ++ " BUILD\n") == null);
    try testing.expect(parseSums("xyz  BUILD\n") == null);
    try testing.expectEqualStrings(h, sha256Hex("abc"));

    const b = parseBuild(
        \\kernel-custom gf63: linux-6.18.57, features usb-common,bluetooth, commit 0123abc, run 12
        \\hw.zon: kernel/hw/gf63.zon sha256 ABCDEF
        \\KBUILD_BUILD_TIMESTAMP=2026-10-19T12:00:00+02:00 KCFLAGS=-march=skylake LLVM=1 clang version 18
        \\
    );
    try testing.expectEqualStrings("gf63", b.name);
    try testing.expectEqualStrings("", b.linux_version);
    const arm = parseBuild("kernel-custom qemu-virt: linux-6.18.59, features auto, commit ff, run 3\nhw.zon: kernel/hw/qemu-virt.zon sha256 00\nKCFLAGS=-march=armv8-a\nLinux version 6.18.59-vh (vh@ci) (clang version 18.1.3) #1 SMP PREEMPT_DYNAMIC Tue Oct 28 00:00:00 UTC 2026\n");
    try testing.expectEqualStrings("6.18.59-vh", arm.linux_version);
    try testing.expectEqualStrings("6.18.57", b.kver);
    try testing.expectEqualStrings("usb-common,bluetooth", b.features);
    try testing.expectEqualStrings("0123abc", b.commit);
    try testing.expectEqualStrings("12", b.run);
    try testing.expectEqualStrings("gf63.zon", b.hwFile());
    try testing.expectEqualStrings("ABCDEF", b.hw_sha);
    // a BUILD from before vh-kconf install: the hw.zon is NAME.zon
    const old = parseBuild("kernel-custom qemu-q35: linux-6.18.57, features auto, commit ff, run 3\n");
    try testing.expectEqualStrings("qemu-q35.zon", old.hwFile());
    try testing.expect(isVersion("6.18.57") and !isVersion("6.18") and !isVersion("6.18.57-rc1") and !isVersion("6..1"));
    try testing.expect(safeName("gf63.zon") and !safeName("../x.zon") and !safeName(".zon") and !safeName("a/b"));
    try testing.expect(stockRelease("6.18.57_1") and !stockRelease("6.18.57-vh") and !stockRelease("6.18.57_") and !stockRelease("6.18_1"));
}

test "install: the command line of a machine kernel" {
    var builtin: ModSet = .{};
    builtin.addPaths("kernel/net/wireless/cfg80211.ko\nkernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko\nkernel/net/ipv6/ipv6.ko\n");
    builtin.addModinfo("iTCO_wdt.parmtype=nowayout:bool\x00iTCO_wdt.file=drivers/watchdog/iTCO_wdt\x00");
    try testing.expect(builtin.has("iTCO-wdt") and builtin.has("iwlwifi") and !builtin.has("iwlmvm"));
    var stock: ModSet = .{};
    stock.addPaths("kernel/drivers/net/wireless/intel/iwlwifi/mvm/iwlmvm.ko.zst: kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko.zst\n" ++
        "kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko.zst: kernel/net/wireless/cfg80211.ko.zst\nkernel/net/wireless/cfg80211.ko.zst:\n" ++
        "kernel/drivers/watchdog/iTCO_wdt.ko.zst:\n");
    stock.addPaths("kernel/drivers/firmware/efi/efi-pstore.ko\nkernel/net/ipv6/ipv6.ko\n");
    var opts: std.ArrayList(ModOption) = .empty;
    parseOptions("# a comment\noptions iwlwifi power_save=0 uapsd_disable=3\noptions iwlmvm power_scheme=1\n" ++
        "install sctp /bin/false\noptions iTCO-wdt \\\n\tnowayout=1\noptions cfg80211 ieee80211_regdom=\"SI\"\n", "/etc/modprobe.d/vh.conf", &opts);
    try testing.expectEqual(@as(usize, 5), opts.items.len);
    try testing.expectEqualStrings("iTCO_wdt", opts.items[3].module);
    try testing.expectEqualStrings("nowayout=1", opts.items[3].arg);
    const stock_line = "rd.luks.uuid=x root=UUID=y ro rd.shell=0 panic=10 lockdown=confidentiality module.sig_enforce=1 iommu.strict=1 page_alloc.shuffle=1 efi_pstore.pstore_disable=1 cfg80211.ieee80211_regdom=SI module_blacklist=sctp,mei_me ipv6.disable=1 quiet";
    const c = machineCmdline(stock_line, false, &builtin, &stock, opts.items);
    try testing.expectEqualStrings("rd.luks.uuid=x root=UUID=y ro rd.shell=0 panic=10 lockdown=confidentiality iommu.strict=1 page_alloc.shuffle=1 cfg80211.ieee80211_regdom=SI ipv6.disable=1 quiet " ++
        "iwlwifi.power_save=0 iwlwifi.uapsd_disable=3 iTCO_wdt.nowayout=1 cfg80211.ieee80211_regdom=\"SI\"", c.text);
    try testing.expectEqual(@as(usize, 3), c.removed.len);
    try testing.expectEqualStrings("module.sig_enforce=1", c.removed[0].word);
    try testing.expectEqualStrings("efi_pstore is not in this kernel", c.removed[1].why);
    try testing.expectEqualStrings("module_blacklist=sctp,mei_me", c.removed[2].word);
    try testing.expectEqual(@as(usize, 1), c.stayed.len);
    try testing.expect(mem.indexOf(u8, c.stayed[0].why, "iwlmvm is not built into this kernel") != null);
    // with loadable modules (the game feature), the refusals of the stock kernel stay
    const g = machineCmdline(stock_line, true, &builtin, &stock, &.{});
    try testing.expect(mem.indexOf(u8, g.text, "module.sig_enforce=1") != null and mem.indexOf(u8, g.text, "module_blacklist=sctp,mei_me") != null);
    // init's arguments stay last; a quoted value is one word
    const q = machineCmdline("root=x foo=\"a b\" -- single", false, &builtin, &stock, opts.items[0..1]);
    try testing.expectEqualStrings("root=x foo=\"a b\" iwlwifi.power_save=0 -- single", q.text);
    try testing.expectEqual(@as(usize, 3), splitArgs("  a=\"x y\"  b\tc ").len);
    try testing.expect(cmdlineProblem("ok text") == null);
    try testing.expect(cmdlineProblem("bad\x01") != null);
}

test "install: dracut's compressor and the final .config" {
    try testing.expectEqualStrings("zstd", compressOf("hostonly=\"yes\"\ncompress=\"zstd\"\n").?);
    try testing.expectEqualStrings("lz4", compressOf("compress=\"/usr/bin/lz4 -l\"\ncompress='lz4'\n").?);
    try testing.expect(compressOf("# nothing\n") == null);
    try testing.expectEqualStrings("lz4", compressOption(&.{ "-q", "--lz4" }).?);
    try testing.expectEqualStrings("xz", compressOption(&.{ "--compress", "/usr/bin/xz -9" }).?);
    try testing.expectEqualStrings("cat", compressOption(&.{ "--zstd", "--no-compress" }).?);
    try testing.expect(compressOption(&.{"--hostonly"}) == null);
    try testing.expectEqualStrings("RD_LZ4", rdSymbol("lz4").?);
    try testing.expectEqualStrings("", rdSymbol("cat").?);
    try testing.expect(rdSymbol("brotli") == null);
    var cfg: kconfig.DotConfig = .{};
    cfg.parse("CONFIG_EFI_STUB=y\nCONFIG_BLK_DEV_INITRD=y\nCONFIG_RD_ZSTD=y\nCONFIG_FW_LOADER=y\nCONFIG_FW_LOADER_COMPRESS_ZSTD=y\nCONFIG_MICROCODE=y\n# CONFIG_MODULES is not set\n");
    var problems: vh.Strv = .{};
    var notes: vh.Strv = .{};
    checkConfig(&cfg, "zstd", &.{ "a/b.bin.zst", "regulatory.db" }, "x86_64", &problems, &notes);
    try testing.expectEqual(@as(usize, 0), problems.len());
    try testing.expectEqual(@as(usize, 0), notes.len());
    checkConfig(&cfg, "lz4", &.{"a/b.bin.xz"}, "x86_64", &problems, &notes);
    try testing.expectEqual(@as(usize, 2), problems.len());
    try testing.expect(mem.indexOf(u8, problems.slice()[0], "CONFIG_RD_LZ4 is not set") != null);
    try testing.expect(mem.indexOf(u8, problems.slice()[1], "CONFIG_FW_LOADER_COMPRESS_XZ") != null);
    // the microcode is x86's: on arm64 a kernel without CONFIG_MICROCODE gets no note
    var arm: kconfig.DotConfig = .{};
    arm.parse("CONFIG_EFI_STUB=y\nCONFIG_BLK_DEV_INITRD=y\nCONFIG_RD_ZSTD=y\nCONFIG_FW_LOADER=y\n# CONFIG_MODULES is not set\n");
    var p2: vh.Strv = .{};
    var n2: vh.Strv = .{};
    checkConfig(&arm, "zstd", &.{}, "aarch64", &p2, &n2);
    try testing.expectEqual(@as(usize, 0), p2.len());
    try testing.expectEqual(@as(usize, 0), n2.len());
    checkConfig(&arm, "zstd", &.{}, "x86_64", &p2, &n2);
    try testing.expectEqual(@as(usize, 1), n2.len());
    try testing.expectEqualStrings("bzImage", kernelImage("x86_64"));
    try testing.expectEqualStrings("Image", kernelImage("aarch64"));
}

test "install: the firmware of the initrd" {
    const items = [_]FwItem{
        .{ .value = "i915/kbl_*", .rules = &.{"gpu.i915.cml"} },
        .{ .value = "intel-ucode/*", .rules = &.{"cpu.intel.microcode"} },
        .{ .value = "iwlwifi-Qu*", .rules = &.{"net.iwlwifi.qu"} },
        .{ .value = "regulatory.db*", .rules = &.{"net.wifi"} },
    };
    var pats: vh.Strv = .{};
    var left: vh.Strv = .{};
    initrdPatterns(&items, &pats, &left);
    initrdPatterns(items[0..1], &pats, &left); // the installation's plan: the same pattern once
    try testing.expectEqual(@as(usize, 3), pats.len());
    try testing.expectEqualStrings("intel-ucode/*", left.slice()[0]);
    const files = [_][]const u8{ "i915/kbl_dmc_ver1_04.bin.zst", "i915/tgl_dmc.bin.zst", "intel-ucode/06-a5-02", "iwlwifi-QuZ-a0-hr-b0-77.ucode.zst", "regulatory.db", "regulatory.db.p7s", "brcm/a b.txt" };
    const sel = selectFirmware(&files, pats.slice(), &.{"brcm/a b.txt"});
    try testing.expectEqual(@as(usize, 5), sel.len);
    try testing.expectEqualStrings("brcm/a b.txt", sel[4]);
    try testing.expectEqualStrings("iwlwifi-QuZ-a0-hr-b0-*", namedPattern("iwlwifi-QuZ-a0-hr-b0-77.ucode"));
    try testing.expectEqualStrings("i915/kbl_dmc_ver1_04.bin*", namedPattern("i915/kbl_dmc_ver1_04.bin"));
    const table = "# x\ni915 i915/kbl_dmc_ver1_04.bin\ni915 i915/tgl_dmc.bin\niwlwifi iwlwifi-QuZ-a0-hr-b0-77.ucode\nr8169 rtl_nic/rtl8168h-2.fw\n";
    const gaps = firmwareGaps(table, &.{ "i915", "iwlwifi", "r8169", "xfs" }, sel);
    try testing.expectEqual(@as(usize, 1), gaps.len);
    try testing.expect(vh.startsWith(gaps[0], "r8169 (1 file(s)"));
}

test "install: the number of an install and the stock UKIs" {
    try testing.expectEqual(@as(?u32, 2), installNumber("linux-6.18.57-vh_2.efi", "6.18.57-vh"));
    try testing.expect(installNumber("linux-6.18.57_1.efi", "6.18.57-vh") == null);
    try testing.expect(installNumber("linux-6.18.57-vh_.efi", "6.18.57-vh") == null);
    try testing.expectEqual(@as(u32, 1), nextNumber("6.18.57-vh", &.{"linux-6.18.57_1.efi"}, &.{}, ""));
    try testing.expectEqual(@as(u32, 3), nextNumber("6.18.57-vh", &.{ "linux-6.18.57-vh_2.efi", "linux-6.18.58-vh_5.efi" }, &.{"6.18.57-vh_1"}, ""));
    try testing.expectEqual(@as(u32, 5), nextNumber("6.18.57-vh", &.{}, &.{"6.18.57-vh_2"}, "DEFAULT=linux-6.18.57-vh_4.efi\nTRIAL=\n"));
    const s = stockUkis(&.{ "linux-6.18.9_1.efi", "linux-6.18.57-vh_1.efi", "linux-6.18.10_2.efi", "linux-6.18.10_1.efi", "other.efi" });
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqualStrings("linux-6.18.10_2.efi", s[0]);
    try testing.expectEqualStrings("linux-6.18.9_1.efi", s[2]);
}

/// a system and a run for the end-to-end test, under DIR: ROOT (with fakes of dracut and
/// vh-limine-update that record their arguments) and RUN (a run's files with SHA256SUMS)
const Fixture = struct {
    root: []const u8,
    run: []const u8,
    /// the run's kernel image: the bzImage, or the arm64 Image
    kernel: []const u8,
    want_cmdline: []const u8,

    fn put(path: []const u8, data: []const u8) void {
        vh.mkdirs(probe.dirname(path), 0o755);
        vh.writeAtomic(path, data, 0o644);
    }

    fn exe(path: []const u8, script: []const u8) void {
        vh.mkdirs(probe.dirname(path), 0o755);
        vh.writeAtomic(path, script, 0o755);
    }

    /// a file of the run replaced, with its line of SHA256SUMS
    fn replace(run_dir: []const u8, name: []const u8, data: []const u8) void {
        put(vh.fmt("{s}/{s}", .{ run_dir, name }), data);
        const sums_path = vh.fmt("{s}/SHA256SUMS", .{run_dir});
        const sums = vh.readFile(sums_path) catch vh.die("{s}: {s}", .{ sums_path, vh.serr() });
        var out: std.ArrayList(u8) = .empty;
        var lines = mem.tokenizeScalar(u8, sums, '\n');
        while (lines.next()) |l| {
            if (vh.endsWith(l, vh.fmt("  {s}", .{name}))) out.print(vh.gpa, "{s}  {s}\n", .{ sha256Hex(data), name }) catch vh.oom() else out.print(vh.gpa, "{s}\n", .{l}) catch vh.oom();
        }
        put(sums_path, out.items);
    }

    /// the fakes of dracut (records its arguments, writes the UKI it would build: expected.efi)
    /// and of vh-limine-update (records its arguments, exits VH_TEST_LIMINE_RC)
    fn fakes(dir: []const u8, root: []const u8) void {
        exe(vh.fmt("{s}/usr/bin/dracut", .{root}), vh.fmt("#!/bin/sh\nprintf '%s\\n' \"$@\" > {s}/dracut.args\nfor a; do out=$a; done\ncp {s}/expected.efi \"$out\"\n", .{ dir, dir }));
        exe(vh.fmt("{s}/usr/local/sbin/vh-limine-update", .{root}), vh.fmt("#!/bin/sh\necho \"$@\" > {s}/limine.args\nexit ${{VH_TEST_LIMINE_RC:-0}}\n", .{dir}));
    }

    /// the aarch64 rig (kernel/hw/qemu-virt.zon, its tiered plan: no firmware pattern, no
    /// cfg80211) and a run's arm64 Image: nvme, virtio_net and tpm_tis built in, the stock
    /// kernel's efi_pstore not, modprobe.d options of two built-in modules
    fn makeArm64(dir: []const u8) ?Fixture {
        const hwf = probe.repoPath("kernel/hw/qemu-virt.zon") orelse return null;
        const plan = probe.repoPath("tests/adapt/golden/qemu-virt/tiered/plan.zon") orelse return null;
        const hw_text = vh.readFile(hwf) catch return null;
        const plan_text = vh.readFile(plan) catch return null;
        const root = vh.fmt("{s}/root", .{dir});
        const run_dir = vh.fmt("{s}/run", .{dir});
        put(vh.fmt("{s}/etc/vh/hw.zon", .{root}), hw_text);
        put(vh.fmt("{s}/etc/vh/plan.zon", .{root}), plan_text);
        const stock_cmdline = "rd.luks.uuid=L root=UUID=R rootfstype=xfs ro rd.shell=0 rd.emergency=poweroff panic=10 lockdown=confidentiality module.sig_enforce=1 " ++
            "iommu.strict=1 efi_pstore.pstore_disable=1 module_blacklist=sctp,uvcvideo console=tty0 console=ttyAMA0,115200";
        put(vh.fmt("{s}/boot/efi/EFI/void/linux-6.18.59_1.efi", .{root}), uki.testPe(&.{ .{ ".cmdline", " " ++ stock_cmdline ++ " \x00" }, .{ ".linux", "stock" } }));
        put(vh.fmt("{s}/etc/default/dracut-uefi-hook", .{root}), "KERNEL_CMDLINE=\"" ++ stock_cmdline ++ "\"\n");
        put(vh.fmt("{s}/usr/lib/modules/6.18.59_1/modules.dep", .{root}), "kernel/drivers/nvme/host/nvme.ko.zst: kernel/drivers/nvme/host/nvme-core.ko.zst\nkernel/drivers/nvme/host/nvme-core.ko.zst:\n" ++
            "kernel/drivers/net/virtio_net.ko.zst:\nkernel/drivers/char/tpm/tpm_tis.ko.zst:\n");
        put(vh.fmt("{s}/usr/lib/modules/6.18.59_1/modules.builtin", .{root}), "kernel/drivers/firmware/efi/efi-pstore.ko\n");
        put(vh.fmt("{s}/etc/modprobe.d/vh-nvme.conf", .{root}), "options nvme_core default_ps_max_latency_us=0\noptions tpm_tis interrupts=0\n");
        put(vh.fmt("{s}/etc/dracut.conf.d/10-vh.conf", .{root}), "hostonly=\"yes\"\ncompress=\"zstd\"\nearly_microcode=\"yes\"\n");
        for ([_][]const u8{ "regulatory.db", "regulatory.db.p7s", "intel/ibt-19-0-4.sfi.zst" }) |f|
            put(vh.fmt("{s}/usr/lib/firmware/{s}", .{ root, f }), f);
        const kernel = uki.testImage("6.18.59-vh", "the machine kernel");
        const files = [_][2][]const u8{
            .{ "BUILD", vh.fmt("kernel-custom qemu-virt: linux-6.18.59, features auto, commit 0123abc, run 7\nhw.zon: kernel/hw/qemu-virt.zon sha256 {s}\n" ++
                "KBUILD_BUILD_TIMESTAMP=2026-10-28T00:00:00+00:00 KCFLAGS=-march=armv8-a LLVM=1 clang version 18\n" ++
                "Linux version 6.18.59-vh (vh@ci) (clang version 18.1.3) #1 SMP PREEMPT_DYNAMIC Tue Oct 28 00:00:00 UTC 2026\n", .{sha256Hex(hw_text)}) },
            .{ "Image-vh-6.18.59", kernel },
            .{ "config-vh-6.18.59", "CONFIG_LOCALVERSION=\"-vh\"\n# CONFIG_MODULES is not set\nCONFIG_EFI_STUB=y\nCONFIG_BLK_DEV_INITRD=y\nCONFIG_RD_ZSTD=y\nCONFIG_FW_LOADER=y\nCONFIG_FW_LOADER_COMPRESS=y\nCONFIG_FW_LOADER_COMPRESS_ZSTD=y\nCONFIG_ARM64_4K_PAGES=y\n" },
            .{ "modules.builtin-vh-6.18.59", "kernel/drivers/nvme/host/nvme.ko\nkernel/drivers/nvme/host/nvme-core.ko\nkernel/drivers/net/virtio_net.ko\nkernel/drivers/char/tpm/tpm_tis.ko\n" },
            .{ "modules.builtin.modinfo-vh-6.18.59", "nvme_core.parmtype=default_ps_max_latency_us:ulong\x00tpm_tis.parmtype=interrupts:bool\x00" },
            .{ "lsmod", "nvme\nvirtio_net\ntpm_tis\n" },
            .{ "resolve-report.txt", "vh-kconf resolve report\n\nDrivers already built into the stock kernel (1): xhci_pci\n" },
            .{ "plan.zon", plan_text },
            .{ "qemu-virt.zon", hw_text },
        };
        var sums: std.ArrayList(u8) = .empty;
        for (files) |f| {
            put(vh.fmt("{s}/{s}", .{ run_dir, f[0] }), f[1]);
            sums.print(vh.gpa, "{s}  {s}\n", .{ sha256Hex(f[1]), f[0] }) catch vh.oom();
        }
        put(vh.fmt("{s}/SHA256SUMS", .{run_dir}), sums.items);
        const want = "rd.luks.uuid=L root=UUID=R rootfstype=xfs ro rd.shell=0 rd.emergency=poweroff panic=10 lockdown=confidentiality iommu.strict=1 " ++
            "console=tty0 console=ttyAMA0,115200 nvme_core.default_ps_max_latency_us=0 tpm_tis.interrupts=0";
        // the UKI dracut would build on aarch64: no early cpio (the microcode is x86's)
        put(vh.fmt("{s}/expected.efi", .{dir}), uki.testPe(&.{
            .{ ".cmdline", vh.fmt(" {s} \x00", .{want}) },
            .{ ".linux", kernel },
            .{ ".initrd", "\x28\xb5\x2f\xfdmain" },
        }));
        fakes(dir, root);
        return .{ .root = root, .run = run_dir, .kernel = kernel, .want_cmdline = want };
    }

    fn make(dir: []const u8) ?Fixture {
        return makeKind(dir, false);
    }

    /// GAME: the run is the gaming kernel's (vh-game kernel build): A.B.C-vh-game, loadable
    /// modules and ia32
    fn makeKind(dir: []const u8, game: bool) ?Fixture {
        const gf63 = probe.repoPath("kernel/hw/gf63.zon") orelse return null;
        const plan = probe.repoPath("tests/adapt/golden/gf63/strict/plan.zon") orelse return null;
        const hw_text = vh.readFile(gf63) catch return null;
        const plan_text = vh.readFile(plan) catch return null;
        const root = vh.fmt("{s}/root", .{dir});
        const run_dir = vh.fmt("{s}/run", .{dir});
        // the system: its probe and plan, the stock UKI, the stock kernel's modules, modprobe.d,
        // dracut's configuration, the firmware the trim left
        put(vh.fmt("{s}/etc/vh/hw.zon", .{root}), hw_text);
        put(vh.fmt("{s}/etc/vh/plan.zon", .{root}), plan_text);
        const stock_cmdline = "rd.luks.uuid=L root=UUID=R rootfstype=xfs ro rd.shell=0 rd.emergency=poweroff panic=10 lockdown=confidentiality module.sig_enforce=1 " ++
            "iommu.strict=1 efi_pstore.pstore_disable=1 cfg80211.ieee80211_regdom=SI module_blacklist=sctp,nouveau intel_iommu=on";
        put(vh.fmt("{s}/boot/efi/EFI/void/linux-6.18.57_1.efi", .{root}), uki.testPe(&.{ .{ ".cmdline", " " ++ stock_cmdline ++ " \x00" }, .{ ".linux", "stock" } }));
        put(vh.fmt("{s}/boot/efi/EFI/void/linux-6.18.56_1.efi", .{root}), uki.testPe(&.{.{ ".cmdline", " old \x00" }}));
        put(vh.fmt("{s}/etc/default/dracut-uefi-hook", .{root}), "KERNEL_CMDLINE=\"" ++ stock_cmdline ++ "\"\n");
        put(vh.fmt("{s}/usr/lib/modules/6.18.57_1/modules.dep", .{root}), "kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko.zst: kernel/net/wireless/cfg80211.ko.zst\n" ++
            "kernel/drivers/net/wireless/intel/iwlwifi/mvm/iwlmvm.ko.zst: kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko.zst\nkernel/net/wireless/cfg80211.ko.zst:\nkernel/drivers/watchdog/iTCO_wdt.ko.zst:\n");
        put(vh.fmt("{s}/usr/lib/modules/6.18.57_1/modules.builtin", .{root}), "kernel/drivers/firmware/efi/efi-pstore.ko\n");
        put(vh.fmt("{s}/etc/modprobe.d/vh-iwlwifi.conf", .{root}), "options iwlwifi power_save=0 uapsd_disable=3\noptions iwlmvm power_scheme=1\n");
        put(vh.fmt("{s}/etc/modprobe.d/vh-watchdog.conf", .{root}), "options iTCO_wdt nowayout=1\n");
        put(vh.fmt("{s}/usr/lib/modprobe.d/vh-watchdog.conf", .{root}), "options iTCO_wdt nowayout=0\n"); // /etc wins for the name
        put(vh.fmt("{s}/etc/dracut.conf.d/10-vh.conf", .{root}), "hostonly=\"yes\"\ncompress=\"zstd\"\nearly_microcode=\"yes\"\n");
        for ([_][]const u8{ "i915/kbl_dmc_ver1_04.bin.zst", "i915/cml_guc_70.1.1.bin.zst", "iwlwifi-QuZ-a0-hr-b0-77.ucode.zst", "intel/ibt-19-0-4.sfi.zst", "rtl_nic/rtl8168h-2.fw.zst", "regulatory.db", "regulatory.db.p7s", "intel-ucode/06-a5-02", "nvidia/tu117/gsp.bin.zst" }) |f|
            put(vh.fmt("{s}/usr/lib/firmware/{s}", .{ root, f }), f);
        // the run: the machine kernel and what the workflow uploads with it
        const bz = if (game) uki.testBzImage("6.18.57-vh-game", "the gaming kernel") else uki.testBzImage("6.18.57-vh", "the machine kernel");
        const common_config = "CONFIG_EFI_STUB=y\nCONFIG_BLK_DEV_INITRD=y\nCONFIG_RD_ZSTD=y\nCONFIG_FW_LOADER=y\nCONFIG_FW_LOADER_COMPRESS=y\nCONFIG_FW_LOADER_COMPRESS_ZSTD=y\nCONFIG_MICROCODE=y\nCONFIG_CFG80211=y\n";
        const files = [_][2][]const u8{
            .{ "BUILD", if (game)
                vh.fmt("kernel-custom local: linux-6.18.57, features auto,game, commit vh-game, run 1\nhw.zon: gf63.zon sha256 {s}\n", .{sha256Hex(hw_text)})
            else
                vh.fmt("kernel-custom gf63: linux-6.18.57, features usb-common,bluetooth, commit 0123abc, run 12\nhw.zon: kernel/hw/gf63.zon sha256 {s}\n", .{sha256Hex(hw_text)}) },
            .{ "bzImage-vh-6.18.57", bz },
            .{ "config-vh-6.18.57", if (game)
                "CONFIG_LOCALVERSION=\"-vh-game\"\nCONFIG_MODULES=y\nCONFIG_MODULE_SIG_FORCE=y\nCONFIG_IA32_EMULATION=y\n" ++ common_config
            else
                "CONFIG_LOCALVERSION=\"-vh\"\n# CONFIG_MODULES is not set\n" ++ common_config },
            .{ "modules.builtin-vh-6.18.57", "kernel/net/wireless/cfg80211.ko\nkernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko\nkernel/drivers/net/wireless/intel/iwlwifi/mvm/iwlmvm.ko\nkernel/drivers/watchdog/iTCO_wdt.ko\n" },
            .{ "modules.builtin.modinfo-vh-6.18.57", "iwlwifi.parmtype=power_save:bool\x00iTCO_wdt.parmtype=nowayout:bool\x00" },
            .{ "lsmod", "iwlmvm\niwlwifi\nr8169\n" },
            .{ "resolve-report.txt", "vh-kconf resolve report\n\nDrivers already built into the stock kernel (2): nvme i8042\n" },
            .{ "plan.zon", plan_text },
            .{ "gf63.zon", hw_text },
        };
        var sums: std.ArrayList(u8) = .empty;
        for (files) |f| {
            put(vh.fmt("{s}/{s}", .{ run_dir, f[0] }), f[1]);
            sums.print(vh.gpa, "{s}  {s}\n", .{ sha256Hex(f[1]), f[0] }) catch vh.oom();
        }
        put(vh.fmt("{s}/SHA256SUMS", .{run_dir}), sums.items);
        // the gaming kernel keeps the module parameters (it has loadable modules) and turns ia32 on
        const want = if (game)
            "rd.luks.uuid=L root=UUID=R rootfstype=xfs ro rd.shell=0 rd.emergency=poweroff panic=10 lockdown=confidentiality module.sig_enforce=1 iommu.strict=1 " ++
                "cfg80211.ieee80211_regdom=SI module_blacklist=sctp,nouveau intel_iommu=on iwlwifi.power_save=0 iwlwifi.uapsd_disable=3 iwlmvm.power_scheme=1 iTCO_wdt.nowayout=1 ia32_emulation=1"
        else
            "rd.luks.uuid=L root=UUID=R rootfstype=xfs ro rd.shell=0 rd.emergency=poweroff panic=10 lockdown=confidentiality iommu.strict=1 " ++
                "cfg80211.ieee80211_regdom=SI intel_iommu=on iwlwifi.power_save=0 iwlwifi.uapsd_disable=3 iwlmvm.power_scheme=1 iTCO_wdt.nowayout=1";
        // dracut: records its arguments and writes the UKI it would build
        put(vh.fmt("{s}/expected.efi", .{dir}), uki.testPe(&.{
            .{ ".cmdline", vh.fmt(" {s} \x00", .{want}) },
            .{ ".linux", bz },
            .{ ".initrd", vh.fmt("{s}\x28\xb5\x2f\xfdmain", .{uki.testCpio(&.{ "kernel", "kernel/x86", "kernel/x86/microcode", "kernel/x86/microcode/CPU.bin" })}) },
        }));
        fakes(dir, root);
        return .{ .root = root, .run = run_dir, .kernel = bz, .want_cmdline = want };
    }
};

test "install: a run's machine kernel becomes a machine UKI on trial" {
    const dir = vh.fmt("/tmp/vh-kconf-install-{d}", .{linux.getpid()});
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    defer _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    const f = Fixture.make(dir) orelse return error.SkipZigTest;
    const repo = probe.repoRoot() orelse return error.SkipZigTest;
    var d: Diag = .{};

    // a dry run: verified and planned, nothing written
    try testing.expectEqual(@as(u8, 0), try install(.{ .dir = f.run, .root = f.root, .repo = repo, .dry_run = true }, &d));
    try testing.expect(!vh.pathExists(vh.fmt("{s}/dracut.args", .{dir})));

    try testing.expectEqual(@as(u8, 0), try install(.{ .dir = f.run, .root = f.root, .repo = repo }, &d));
    const args = try vh.readFile(vh.fmt("{s}/dracut.args", .{dir}));
    for ([_][]const u8{ "--no-kernel\n", "--kver\n6.18.57-vh\n", vh.fmt("--kernel-image\n{s}/bzImage-vh-6.18.57\n", .{f.run}), "--uefi\n", vh.fmt("--kernel-cmdline={s}\n", .{f.want_cmdline}) }) |want|
        try testing.expect(mem.indexOf(u8, args, want) != null);
    // the firmware of the plan's patterns, regulatory.db; not the microcode, not what the plan leaves out
    for ([_][]const u8{ "i915/kbl_dmc_ver1_04.bin.zst", "i915/cml_guc_70.1.1.bin.zst", "iwlwifi-QuZ-a0-hr-b0-77.ucode.zst", "intel/ibt-19-0-4.sfi.zst", "rtl_nic/rtl8168h-2.fw.zst", "regulatory.db", "regulatory.db.p7s" }) |fw|
        try testing.expect(mem.indexOf(u8, args, vh.fmt("--include\n{s}/usr/lib/firmware/{s}\n/usr/lib/firmware/{s}\n", .{ f.root, fw, fw })) != null);
    try testing.expect(mem.indexOf(u8, args, "intel-ucode") == null and mem.indexOf(u8, args, "nvidia") == null);
    const esp = vh.fmt("{s}/boot/efi/EFI/void", .{f.root});
    try testing.expect(vh.pathExists(vh.fmt("{s}/linux-6.18.57-vh_1.efi", .{esp})));
    try testing.expectEqualStrings("--new 6.18.57-vh_1\n", try vh.readFile(vh.fmt("{s}/limine.args", .{dir})));
    const rec = vh.fmt("{s}/var/lib/vh/kernels/6.18.57-vh_1", .{f.root});
    try testing.expectEqualStrings(vh.fmt("{s}\n", .{f.want_cmdline}), try vh.readFile(vh.fmt("{s}/cmdline", .{rec})));
    try testing.expect(mem.indexOf(u8, try vh.readFile(vh.fmt("{s}/report.txt", .{rec})), "commit 0123abc") != null);

    // the second install of the same release is _2
    try testing.expectEqual(@as(u8, 0), try install(.{ .dir = f.run, .root = f.root, .repo = repo }, &d));
    try testing.expect(vh.pathExists(vh.fmt("{s}/linux-6.18.57-vh_2.efi", .{esp})));
    // vh-init wanted as PID 1 (its marker): the machine UKI's command line ends in init= (the
    // fake dracut writes the UKI it would build: one with that line)
    Fixture.put(vh.fmt("{s}{s}", .{ f.root, init_mark }), "# vh-init --install\n");
    Fixture.put(vh.fmt("{s}/expected.efi", .{dir}), uki.testPe(&.{
        .{ ".cmdline", vh.fmt(" {s} {s} \x00", .{ f.want_cmdline, init_param }) },
        .{ ".linux", f.kernel },
        .{ ".initrd", vh.fmt("{s}\x28\xb5\x2f\xfdmain", .{uki.testCpio(&.{ "kernel", "kernel/x86", "kernel/x86/microcode", "kernel/x86/microcode/CPU.bin" })}) },
    }));
    try testing.expectEqual(@as(u8, 0), try install(.{ .dir = f.run, .root = f.root, .repo = repo }, &d));
    const args3 = try vh.readFile(vh.fmt("{s}/dracut.args", .{dir}));
    try testing.expect(mem.indexOf(u8, args3, vh.fmt("--kernel-cmdline={s} {s}\n", .{ f.want_cmdline, init_param })) != null);
    try testing.expect(mem.indexOf(u8, try vh.readFile(vh.fmt("{s}/var/lib/vh/kernels/6.18.57-vh_3/report.txt", .{f.root})), "+ init=/usr/local/sbin/vh-init: vh-init is wanted") != null);
    vh.unlink(vh.fmt("{s}{s}", .{ f.root, init_mark })) catch {};
    Fixture.put(vh.fmt("{s}/expected.efi", .{dir}), uki.testPe(&.{
        .{ ".cmdline", vh.fmt(" {s} \x00", .{f.want_cmdline}) },
        .{ ".linux", f.kernel },
        .{ ".initrd", vh.fmt("{s}\x28\xb5\x2f\xfdmain", .{uki.testCpio(&.{ "kernel", "kernel/x86", "kernel/x86/microcode", "kernel/x86/microcode/CPU.bin" })}) },
    }));
    try testing.expectEqualStrings("a b init=/usr/local/sbin/vh-init -- c", withInit(.{ .text = "a init=/old b -- c" }).text);
    try testing.expectEqualStrings("root=x ro init=/usr/local/sbin/vh-init", withInit(.{ .text = "root=x ro" }).text);
    // vh-limine-update fails before writing limine.conf: the UKI is removed again
    vh.setenv("VH_TEST_LIMINE_RC", "1");
    try testing.expectError(error.Refused, install(.{ .dir = f.run, .root = f.root, .repo = repo }, &d));
    vh.setenv("VH_TEST_LIMINE_RC", "0");
    try testing.expect(mem.indexOf(u8, d.msg, "the UKI was removed") != null);
    try testing.expect(!vh.pathExists(vh.fmt("{s}/linux-6.18.57-vh_4.efi", .{esp})));
}

test "install: the gaming kernel becomes the gaming entry, with ia32 on" {
    const dir = vh.fmt("/tmp/vh-kconf-install-game-{d}", .{linux.getpid()});
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    defer _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    const f = Fixture.makeKind(dir, true) orelse return error.SkipZigTest;
    const repo = probe.repoRoot() orelse return error.SkipZigTest;
    var d: Diag = .{};
    // the gaming boot off: refused, nothing written
    try testing.expectError(error.Refused, install(.{ .dir = f.run, .root = f.root, .repo = repo }, &d));
    try testing.expect(mem.indexOf(u8, d.msg, "the gaming boot is off") != null);
    try testing.expect(!vh.pathExists(vh.fmt("{s}/dracut.args", .{dir})));
    Fixture.put(vh.fmt("{s}{s}", .{ f.root, game_mark }), "#!/usr/local/sbin/vh-game stage2\n");

    try testing.expectEqual(@as(u8, 0), try install(.{ .dir = f.run, .root = f.root, .repo = repo }, &d));
    const args = try vh.readFile(vh.fmt("{s}/dracut.args", .{dir}));
    for ([_][]const u8{ "--no-kernel\n", "--kver\n6.18.57-vh-game\n", vh.fmt("--kernel-cmdline={s}\n", .{f.want_cmdline}) }) |want|
        try testing.expect(mem.indexOf(u8, args, want) != null);
    // into the gaming series, beside nothing of the machine series; vh-limine-update makes the entry
    const game_dir = vh.fmt("{s}/boot/efi/EFI/vh-game", .{f.root});
    try testing.expect(vh.pathExists(vh.fmt("{s}/linux-6.18.57-vh-game_1.efi", .{game_dir})));
    try testing.expect(!vh.pathExists(vh.fmt("{s}/boot/efi/EFI/void/linux-6.18.57-vh-game_1.efi", .{f.root})));
    try testing.expectEqualStrings("\n", try vh.readFile(vh.fmt("{s}/limine.args", .{dir})));
    try testing.expectEqual(@as(u8, 0), try install(.{ .dir = f.run, .root = f.root, .repo = repo }, &d));
    try testing.expect(vh.pathExists(vh.fmt("{s}/linux-6.18.57-vh-game_2.efi", .{game_dir})));
    // the release names the gaming kernel, the configuration must too
    try testing.expectEqualStrings("a ia32_emulation=1 b -- c", gameCmdline("a ia32_emulation=0 b ia32_emulation=0 -- c"));
    try testing.expectEqualStrings("root=x ro ia32_emulation=1", gameCmdline("root=x ro"));
}

test "install: an arm64 Image of a run becomes the machine UKI" {
    const dir = vh.fmt("/tmp/vh-kconf-install-arm64-{d}", .{linux.getpid()});
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    defer _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    const f = Fixture.makeArm64(dir) orelse return error.SkipZigTest;
    const repo = probe.repoRoot() orelse return error.SkipZigTest;
    var d: Diag = .{};
    try testing.expectEqual(@as(u8, 0), try install(.{ .dir = f.run, .root = f.root, .repo = repo, .dry_run = true }, &d));
    try testing.expect(!vh.pathExists(vh.fmt("{s}/dracut.args", .{dir})));
    try testing.expectEqual(@as(u8, 0), try install(.{ .dir = f.run, .root = f.root, .repo = repo }, &d));
    const args = try vh.readFile(vh.fmt("{s}/dracut.args", .{dir}));
    for ([_][]const u8{ "--no-kernel\n", "--kver\n6.18.59-vh\n", vh.fmt("--kernel-image\n{s}/Image-vh-6.18.59\n", .{f.run}), "--uefi\n", vh.fmt("--kernel-cmdline={s}\n", .{f.want_cmdline}) }) |want|
        try testing.expect(mem.indexOf(u8, args, want) != null);
    // the plan names no firmware and cfg80211 is not built in: nothing goes into the initrd
    try testing.expect(mem.indexOf(u8, args, "--include") == null);
    const esp = vh.fmt("{s}/boot/efi/EFI/void", .{f.root});
    try testing.expect(vh.pathExists(vh.fmt("{s}/linux-6.18.59-vh_1.efi", .{esp})));
    try testing.expectEqualStrings("--new 6.18.59-vh_1\n", try vh.readFile(vh.fmt("{s}/limine.args", .{dir})));
    const rep = try vh.readFile(vh.fmt("{s}/var/lib/vh/kernels/6.18.59-vh_1/report.txt", .{f.root}));
    try testing.expect(mem.indexOf(u8, rep, "kernel: 6.18.59-vh (Image-vh-6.18.59, sha256 ") != null);
    try testing.expect(mem.indexOf(u8, rep, "arm64 Image: ") != null and mem.indexOf(u8, rep, "4 KiB pages, little-endian, loadable anywhere: yes, EFI stub: yes") != null);
    try testing.expect(mem.indexOf(u8, rep, "firmware for the initrd: 0 file(s)") != null);
    // no note about the microcode on arm64; the stock kernel's module parameter went, the
    // built-in modules' options came
    try testing.expect(mem.indexOf(u8, rep, "CONFIG_MICROCODE") == null);
    try testing.expect(mem.indexOf(u8, rep, "- efi_pstore.pstore_disable=1: efi_pstore is not in this kernel") != null);
    try testing.expect(mem.indexOf(u8, rep, "+ tpm_tis.interrupts=0") != null);

    // what is refused on arm64, each on a run whose SHA256SUMS agrees with the file
    const o: Opts = .{ .dir = f.run, .root = f.root, .repo = repo, .dry_run = true };
    Fixture.replace(f.run, "Image-vh-6.18.59", uki.testBzImage("6.18.59-vh", "an x86 kernel"));
    try testing.expectError(error.Refused, install(o, &d));
    try testing.expect(mem.indexOf(u8, d.msg, "not an arm64 Image") != null);
    var no_stub = vh.dupe(f.kernel);
    no_stub[0] = 0;
    Fixture.replace(f.run, "Image-vh-6.18.59", no_stub);
    try testing.expectError(error.Refused, install(o, &d));
    try testing.expect(mem.indexOf(u8, d.msg, "CONFIG_EFI_STUB") != null);
    // a gaming kernel (the run's Image and BUILD's banner agree on it): x86_64's
    const build = try vh.readFile(vh.fmt("{s}/BUILD", .{f.run}));
    Fixture.replace(f.run, "Image-vh-6.18.59", uki.testImage("6.18.59-vh-game", "a gaming kernel"));
    Fixture.replace(f.run, "BUILD", mem.replaceOwned(u8, vh.gpa, build, "Linux version 6.18.59-vh ", "Linux version 6.18.59-vh-game ") catch vh.oom());
    try testing.expectError(error.Refused, install(o, &d));
    try testing.expect(mem.indexOf(u8, d.msg, "x86_64's") != null);
    Fixture.replace(f.run, "Image-vh-6.18.59", f.kernel);
    // BUILD's banner of another kernel than the Image
    Fixture.replace(f.run, "BUILD", mem.replaceOwned(u8, vh.gpa, build, "Linux version 6.18.59-vh ", "Linux version 6.18.59-vh+ ") catch vh.oom());
    try testing.expectError(error.Refused, install(o, &d));
    try testing.expect(mem.indexOf(u8, d.msg, "not the kernel of this run") != null);
    Fixture.replace(f.run, "BUILD", build);
    try testing.expectEqual(@as(u8, 0), try install(o, &d));
}

test "install: what is refused" {
    const dir = vh.fmt("/tmp/vh-kconf-refuse-{d}", .{linux.getpid()});
    _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    defer _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    const f = Fixture.make(dir) orelse return error.SkipZigTest;
    const repo = probe.repoRoot() orelse return error.SkipZigTest;
    var d: Diag = .{};
    const o: Opts = .{ .dir = f.run, .root = f.root, .repo = repo, .dry_run = true };
    // another probe of this machine
    const amd = probe.repoPath("kernel/hw/amd-desktop.zon") orelse return error.SkipZigTest;
    var o2 = o;
    o2.hw = amd;
    try testing.expectError(error.Refused, install(o2, &d));
    try testing.expect(mem.indexOf(u8, d.msg, "another machine than this one") != null);
    const mine = vh.fmt("{s}/etc/vh/hw.zon", .{f.root});
    const text = try vh.readFile(mine);
    vh.writeAtomic(vh.fmt("{s}/reprobed.zon", .{dir}), vh.fmt("{s}\n", .{text}), 0o644);
    o2.hw = vh.fmt("{s}/reprobed.zon", .{dir});
    try testing.expectError(error.Refused, install(o2, &d));
    try testing.expect(mem.indexOf(u8, d.msg, "another probe of this machine") != null);
    // a damaged file
    const bz = vh.fmt("{s}/bzImage-vh-6.18.57", .{f.run});
    vh.writeAtomic(bz, vh.fmt("{s}x", .{f.kernel}), 0o644);
    try testing.expectError(error.Refused, install(o, &d));
    try testing.expect(mem.indexOf(u8, d.msg, "a damaged or replaced file") != null);
    vh.writeAtomic(bz, f.kernel, 0o644);
    // a run of the workflow before vh-kconf install: no modules.builtin
    const sums_path = vh.fmt("{s}/SHA256SUMS", .{f.run});
    const sums = try vh.readFile(sums_path);
    var lines = mem.tokenizeScalar(u8, sums, '\n');
    var older: std.ArrayList(u8) = .empty;
    while (lines.next()) |l| if (mem.indexOf(u8, l, "modules.builtin-vh-") == null) older.print(vh.gpa, "{s}\n", .{l}) catch vh.oom();
    vh.writeAtomic(sums_path, older.items, 0o644);
    try testing.expectError(error.Refused, install(o, &d));
    try testing.expect(mem.indexOf(u8, d.msg, "older than vh-kconf install") != null);
    vh.writeAtomic(sums_path, sums, 0o644);
    // an initrd compression the kernel cannot unpack
    const conf = vh.fmt("{s}/etc/dracut.conf.d/10-vh.conf", .{f.root});
    vh.writeAtomic(conf, "compress=\"lz4\"\n", 0o644);
    try testing.expectError(error.Refused, install(o, &d));
    try testing.expect(mem.indexOf(u8, d.msg, "problem(s) above") != null);
    vh.writeAtomic(conf, "compress=\"zstd\"\n", 0o644);
    try testing.expectEqual(@as(u8, 0), try install(o, &d));
    // no stock UKI on the ESP
    _ = vh.runOpts(&.{ "rm", "-f", vh.fmt("{s}/boot/efi/EFI/void/linux-6.18.57_1.efi", .{f.root}), vh.fmt("{s}/boot/efi/EFI/void/linux-6.18.56_1.efi", .{f.root}) }, .{});
    try testing.expectError(error.Refused, install(o, &d));
    try testing.expect(mem.indexOf(u8, d.msg, "no stock UKI") != null);
}
