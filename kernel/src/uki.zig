//! The binary formats vh-kconf install reads: the x86 boot header of a bzImage and the arm64
//! header of an Image (the release the kernel reports), the sections of a PE image (a UKI:
//! .linux, .initrd, .cmdline) and the names in a newc cpio archive (the early cpio of an
//! initrd). A release's kernel image and a UKI on the ESP are untrusted data: every offset and
//! size is checked before it is used, the ReleaseSafe bounds checks apply on top, and a
//! malformed file is null, never a crash.
const std = @import("std");
const vh = @import("vh");
const linux = std.os.linux;
const mem = std.mem;

fn le16(p: []const u8) u16 {
    return mem.readInt(u16, p[0..2], .little);
}

fn le32(p: []const u8) u32 {
    return mem.readInt(u32, p[0..4], .little);
}

fn le64(p: []const u8) u64 {
    return mem.readInt(u64, p[0..8], .little);
}

/// The release a bzImage reports (uname -r): the first word of the kernel_version string of its
/// setup header (Documentation/arch/x86/boot.rst: "HdrS" at 0x202 and a boot protocol of 2.00 or
/// later at 0x206; kernel_version at 0x20e is the string's offset less 0x200); null without one.
pub fn bzRelease(img: []const u8) ?[]const u8 {
    if (img.len < 0x210 or !mem.eql(u8, img[0x202..0x206], "HdrS")) return null;
    if (le16(img[0x206..]) < 0x0200) return null;
    const off = le16(img[0x20e..]);
    if (off == 0) return null;
    const start = @as(usize, off) + 0x200;
    if (start >= img.len) return null;
    const s = img[start..@min(img.len, start + 256)];
    const end = mem.indexOfAny(u8, s, " \x00") orelse return null;
    if (end == 0) return null;
    for (s[0..end]) |c| if (c < 0x21 or c > 0x7e) return null;
    return s[0..end];
}

/// The 64-byte header of an arm64 kernel Image (Documentation/arch/arm64/booting.rst): two
/// instructions, then text_offset, image_size and flags as little-endian u64, four reserved
/// words, the magic "ARM\x64" at offset 56 and, with CONFIG_EFI_STUB, the offset of a PE
/// header at 60 (the kernel is then a PE image too, "MZ" first: the UKI's stub starts it
/// through that header). The Image is uncompressed: it has no setup header and no version
/// field of its own; its release is in the banner the kernel prints at boot (imageRelease).
pub const ImageHeader = struct {
    text_offset: u64,
    /// the memory the image needs: the file and its BSS, so never less than the file
    image_size: u64,
    flags: u64,
    /// a PE header where the arm64 header points: an EFI stub (CONFIG_EFI_STUB)
    efi: bool,

    /// the page size the kernel was built for (bits 1-2 of the flags); null when unspecified
    pub fn pageSize(h: ImageHeader) ?u32 {
        return switch ((h.flags >> 1) & 3) {
            1 => 4096,
            2 => 16384,
            3 => 65536,
            else => null,
        };
    }

    /// bit 0: a big-endian kernel
    pub fn bigEndian(h: ImageHeader) bool {
        return h.flags & 1 == 1;
    }

    /// bit 3: the image may be loaded anywhere in memory (2 MiB aligned), not at the base of RAM
    pub fn anywhere(h: ImageHeader) bool {
        return h.flags & 8 != 0;
    }
};

/// the arm64 header of an Image; null without the magic
pub fn imageHeader(img: []const u8) ?ImageHeader {
    if (img.len < 64 or !mem.eql(u8, img[56..60], "ARM\x64")) return null;
    return .{
        .text_offset = le64(img[8..]),
        .image_size = le64(img[16..]),
        .flags = le64(img[24..]),
        .efi = img[0] == 'M' and img[1] == 'Z' and sectionTable(img, img.len) != null,
    };
}

/// The release an arm64 Image reports (uname -r): the word after "Linux version " in the
/// kernel's banner, "Linux version REL (user@host) (compiler) #1 SMP ...", the string of
/// /proc/version, which the uncompressed Image carries as it is (the kernel-custom workflow
/// records the same line in BUILD with `strings`). The banner is the first "Linux version "
/// whose word starts with a digit (a version, not the "%s" of a format string) and is
/// followed by " (" and the builder; null without the header or the banner.
pub fn imageRelease(img: []const u8) ?[]const u8 {
    if (imageHeader(img) == null) return null;
    const key = "Linux version ";
    var from: usize = 64;
    while (mem.indexOfPos(u8, img, from, key)) |at| {
        from = at + key.len;
        const s = img[from..@min(img.len, from + 256)];
        const end = mem.indexOfAny(u8, s, " \x00") orelse continue;
        if (end == 0 or end + 2 > s.len or !mem.eql(u8, s[end .. end + 2], " (")) continue;
        var printable = std.ascii.isDigit(s[0]);
        for (s[0..end]) |c| printable = printable and c >= 0x21 and c <= 0x7e;
        if (printable) return s[0..end];
    }
    return null;
}

pub const Section = struct {
    name: []const u8,
    /// the section's bytes: the virtual size where the header gives one (the raw size is
    /// rounded up to the file alignment), else the raw size
    data: []const u8,
};

/// a section header: the name, and where the section's bytes are in the file
const Hdr = struct { name: []const u8, offset: usize, size: usize };

/// the section table of a PE image whose first bytes are `d`, in a file of `file_len` bytes
fn sectionTable(d: []const u8, file_len: usize) ?[]const Hdr {
    if (d.len < 0x40 or d[0] != 'M' or d[1] != 'Z') return null;
    const pe: usize = le32(d[0x3c..]);
    if (pe > d.len or d.len - pe < 24 or !mem.eql(u8, d[pe .. pe + 4], "PE\x00\x00")) return null;
    const nsec: usize = le16(d[pe + 6 ..]);
    const opt: usize = le16(d[pe + 20 ..]);
    if (nsec > 96) return null;
    const table = pe + 24 + opt;
    if (table > d.len or (d.len - table) / 40 < nsec) return null;
    const out = vh.gpa.alloc(Hdr, nsec) catch vh.oom();
    for (0..nsec) |i| {
        const h = d[table + i * 40 ..][0..40];
        const vsize: usize = le32(h[8..]);
        const rsize: usize = le32(h[16..]);
        const rptr: usize = le32(h[20..]);
        if (rptr > file_len or rsize > file_len - rptr) return null;
        out[i] = .{ .name = vh.dupe(mem.sliceTo(h[0..8], 0)), .offset = rptr, .size = if (vsize != 0) @min(vsize, rsize) else rsize };
    }
    return out;
}

/// The sections of a PE image in memory; null when it is not one or a section lies past its end.
pub fn peSections(d: []const u8) ?[]const Section {
    const hdrs = sectionTable(d, d.len) orelse return null;
    const out = vh.gpa.alloc(Section, hdrs.len) catch vh.oom();
    for (hdrs, 0..) |h, i| out[i] = .{ .name = h.name, .data = d[h.offset .. h.offset + h.size] };
    return out;
}

pub fn section(s: []const Section, name: []const u8) ?[]const u8 {
    for (s) |x| if (vh.eql(x.name, name)) return x.data;
    return null;
}

/// One section of a PE file, read from the file without the rest of it (a UKI is tens of MB):
/// null when the file is not a PE image or has no such section; on a read error errno is set.
pub fn fileSection(path: []const u8, name: []const u8) vh.Error!?[]const u8 {
    const fd = try vh.openFd(path, .{ .ACCMODE = .RDONLY }, 0);
    defer vh.close(fd);
    const st = try vh.fstat(fd);
    const head = try pread(fd, 0, @min(st.size, 65536));
    const hdrs = sectionTable(head, st.size) orelse return null;
    for (hdrs) |h| if (vh.eql(h.name, name)) {
        if (h.size > 1 << 20) return null; // a command line or a version, not a payload
        return try pread(fd, h.offset, h.size);
    };
    return null;
}

fn pread(fd: vh.fd_t, off: usize, len: usize) vh.Error![]u8 {
    const buf = vh.gpa.alloc(u8, len) catch vh.oom();
    var got: usize = 0;
    while (got < len) {
        const n = try vh.sysRetry(linux.pread, .{ fd, buf[got..].ptr, len - got, @as(i64, @intCast(off + got)) });
        if (n == 0) break;
        got += n;
    }
    return buf[0..got];
}

/// The names in the newc cpio archive at the start of `b`, up to its TRAILER!!! (the early cpio
/// of an initrd, where dracut puts the CPU's microcode); empty when `b` does not start with one.
pub fn cpioNames(b: []const u8) []const []const u8 {
    var out: vh.Strv = .{};
    var off: usize = 0;
    while (b.len - off >= 110 and (mem.eql(u8, b[off .. off + 6], "070701") or mem.eql(u8, b[off .. off + 6], "070702"))) {
        const fsize = hex8(b[off + 54 ..]) orelse break;
        const nsize = hex8(b[off + 94 ..]) orelse break;
        const name_off = off + 110;
        if (nsize == 0 or nsize > b.len - name_off) break;
        const name = mem.sliceTo(b[name_off .. name_off + nsize - 1], 0);
        if (vh.eql(name, "TRAILER!!!")) break;
        out.add(name);
        const body = mem.alignForward(usize, name_off + nsize, 4);
        if (body > b.len or fsize > b.len - body) break;
        off = mem.alignForward(usize, body + fsize, 4);
        if (off > b.len) break;
    }
    return out.slice();
}

fn hex8(p: []const u8) ?usize {
    if (p.len < 8) return null;
    return std.fmt.parseInt(u32, p[0..8], 16) catch null;
}

// ---------------------------------------------------------------- tests

/// a bzImage as far as the setup header goes, reporting `version`
pub fn testBzImage(version: []const u8, payload: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    b.appendNTimes(vh.gpa, 0, 0x400) catch vh.oom();
    b.items[0] = 'M';
    b.items[1] = 'Z';
    @memcpy(b.items[0x202..0x206], "HdrS");
    mem.writeInt(u16, b.items[0x206..0x208], 0x020f, .little);
    mem.writeInt(u16, b.items[0x20e..0x210], 0x0200, .little);
    b.appendSlice(vh.gpa, version) catch vh.oom();
    b.appendSlice(vh.gpa, " (vh@ci) #1 SMP PREEMPT_DYNAMIC\x00") catch vh.oom();
    b.appendSlice(vh.gpa, payload) catch vh.oom();
    return b.items;
}

/// an arm64 Image as far as its header and banner go, reporting `version`: the 64-byte header
/// (little-endian, 4 KiB pages, loadable anywhere) with the PE header of an EFI stub where it
/// points, the banner among the strings, then `payload`
pub fn testImage(version: []const u8, payload: []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    b.appendNTimes(vh.gpa, 0, 64 + 24) catch vh.oom();
    b.items[0] = 'M';
    b.items[1] = 'Z';
    mem.writeInt(u64, b.items[24..32], 0b1010, .little);
    @memcpy(b.items[56..60], "ARM\x64");
    mem.writeInt(u32, b.items[60..64], 64, .little);
    @memcpy(b.items[64..68], "PE\x00\x00");
    b.appendSlice(vh.gpa, "Linux version %s (\x00Decompressing\x00") catch vh.oom();
    b.appendSlice(vh.gpa, "Linux version ") catch vh.oom();
    b.appendSlice(vh.gpa, version) catch vh.oom();
    b.appendSlice(vh.gpa, " (vh@ci) (clang version 18.1.3) #1 SMP PREEMPT_DYNAMIC Tue Oct 28 00:00:00 UTC 2026\n\x00") catch vh.oom();
    b.appendSlice(vh.gpa, payload) catch vh.oom();
    mem.writeInt(u64, b.items[16..24], @as(u64, b.items.len) + 4096, .little);
    return b.items;
}

/// a PE image with these sections, as objcopy lays them out (each at a 512-byte boundary)
pub fn testPe(sections: []const [2][]const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    b.appendNTimes(vh.gpa, 0, 0x40 + 24 + 40 * sections.len) catch vh.oom();
    b.items[0] = 'M';
    b.items[1] = 'Z';
    mem.writeInt(u32, b.items[0x3c..0x40], 0x40, .little);
    @memcpy(b.items[0x40..0x44], "PE\x00\x00");
    mem.writeInt(u16, b.items[0x46..0x48], @intCast(sections.len), .little);
    for (sections, 0..) |s, i| {
        while (b.items.len % 512 != 0) b.append(vh.gpa, 0) catch vh.oom();
        const at = b.items.len;
        b.appendSlice(vh.gpa, s[1]) catch vh.oom();
        while (b.items.len % 512 != 0) b.append(vh.gpa, 0) catch vh.oom();
        const h = b.items[0x58 + i * 40 ..][0..40];
        @memcpy(h[0..s[0].len], s[0]);
        mem.writeInt(u32, h[8..12], @intCast(s[1].len), .little);
        mem.writeInt(u32, h[16..20], @intCast(b.items.len - at), .little);
        mem.writeInt(u32, h[20..24], @intCast(at), .little);
    }
    return b.items;
}

/// a newc cpio archive of these files (the early cpio of an initrd)
pub fn testCpio(names: []const []const u8) []const u8 {
    var b: std.ArrayList(u8) = .empty;
    const all = vh.gpa.alloc([]const u8, names.len + 1) catch vh.oom();
    @memcpy(all[0..names.len], names);
    all[names.len] = "TRAILER!!!";
    for (all, 0..) |n, i| {
        const body = if (i < names.len) "data" else "";
        b.print(vh.gpa, "070701{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}", .{
            i + 1, @as(u32, if (body.len > 0) 0o100644 else 0), 0, 0, 1, 0, body.len, 0, 0, 0, 0, n.len + 1, 0,
        }) catch vh.oom();
        b.appendSlice(vh.gpa, n) catch vh.oom();
        b.append(vh.gpa, 0) catch vh.oom();
        while (b.items.len % 4 != 0) b.append(vh.gpa, 0) catch vh.oom();
        b.appendSlice(vh.gpa, body) catch vh.oom();
        while (b.items.len % 4 != 0) b.append(vh.gpa, 0) catch vh.oom();
    }
    return b.items;
}

const testing = std.testing;

test "uki: the release of a bzImage" {
    try testing.expectEqualStrings("6.18.57-vh", bzRelease(testBzImage("6.18.57-vh", "kernel")).?);
    var bad = vh.dupe(testBzImage("6.18.57-vh", ""));
    try testing.expect(bzRelease(bad[0..0x300]) == null); // the string is cut off
    bad[0x203] = 'X';
    try testing.expect(bzRelease(bad) == null); // no "HdrS"
    bad = vh.dupe(testBzImage("6.18.57-vh", ""));
    mem.writeInt(u16, bad[0x20e..0x210], 0xfff0, .little);
    try testing.expect(bzRelease(bad) == null); // the offset points past the end
    try testing.expect(bzRelease("short") == null);
    try testing.expect(bzRelease(testBzImage("", "")) == null);
}

test "uki: the header and the release of an arm64 Image" {
    const pad = vh.gpa.alloc(u8, 1200) catch vh.oom();
    @memset(pad, 'k');
    const img = testImage("6.18.59-vh", pad);
    try testing.expectEqualStrings("6.18.59-vh", imageRelease(img).?);
    const h = imageHeader(img).?;
    try testing.expect(h.efi and !h.bigEndian() and h.anywhere());
    try testing.expectEqual(@as(?u32, 4096), h.pageSize());
    try testing.expectEqual(@as(u64, 0), h.text_offset);
    try testing.expect(h.image_size > img.len);
    // the two formats do not pass for each other
    try testing.expect(bzRelease(img) == null);
    try testing.expect(imageHeader(testBzImage("6.18.57-vh", pad)) == null);
    try testing.expect(imageRelease(testBzImage("6.18.57-vh", pad)) == null);
    // cut off before the banner, the magic broken, the banner without a builder, no banner
    try testing.expect(imageHeader(img[0..100]) != null and imageRelease(img[0..100]) == null);
    var bad = vh.dupe(img);
    bad[57] = 'X';
    try testing.expect(imageHeader(bad) == null and imageRelease(bad) == null);
    try testing.expect(imageRelease(testImage("", "")) == null);
    const no_builder = mem.replaceOwned(u8, vh.gpa, img, "6.18.59-vh (vh@ci)", "6.18.59-vh\x00(vh@ci)") catch vh.oom();
    try testing.expect(imageRelease(no_builder) == null);
    // no EFI stub: the arm64 header is there, the PE header is not
    bad = vh.dupe(img);
    bad[0] = 0;
    try testing.expect(!imageHeader(bad).?.efi);
    bad = vh.dupe(img);
    mem.writeInt(u32, bad[60..64], 0xfffffff0, .little);
    try testing.expect(!imageHeader(bad).?.efi);
    // a big-endian image, no page size given
    bad = vh.dupe(img);
    mem.writeInt(u64, bad[24..32], 1, .little);
    try testing.expect(imageHeader(bad).?.bigEndian() and imageHeader(bad).?.pageSize() == null);
    try testing.expect(imageHeader("short") == null);
}

test "uki: PE sections, in memory and from a file" {
    const pe = testPe(&.{ .{ ".cmdline", " root=UUID=x ro \x00" }, .{ ".linux", "KERNEL" }, .{ ".initrd", "INITRD" } });
    const s = peSections(pe).?;
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqualStrings(" root=UUID=x ro \x00", section(s, ".cmdline").?);
    try testing.expectEqualStrings("KERNEL", section(s, ".linux").?);
    try testing.expect(section(s, ".osrel") == null);
    // a section past the end, a section table past the end, not a PE image
    var cut = vh.dupe(pe);
    try testing.expect(peSections(cut[0 .. cut.len - 600]) == null);
    try testing.expect(peSections(cut[0..0x60]) == null);
    cut[0] = 'X';
    try testing.expect(peSections(cut) == null);
    const dir = vh.fmt("/tmp/vh-kconf-uki-{d}", .{linux.getpid()});
    vh.mkdirs(dir, 0o755);
    defer _ = vh.runOpts(&.{ "rm", "-rf", dir }, .{});
    const f = vh.fmt("{s}/linux.efi", .{dir});
    vh.writeAtomic(f, pe, 0o644);
    try testing.expectEqualStrings(" root=UUID=x ro \x00", (try fileSection(f, ".cmdline")).?);
    try testing.expect((try fileSection(f, ".splash")) == null);
    try testing.expectError(error.Sys, fileSection(vh.fmt("{s}/missing.efi", .{dir}), ".cmdline"));
}

test "uki: the names of an early cpio" {
    const early = testCpio(&.{ "kernel", "kernel/x86", "kernel/x86/microcode", "kernel/x86/microcode/CPU.bin" });
    const n = cpioNames(vh.fmt("{s}\x28\xb5\x2f\xfdmain", .{early}));
    try testing.expectEqual(@as(usize, 4), n.len);
    try testing.expectEqualStrings("kernel/x86/microcode/CPU.bin", n[3]);
    try testing.expectEqual(@as(usize, 0), cpioNames("\x28\xb5\x2f\xfd").len);
    // a truncated archive stays within bounds
    try testing.expect(cpioNames(early[0..150]).len <= 1);
}
