//! The twins of a stock UKI: the same PE image with another .cmdline section and nothing else.
//! Under Secure Boot systemd-stub ignores a command line from the boot loader, so a boot with
//! another command line needs a UKI of its own; a twin takes the stock UKI's kernel and initrd
//! as dracut made them and the everyday boot runs them, and no second dracut run is needed.
//! Two twins exist, and vh-limine-update is the only user:
//!   * the gaming twin (vh-game boot on, docs/uni/game.md, G3): ia32_emulation=1 in place of
//!     ia32_emulation=0, one byte changed in place, every section where it was;
//!   * the init twin (vh-init --install, init/README.md): init=/usr/local/sbin/vh-init appended.
//!     A longer command line takes the padding of its section, or one more block of the file
//!     alignment: then the .cmdline header's sizes and the file offsets of the sections after it
//!     move by that block, nothing else. The sections' addresses in memory stay as they are (the
//!     new command line must fit before the next section's address, which dracut aligns to the
//!     stub's page size).
//! The twin is written without the stock UKI's signature (the certificate table cut off, its
//! data directory entry zeroed); vh-limine-update signs it with the db key, as every UKI.
//!
//! A UKI on the ESP is untrusted data: every offset and size is checked before it is used, and
//! a file that is not the PE image this expects is an error, never a crash.
const std = @import("std");
const vh = @import("vh");
const linux = std.os.linux;
const mem = std.mem;

/// what the twin's command line is, made from the stock UKI's
pub const Change = enum { ia32_on, vh_init };

/// the parameter the init twin appends (init/src/initsetup.zig says the same)
pub const init_param = "init=/usr/local/sbin/vh-init";

/// a kernel command line's limit on x86 (COMMAND_LINE_SIZE), without the NUL
pub const cmdline_max = 2047;

/// a 4-byte little-endian value of the headers that differs in the twin
pub const Patch = struct { off: u64, val: u32 };

/// where the twin differs from the stock UKI, as offsets in the file
pub const Plan = struct {
    /// the image: the stock UKI up to its certificate table, or all of it when it is not signed
    end: u64,
    /// the .cmdline section's raw data in the stock UKI: its offset and its SizeOfRawData
    cmd_off: u64,
    cmd_raw: u64,
    /// the twin's command line, NUL-ended, and the raw size of its section in the twin (a
    /// multiple of the file alignment, never less than the stock UKI's)
    cmd: []const u8,
    cmd_raw_new: u64,
    /// the header bytes that differ: the .cmdline header's VirtualSize and SizeOfRawData where
    /// they change, the PointerToRawData of every section after it when the raw size grew, and
    /// the certificate table's entry (zero in the twin)
    patches: []const Patch,
    /// the certificate table's entry of the data directories (8 bytes) and the optional
    /// header's CheckSum (4 bytes): neither is compared (signing sets both)
    cert_entry: u64,
    checksum: u64,

    /// how much the sections after .cmdline move in the file
    pub fn delta(p: Plan) u64 {
        return p.cmd_raw_new - p.cmd_raw;
    }

    /// the twin's size, unsigned
    pub fn size(p: Plan) u64 {
        return p.end + p.delta();
    }

    /// the twin's byte at T when the stock UKI has B at the offset T maps to; null for an
    /// offset of the command line's region, which maps to nothing of the stock UKI
    fn byte(p: Plan, at: u64, b: u8) u8 {
        for (p.patches) |pt| if (at >= pt.off and at < pt.off + 4) return @truncate(pt.val >> @intCast(8 * (at - pt.off)));
        return b;
    }

    /// the byte of the command line's region at T
    fn cmdByte(p: Plan, at: u64) u8 {
        const i = at - p.cmd_off;
        return if (i < p.cmd.len) p.cmd[i] else 0;
    }

    /// a byte whose value is no part of the comparison: CheckSum, and the certificate table's
    /// entry, which a signature sets
    fn ignored(p: Plan, at: u64) bool {
        return (at >= p.checksum and at < p.checksum + 4) or (at >= p.cert_entry and at < p.cert_entry + 8);
    }
};

pub const Error = error{
    /// not a PE image, or one whose headers point outside the file
    NotPe,
    /// no .cmdline section, or an empty command line
    NoCmdline,
    /// the command line has no ia32_emulation=0
    NoIa32Off,
    /// an ia32_emulation= with another value than 0: ia32 is on in the everyday boot already
    Ia32NotOff,
    /// the command line names an init= already
    HasInit,
    /// the longer command line would not fit before the next section's address in memory
    NoRoom,
    /// the longer command line is more than the kernel takes
    TooLong,
    /// a certificate table that is not the last thing in the file
    BadCertTable,
};

pub fn describe(e: Error) []const u8 {
    return switch (e) {
        error.NotPe => "not a PE image this tool reads",
        error.NoCmdline => "no .cmdline section, or an empty command line",
        error.NoIa32Off => "its command line has no ia32_emulation=0 (the plan's x86.ia32-off): the everyday boot would be a gaming one",
        error.Ia32NotOff => "its command line turns ia32 on already (an ia32_emulation= other than 0)",
        error.HasInit => "its command line names an init= already (an earlier vh-init --install edited /etc/default/dracut-uefi-hook: take it out and rebuild the stock UKI)",
        error.NoRoom => "the longer command line does not fit before the next section of the image",
        error.TooLong => "the longer command line is more than the kernel's 2047 bytes",
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
    /// FileAlignment: every section's raw data is a multiple of it
    file_align: u64,
    /// the .cmdline section: its header's offset in the file, its bytes in the file (the
    /// command line's length, and the raw size of the section), its address in memory
    cmd_hdr: u64,
    cmd_off: u64,
    cmd_len: u64,
    cmd_raw: u64,
    cmd_vma: u64,
    /// the address of the section that follows .cmdline in memory; null when it is the last
    next_vma: ?u64,
    /// the PointerToRawData fields of the sections whose data follows .cmdline in the file
    later: []const u64,
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
    if (opt_size < 40 or head.len - opt < opt_size) return error.NotPe;
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
    const file_align: u64 = le32(head[opt + 36 ..]);
    if (file_align < 512 or file_align > 65536 or @popCount(file_align) != 1) return error.NotPe;
    var h: Headers = .{
        .cert_entry = cert_entry,
        .checksum = opt + 64,
        .cert_off = le32(head[cert_entry..]),
        .cert_size = le32(head[cert_entry + 4 ..]),
        .file_align = file_align,
        .cmd_hdr = 0,
        .cmd_off = 0,
        .cmd_len = 0,
        .cmd_raw = 0,
        .cmd_vma = 0,
        .next_vma = null,
        .later = &.{},
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
            h.cmd_hdr = table + i * 40;
            h.cmd_off = rptr;
            h.cmd_raw = rsize;
            h.cmd_len = if (vsize != 0) @min(vsize, rsize) else rsize;
            h.cmd_vma = le32(s[12..]);
        }
    }
    if (!found or h.cmd_raw == 0) return error.NoCmdline;
    // the sections after .cmdline: in the file (their offsets move with a longer command line)
    // and in memory (the next address bounds it)
    var later: std.ArrayList(u64) = .empty;
    for (0..nsec) |i| {
        const s = head[table + i * 40 ..][0..40];
        const rsize: u64 = le32(s[16..]);
        const rptr: u64 = le32(s[20..]);
        const vma: u64 = le32(s[12..]);
        if (rsize > 0 and rptr > h.cmd_off) later.append(vh.gpa, table + i * 40 + 20) catch vh.oom();
        if (vma > h.cmd_vma and (h.next_vma == null or vma < h.next_vma.?)) h.next_vma = vma;
    }
    h.later = later.items;
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
    var it = words(cmdline);
    while (it.next()) |w| {
        const key = "ia32_emulation=";
        if (!vh.startsWith(w.text, key)) continue;
        if (!vh.eql(w.text[key.len..], "0")) return error.Ia32NotOff;
        out.append(vh.gpa, w.start + key.len) catch vh.oom();
    }
    if (out.items.len == 0) return error.NoIa32Off;
    return out.items;
}

/// the words of a command line as the kernel splits them: white space and NUL
const Words = struct {
    s: []const u8,
    i: usize = 0,

    const Word = struct { start: usize, text: []const u8 };

    fn next(w: *Words) ?Word {
        while (w.i < w.s.len and (vh.isSpace(w.s[w.i]) or w.s[w.i] == 0)) w.i += 1;
        if (w.i >= w.s.len) return null;
        const start = w.i;
        while (w.i < w.s.len and !(vh.isSpace(w.s[w.i]) or w.s[w.i] == 0)) w.i += 1;
        return .{ .start = start, .text = w.s[start..w.i] };
    }
};

fn words(s: []const u8) Words {
    return .{ .s = s };
}

/// The twin's command line from the stock UKI's (its .cmdline section, NUL-ended as dracut
/// writes it), NUL-ended.
pub fn newCmdline(cmd: []const u8, change: Change) Error![]const u8 {
    switch (change) {
        .ia32_on => {
            const out = vh.dupe(cmd);
            for (try ia32Flips(cmd)) |o| out[o] = '1';
            return out;
        },
        .vh_init => {
            var it = words(cmd);
            while (it.next()) |w| if (vh.startsWith(w.text, "init=")) return error.HasInit;
            // the text up to the NUL, without trailing white space
            const text = mem.trimEnd(u8, cmd[0 .. mem.indexOfScalar(u8, cmd, 0) orelse cmd.len], " \t\r\n");
            if (text.len == 0) return error.NoCmdline;
            if (text.len + 1 + init_param.len > cmdline_max) return error.TooLong;
            return vh.fmt("{s} {s}\x00", .{ text, init_param });
        },
    }
}

/// The plan of the twin of the stock UKI at PATH with CHANGE; errno is set on a read error.
pub fn plan(path: []const u8, change: Change) (vh.Error || Error)!Plan {
    const fd = try vh.openFd(path, .{ .ACCMODE = .RDONLY }, 0);
    defer vh.close(fd);
    const size = (try vh.fstat(fd)).size;
    const head = try pread(fd, 0, @min(size, 65536));
    const h = try headers(head, size);
    if (h.cmd_len > 65536) return error.NotPe; // a command line, not a payload
    const cmd = try pread(fd, h.cmd_off, h.cmd_len);
    if (cmd.len != h.cmd_len) return error.NotPe;
    const new = try newCmdline(cmd, change);
    // the raw size of the twin's section: the stock UKI's, or more blocks of the file alignment
    const raw_new = @max(mem.alignForward(u64, new.len, h.file_align), h.cmd_raw);
    const next = h.next_vma orelse return error.NoRoom;
    if (raw_new > next - h.cmd_vma) return error.NoRoom;
    const delta = raw_new - h.cmd_raw;
    var patches: std.ArrayList(Patch) = .empty;
    if (new.len != h.cmd_len) patches.append(vh.gpa, .{ .off = h.cmd_hdr + 8, .val = @intCast(new.len) }) catch vh.oom();
    if (delta != 0) {
        patches.append(vh.gpa, .{ .off = h.cmd_hdr + 16, .val = @intCast(raw_new) }) catch vh.oom();
        for (h.later) |off| {
            const ptr: u64 = le32(head[@intCast(off)..]);
            patches.append(vh.gpa, .{ .off = off, .val = @intCast(ptr + delta) }) catch vh.oom();
        }
    }
    patches.append(vh.gpa, .{ .off = h.cert_entry, .val = 0 }) catch vh.oom();
    patches.append(vh.gpa, .{ .off = h.cert_entry + 4, .val = 0 }) catch vh.oom();
    // every patched byte is in the headers, before any section's data
    for (patches.items) |pt| if (pt.off + 4 > h.cmd_off) return error.NotPe;
    return .{
        .end = if (h.cert_off != 0) h.cert_off else size,
        .cmd_off = h.cmd_off,
        .cmd_raw = h.cmd_raw,
        .cmd = new,
        .cmd_raw_new = raw_new,
        .patches = patches.items,
        .cert_entry = h.cert_entry,
        .checksum = h.checksum,
    };
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
    // the headers and the sections before .cmdline, patched
    var pos: u64 = 0;
    while (pos < p.cmd_off) {
        const n = try copyChunk(in, pos, buf[0..@intCast(@min(p.cmd_off - pos, chunk))]);
        for (buf[0..n], 0..) |*b, k| b.* = p.byte(pos + k, b.*);
        try vh.writeAllFd(out, buf[0..n]);
        pos += n;
    }
    // the command line's section: the new line, zero-padded to its raw size
    var at: u64 = p.cmd_off;
    while (at < p.cmd_off + p.cmd_raw_new) {
        const n: usize = @intCast(@min(p.cmd_off + p.cmd_raw_new - at, chunk));
        for (buf[0..n], 0..) |*b, k| b.* = p.cmdByte(at + k);
        try vh.writeAllFd(out, buf[0..n]);
        at += n;
    }
    // the sections after it, as they are
    pos = p.cmd_off + p.cmd_raw;
    while (pos < p.end) {
        const n = try copyChunk(in, pos, buf[0..@intCast(@min(p.end - pos, chunk))]);
        try vh.writeAllFd(out, buf[0..n]);
        pos += n;
    }
    _ = try vh.sys(linux.fsync(out));
}

/// BUF filled from FD at OFF; EIO when the file got shorter under us
fn copyChunk(fd: vh.fd_t, off: u64, buf: []u8) vh.Error!usize {
    const n = try preadInto(fd, buf, off);
    if (n != buf.len) {
        vh.errno = .IO;
        return error.Sys;
    }
    return n;
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
    const psize = p.size();
    if (tend < psize or tend > mem.alignForward(u64, psize, 8)) return false;
    const sf = vh.openFd(src, .{ .ACCMODE = .RDONLY }, 0) catch return false;
    defer vh.close(sf);
    const a = vh.gpa.alloc(u8, chunk) catch vh.oom();
    defer vh.gpa.free(a);
    const b = vh.gpa.alloc(u8, chunk) catch vh.oom();
    defer vh.gpa.free(b);
    // the twin in three regions of the stock UKI's offsets plus the padding of a signature;
    // the command line's region maps to no bytes of the stock UKI
    const cmd_end = p.cmd_off + p.cmd_raw_new;
    var pos: u64 = 0;
    while (pos < tend) {
        const region_end = if (pos < p.cmd_off) p.cmd_off else if (pos < cmd_end) cmd_end else if (pos < psize) psize else tend;
        const want: usize = @intCast(@min(region_end - pos, chunk));
        const nt = preadInto(tf, b[0..want], pos) catch return false;
        if (nt != want) return false;
        if (pos < p.cmd_off or (pos >= cmd_end and pos < psize)) {
            // the stock UKI's bytes: at the same offset before the command line, moved after it
            const ns = preadInto(sf, a[0..want], if (pos < p.cmd_off) pos else pos - p.delta()) catch return false;
            if (ns != want) return false;
            for (0..want) |k| {
                const o = pos + k;
                if (!p.ignored(o) and b[k] != p.byte(o, a[k])) return false;
            }
        } else if (pos < cmd_end) {
            for (0..want) |k| if (b[k] != p.cmdByte(pos + k)) return false;
        } else {
            for (0..want) |k| if (b[k] != 0) return false;
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
/// data directories, FileAlignment 512), sections at 512-byte boundaries in the file and at
/// 4096-byte addresses in memory; with SIG, a certificate table after the last section, its
/// entry set, as a signature leaves it.
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
    mem.writeInt(u32, b.items[opt + 32 ..][0..4], 4096, .little); // SectionAlignment
    mem.writeInt(u32, b.items[opt + 36 ..][0..4], 512, .little); // FileAlignment
    mem.writeInt(u32, b.items[opt + 64 ..][0..4], 0x1234, .little); // CheckSum
    mem.writeInt(u32, b.items[opt + 108 ..][0..4], 16, .little);
    const table = opt + opt_size;
    var vma: u32 = 0x1000;
    for (sections, 0..) |s, i| {
        while (b.items.len % 512 != 0) b.append(vh.gpa, 0) catch vh.oom();
        const at = b.items.len;
        b.appendSlice(vh.gpa, s[1]) catch vh.oom();
        while (b.items.len % 512 != 0) b.append(vh.gpa, 0) catch vh.oom();
        const h = b.items[table + i * 40 ..][0..40];
        @memcpy(h[0..s[0].len], s[0]);
        mem.writeInt(u32, h[8..12], @intCast(s[1].len), .little);
        mem.writeInt(u32, h[12..16], vma, .little);
        mem.writeInt(u32, h[16..20], @intCast(b.items.len - at), .little);
        mem.writeInt(u32, h[20..24], @intCast(at), .little);
        vma += @intCast(mem.alignForward(usize, s[1].len, 4096));
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

/// the sections of a test image as (name, raw offset, raw size, virtual size, address)
const Sec = struct { name: []const u8, off: u64, raw: u64, vsize: u64, vma: u64 };

fn sectionsOf(img: []const u8) []const Sec {
    const pe: usize = le32(img[0x3c..]);
    const nsec: usize = le16(img[pe + 6 ..]);
    const table = pe + 24 + le16(img[pe + 20 ..]);
    const out = vh.gpa.alloc(Sec, nsec) catch vh.oom();
    for (0..nsec) |i| {
        const h = img[table + i * 40 ..][0..40];
        out[i] = .{ .name = vh.dupe(mem.sliceTo(h[0..8], 0)), .off = le32(h[20..]), .raw = le32(h[16..]), .vsize = le32(h[8..]), .vma = le32(h[12..]) };
    }
    return out;
}

fn section(img: []const u8, name: []const u8) []const u8 {
    for (sectionsOf(img)) |s| if (vh.eql(s.name, name)) return img[@intCast(s.off)..@intCast(s.off + s.raw)];
    unreachable;
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
    try t.expectEqualStrings("root=x ia32_emulation=1 ro\x00", try newCmdline("root=x ia32_emulation=0 ro\x00", .ia32_on));
}

test "twin: the init twin's command line" {
    try t.expectEqualStrings("root=UUID=x ro init=/usr/local/sbin/vh-init\x00", try newCmdline("root=UUID=x ro\x00", .vh_init));
    // trailing white space goes, a line without the NUL gets one
    try t.expectEqualStrings("root=x init=/usr/local/sbin/vh-init\x00", try newCmdline("root=x  \x00", .vh_init));
    try t.expectEqualStrings("root=x init=/usr/local/sbin/vh-init\x00", try newCmdline("root=x", .vh_init));
    try t.expectError(error.HasInit, newCmdline("root=x init=/usr/bin/runit-init\x00", .vh_init));
    try t.expectError(error.HasInit, newCmdline("root=x init=/usr/local/sbin/vh-init\x00", .vh_init));
    try t.expectError(error.NoCmdline, newCmdline("\x00", .vh_init));
    try t.expectError(error.NoCmdline, newCmdline("   ", .vh_init));
    const long = vh.gpa.alloc(u8, 2030) catch vh.oom();
    @memset(long, 'a');
    try t.expectError(error.TooLong, newCmdline(long, .vh_init));
    // "init" as a value or a prefix of another word is no init=
    try t.expectEqualStrings("rd.init=x initcall_debug init=/usr/local/sbin/vh-init\x00", try newCmdline("rd.init=x initcall_debug\x00", .vh_init));
}

test "twin: an unsigned and a signed stock UKI, the gaming twin, the comparison" {
    const d = tmpDir();
    defer _ = vh.runOpts(&.{ "rm", "-rf", d }, .{});
    const cmd = "root=UUID=x ia32_emulation=0 module_blacklist=uhid\x00";
    for ([_]?[]const u8{ null, "SIGNATURE-OF-THE-STOCK-UKI" }) |sig| {
        const stock = testUki(cmd, sig);
        const src = vh.fmt("{s}/stock.efi", .{d});
        vh.writeAtomic(src, stock, 0o644);
        const p = try plan(src, .ia32_on);
        try t.expectEqual(@as(u64, 0), p.delta());
        try t.expectEqual(@as(u64, if (sig) |s| stock.len - s.len else stock.len), p.end);
        try t.expectEqual(@as(usize, 2), p.patches.len); // the certificate table's entry alone
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
    try t.expectError(error.NoIa32Off, plan(bad, .ia32_on));
    vh.writeAtomic(bad, testUki("ia32_emulation=1\x00", null), 0o644);
    try t.expectError(error.Ia32NotOff, plan(bad, .ia32_on));
    vh.writeAtomic(bad, "MZ not a PE image", 0o644);
    try t.expectError(error.NotPe, plan(bad, .ia32_on));
    // a certificate table that claims to end before the file does
    var odd = vh.dupe(testUki("ia32_emulation=0\x00", "SIG"));
    mem.writeInt(u32, odd[0x40 + 24 + 112 + 36 ..][0..4], 1, .little);
    vh.writeAtomic(bad, odd, 0o644);
    try t.expectError(error.BadCertTable, plan(bad, .ia32_on));
}

test "twin: the init twin, in the section's padding and with one more block" {
    const d = tmpDir();
    defer _ = vh.runOpts(&.{ "rm", "-rf", d }, .{});
    // 60 bytes: room for the parameter in the 512-byte section; 500 bytes: one more block
    const short = "root=UUID=x ia32_emulation=0 module_blacklist=uhid ro quiet\x00";
    const filler = repeat("a", 467);
    const long = vh.fmt("root=UUID=x module_blacklist={s} ro\x00", .{filler});
    try t.expectEqual(@as(usize, 500), long.len);
    for ([_][]const u8{ short, long }, 0..) |cmd, n| for ([_]?[]const u8{ null, "SIGNATURE-OF-THE-STOCK-UKI" }) |sig| {
        const stock = testUki(cmd, sig);
        const src = vh.fmt("{s}/stock.efi", .{d});
        vh.writeAtomic(src, stock, 0o644);
        const p = try plan(src, .vh_init);
        const want = vh.fmt("{s} {s}\x00", .{ cmd[0 .. cmd.len - 1], init_param });
        try t.expectEqualStrings(want, p.cmd);
        try t.expectEqual(@as(u64, if (n == 0) 0 else 512), p.delta());
        const dst = vh.fmt("{s}/twin.efi", .{d});
        vh.unlink(dst) catch {};
        try write(src, dst, p);
        const tw = try vh.readFile(dst);
        try t.expectEqual(p.size(), tw.len);
        try t.expect(same(src, dst, p));
        // the headers: the command line's sizes, the later sections moved by the block, the
        // addresses in memory as they were, the certificate table's entry zero
        const ss = sectionsOf(stock);
        const ts = sectionsOf(tw);
        try t.expectEqual(ss.len, ts.len);
        for (ss, ts) |s, x| {
            try t.expectEqualStrings(s.name, x.name);
            try t.expectEqual(s.vma, x.vma);
            if (vh.eql(s.name, ".cmdline")) {
                try t.expectEqual(want.len, x.vsize);
                try t.expectEqual(s.raw + p.delta(), x.raw);
                try t.expectEqual(s.off, x.off);
            } else {
                try t.expectEqual(s.vsize, x.vsize);
                try t.expectEqual(s.raw, x.raw);
                try t.expectEqual(if (s.off > p.cmd_off) s.off + p.delta() else s.off, x.off);
            }
        }
        const h = try headers(tw[0..4096], tw.len);
        try t.expect(h.cert_off == 0 and h.cert_size == 0);
        // every section's bytes: the stock UKI's, the command line's the new line and zeros
        for (ss, ts) |s, x| {
            if (vh.eql(s.name, ".cmdline")) {
                const sec = section(tw, ".cmdline");
                try t.expectEqualStrings(want, sec[0..want.len]);
                for (sec[want.len..]) |c| try t.expectEqual(@as(u8, 0), c);
            } else try t.expectEqualSlices(u8, stock[@intCast(s.off)..@intCast(s.off + s.raw)], tw[@intCast(x.off)..@intCast(x.off + x.raw)]);
        }
        // the headers differ in the patched fields alone (CheckSum aside, which signing sets)
        var diff: usize = 0;
        for (tw[0..@intCast(p.cmd_off)], 0..) |c, k| if (c != stock[k] and !p.ignored(k)) {
            diff += 1;
        };
        // VirtualSize 60 -> 89: one byte; 500 -> 529: two bytes, SizeOfRawData 512 -> 1024 one,
        // .linux's pointer 0x600 -> 0x800 one, .initrd's 0xe00 -> 0x1000 one
        try t.expectEqual(@as(usize, if (n == 0) 1 else 5), diff);
        // the same twin, signed afterwards, is still the twin; a twin of another line is not
        var signed: std.ArrayList(u8) = .empty;
        signed.appendSlice(vh.gpa, tw) catch vh.oom();
        while (signed.items.len % 8 != 0) signed.append(vh.gpa, 0) catch vh.oom();
        const at = signed.items.len;
        signed.appendSlice(vh.gpa, "SIGNATURE-OF-THE-TWIN") catch vh.oom();
        mem.writeInt(u32, signed.items[h.cert_entry..][0..4], @intCast(at), .little);
        mem.writeInt(u32, signed.items[h.cert_entry + 4 ..][0..4], @intCast(signed.items.len - at), .little);
        vh.writeAtomic(dst, signed.items, 0o644);
        try t.expect(same(src, dst, p));
        const other = vh.fmt("{s}/other.efi", .{d});
        vh.writeAtomic(other, testUki(vh.fmt("{s}x\x00", .{cmd[0 .. cmd.len - 1]}), sig), 0o644);
        try t.expect(!same(other, dst, try plan(other, .vh_init)));
        // the gaming twin of the same stock UKI is another file
        if (n == 0) try t.expect(!same(src, dst, try plan(src, .ia32_on)));
    };
    // a command line that names an init= already, and one too long for the kernel
    const bad = vh.fmt("{s}/bad.efi", .{d});
    vh.writeAtomic(bad, testUki("root=UUID=x init=/usr/bin/runit-init\x00", null), 0o644);
    try t.expectError(error.HasInit, plan(bad, .vh_init));
    vh.writeAtomic(bad, testUki(vh.fmt("root=x {s}\x00", .{repeat("b", 2030)}), null), 0o644);
    try t.expectError(error.TooLong, plan(bad, .vh_init));
}
