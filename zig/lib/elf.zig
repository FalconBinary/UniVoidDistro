//! zig/lib/elf.zig: a reader of ELF64 little-endian relocatable objects, enough for the
//! BPF objects that Zig emits (sections, symbols, REL relocations). No allocation: every
//! accessor is a view into the file bytes.
const std = @import("std");
const mem = std.mem;

pub const Error = error{ BadElf, BadSection };

pub const Ehdr = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

pub const Shdr = extern struct {
    name: u32,
    type: u32,
    flags: u64,
    addr: u64,
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
    addralign: u64,
    entsize: u64,
};

pub const Sym = extern struct {
    name: u32,
    info: u8,
    other: u8,
    shndx: u16,
    value: u64,
    size: u64,

    pub fn bind(s: Sym) u8 {
        return s.info >> 4;
    }
    pub fn kind(s: Sym) u8 {
        return s.info & 0xf;
    }
};

pub const Rel = extern struct {
    offset: u64,
    info: u64,

    pub fn sym(r: Rel) u32 {
        return @truncate(r.info >> 32);
    }
    pub fn kind(r: Rel) u32 {
        return @truncate(r.info);
    }
};

pub const EM_BPF = 247;
pub const ET_REL = 1;

pub const SHT_NULL = 0;
pub const SHT_PROGBITS = 1;
pub const SHT_SYMTAB = 2;
pub const SHT_STRTAB = 3;
pub const SHT_RELA = 4;
pub const SHT_NOBITS = 8;
pub const SHT_REL = 9;

pub const SHF_WRITE = 1;
pub const SHF_ALLOC = 2;
pub const SHF_EXECINSTR = 4;
pub const SHF_MERGE = 0x10;
pub const SHF_STRINGS = 0x20;

pub const SHN_UNDEF = 0;
pub const SHN_ABS = 0xfff1;

pub const STB_LOCAL = 0;
pub const STB_GLOBAL = 1;
pub const STB_WEAK = 2;
pub const STT_NOTYPE = 0;
pub const STT_OBJECT = 1;
pub const STT_FUNC = 2;
pub const STT_SECTION = 3;
pub const STT_FILE = 4;

/// relocation types of the BPF target (llvm/BinaryFormat/ELFRelocs/BPF.def)
pub const R_BPF_NONE = 0;
pub const R_BPF_64_64 = 1;
pub const R_BPF_64_ABS64 = 2;
pub const R_BPF_64_ABS32 = 3;
pub const R_BPF_64_NODYLD32 = 4;
pub const R_BPF_64_32 = 10;

pub const Object = struct {
    data: []const u8,
    hdr: Ehdr,
    shdrs: []align(1) const Shdr,
    shstr: []const u8,
    symtab: []align(1) const Sym,
    strtab: []const u8,

    pub fn parse(data: []const u8) Error!Object {
        if (data.len < @sizeOf(Ehdr)) return error.BadElf;
        const hdr = mem.bytesToValue(Ehdr, data[0..@sizeOf(Ehdr)]);
        if (!mem.eql(u8, hdr.ident[0..4], "\x7fELF")) return error.BadElf;
        if (hdr.ident[4] != 2 or hdr.ident[5] != 1) return error.BadElf; // 64-bit, little-endian
        if (hdr.shentsize != @sizeOf(Shdr) or hdr.shnum == 0) return error.BadElf;
        const sh_end = hdr.shoff + @as(u64, hdr.shnum) * @sizeOf(Shdr);
        if (hdr.shoff == 0 or sh_end > data.len) return error.BadElf;
        const shdrs = mem.bytesAsSlice(Shdr, data[hdr.shoff..sh_end]);
        if (hdr.shstrndx >= shdrs.len) return error.BadElf;
        var o: Object = .{ .data = data, .hdr = hdr, .shdrs = shdrs, .shstr = &.{}, .symtab = &.{}, .strtab = &.{} };
        for (shdrs) |sh| {
            if (sh.type == SHT_NOBITS) continue;
            if (sh.offset + sh.size > data.len) return error.BadSection;
        }
        o.shstr = o.sectionData(hdr.shstrndx);
        for (shdrs, 0..) |sh, i| {
            if (sh.type != SHT_SYMTAB) continue;
            if (sh.entsize != @sizeOf(Sym) or sh.link >= shdrs.len) return error.BadSection;
            o.symtab = mem.bytesAsSlice(Sym, o.sectionData(@intCast(i)));
            o.strtab = o.sectionData(sh.link);
            break;
        }
        return o;
    }

    pub fn sectionData(o: Object, i: u32) []const u8 {
        const sh = o.shdrs[i];
        if (sh.type == SHT_NOBITS) return &.{};
        return o.data[sh.offset .. sh.offset + sh.size];
    }

    pub fn sectionName(o: Object, i: u32) []const u8 {
        return strAt(o.shstr, o.shdrs[i].name);
    }

    pub fn symName(o: Object, s: Sym) []const u8 {
        return strAt(o.strtab, s.name);
    }

    pub fn findSection(o: Object, name: []const u8) ?u32 {
        for (o.shdrs, 0..) |_, i| if (mem.eql(u8, o.sectionName(@intCast(i)), name)) return @intCast(i);
        return null;
    }

    /// The REL entries that apply to section `target` (SHT_REL with info == target), or empty.
    pub fn relocs(o: Object, target: u32) []align(1) const Rel {
        for (o.shdrs, 0..) |sh, i| {
            if (sh.type == SHT_REL and sh.info == target and sh.entsize == @sizeOf(Rel))
                return mem.bytesAsSlice(Rel, o.sectionData(@intCast(i)));
        }
        return &.{};
    }

    /// The first symbol defined in section `shndx` at `value` with the given type, or null.
    pub fn symbolAt(o: Object, shndx: u32, value: u64, kind: u8) ?Sym {
        for (o.symtab) |s| if (s.shndx == shndx and s.value == value and s.kind() == kind) return s;
        return null;
    }
};

pub fn strAt(tab: []const u8, off: u32) []const u8 {
    if (off >= tab.len) return "";
    const end = mem.indexOfScalarPos(u8, tab, off, 0) orelse tab.len;
    return tab[off..end];
}

test "header sizes" {
    try std.testing.expectEqual(64, @sizeOf(Ehdr));
    try std.testing.expectEqual(64, @sizeOf(Shdr));
    try std.testing.expectEqual(24, @sizeOf(Sym));
    try std.testing.expectEqual(16, @sizeOf(Rel));
}

test "rejects a non-ELF file" {
    try std.testing.expectError(error.BadElf, Object.parse("not an elf file at all, just bytes that are long enough to pass the size check......"));
}
