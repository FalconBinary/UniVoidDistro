//! zig/lib/btf.zig: BTF, the BPF Type Format (include/uapi/linux/btf.h, Linux 6.18).
//! Two halves:
//!   - `Btf`: a reader for the kernel's own BTF (/sys/kernel/btf/vmlinux): find a struct or a
//!     kfunc by name, member offsets and indexes, enum names. Only `parse` allocates (the
//!     table of type offsets).
//!   - `Builder`: an encoder that generates BTF from Zig types with C type names, usable at
//!     compile time. The kernel's BTF for a BPF object does not come from Zig/LLVM (Zig's
//!     BTF has no argument names and non-C type names), it is produced here.
const std = @import("std");
const mem = std.mem;

pub const magic: u16 = 0xeb9f;
pub const version: u8 = 1;

pub const Header = extern struct {
    magic: u16,
    version: u8,
    flags: u8,
    hdr_len: u32,
    /// offsets are relative to the end of the header
    type_off: u32,
    type_len: u32,
    str_off: u32,
    str_len: u32,
};

pub const Kind = enum(u5) {
    unknown = 0,
    int = 1,
    ptr = 2,
    array = 3,
    @"struct" = 4,
    @"union" = 5,
    @"enum" = 6,
    fwd = 7,
    typedef = 8,
    @"volatile" = 9,
    @"const" = 10,
    restrict = 11,
    func = 12,
    func_proto = 13,
    @"var" = 14,
    datasec = 15,
    float = 16,
    decl_tag = 17,
    type_tag = 18,
    enum64 = 19,
    _,
};

pub const Type = extern struct {
    name_off: u32,
    /// bits 0-15 vlen, 24-28 kind, 31 kind_flag
    info: u32,
    /// size for int, enum, struct, union, datasec; a type id for the others
    size_or_type: u32,

    pub fn vlen(t: Type) u16 {
        return @truncate(t.info);
    }
    pub fn kind(t: Type) Kind {
        return @enumFromInt(@as(u5, @truncate(t.info >> 24)));
    }
    pub fn kindFlag(t: Type) bool {
        return (t.info >> 31) != 0;
    }
    pub fn mkInfo(k: Kind, n: u16, kind_flag: bool) u32 {
        return @as(u32, n) | (@as(u32, @intFromEnum(k)) << 24) | (if (kind_flag) @as(u32, 1) << 31 else 0);
    }
};

pub const Member = extern struct {
    name_off: u32,
    type: u32,
    /// bit offset (bitfield size in the high 8 bits when the struct has kind_flag)
    offset: u32,
};
pub const Array = extern struct { type: u32, index_type: u32, nelems: u32 };
pub const Param = extern struct { name_off: u32, type: u32 };
pub const EnumVal = extern struct { name_off: u32, val: i32 };
pub const Enum64Val = extern struct { name_off: u32, val_lo32: u32, val_hi32: u32 };
pub const Var = extern struct { linkage: u32 };
pub const VarSecinfo = extern struct { type: u32, offset: u32, size: u32 };

/// the int encoding, in the high byte of the u32 that follows an INT
pub const INT_SIGNED: u32 = 1 << 24;
pub const INT_CHAR: u32 = 2 << 24;
pub const INT_BOOL: u32 = 4 << 24;

pub const FUNC_STATIC: u16 = 0;
pub const FUNC_GLOBAL: u16 = 1;

pub const Error = error{ BadBtf, OutOfMemory };

/// The size of the data that follows the 12-byte type header.
fn extraSize(t: Type) Error!usize {
    return switch (t.kind()) {
        .int, .@"var", .decl_tag => 4,
        .ptr, .fwd, .typedef, .@"volatile", .@"const", .restrict, .func, .float, .type_tag => 0,
        .array => @sizeOf(Array),
        .@"struct", .@"union" => @as(usize, t.vlen()) * @sizeOf(Member),
        .@"enum" => @as(usize, t.vlen()) * @sizeOf(EnumVal),
        .enum64 => @as(usize, t.vlen()) * @sizeOf(Enum64Val),
        .func_proto => @as(usize, t.vlen()) * @sizeOf(Param),
        .datasec => @as(usize, t.vlen()) * @sizeOf(VarSecinfo),
        else => error.BadBtf,
    };
}

// ---------------------------------------------------------------- reading

pub const MemberInfo = struct { index: u32, bit_offset: u32, type: u32 };

pub const Btf = struct {
    types: []const u8,
    strs: []const u8,
    /// offs[id - 1]: the offset of type `id` in `types`; id 0 is void
    offs: []u32,

    pub fn parse(gpa: mem.Allocator, data: []const u8) Error!Btf {
        if (data.len < @sizeOf(Header)) return error.BadBtf;
        const h = mem.bytesToValue(Header, data[0..@sizeOf(Header)]);
        if (h.magic != magic or h.version != version or h.hdr_len < @sizeOf(Header)) return error.BadBtf;
        const base: usize = h.hdr_len;
        const type_end = base + @as(usize, h.type_off) + h.type_len;
        const str_end = base + @as(usize, h.str_off) + h.str_len;
        if (type_end > data.len or str_end > data.len or h.str_len == 0) return error.BadBtf;
        var b: Btf = .{
            .types = data[base + h.type_off .. type_end],
            .strs = data[base + h.str_off .. str_end],
            .offs = &.{},
        };
        if (b.strs[0] != 0 or b.strs[b.strs.len - 1] != 0) return error.BadBtf;
        var list: std.ArrayList(u32) = .empty;
        var off: usize = 0;
        while (off + @sizeOf(Type) <= b.types.len) {
            const t = mem.bytesToValue(Type, b.types[off..][0..@sizeOf(Type)]);
            const ex = try extraSize(t);
            if (off + @sizeOf(Type) + ex > b.types.len) return error.BadBtf;
            list.append(gpa, @intCast(off)) catch return error.OutOfMemory;
            off += @sizeOf(Type) + ex;
        }
        if (off != b.types.len) return error.BadBtf;
        b.offs = list.toOwnedSlice(gpa) catch return error.OutOfMemory;
        return b;
    }

    pub fn count(b: Btf) u32 {
        return @intCast(b.offs.len);
    }

    pub fn typ(b: Btf, id: u32) Type {
        if (id == 0 or id > b.offs.len) return .{ .name_off = 0, .info = 0, .size_or_type = 0 };
        const off = b.offs[id - 1];
        return mem.bytesToValue(Type, b.types[off..][0..@sizeOf(Type)]);
    }

    pub fn extra(b: Btf, id: u32) []const u8 {
        if (id == 0 or id > b.offs.len) return &.{};
        const off = b.offs[id - 1] + @sizeOf(Type);
        const n = extraSize(b.typ(id)) catch 0;
        return b.types[off .. off + n];
    }

    pub fn str(b: Btf, off: u32) []const u8 {
        if (off >= b.strs.len) return "";
        const end = mem.indexOfScalarPos(u8, b.strs, off, 0) orelse b.strs.len;
        return b.strs[off..end];
    }

    pub fn name(b: Btf, id: u32) []const u8 {
        return b.str(b.typ(id).name_off);
    }

    /// The first type of the kind with this name.
    pub fn find(b: Btf, kind: Kind, n: []const u8) ?u32 {
        var id: u32 = 1;
        while (id <= b.offs.len) : (id += 1) {
            const t = b.typ(id);
            if (t.kind() == kind and mem.eql(u8, b.str(t.name_off), n)) return id;
        }
        return null;
    }

    pub fn members(b: Btf, id: u32) []align(1) const Member {
        const t = b.typ(id);
        if (t.kind() != .@"struct" and t.kind() != .@"union") return &.{};
        return mem.bytesAsSlice(Member, b.extra(id));
    }

    pub fn member(b: Btf, struct_id: u32, n: []const u8) ?MemberInfo {
        const kf = b.typ(struct_id).kindFlag();
        for (b.members(struct_id), 0..) |m, i| {
            if (mem.eql(u8, b.str(m.name_off), n))
                return .{ .index = @intCast(i), .bit_offset = if (kf) m.offset & 0xffffff else m.offset, .type = m.type };
        }
        return null;
    }

    /// Strips typedefs and modifiers.
    pub fn resolve(b: Btf, id: u32) u32 {
        var cur = id;
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            const t = b.typ(cur);
            switch (t.kind()) {
                .typedef, .@"volatile", .@"const", .restrict, .type_tag => cur = t.size_or_type,
                else => return cur,
            }
        }
        return cur;
    }

    pub fn isFuncPtr(b: Btf, id: u32) bool {
        const t = b.typ(b.resolve(id));
        if (t.kind() != .ptr) return false;
        return b.typ(b.resolve(t.size_or_type)).kind() == .func_proto;
    }

    pub fn size(b: Btf, id: u32) u32 {
        const rid = b.resolve(id);
        const t = b.typ(rid);
        return switch (t.kind()) {
            .int, .@"struct", .@"union", .@"enum", .enum64, .float, .datasec => t.size_or_type,
            .ptr => 8,
            .array => blk: {
                const a = mem.bytesToValue(Array, b.extra(rid)[0..@sizeOf(Array)]);
                break :blk a.nelems * b.size(a.type);
            },
            else => 0,
        };
    }

    pub fn enumName(b: Btf, id: u32, val: i64) ?[]const u8 {
        const rid = b.resolve(id);
        const t = b.typ(rid);
        switch (t.kind()) {
            .@"enum" => for (mem.bytesAsSlice(EnumVal, b.extra(rid))) |e| {
                if (@as(i64, e.val) == val) return b.str(e.name_off);
            },
            .enum64 => for (mem.bytesAsSlice(Enum64Val, b.extra(rid))) |e| {
                const v: i64 = @bitCast(@as(u64, e.val_lo32) | (@as(u64, e.val_hi32) << 32));
                if (v == val) return b.str(e.name_off);
            },
            else => {},
        }
        return null;
    }

    pub fn enumValue(b: Btf, id: u32, n: []const u8) ?i64 {
        const rid = b.resolve(id);
        const t = b.typ(rid);
        switch (t.kind()) {
            .@"enum" => for (mem.bytesAsSlice(EnumVal, b.extra(rid))) |e| {
                if (mem.eql(u8, b.str(e.name_off), n)) return e.val;
            },
            .enum64 => for (mem.bytesAsSlice(Enum64Val, b.extra(rid))) |e| {
                if (mem.eql(u8, b.str(e.name_off), n)) return @bitCast(@as(u64, e.val_lo32) | (@as(u64, e.val_hi32) << 32));
            },
            else => {},
        }
        return null;
    }
};

// ---------------------------------------------------------------- generating

/// The C name of a Zig integer or bool type, as clang's BTF names them.
pub fn cName(comptime T: type) []const u8 {
    return switch (T) {
        u8 => "unsigned char",
        i8 => "signed char",
        u16 => "unsigned short",
        i16 => "short",
        u32 => "unsigned int",
        i32 => "int",
        u64 => "unsigned long long",
        i64 => "long long",
        usize => "unsigned long",
        isize => "long",
        bool => "_Bool",
        else => @compileError("btf: no C name for " ++ @typeName(T)),
    };
}

/// The struct's C name: its `c_name` declaration, otherwise the last part of the Zig name.
pub fn structName(comptime T: type) []const u8 {
    if (@hasDecl(T, "c_name")) return T.c_name;
    const full = @typeName(T);
    const i = mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[i + 1 ..];
}

pub const MemberDef = struct { name: []const u8, type: u32, bit_offset: u32 };
pub const ParamDef = struct { name: []const u8, type: u32 };

/// Fixed-capacity BTF encoder; every method works at compile time.
pub const Builder = struct {
    types: [types_cap]u8 = undefined,
    types_len: usize = 0,
    strs: [strs_cap]u8 = @splat(0),
    /// the string section starts with "\0"
    strs_len: usize = 1,
    ntypes: u32 = 0,

    pub const types_cap = 16384;
    pub const strs_cap = 4096;

    fn str(b: *Builder, s: []const u8) u32 {
        if (s.len == 0) return 0;
        // deduplicate: the same name is used by many members
        var off: usize = 1;
        while (off < b.strs_len) {
            const end = mem.indexOfScalarPos(u8, b.strs[0..b.strs_len], off, 0).?;
            if (mem.eql(u8, b.strs[off..end], s)) return @intCast(off);
            off = end + 1;
        }
        if (b.strs_len + s.len + 1 > strs_cap) @panic("btf.Builder: string table full");
        const at = b.strs_len;
        @memcpy(b.strs[at .. at + s.len], s);
        b.strs[at + s.len] = 0;
        b.strs_len += s.len + 1;
        return @intCast(at);
    }

    fn emit(b: *Builder, bytes: []const u8) void {
        if (b.types_len + bytes.len > types_cap) @panic("btf.Builder: type section full");
        @memcpy(b.types[b.types_len .. b.types_len + bytes.len], bytes);
        b.types_len += bytes.len;
    }

    fn header(b: *Builder, n: []const u8, kind: Kind, vlen: u16, kind_flag: bool, size_or_type: u32) u32 {
        const t: Type = .{ .name_off = b.str(n), .info = Type.mkInfo(kind, vlen, kind_flag), .size_or_type = size_or_type };
        b.emit(mem.asBytes(&t));
        b.ntypes += 1;
        return b.ntypes;
    }

    /// The id of an already emitted type of this kind and name.
    pub fn findNamed(b: *const Builder, kind: Kind, n: []const u8) ?u32 {
        var off: usize = 0;
        var id: u32 = 0;
        while (off + @sizeOf(Type) <= b.types_len) {
            id += 1;
            const t = mem.bytesToValue(Type, b.types[off..][0..@sizeOf(Type)]);
            if (t.kind() == kind and t.name_off != 0) {
                const s = b.strs[t.name_off..];
                const end = mem.indexOfScalar(u8, s, 0).?;
                if (mem.eql(u8, s[0..end], n)) return id;
            }
            off += @sizeOf(Type) + (extraSize(t) catch unreachable);
        }
        return null;
    }

    pub fn int(b: *Builder, n: []const u8, sz: u32, encoding: u32) u32 {
        const id = b.header(n, .int, 0, false, sz);
        const data: u32 = encoding | (sz * 8);
        b.emit(mem.asBytes(&data));
        return id;
    }

    pub fn ptr(b: *Builder, to: u32) u32 {
        return b.header("", .ptr, 0, false, to);
    }

    pub fn array(b: *Builder, elem: u32, index: u32, n: u32) u32 {
        const id = b.header("", .array, 0, false, 0);
        const a: Array = .{ .type = elem, .index_type = index, .nelems = n };
        b.emit(mem.asBytes(&a));
        return id;
    }

    pub fn structType(b: *Builder, n: []const u8, sz: u32, defs: []const MemberDef) u32 {
        const id = b.header(n, .@"struct", @intCast(defs.len), false, sz);
        for (defs) |d| {
            const m: Member = .{ .name_off = b.str(d.name), .type = d.type, .offset = d.bit_offset };
            b.emit(mem.asBytes(&m));
        }
        return id;
    }

    pub fn funcProto(b: *Builder, ret: u32, params: []const ParamDef) u32 {
        const id = b.header("", .func_proto, @intCast(params.len), false, ret);
        for (params) |p| {
            const m: Param = .{ .name_off = b.str(p.name), .type = p.type };
            b.emit(mem.asBytes(&m));
        }
        return id;
    }

    pub fn func(b: *Builder, n: []const u8, proto: u32, linkage: u16) u32 {
        return b.header(n, .func, linkage, false, proto);
    }

    /// the index type of arrays, as clang emits it
    fn sizeType(b: *Builder) u32 {
        return b.findNamed(.int, "__ARRAY_SIZE_TYPE__") orelse b.int("__ARRAY_SIZE_TYPE__", 4, 0);
    }

    /// A Zig type as BTF with C names: integers, bool, arrays, extern structs, pointers
    /// (to extern structs or to void), enums (as their integer), opaque (void).
    /// Returns the type id; a type that was already added is reused by name.
    pub fn add(b: *Builder, comptime T: type) u32 {
        switch (@typeInfo(T)) {
            .int => |i| {
                const n = cName(T);
                if (b.findNamed(.int, n)) |id| return id;
                return b.int(n, @sizeOf(T), if (i.signedness == .signed) INT_SIGNED else 0);
            },
            .bool => {
                if (b.findNamed(.int, "_Bool")) |id| return id;
                return b.int("_Bool", 1, INT_BOOL);
            },
            .array => |a| {
                const elem = b.add(a.child);
                const idx = b.sizeType();
                return b.array(elem, idx, a.len);
            },
            .@"struct" => |s| {
                if (s.layout != .@"extern") @compileError("btf: " ++ @typeName(T) ++ " must be an extern struct");
                const n = comptime structName(T);
                if (b.findNamed(.@"struct", n)) |id| return id;
                var ids: [s.field_names.len]u32 = undefined;
                inline for (s.field_types, 0..) |FT, i| ids[i] = b.add(FT);
                var defs: [s.field_names.len]MemberDef = undefined;
                inline for (s.field_names, 0..) |fname, i| defs[i] = .{ .name = fname, .type = ids[i], .bit_offset = @offsetOf(T, fname) * 8 };
                return b.structType(n, @sizeOf(T), &defs);
            },
            .pointer => |p| {
                const target: u32 = switch (@typeInfo(p.child)) {
                    .@"struct" => |s| if (s.layout == .@"extern") (b.findNamed(.@"struct", comptime structName(p.child)) orelse b.add(p.child)) else 0,
                    .int, .bool => b.add(p.child),
                    else => 0,
                };
                return b.ptr(target);
            },
            .optional => |o| return b.add(o.child),
            .@"enum" => |e| return b.add(e.tag_type),
            .@"opaque", .void => return 0,
            else => @compileError("btf: unsupported type " ++ @typeName(T)),
        }
    }

    pub fn size(b: *const Builder) usize {
        return @sizeOf(Header) + b.types_len + b.strs_len;
    }

    /// The BTF blob, for use at run time.
    pub fn write(b: *const Builder, out: []u8) []u8 {
        const h: Header = .{
            .magic = magic,
            .version = version,
            .flags = 0,
            .hdr_len = @sizeOf(Header),
            .type_off = 0,
            .type_len = @intCast(b.types_len),
            .str_off = @intCast(b.types_len),
            .str_len = @intCast(b.strs_len),
        };
        const total = b.size();
        @memcpy(out[0..@sizeOf(Header)], mem.asBytes(&h));
        @memcpy(out[@sizeOf(Header) .. @sizeOf(Header) + b.types_len], b.types[0..b.types_len]);
        @memcpy(out[@sizeOf(Header) + b.types_len .. total], b.strs[0..b.strs_len]);
        return out[0..total];
    }

    /// The BTF blob as a compile-time array: `const blob = comptime b.finish();`
    pub fn finish(comptime b: Builder) [b.size()]u8 {
        var out: [b.size()]u8 = undefined;
        _ = b.write(&out);
        return out;
    }
};

// ---------------------------------------------------------------- tests

const TestRec = extern struct {
    pub const c_name = "vh_test_rec";
    kind: i32,
    code: i64,
    name: [8]u8,
    flag: bool,
};

test "generated BTF parses back with C names" {
    const blob = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var b: Builder = .{};
        _ = b.add(u32);
        _ = b.add(TestRec);
        break :blk b.finish();
    };
    const p = try Btf.parse(std.testing.allocator, &blob);
    defer std.testing.allocator.free(p.offs);
    try std.testing.expect(p.count() >= 6);
    const key = p.find(.int, "unsigned int").?;
    try std.testing.expectEqual(@as(u32, 4), p.size(key));
    const rec = p.find(.@"struct", "vh_test_rec").?;
    try std.testing.expectEqual(@as(u32, @sizeOf(TestRec)), p.size(rec));
    const code = p.member(rec, "code").?;
    try std.testing.expectEqual(@as(u32, 1), code.index);
    try std.testing.expectEqual(@as(u32, 64), code.bit_offset);
    try std.testing.expectEqualStrings("long long", p.name(code.type));
    const nm = p.member(rec, "name").?;
    try std.testing.expectEqual(@as(u32, 8), p.size(nm.type));
    try std.testing.expectEqual(Kind.array, p.typ(nm.type).kind());
    try std.testing.expectEqualStrings("_Bool", p.name(p.member(rec, "flag").?.type));
    // the same struct again is not duplicated
    try std.testing.expectEqual(@as(?u32, null), p.find(.@"struct", "TestRec"));
}

test "rejects a bad header" {
    const pad: [20]u8 = @splat(0);
    try std.testing.expectError(error.BadBtf, Btf.parse(std.testing.allocator, "\x9f\xeb\x02\x00" ++ pad));
}
