//! The gaming twin of a stock UKI (vh-game boot on, docs/uni/game.md, G3): the same image with
//! ia32_emulation=1 in place of ia32_emulation=0 in its .cmdline section, and nothing else.
//! Under Secure Boot systemd-stub ignores a command line from the boot loader, so the gaming
//! boot needs a UKI of its own. One byte changed in place keeps every section where it was: the
//! layout, the kernel and the initrd are the stock UKI's, as dracut made them and the everyday
//! boot runs them, and no second dracut run is needed. The twin is written without the stock
//! UKI's signature (the certificate table cut off, its data directory entry zeroed);
//! vh-limine-update signs it with the db key, as every UKI. vh-limine-update is the only user.
//!
//! A UKI on the ESP is untrusted data: every offset and size is checked before it is used, and
//! a file that is not the PE image this expects is an error, never a crash.
const std = @import("std");
const vh = @import("vh");
const linux = std.os.linux;
const mem = std.mem;

/// where the twin differs from the stock UKI, as offsets in the file
pub const Plan = struct {
    /// the image: the file up to its certificate table, or all of it when it is not signed
    end: u64,
    /// the "0" of every ia32_emulation=0 of the .cmdline section, a "1" in the twin
    flips: []const u64,
    /// the certificate table's entry of the data directories (8 bytes, zero in the twin)
    cert_entry: u64,
    /// the optional header's CheckSum (4 bytes): kept, and not compared (signing may set it)
    checksum: u64,
};

pub const Error = error{
    /// not a PE image, or one whose headers point outside the file
    NotPe,
    /// no .cmdline section
    NoCmdline,
    /// the command line has no ia32_emulation=0
    NoIa32Off,
    /// an ia32_emulation= with another value than 0: ia32 is on in the everyday boot already
    Ia32NotOff,
    /// a certificate table that is not the last thing in the file
    BadCertTable,
};

pub fn describe(e: Error) []const u8 {
    return switch (e) {
        error.NotPe => "not a PE image this tool reads",
        error.NoCmdline => "no .cmdline section",
        error.NoIa32Off => "its command line has no ia32_emulation=0 (the plan's x86.ia32-off): the everyday boot would be a gaming one",
        error.Ia32NotOff => "its command line turns ia32 on already (an ia32_emulation= other than 0)",
        error.BadCertTable => "a certificate table that is not at the end of the file",
    };
}

fn le16(p: []const u8) u16 {
    return mem.readInt(u16, p[0..2], .little);
}

fn le32(p: []const u8) u32 {
    return mem.readInt(u32, p[0..4], .little);
}

/// what plan() reads of a PE image's headers
const Headers = struct {
    /// the file offset of the certificate table's entry and of CheckSum
    cert_entry: u64,
    checksum: u64,
    /// the certificate table: file offset and size (0 when the image is not signed)
    cert_off: u64,
    cert_size: u64,
    /// the .cmdline section's bytes in the file
    cmd_off: u64,
    cmd_len: u64,
    /// the end of the last section's raw data
    raw_end: u64,
};

/// The headers of a PE image whose first bytes are `head`, in a file of `size` bytes.
fn headers(head: []const u8, size: u64) Error!Headers {
    if (head.len < 0x40 or head[0] != 'M' or head[1] != 'Z') return error.NotPe;
    const pe: usize = le32(head[0x3c..]);
    if (pe > head.len or head.len - pe < 24 or !mem.eql(u8, head[pe .. pe + 4], "PE\x00\x00")) return error.NotPe;
    const nsec: usize = le16(head[pe + 6 ..]);
    const opt_size: usize = le16(head[pe + 20 ..]);
    const opt = pe + 24;
    if (opt_size < 2 or head.len - opt < opt_size) return error.NotPe;
    // PE32+ (EFI on x86_64) or PE32: where the data directories begin and how many there are
    const magic = le16(head[opt..]);
    const dd: usize, const ndd_at: usize = switch (magic) {
        0x20b => .{ opt + 112, opt + 108 },
        0x10b => .{ opt + 96, opt + 92 },
        else => return error.NotPe,
    };
    // the certificate table is entry 4 of the data directories
    if (dd + 5 * 8 > opt + opt_size or le32(head[ndd_at..]) < 5) return error.NotPe;
    const cert_entry = dd + 4 * 8;
    var h: Headers = .{
        .cert_entry = cert_entry,
        .checksum = opt + 64,
        .cert_off = le32(head[cert_entry..]),
        .cert_size = le32(head[cert_entry + 4 ..]),
        .cmd_off = 0,
        .cmd_len = 0,
        .raw_end = 0,
    };
    const table = opt + opt_size;
    if (nsec > 96 or (head.len - table) / 40 < nsec) return error.NotPe;
    var found = false;
    for (0..nsec) |i| {
        const s = head[table + i * 40 ..][0..40];
        const vsize: u64 = le32(s[8..]);
        const rsize: u64 = le32(s[16..]);
        const rptr: u64 = le32(s[20..]);
        if (rptr > size or rsize > size - rptr) return error.NotPe;
        h.raw_end = @max(h.raw_end, rptr + rsize);
        if (vh.eql(mem.sliceTo(s[0..8], 0), ".cmdline")) {
            if (found) return error.NotPe;
            found = true;
            h.cmd_off = rptr;
            h.cmd_len = if (vsize != 0) @min(vsize, rsize) else rsize;
        }
    }
    if (!found) return error.NoCmdline;
    // Authenticode puts the certificate table last, after every section's data
    if (h.cert_off != 0 or h.cert_size != 0) {
        if (h.cert_off < h.raw_end or h.cert_off > size or h.cert_size != size - h.cert_off) return error.BadCertTable;
    }
    return h;
}

/// The offsets of the value of every ia32_emulation=0 in a command line (words split by
/// white space and NUL, as the kernel reads it); an error when there is none, or when one
/// names another value.
pub fn ia32Flips(cmdline: []const u8) Error![]const usize {
    var out: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    while (i < cmdline.len) {
        while (i < cmdline.len and (vh.isSpace(cmdline[i]) or cmdline[i] == 0)) i += 1;
        const start = i;
        while (i < cmdline.len and !(vh.isSpace(cmdline[i]) or cmdline[i] == 0)) i += 1;
        const word = cmdline[start..i];
        const key = "ia32_emulation=";
        if (!vh.startsWith(word, key)) continue;
        if (!vh.eql(word[key.len..], "0")) return error.Ia32NotOff;
        out.append(vh.gpa, start + key.len) catch vh.oom();
    }
    if (out.items.len == 0) return error.NoIa32Off;
    return out.items;
}

/// The plan of the twin of the stock UKI at PATH; errno is set on a read error.
pub fn plan(path: []const u8) (vh.Error || Error)!Plan {
    const fd = try vh.openFd(path, .{ .ACCMODE = .RDONLY }, 0);
    defer vh.close(fd);
    const size = (try vh.fstat(fd)).size;
    const head = try pread(fd, 0, @min(size, 65536));
    const h = try headers(head, size);
    if (h.cmd_len > 65536) return error.NotPe; // a command line, not a payload
    const cmd = try pread(fd, h.cmd_off, h.cmd_len);
    if (cmd.len != h.cmd_len) return error.NotPe;
    const at = try ia32Flips(cmd);
    const flips = vh.gpa.alloc(u64, at.len) catch vh.oom();
    for (at, 0..) |o, k| flips[k] = h.cmd_off + o;
    return .{
        .end = if (h.cert_off != 0) h.cert_off else size,
        .flips = flips,
        .cert_entry = h.cert_entry,
        .checksum = h.checksum,
    };
}

/// the byte the twin has at OFF in place of the stock UKI's B
fn patched(p: Plan, off: u64, b: u8) u8 {
    for (p.flips) |f| if (f == off) return '1';
    if (off >= p.cert_entry and off < p.cert_entry + 8) return 0;
    return b;
}

/// a byte whose value is no part of the comparison: CheckSum, and the certificate table's
/// entry, which a signature sets
fn ignored(p: Plan, off: u64) bool {
    return (off >= p.checksum and off < p.checksum + 4) or (off >= p.cert_entry and off < p.cert_entry + 8);
}

const chunk = 1 << 20;

/// Write the twin of SRC to DST, a new file (O_EXCL), and flush it to the disk. On an error
/// DST may be left half written: the caller removes it.
pub fn write(src: []const u8, dst: []const u8, p: Plan) vh.Error!void {
    const in = try vh.openFd(src, .{ .ACCMODE = .RDONLY }, 0);
    defer vh.close(in);
    const out = try vh.openFd(dst, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o644);
    defer vh.close(out);
    const buf = vh.gpa.alloc(u8, chunk) catch vh.oom();
    defer vh.gpa.free(buf);
    var pos: u64 = 0;
    while (pos < p.end) {
        const want: usize = @intCast(@min(p.end - pos, chunk));
        const n = try preadInto(in, buf[0..want], pos);
        if (n != want) {
            vh.errno = .IO; // the file got shorter under us
            return error.Sys;
        }
        for (buf[0..n], 0..) |*b, k| b.* = patched(p, pos + k, b.*);
        try vh.writeAllFd(out, buf[0..n]);
        pos += n;
    }
    _ = try vh.sys(linux.fsync(out));
}

/// Whether TWIN is the twin of SRC already, signed or not: the same image with the plan's
/// changes, CheckSum and the certificate table's entry aside, and after it at most the zero
/// padding a signature aligns its table with.
pub fn same(src: []const u8, twin: []const u8, p: Plan) bool {
    const tf = vh.openFd(twin, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    defer vh.close(tf);
    const tsize = (vh.fstat(tf) catch return false).size;
    const thead = pread(tf, 0, @min(tsize, 65536)) catch return false;
    const th = headers(thead, tsize) catch return false;
    const tend = if (th.cert_off != 0) th.cert_off else tsize;
    if (tend < p.end or tend > mem.alignForward(u64, p.end, 8)) return false;
    const sf = vh.openFd(src, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    defer vh.close(sf);
    const a = vh.gpa.alloc(u8, chunk) catch vh.oom();
    defer vh.gpa.free(a);
    const b = vh.gpa.alloc(u8, chunk) catch vh.oom();
    defer vh.gpa.free(b);
    var pos: u64 = 0;
    while (pos < tend) {
        const want: usize = @intCast(@min(tend - pos, chunk));
        const nt = preadInto(tf, b[0..want], pos) catch return false;
        if (nt != want) return false;
        const in_src: usize = @intCast(@min(want, p.end -| pos));
        if (in_src > 0) {
            const ns = preadInto(sf, a[0..in_src], pos) catch return false;
            if (ns != in_src) return false;
        }
        for (0..want) |k| {
            const off = pos + k;
            if (off >= p.end) {
                if (b[k] != 0) return false;
            } else if (!ignored(p, off) and b[k] != patched(p, off, a[k])) return false;
        }
        pos += want;
    }
    return true;
}

fn pread(fd: vh.fd_t, off: u64, len: u64) vh.Error![]u8 {
    const buf = vh.gpa.alloc(u8, @intCast(len)) catch vh.oom();
    const n = try preadInto(fd, buf, off);
    return buf[0..n];
}

fn preadInto(fd: vh.fd_t, buf: []u8, off: u64) vh.Error!usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try vh.sysRetry(linux.pread, .{ fd, buf[got..].ptr, buf.len - got, @as(i64, @intCast(off + got)) });
        if (n == 0) break;
        got += n;
    }
    return got;
}

// ---------------------------------------------------------------- tests

/// A UKI as dracut lays it out with objcopy: a PE32+ image (the optional header with its 16
/// data directories), sections at 512-byte boundaries; with SIG, a certificate table after the
/// last section, its entry set, as a signature leaves it.
pub fn testUki(cmdline: []const u8, sig: ?[]const u8) []const u8 {
    const sections = [_][2][]const u8{ .{ ".osrel", "ID=void\n" }, .{ ".cmdline", cmdline }, .{ ".linux", repeat("KERNEL", 300) }, .{ ".initrd", repeat("INITRD", 500) } };
    const opt_size = 240;
    var b: std.ArrayList(u8) = .empty;
    b.appendNTimes(vh.gpa, 0, 0x40 + 24 + opt_size + 40 * sections.len) catch vh.oom();
    b.items[0] = 'M';
    b.items[1] = 'Z';
    mem.writeInt(u32, b.items[0x3c..0x40], 0x40, .little);
    @memcpy(b.items[0x40..0x44], "PE\x00\x00");
    mem.writeInt(u16, b.items[0x44..0x46], 0x8664, .little);
    mem.writeInt(u16, b.items[0x46..0x48], sections.len, .little);
    mem.writeInt(u16, b.items[0x54..0x56], opt_size, .little);
    const opt = 0x40 + 24;
    mem.writeInt(u16, b.items[opt..][0..2], 0x20b, .little);
    mem.writeInt(u32, b.items[opt + 64 ..][0..4], 0x1234, .little); // CheckSum
    mem.writeInt(u32, b.items[opt + 108 ..][0..4], 16, .little);
    const table = opt + opt_size;
    for (sections, 0..) |s, i| {
        while (b.items.len % 512 != 0) b.append(vh.gpa, 0) catch vh.oom();
        const at = b.items.len;
        b.appendSlice(vh.gpa, s[1]) catch vh.oom();
        while (b.items.len % 512 != 0) b.append(vh.gpa, 0) catch vh.oom();
        const h = b.items[table + i * 40 ..][0..40];
        @memcpy(h[0..s[0].len], s[0]);
        mem.writeInt(u32, h[8..12], @intCast(s[1].len), .little);
        mem.writeInt(u32, h[12..16], @intCast(0x1000 * (i + 1)), .little);
        mem.writeInt(u32, h[16..20], @intCast(b.items.len - at), .little);
        mem.writeInt(u32, h[20..24], @intCast(at), .little);
    }
    if (sig) |s| {
        const at = b.items.len;
        b.appendSlice(vh.gpa, s) catch vh.oom();
        mem.writeInt(u32, b.items[opt + 112 + 32 ..][0..4], @intCast(at), .little);
        mem.writeInt(u32, b.items[opt + 112 + 36 ..][0..4], @intCast(s.len), .little);
        mem.writeInt(u32, b.items[opt + 64 ..][0..4], 0x5678, .little); // a signing tool's CheckSum
    }
    return b.items;
}

fn repeat(s: []const u8, n: usize) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    for (0..n) |_| b.appendSlice(vh.gpa, s) catch vh.oom();
    return b.items;
}

const t = std.testing;

fn tmpDir() []const u8 {
    const d = vh.fmt("/tmp/vh-twin-test-{d}", .{linux.getpid()});
    vh.mkdirs(d, 0o700);
    return d;
}

test "twin: the command line's ia32_emulation" {
    // the offset of the value, the "0" itself
    try t.expectEqualSlices(usize, &.{53}, try ia32Flips("root=UUID=x efi=disable_early_pci_dma ia32_emulation=0 ro\x00"));
    try t.expectEqualSlices(usize, &.{ 15, 32 }, try ia32Flips("ia32_emulation=0 ia32_emulation=0"));
    try t.expectError(error.NoIa32Off, ia32Flips("root=UUID=x ro\x00"));
    try t.expectError(error.NoIa32Off, ia32Flips("xia32_emulation=0 ia32_emulation_x=0"));
    try t.expectError(error.Ia32NotOff, ia32Flips("ia32_emulation=0 ia32_emulation=1"));
    try t.expectError(error.Ia32NotOff, ia32Flips("ia32_emulation=00"));
    try t.expectError(error.Ia32NotOff, ia32Flips("ia32_emulation="));
}

test "twin: an unsigned and a signed stock UKI, the twin, the comparison" {
    const d = tmpDir();
    defer _ = vh.runOpts(&.{ "rm", "-rf", d }, .{});
    const cmd = "root=UUID=x ia32_emulation=0 module_blacklist=uhid\x00";
    for ([_]?[]const u8{ null, "SIGNATURE-OF-THE-STOCK-UKI" }) |sig| {
        const stock = testUki(cmd, sig);
        const src = vh.fmt("{s}/stock.efi", .{d});
        vh.writeAtomic(src, stock, 0o644);
        const p = try plan(src);
        try t.expectEqual(@as(usize, 1), p.flips.len);
        try t.expectEqual(@as(u64, if (sig) |s| stock.len - s.len else stock.len), p.end);
        const dst = vh.fmt("{s}/twin.efi", .{d});
        vh.unlink(dst) catch {};
        try write(src, dst, p);
        const tw = try vh.readFile(dst);
        // the image without a signature, one byte of the command line changed, nothing moved
        try t.expectEqual(p.end, tw.len);
        var diff: usize = 0;
        for (tw, 0..) |c, k| if (c != stock[k]) {
            diff += 1;
        };
        try t.expectEqual(@as(usize, if (sig != null) 1 + 2 else 1), diff); // the flip, and the table's entry
        const at_ia = mem.indexOf(u8, tw, "ia32_emulation=").?;
        try t.expectEqualStrings("ia32_emulation=1 module_blacklist=uhid", tw[at_ia .. at_ia + 38]);
        const h = try headers(tw[0..4096], tw.len);
        try t.expect(h.cert_off == 0 and h.cert_size == 0);
        try t.expect(same(src, dst, p));
        // signed afterwards: a table after 8-byte padding, CheckSum changed: still the twin
        var signed: std.ArrayList(u8) = .empty;
        signed.appendSlice(vh.gpa, tw) catch vh.oom();
        while (signed.items.len % 8 != 0) signed.append(vh.gpa, 0) catch vh.oom();
        const at = signed.items.len;
        signed.appendSlice(vh.gpa, "SIGNATURE-OF-THE-TWIN") catch vh.oom();
        mem.writeInt(u32, signed.items[h.cert_entry..][0..4], @intCast(at), .little);
        mem.writeInt(u32, signed.items[h.cert_entry + 4 ..][0..4], @intCast(signed.items.len - at), .little);
        mem.writeInt(u32, signed.items[h.checksum..][0..4], 0x9abc, .little);
        vh.writeAtomic(dst, signed.items, 0o644);
        try t.expect(same(src, dst, p));
        // another byte of the image, or a stock UKI rebuilt: no longer the twin
        signed.items[p.end - 1] ^= 1;
        vh.writeAtomic(dst, signed.items, 0o644);
        try t.expect(!same(src, dst, p));
        try t.expect(!same(src, vh.fmt("{s}/missing.efi", .{d}), p));
    }
    // the stock UKI's twin is never made of a command line without ia32_emulation=0, or of a
    // file that is not a UKI
    const bad = vh.fmt("{s}/bad.efi", .{d});
    vh.writeAtomic(bad, testUki("root=UUID=x ro\x00", null), 0o644);
    try t.expectError(error.NoIa32Off, plan(bad));
    vh.writeAtomic(bad, testUki("ia32_emulation=1\x00", null), 0o644);
    try t.expectError(error.Ia32NotOff, plan(bad));
    vh.writeAtomic(bad, "MZ not a PE image", 0o644);
    try t.expectError(error.NotPe, plan(bad));
    // a certificate table that claims to end before the file does
    var odd = vh.dupe(testUki("ia32_emulation=0\x00", "SIG"));
    mem.writeInt(u32, odd[0x40 + 24 + 112 + 36 ..][0..4], 1, .little);
    vh.writeAtomic(bad, odd, 0o644);
    try t.expectError(error.BadCertTable, plan(bad));
}
