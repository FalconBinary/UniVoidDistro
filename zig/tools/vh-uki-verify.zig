//! vh-uki-verify: checks the UKI inputs before signing (optional/sb-offline-keys).
//!
//! A db key on offline media does not help if a root rootkit replaced what the UKI is built
//! from (dracut modules and configs, the cmdline, the kernel.d hooks): at the next update you
//! would sign its image yourself. So, before signing:
//!
//!   1. xbps-pkgdb: the files of the packages the UKI is built from match the xbps database;
//!   2. the hashes of files NOT from packages that influence the build match the reference on
//!      the key media (hidden files included; a symlink by its target);
//!   3. the .cmdline section of the new UKI matches the reference on the media byte for byte,
//!      .uname matches the version;
//!   4. the initramfs content (the .initrd section) is compared with the previously approved
//!      UKI: new, removed and changed files are shown, the admin confirms them by hand.
//!
//! The reference values live on the key media (REF), not on the root file system: a rootkit in
//! the running system cannot rewrite them without the media. Residual risk: a rootkit that
//! hijacked the check itself or sbctl bypasses it; only signing from the live USB closes that fully.
//!
//! PE, cpio and the compressed initramfs are untrusted data: every size is checked, and the
//! ReleaseSafe bounds checks apply on top.
//!
//!   vh-uki-verify UKI VERSION    -- check (called by vh-limine-update before signing)
//!   vh-uki-verify --init [UKI]   -- record the reference values from the current system (after a clean install)
const std = @import("std");
const vh = @import("vh");
const hash = @import("hash");
const linux = std.os.linux;
const mem = std.mem;

const REF = "/run/vh-keys/ref";

const pkgs = [_][]const u8{
    "dracut", "dracut-uefi", "systemd-boot-efistub", "cryptsetup", "intel-ucode",
    "linux-firmware-intel", "tpm2-tools", "tpm2-totp", "limine", "sbctl", "eudev", "kmod",
};
const inputs = [_][]const u8{
    "/etc/dracut.conf",              "/etc/dracut.conf.d",             "/etc/default/dracut-uefi-hook",
    "/etc/kernel.d",                 "/etc/vh/boot.conf",              "/etc/vh/vh.env",
    "/usr/local/sbin/vh-limine-update", "/usr/local/sbin/vh-uki-verify", "/usr/local/lib/dracut",
    "/etc/modprobe.d",
};

const usage_text =
    \\vh-uki-verify UKI VERSION    -- check (called by vh-limine-update before signing)
    \\vh-uki-verify --init [UKI]   -- record the reference values from the current system (after a clean install)
    \\
;

/// a "name -> value" list (a hash or a description)
const Ent = struct { name: []const u8, val: []const u8, seq: usize };

const List = struct {
    e: std.ArrayList(Ent) = .empty,

    fn add(l: *List, name_in: []const u8, val: []const u8) void {
        // the name goes into the reference file line by line: control characters become "?"
        const name = vh.dupe(name_in);
        for (name) |*ch| if (ch.* < 0x20 or ch.* == 0x7F) {
            ch.* = '?';
        };
        l.e.append(vh.gpa, .{ .name = name, .val = val, .seq = l.e.items.len }) catch vh.oom();
    }

    fn lt(_: void, x: Ent, y: Ent) bool {
        return switch (mem.order(u8, x.name, y.name)) {
            .lt => true,
            .gt => false,
            .eq => x.seq < y.seq,
        };
    }

    /// sort by name; of duplicates the last one stays (like a dictionary)
    fn finish(l: *List) void {
        mem.sort(Ent, l.e.items, {}, lt);
        var w: usize = 0;
        const it = l.e.items;
        for (it, 0..) |e, i| {
            if (i + 1 < it.len and vh.eql(e.name, it[i + 1].name)) continue;
            it[w] = e;
            w += 1;
        }
        l.e.items.len = w;
    }

    fn get(l: *const List, name: []const u8) ?[]const u8 {
        var lo: usize = 0;
        var hi = l.e.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            switch (mem.order(u8, l.e.items[mid].name, name)) {
                .eq => return l.e.items[mid].val,
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }
};

fn readList(path: []const u8, l: *List) void {
    if (vh.readFile(path)) |text| {
        var it = mem.tokenizeScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (mem.indexOf(u8, line, "  ")) |sep| l.add(line[sep + 2 ..], line[0..sep]) else l.add("", line);
        }
    } else |_| {}
    l.finish();
}

fn writeList(path: []const u8, l: *const List) void {
    var b: std.ArrayList(u8) = .empty;
    for (l.e.items) |e| b.print(vh.gpa, "{s}  {s}\n", .{ e.val, e.name }) catch vh.oom();
    vh.writeAtomic(path, b.items, 0o600);
}

// ---------------------------------------------------------------- the build inputs

fn addFile(l: *List, f: []const u8, mode: u32) void {
    if (vh.endsWith(f, ".vh-orig") or vh.endsWith(f, ".new")) return;
    if (vh.S.isLnk(mode)) {
        const t = vh.readlink(f) catch "";
        l.add(f, vh.fmt("-> {s}", .{t}));
    } else if (vh.S.isReg(mode)) {
        const h = hash.sha256File(f) catch vh.die("{s}: {s}", .{ f, vh.serr() });
        l.add(f, h);
    }
}

/// a walk like nftw(FTW_PHYS): symlinks are not followed, hidden files are included
fn walk(l: *List, dir: []const u8, depth: u32) void {
    if (depth > 64) return;
    const names = vh.listDir(dir) catch return;
    for (names) |n| {
        const p = vh.fmt("{s}/{s}", .{ dir, n });
        const st = vh.stat(p, false) catch continue;
        if (vh.S.isDir(st.mode)) walk(l, p, depth + 1) else addFile(l, p, st.mode);
    }
}

fn inputHashes(l: *List) void {
    for (inputs) |in| {
        const st = vh.stat(in, false) catch continue;
        if (vh.S.isDir(st.mode)) walk(l, in, 0) else addFile(l, in, st.mode);
    }
    l.finish();
}

// ---------------------------------------------------------------- PE and the initramfs

const Section = struct { name: []const u8, p: []const u8 };

fn le32(p: []const u8) u32 {
    return mem.readInt(u32, p[0..4], .little);
}
fn le16(p: []const u8) u16 {
    return mem.readInt(u16, p[0..2], .little);
}

/// the sections of a PE file without binutils; the data stays in memory until exit
pub fn peSections(path: []const u8, d: []const u8) []const Section {
    if (d.len < 0x40 or d[0] != 'M' or d[1] != 'Z') vh.die("{s}: not a PE file", .{path});
    const pe: usize = le32(d[0x3C..]);
    if (pe > d.len or d.len - pe < 24 or !mem.eql(u8, d[pe .. pe + 4], "PE\x00\x00")) vh.die("{s}: no PE signature", .{path});
    const nsec: usize = le16(d[pe + 6 ..]);
    const opt: usize = le16(d[pe + 20 ..]);
    const off = pe + 24 + opt;
    var out: std.ArrayList(Section) = .empty;
    for (0..@min(nsec, 96)) |i| {
        if (off + i * 40 + 40 > d.len) vh.die("{s}: section headers past the end of the file", .{path});
        const h = d[off + i * 40 ..][0..40];
        const vsize: usize = le32(h[8..]);
        const rsize: usize = le32(h[16..]);
        const rptr: usize = @min(le32(h[20..]), d.len);
        var sz: usize = if (vsize != 0) @min(vsize, rsize) else rsize;
        if (sz > d.len - rptr) sz = d.len - rptr;
        out.append(vh.gpa, .{ .name = mem.sliceTo(h[0..8], 0), .p = d[rptr .. rptr + sz] }) catch vh.oom();
    }
    return out.items;
}

fn section(s: []const Section, name: []const u8) ?Section {
    for (s) |x| if (vh.eql(x.name, name)) return x;
    return null;
}

fn rstrip0(p: []const u8) []const u8 {
    return mem.trimEnd(u8, p, "\x00");
}

fn hex8(p: []const u8) ?u32 {
    var v: u32 = 0;
    for (p[0..8]) |c| v = v << 4 | (std.fmt.charToDigit(c, 16) catch return null);
    return v;
}

fn isCpio(p: []const u8) bool {
    return p.len >= 6 and (mem.eql(u8, p[0..6], "070701") or mem.eql(u8, p[0..6], "070702"));
}

/// a newc archive: regular file -> sha256, symlink -> "-> target", anything else -> "mode ..."
pub fn parseCpio(b: []const u8, off_in: usize, l: *List, prefix: []const u8) usize {
    var off = off_in;
    while (off <= b.len and b.len - off >= 110 and isCpio(b[off..])) {
        var f: [13]u32 = undefined;
        for (0..13) |i| f[i] = hex8(b[off + 6 + 8 * i ..]) orelse vh.die("initramfs: bad cpio header at offset {d}", .{off});
        const mode = f[1];
        const fsize: usize = f[6];
        const nsize: usize = f[11];
        const name_off = off + 110;
        if (nsize > b.len - name_off) vh.die("initramfs: name past the end of the archive", .{});
        const name = if (nsize > 0) mem.sliceTo(b[name_off .. name_off + nsize - 1], 0) else "";
        off = std.mem.alignForward(usize, name_off + nsize, 4);
        if (off > b.len) off = b.len;
        const body = b[off .. off + @min(fsize, b.len - off)];
        off = std.mem.alignForward(usize, off + fsize, 4);
        if (vh.eql(name, "TRAILER!!!")) break;
        const val = switch (mode & 0o170000) {
            0o100000 => hash.sha256Hex(body),
            0o120000 => vh.fmt("-> {s}", .{body}),
            else => vh.fmt("mode {o}", .{mode}),
        };
        l.add(vh.fmt("{s}{s}", .{ prefix, name }), val);
    }
    return off;
}

/// every file of the initramfs: the early cpio (microcode) plus the compressed main one
fn initrdFiles(blob: []const u8, l: *List) void {
    var off: usize = 0;
    while (off < blob.len) {
        if (isCpio(blob[off..])) {
            off = parseCpio(blob, off, l, "early:");
            while (off < blob.len and blob[off] == 0) off += 1;
            continue;
        }
        const rest = blob[off..];
        const tool: []const u8 = if (mem.startsWith(u8, rest, "\x28\xb5\x2f\xfd"))
            "zstd"
        else if (mem.startsWith(u8, rest, "\x02\x21\x4c\x18") or mem.startsWith(u8, rest, "\x04\x22\x4d\x18"))
            "lz4"
        else
            vh.die("unknown initramfs format at offset {d}", .{off});
        var raw: std.ArrayList(u8) = .empty;
        if (vh.runOpts(&.{ tool, "-dcq" }, .{ .in = rest, .out = &raw }) != 0)
            vh.die("{s} -dcq: initramfs decompression failed", .{tool});
        _ = parseCpio(raw.items, 0, l, "");
        break;
    }
    l.finish();
}

/// a question on /dev/tty: confirmed only by the word "yes"
fn confirm(prompt: []const u8) bool {
    const fd = vh.openFd("/dev/tty", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch return false;
    defer vh.close(fd);
    vh.writeAllFd(fd, vh.fmt("{s} Type \"yes\": ", .{prompt})) catch return false;
    var line: std.ArrayList(u8) = .empty;
    while (line.items.len < 63) {
        var c: [1]u8 = undefined;
        const n = vh.readFd(fd, &c) catch return false;
        if (n == 0) break;
        line.append(vh.gpa, c[0]) catch vh.oom();
        if (c[0] == '\n') break;
    }
    return vh.eql(vh.strip(line.items), "yes");
}

fn readUki(path: []const u8) []const Section {
    const d = vh.readFile(path) catch vh.die("{s}: {s}", .{ path, vh.serr() });
    return peSections(path, d);
}

fn init(uki: ?[]const u8) void {
    vh.mkdirs(REF, 0o700);
    var in: List = .{};
    inputHashes(&in);
    writeList(REF ++ "/inputs.sha256", &in);
    if (uki) |u| {
        const s = readUki(u);
        const c = section(s, ".cmdline");
        const i = section(s, ".initrd");
        if (c == null or i == null) vh.die("{s}: no .cmdline and .initrd sections", .{u});
        vh.writeAtomic(REF ++ "/cmdline", rstrip0(c.?.p), 0o600);
        var ir: List = .{};
        initrdFiles(i.?.p, &ir);
        writeList(REF ++ "/initrd.sha256", &ir);
    }
    vh.outs("reference values written to " ++ REF ++ "\n");
}

fn verify(uki: []const u8, version: []const u8) void {
    if (!vh.isDir(REF)) vh.die("no reference values in " ++ REF ++ ": the key media is not attached (doas vh-keys mount)", .{});
    var bad: usize = 0;
    var pk: vh.Strv = .{};
    for (pkgs) |p| {
        var o: std.ArrayList(u8) = .empty;
        if (vh.runOpts(&.{ "xbps-query", p }, .{ .out = &o, .err = &o }) == 0) pk.add(p);
    }
    var env: vh.Kv = .{};
    env.read("/etc/vh/vh.env", false);
    const kernel = env.get("VH_KERNEL", "");
    if (kernel.len > 0) pk.add(kernel);
    vh.out("1. xbps-pkgdb: {s}\n", .{pk.join(" ")});
    for (pk.slice()) |p| {
        var o: std.ArrayList(u8) = .empty;
        var e: std.ArrayList(u8) = .empty;
        if (vh.runOpts(&.{ "xbps-pkgdb", p }, .{ .out = &o, .err = &e }) != 0) {
            vh.out("   x {s}: {s} {s}\n", .{ p, vh.strip(o.items), vh.strip(e.items) });
            bad += 1;
        }
    }
    vh.outs("2. build inputs not from packages, against the reference on the media\n");
    var ref: List = .{};
    var cur: List = .{};
    readList(REF ++ "/inputs.sha256", &ref);
    inputHashes(&cur);
    const r = ref.e.items;
    const cu = cur.e.items;
    var i: usize = 0;
    var j: usize = 0;
    while (i < r.len or j < cu.len) {
        const c: std.math.Order = if (i >= r.len) .gt else if (j >= cu.len) .lt else mem.order(u8, r[i].name, cu[j].name);
        switch (c) {
            .lt => {
                vh.out("   x removed: {s}\n", .{r[i].name});
                i += 1;
                bad += 1;
            },
            .gt => {
                vh.out("   x new: {s}\n", .{cu[j].name});
                j += 1;
                bad += 1;
            },
            .eq => {
                if (!vh.eql(r[i].val, cu[j].val)) {
                    vh.out("   x changed: {s}\n", .{cu[j].name});
                    bad += 1;
                }
                i += 1;
                j += 1;
            },
        }
    }
    const s = readUki(uki);
    vh.outs("3. .cmdline and .uname of the new UKI\n");
    const want = vh.readFile(REF ++ "/cmdline") catch vh.die(REF ++ "/cmdline: {s}", .{vh.serr()});
    const got: []const u8 = if (section(s, ".cmdline")) |c| rstrip0(c.p) else "";
    if (!vh.eql(got, want)) {
        vh.out("   x the cmdline differs from the reference:\n     was: {s}\n     now: {s}\n", .{ mem.sliceTo(want, 0), got });
        bad += 1;
    }
    const uname: []const u8 = if (section(s, ".uname")) |u| rstrip0(u.p) else "";
    const ubase = uname[0 .. mem.indexOfScalar(u8, uname, '_') orelse uname.len];
    const vbase = version[0 .. mem.indexOfScalar(u8, version, '_') orelse version.len];
    if (version.len > 0 and !vh.startsWith(version, ubase) and !vh.startsWith(uname, vbase)) {
        vh.out("   x .uname \"{s}\" does not match the package version {s}\n", .{ mem.sliceTo(uname, 0), version });
        bad += 1;
    }
    if (bad > 0) vh.die("{d} discrepancies. If the changes are yours and deliberate, refresh the reference values: " ++
        "doas vh-uki-verify --init (with the media attached)", .{bad});
    vh.outs("4. initramfs content against the previously approved UKI\n");
    const ir = section(s, ".initrd") orelse vh.die("{s}: no .initrd section", .{uki});
    var old: List = .{};
    var now: List = .{};
    readList(REF ++ "/initrd.sha256", &old);
    initrdFiles(ir.p, &now);
    var added: vh.Strv = .{};
    var removed: vh.Strv = .{};
    var changed: vh.Strv = .{};
    for (now.e.items) |e| {
        if (old.get(e.name)) |o| {
            if (!vh.eql(o, e.val)) changed.add(e.name);
        } else added.add(e.name);
    }
    for (old.e.items) |e| if (now.get(e.name) == null) removed.add(e.name);
    var mods: usize = 0;
    var shown: usize = 0;
    const ac = [_]*vh.Strv{ &added, &changed };
    for (ac) |list| for (list.slice()) |n| {
        if (mem.indexOf(u8, n, "/lib/modules/") != null) mods += 1;
    };
    vh.out("   added {d}, removed {d}, changed {d} (kernel modules among them: {d})\n", .{ added.len(), removed.len(), changed.len(), mods });
    for (ac) |list| for (list.slice()) |n| {
        if (shown >= 200) break;
        if (mem.indexOf(u8, n, "/lib/modules/") == null) {
            vh.out("   +- {s}\n", .{n});
            shown += 1;
        }
    };
    for (removed.slice()[0..@min(removed.len(), 50)]) |n| vh.out("   -  {s}\n", .{n});
    vh.flush();
    if ((added.len() > 0 or removed.len() > 0 or changed.len() > 0) and
        !confirm("Are the initramfs changes expected for this update (new kernel, microcode, dracut)?"))
        vh.die("the initramfs changes were not confirmed: signing cancelled", .{});
    writeList(REF ++ "/initrd.sha256", &now);
    vh.outs("   initramfs reference refreshed\n");
}

pub fn main(init_: std.process.Init.Minimal) void {
    const args = vh.init(init_, "vh-uki-verify");
    vh.setenv("PATH", "/usr/bin");
    if (linux.geteuid() != 0) vh.die("root is required", .{});
    if (args.len >= 1 and vh.eql(args[0], "--init")) {
        init(if (args.len > 1) args[1] else null);
    } else if (args.len == 2) {
        verify(args[0], args[1]);
    } else {
        vh.outs(usage_text);
        vh.exit(2);
    }
    vh.exit(0);
}

test "cpio: a truncated archive stays within bounds" {
    var l: List = .{};
    const hdr = "070701" ++ "00000001" ++ "000081A4" ++ "00000000" ++ "00000000" ++ "00000000" ++ "00000000" ++ "00000010" ++ "00000000" ++ "00000000" ++ "00000000" ++ "00000000" ++ "00000006" ++ "00000000";
    _ = parseCpio(hdr ++ "a.txt\x00\x00\x00hello", 0, &l, "");
    try std.testing.expectEqual(@as(usize, 1), l.e.items.len);
    try std.testing.expectEqualStrings("a.txt", l.e.items[0].name);
}
