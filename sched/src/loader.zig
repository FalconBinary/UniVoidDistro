//! sched/src/loader.zig: loads a struct_ops object that Zig built for bpfel-freestanding,
//! with no libbpf, no clang and no C (docs/ROADMAP.md, S, "The loader"):
//!   1. the ELF object and the kernel's BTF (/sys/kernel/btf/vmlinux);
//!   2. BPF_BTF_LOAD of our own BTF (generated from Zig types, btf.Builder);
//!   3. one array map per data section (.rodata frozen and read-only for programs,
//!      .bss/.data mmapped), the maps of the `.maps` section;
//!   4. one program per `struct_ops/MEMBER` section (`struct_ops.s/` loads sleepable):
//!      attach_btf_id = the struct, expected_attach_type = the member index; a call with a
//!      relocation to an undefined symbol becomes a kfunc call (src_reg = 2, imm = the BTF id
//!      from vmlinux); ld_imm64 with a relocation becomes a map fd or a map value pointer;
//!   5. the struct_ops map (BPF_F_LINK) with the `bpf_struct_ops_<type>` value: program fds at
//!      the member offsets that the kernel's BTF gives, the `name` member;
//!   6. BPF_LINK_CREATE: the link fd keeps the scheduler alive.
//! Every kernel-side layout comes from the running kernel's BTF; nothing is hard-coded.
const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;
const vh = @import("vh");
const uapi = @import("bpf_uapi");
const btf = @import("btf");
const elf = @import("elf");

pub const Error = error{Load};

/// which generated BTF type describes a data section (by C name)
pub const SectionType = struct { section: []const u8, type_name: []const u8 };
/// a value written into `.rodata` before it is frozen: the symbol's field, by the generated BTF
pub const Patch = struct { symbol: []const u8, field: []const u8, value: u64 };

pub const Options = struct {
    /// the kernel struct: sched_ext_ops, tcp_congestion_ops
    ops_type: []const u8 = "sched_ext_ops",
    /// the `name` member
    name: []const u8 = "vh_sched",
    own_btf: []const u8,
    section_types: []const SectionType = &.{},
    patches: []const Patch = &.{},
    /// the `flags` member (sched_ext_ops.flags), when not 0
    ops_flags: u64 = 0,
    log_level: u32 = 1,
    verbose: bool = false,
};

pub const Map = struct {
    name: []const u8,
    shndx: u32,
    fd: linux.fd_t,
    /// bytes of a data map, max_entries of a `.maps` map
    size: u32,
    readonly: bool,
    /// a map from the `.maps` section: the offset of its definition there
    is_def: bool = false,
    def_offset: u64 = 0,
    /// the mmap of a .bss/.data map
    mem: []u8 = &.{},
};

pub const Prog = struct {
    func: []const u8,
    member: []const u8,
    member_index: u32,
    shndx: u32,
    sleepable: bool,
    fd: linux.fd_t = -1,
    insn_cnt: u32 = 0,
    /// "processed N insns" from the verifier log
    insn_processed: u32 = 0,
    log: []const u8 = "",
};

pub const Loaded = struct {
    btf_fd: linux.fd_t,
    maps: []Map,
    progs: []Prog,
    ops_map_fd: linux.fd_t,
    link_fd: linux.fd_t,
    vmlinux: btf.Btf,
    ops_type_id: u32,
    value_type_id: u32,
    value_size: u32,

    pub fn map(l: *const Loaded, name: []const u8) ?*Map {
        for (l.maps) |*m| if (vh.eql(m.name, name)) return m;
        return null;
    }
};

/// the map definition in the `.maps` section (sched/bpf/bpf.zig MapDef)
const MapDef = extern struct { type: u32, key_size: u32, value_size: u32, max_entries: u32, flags: u32 };

var log_buf: []u8 = &.{};

fn fail(comptime f: []const u8, args: anytype) Error {
    vh.warn(f, args);
    return error.Load;
}

fn sys(cmd: uapi.Cmd, attr: *uapi.Attr) error{Sys}!usize {
    return uapi.call(cmd, attr);
}

/// a map or program name as the kernel takes it: 15 characters of [A-Za-z0-9_.]
fn objName(s: []const u8) [uapi.obj_name_len]u8 {
    var out: [uapi.obj_name_len]u8 = @splat(0);
    for (s, 0..) |c, i| {
        if (i >= uapi.obj_name_len - 1) break;
        out[i] = if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') c else '_';
    }
    return out;
}

fn pageSize() usize {
    const p = linux.getauxval(6); // AT_PAGESZ
    return if (p == 0) 4096 else p;
}

fn mapBySection(maps: []Map, shndx: u32) ?*Map {
    for (maps) |*m| if (m.shndx == shndx and !m.is_def) return m;
    return null;
}

fn mapByDef(maps: []Map, shndx: u32, offset: u64) ?*Map {
    for (maps) |*m| if (m.is_def and m.shndx == shndx and m.def_offset == offset) return m;
    return null;
}

pub fn load(obj_data: []const u8, vmlinux_data: []const u8, opts: Options) Error!Loaded {
    const o = elf.Object.parse(obj_data) catch |e| return fail("object: {s}", .{@errorName(e)});
    if (o.hdr.machine != elf.EM_BPF or o.hdr.type != elf.ET_REL) return fail("object: not a relocatable BPF object (machine {d})", .{o.hdr.machine});
    const vm = btf.Btf.parse(vh.gpa, vmlinux_data) catch |e| return fail("kernel BTF: {s}", .{@errorName(e)});
    const own = btf.Btf.parse(vh.gpa, opts.own_btf) catch |e| return fail("generated BTF: {s}", .{@errorName(e)});
    if (opts.verbose) vh.log("kernel BTF: {d} types; generated BTF: {d} types, {d} bytes", .{ vm.count(), own.count(), opts.own_btf.len });

    // the kernel side of the struct_ops
    const ops_type_id = vm.find(.@"struct", opts.ops_type) orelse return fail("struct {s} is not in the kernel's BTF", .{opts.ops_type});
    const value_name = vh.fmt("bpf_struct_ops_{s}", .{opts.ops_type});
    const value_type_id = vm.find(.@"struct", value_name) orelse return fail("struct {s} is not in the kernel's BTF: this kernel has no struct_ops of that type", .{value_name});
    const data_m = vm.member(value_type_id, "data") orelse return fail("struct {s} has no member data", .{value_name});
    const value_size = vm.size(value_type_id);
    const data_off = data_m.bit_offset / 8;
    if (opts.verbose) vh.log("struct {s}: BTF id {d}, {d} members; struct {s}: id {d}, {d} bytes, data at {d}", .{ opts.ops_type, ops_type_id, vm.members(ops_type_id).len, value_name, value_type_id, value_size, data_off });

    // our BTF
    const btf_fd = try btfLoad(opts.own_btf, opts.verbose);

    // the data sections as array maps
    var maps: std.ArrayList(Map) = .empty;
    for (o.shdrs, 0..) |sh, i| {
        const idx: u32 = @intCast(i);
        if (sh.flags & elf.SHF_ALLOC == 0 or sh.flags & elf.SHF_EXECINSTR != 0) continue;
        if (sh.type != elf.SHT_PROGBITS and sh.type != elf.SHT_NOBITS) continue;
        const name = o.sectionName(idx);
        if (sh.size == 0 or vh.eql(name, "license") or vh.eql(name, ".maps") or vh.startsWith(name, ".eh_frame") or vh.startsWith(name, ".BTF")) continue;
        const readonly = vh.startsWith(name, ".rodata");
        const size: u32 = @intCast(sh.size);
        var key_id: u32 = 0;
        var val_id: u32 = 0;
        for (opts.section_types) |st| {
            if (!vh.eql(st.section, name)) continue;
            const id = own.find(.@"struct", st.type_name) orelse return fail("generated BTF has no struct {s}", .{st.type_name});
            if (own.size(id) != size) {
                vh.warn("section {s} has {d} bytes, but struct {s} has {d}: no BTF for this map", .{ name, size, st.type_name, own.size(id) });
                continue;
            }
            val_id = id;
            key_id = own.find(.int, "unsigned int") orelse return fail("generated BTF has no unsigned int for the key", .{});
        }
        var attr = uapi.Attr.zero;
        attr.map_create.map_type = @intFromEnum(uapi.MapType.array);
        attr.map_create.key_size = 4;
        attr.map_create.value_size = size;
        attr.map_create.max_entries = 1;
        attr.map_create.map_flags = if (readonly) uapi.F_RDONLY_PROG else uapi.F_MMAPABLE;
        attr.map_create.map_name = objName(name);
        if (val_id != 0) {
            attr.map_create.btf_fd = @intCast(btf_fd);
            attr.map_create.btf_key_type_id = key_id;
            attr.map_create.btf_value_type_id = val_id;
        }
        const fd: linux.fd_t = @intCast(sys(.map_create, &attr) catch return fail("map {s}: BPF_MAP_CREATE: {s}", .{ name, @tagName(uapi.errno) }));
        const data = vh.gpa.alloc(u8, size) catch vh.oom();
        @memset(data, 0);
        if (sh.type == elf.SHT_PROGBITS) @memcpy(data, o.sectionData(idx));
        if (readonly) try applyPatches(o, own, opts, idx, name, data);
        var key: u32 = 0;
        attr = uapi.Attr.zero;
        attr.elem = .{ .map_fd = @intCast(fd), .key = @intFromPtr(&key), .value = @intFromPtr(data.ptr), .flags = 0 };
        _ = sys(.map_update_elem, &attr) catch return fail("map {s}: BPF_MAP_UPDATE_ELEM: {s}", .{ name, @tagName(uapi.errno) });
        var m: Map = .{ .name = name, .shndx = idx, .fd = fd, .size = size, .readonly = readonly };
        if (readonly) {
            attr = uapi.Attr.zero;
            attr.elem.map_fd = @intCast(fd);
            _ = sys(.map_freeze, &attr) catch return fail("map {s}: BPF_MAP_FREEZE: {s}", .{ name, @tagName(uapi.errno) });
        } else {
            const len = mem.alignForward(usize, size, pageSize());
            const p = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
            if (linux.errno(p) != .SUCCESS) return fail("map {s}: mmap: {s}", .{ name, @tagName(linux.errno(p)) });
            m.mem = @as([*]u8, @ptrFromInt(p))[0..size];
        }
        if (opts.verbose) vh.log("map {s}: fd {d}, {d} bytes, {s}{s}", .{ name, fd, size, if (readonly) "read-only, frozen" else "mmapped", if (val_id != 0) ", with BTF" else "" });
        maps.append(vh.gpa, m) catch vh.oom();
    }

    // the map definitions
    if (o.findSection(".maps")) |mi| {
        const data = o.sectionData(mi);
        for (o.symtab) |s| {
            if (s.shndx != mi or s.kind() != elf.STT_OBJECT) continue;
            if (s.value + @sizeOf(MapDef) > data.len) return fail("map {s}: definition outside .maps", .{o.symName(s)});
            const def = mem.bytesToValue(MapDef, data[s.value..][0..@sizeOf(MapDef)]);
            var attr = uapi.Attr.zero;
            attr.map_create.map_type = def.type;
            attr.map_create.key_size = def.key_size;
            attr.map_create.value_size = def.value_size;
            attr.map_create.max_entries = def.max_entries;
            attr.map_create.map_flags = def.flags;
            attr.map_create.map_name = objName(o.symName(s));
            const fd: linux.fd_t = @intCast(sys(.map_create, &attr) catch return fail("map {s}: BPF_MAP_CREATE (type {d}): {s}", .{ o.symName(s), def.type, @tagName(uapi.errno) }));
            if (opts.verbose) vh.log("map {s}: fd {d}, type {d}, {d} entries", .{ o.symName(s), fd, def.type, def.max_entries });
            maps.append(vh.gpa, .{ .name = o.symName(s), .shndx = mi, .fd = fd, .size = def.max_entries, .readonly = false, .is_def = true, .def_offset = s.value }) catch vh.oom();
        }
    }

    // the programs
    var progs: std.ArrayList(Prog) = .empty;
    for (o.shdrs, 0..) |sh, i| {
        const idx: u32 = @intCast(i);
        if (sh.type != elf.SHT_PROGBITS or sh.flags & elf.SHF_EXECINSTR == 0 or sh.size == 0) continue;
        const name = o.sectionName(idx);
        var sleepable = false;
        var member: []const u8 = "";
        if (vh.startsWith(name, "struct_ops/")) {
            member = name["struct_ops/".len..];
        } else if (vh.startsWith(name, "struct_ops.s/")) {
            member = name["struct_ops.s/".len..];
            sleepable = true;
        } else return fail("section {s}: code outside a struct_ops/ section (a function that was not inlined?)", .{name});
        const fsym = o.symbolAt(idx, 0, elf.STT_FUNC) orelse return fail("section {s}: no function at offset 0", .{name});
        const mi = vm.member(ops_type_id, member) orelse return fail("section {s}: struct {s} has no member {s}", .{ name, opts.ops_type, member });
        if (!vm.isFuncPtr(mi.type)) return fail("section {s}: member {s} is not a function pointer", .{ name, member });
        var p: Prog = .{ .func = o.symName(fsym), .member = member, .member_index = mi.index, .shndx = idx, .sleepable = sleepable };
        try relocateAndLoad(&p, o, vm, maps.items, ops_type_id, opts);
        progs.append(vh.gpa, p) catch vh.oom();
    }
    if (progs.items.len == 0) return fail("no struct_ops/ section in the object", .{});

    // the struct_ops map and its value
    var attr = uapi.Attr.zero;
    attr.map_create.map_type = @intFromEnum(uapi.MapType.struct_ops);
    attr.map_create.key_size = 4;
    attr.map_create.value_size = value_size;
    attr.map_create.max_entries = 1;
    attr.map_create.map_flags = uapi.F_LINK;
    attr.map_create.btf_fd = @intCast(btf_fd);
    attr.map_create.btf_vmlinux_value_type_id = value_type_id;
    attr.map_create.map_name = objName(opts.name);
    const ops_map_fd: linux.fd_t = @intCast(sys(.map_create, &attr) catch return fail("struct_ops map: BPF_MAP_CREATE: {s}", .{@tagName(uapi.errno)}));
    const value = vh.gpa.alloc(u8, value_size) catch vh.oom();
    @memset(value, 0);
    for (progs.items) |p| {
        const mi = vm.member(ops_type_id, p.member).?;
        const off = data_off + mi.bit_offset / 8;
        mem.writeInt(u64, value[off..][0..8], @intCast(p.fd), .little);
    }
    if (vm.member(ops_type_id, "name")) |nm| {
        const sz = vm.size(nm.type);
        if (sz < 2) return fail("member name of {s} is {d} bytes", .{ opts.ops_type, sz });
        const n = @min(opts.name.len, sz - 1);
        const off = data_off + nm.bit_offset / 8;
        @memcpy(value[off .. off + n], opts.name[0..n]);
    }
    if (opts.ops_flags != 0) {
        const fm = vm.member(ops_type_id, "flags") orelse return fail("struct {s} has no member flags", .{opts.ops_type});
        const off = data_off + fm.bit_offset / 8;
        mem.writeInt(u64, value[off..][0..8], opts.ops_flags, .little);
    }
    var key: u32 = 0;
    attr = uapi.Attr.zero;
    attr.elem = .{ .map_fd = @intCast(ops_map_fd), .key = @intFromPtr(&key), .value = @intFromPtr(value.ptr), .flags = 0 };
    _ = sys(.map_update_elem, &attr) catch return fail("struct_ops value: BPF_MAP_UPDATE_ELEM: {s}", .{@tagName(uapi.errno)});
    if (opts.verbose) vh.log("struct_ops map: fd {d}, value {d} bytes, {d} programs", .{ ops_map_fd, value_size, progs.items.len });

    // the link: this is where the kernel calls ops.init and switches the scheduler
    attr = uapi.Attr.zero;
    attr.link_create = .{ .prog_fd = @intCast(ops_map_fd), .target_fd = 0, .attach_type = uapi.attach_struct_ops, .flags = 0, .target_btf_id = 0 };
    const link_fd: linux.fd_t = @intCast(sys(.link_create, &attr) catch return fail("BPF_LINK_CREATE: {s} (the kernel refused to enable the struct_ops; dmesg has the reason)", .{@tagName(uapi.errno)}));

    return .{
        .btf_fd = btf_fd,
        .maps = maps.items,
        .progs = progs.items,
        .ops_map_fd = ops_map_fd,
        .link_fd = link_fd,
        .vmlinux = vm,
        .ops_type_id = ops_type_id,
        .value_type_id = value_type_id,
        .value_size = value_size,
    };
}

fn btfLoad(blob: []const u8, verbose: bool) Error!linux.fd_t {
    var blog: [16384]u8 = undefined;
    var attr = uapi.Attr.zero;
    attr.btf_load = .{ .btf = @intFromPtr(blob.ptr), .btf_log_buf = @intFromPtr(&blog), .btf_size = @intCast(blob.len), .btf_log_size = blog.len, .btf_log_level = 1, .btf_log_true_size = 0, .btf_flags = 0, .btf_token_fd = 0 };
    const rc = sys(.btf_load, &attr) catch {
        vh.warn("BPF_BTF_LOAD: {s}", .{@tagName(uapi.errno)});
        const n = @min(attr.btf_load.btf_log_true_size, blog.len);
        if (n > 0) vh.writeAllFd(2, blog[0..n]) catch {};
        return error.Load;
    };
    if (verbose) vh.log("BPF_BTF_LOAD: fd {d}", .{rc});
    return @intCast(rc);
}

fn applyPatches(o: elf.Object, own: btf.Btf, opts: Options, shndx: u32, section: []const u8, data: []u8) Error!void {
    for (opts.patches) |pt| {
        for (o.symtab) |s| {
            if (s.shndx != shndx or s.kind() != elf.STT_OBJECT or !vh.eql(o.symName(s), pt.symbol)) continue;
            var type_name: []const u8 = "";
            for (opts.section_types) |st| if (vh.eql(st.section, section)) {
                type_name = st.type_name;
            };
            if (type_name.len == 0) return fail("--set {s}.{s}: section {s} has no BTF type", .{ pt.symbol, pt.field, section });
            const tid = own.find(.@"struct", type_name).?;
            const m = own.member(tid, pt.field) orelse return fail("--set {s}.{s}: struct {s} has no field {s}", .{ pt.symbol, pt.field, type_name, pt.field });
            const off = s.value + m.bit_offset / 8;
            const sz = own.size(m.type);
            if (off + sz > data.len) return fail("--set {s}.{s}: outside the section", .{ pt.symbol, pt.field });
            switch (sz) {
                1 => data[off] = @intCast(pt.value),
                2 => mem.writeInt(u16, data[off..][0..2], @intCast(pt.value), .little),
                4 => mem.writeInt(u32, data[off..][0..4], @intCast(pt.value), .little),
                8 => mem.writeInt(u64, data[off..][0..8], pt.value, .little),
                else => return fail("--set {s}.{s}: a field of {d} bytes", .{ pt.symbol, pt.field, sz }),
            }
            if (opts.verbose) vh.log("set {s}.{s} = {d} ({d} bytes at {s}+{d})", .{ pt.symbol, pt.field, pt.value, sz, section, off });
        }
    }
}

fn relocateAndLoad(p: *Prog, o: elf.Object, vm: btf.Btf, maps: []Map, ops_type_id: u32, opts: Options) Error!void {
    const code = o.sectionData(p.shndx);
    if (code.len % @sizeOf(uapi.Insn) != 0) return fail("{s}: {d} bytes is not a whole number of instructions", .{ p.func, code.len });
    const n = code.len / @sizeOf(uapi.Insn);
    const insns = vh.gpa.alloc(uapi.Insn, n) catch vh.oom();
    @memcpy(mem.sliceAsBytes(insns), code);
    for (o.relocs(p.shndx)) |r| {
        if (r.offset % 8 != 0 or r.offset / 8 >= n) return fail("{s}: relocation at byte {d}", .{ p.func, r.offset });
        const i: usize = @intCast(r.offset / 8);
        if (r.sym() >= o.symtab.len) return fail("{s}: relocation with symbol {d}", .{ p.func, r.sym() });
        const s = o.symtab[r.sym()];
        const sname = o.symName(s);
        switch (r.kind()) {
            elf.R_BPF_64_64 => {
                if (insns[i].code != uapi.OP_LD_IMM64 or i + 1 >= n) return fail("{s}: insn {d}: a 64-bit relocation that is not on ld_imm64", .{ p.func, i });
                const addend: u64 = @as(u64, @as(u32, @bitCast(insns[i].imm))) | (@as(u64, @as(u32, @bitCast(insns[i + 1].imm))) << 32);
                const target = s.value + addend;
                if (mapByDef(maps, s.shndx, target)) |dm| {
                    insns[i].setSrc(uapi.PSEUDO_MAP_FD);
                    insns[i].imm = dm.fd;
                    insns[i + 1].imm = 0;
                    if (opts.verbose) vh.log("{s}: insn {d}: map {s} (fd {d})", .{ p.func, i, dm.name, dm.fd });
                } else if (mapBySection(maps, s.shndx)) |m| {
                    if (target >= m.size) return fail("{s}: insn {d}: offset {d} outside section {s}", .{ p.func, i, target, m.name });
                    insns[i].setSrc(uapi.PSEUDO_MAP_VALUE);
                    insns[i].imm = m.fd;
                    insns[i + 1].imm = @intCast(target);
                    if (opts.verbose) vh.log("{s}: insn {d}: {s}+{d} (map fd {d})", .{ p.func, i, m.name, target, m.fd });
                } else return fail("{s}: insn {d}: relocation against {s} (section {d}), which is not a map", .{ p.func, i, sname, s.shndx });
            },
            elf.R_BPF_64_32 => {
                if (insns[i].code != uapi.OP_CALL) return fail("{s}: insn {d}: a 32-bit relocation that is not on a call", .{ p.func, i });
                if (s.shndx != elf.SHN_UNDEF) return fail("{s}: insn {d}: a bpf-to-bpf call to {s}; helpers must be inline fn", .{ p.func, i, sname });
                if (vh.eql(sname, "__bpf_trap")) return fail("{s}: insn {d}: a panic or unreachable path calls __bpf_trap; the verifier rejects it when reachable", .{ p.func, i });
                const id = vm.find(.func, sname) orelse return fail("{s}: insn {d}: kfunc {s} is not in the kernel's BTF", .{ p.func, i, sname });
                insns[i].setSrc(uapi.PSEUDO_KFUNC_CALL);
                insns[i].imm = @intCast(id);
                insns[i].off = 0;
                if (opts.verbose) vh.log("{s}: insn {d}: kfunc {s} (BTF id {d})", .{ p.func, i, sname, id });
            },
            else => return fail("{s}: insn {d}: relocation type {d}", .{ p.func, i, r.kind() }),
        }
    }
    if (log_buf.len == 0) log_buf = vh.gpa.alloc(u8, 4 << 20) catch vh.oom();
    var attr = uapi.Attr.zero;
    attr.prog_load.prog_type = @intFromEnum(uapi.ProgType.struct_ops);
    attr.prog_load.insn_cnt = @intCast(n);
    attr.prog_load.insns = @intFromPtr(insns.ptr);
    attr.prog_load.license = @intFromPtr("GPL");
    attr.prog_load.log_level = opts.log_level;
    attr.prog_load.log_size = @intCast(log_buf.len);
    attr.prog_load.log_buf = @intFromPtr(log_buf.ptr);
    attr.prog_load.prog_flags = if (p.sleepable) uapi.F_SLEEPABLE else 0;
    attr.prog_load.prog_name = objName(p.func);
    attr.prog_load.expected_attach_type = p.member_index;
    attr.prog_load.attach_btf_id = ops_type_id;
    const rc = sys(.prog_load, &attr);
    var ln: usize = @min(attr.prog_load.log_true_size, log_buf.len);
    // the kernel rewinds the log to 0 on success unless level 2 is set (do_check_common,
    // pop_log): then only the "processed" line is current and stale text follows its NUL
    if (mem.indexOfScalar(u8, log_buf[0..ln], 0)) |z| ln = z;
    p.log = vh.dupe(log_buf[0..ln]);
    p.insn_cnt = @intCast(n);
    const fd = rc catch {
        vh.warn("{s} ({s}, member {d}{s}): BPF_PROG_LOAD: {s}", .{ p.func, p.member, p.member_index, if (p.sleepable) ", sleepable" else "", @tagName(uapi.errno) });
        vh.writeAllFd(2, p.log) catch {};
        vh.writeAllFd(2, "\n") catch {};
        return error.Load;
    };
    p.fd = @intCast(fd);
    p.insn_processed = parseProcessed(p.log);
    if (opts.verbose) vh.log("{s} ({s}, member {d}{s}): fd {d}, {d} insns, {d} processed", .{ p.func, p.member, p.member_index, if (p.sleepable) ", sleepable" else "", p.fd, p.insn_cnt, p.insn_processed });
}

/// "processed 12 insns (limit 1000000) ..." from the end of the verifier log
pub fn parseProcessed(log: []const u8) u32 {
    const key = "processed ";
    var pos: usize = 0;
    var last: ?u32 = null;
    while (mem.indexOfPos(u8, log, pos, key)) |i| {
        pos = i + key.len;
        var v: u32 = 0;
        var j = pos;
        while (j < log.len and std.ascii.isDigit(log[j])) : (j += 1) v = v *% 10 +% (log[j] - '0');
        if (j > pos and vh.startsWith(log[j..], " insns")) last = v;
    }
    return last orelse 0;
}

// ---------------------------------------------------------------- after the load

pub fn linkDetach(link_fd: linux.fd_t) error{Sys}!void {
    var attr = uapi.Attr.zero;
    attr.link_detach.link_fd = @intCast(link_fd);
    _ = try sys(.link_detach, &attr);
}

pub fn linkInfo(link_fd: linux.fd_t) error{Sys}!uapi.LinkInfo {
    var info: uapi.LinkInfo = mem.zeroes(uapi.LinkInfo);
    var attr = uapi.Attr.zero;
    attr.info = .{ .bpf_fd = @intCast(link_fd), .info_len = @sizeOf(uapi.LinkInfo), .info = @intFromPtr(&info) };
    _ = try sys(.obj_get_info_by_fd, &attr);
    return info;
}

/// A consumer of a BPF ring buffer map (the kernel's layout: a consumer page, a producer
/// page, the data mapped twice so a record never wraps).
pub const Ringbuf = struct {
    fd: linux.fd_t,
    size: usize,
    consumer: *volatile u64,
    producer: *const volatile u64,
    data: [*]const u8,

    pub fn open(fd: linux.fd_t, size: usize) Error!Ringbuf {
        const page = pageSize();
        const c = linux.mmap(null, page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(c) != .SUCCESS) return fail("ringbuf: mmap consumer: {s}", .{@tagName(linux.errno(c))});
        const p = linux.mmap(null, page + 2 * size, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, @intCast(page));
        if (linux.errno(p) != .SUCCESS) return fail("ringbuf: mmap producer: {s}", .{@tagName(linux.errno(p))});
        return .{ .fd = fd, .size = size, .consumer = @ptrFromInt(c), .producer = @ptrFromInt(p), .data = @as([*]const u8, @ptrFromInt(p)) + page };
    }

    /// The next record copied into `out`, or null when the ring is empty.
    pub fn next(r: *Ringbuf, out: []u8) ?[]u8 {
        while (true) {
            const cons = r.consumer.*;
            const prod = @atomicLoad(u64, @volatileCast(r.producer), .acquire);
            if (cons >= prod) return null;
            const at: usize = @intCast(cons & (r.size - 1));
            const hdr: *const u32 = @ptrCast(@alignCast(r.data + at));
            const raw = @atomicLoad(u32, hdr, .acquire);
            if (raw & uapi.RINGBUF_BUSY_BIT != 0) return null;
            const len: usize = raw & ~(uapi.RINGBUF_BUSY_BIT | uapi.RINGBUF_DISCARD_BIT);
            const total = mem.alignForward(usize, len + uapi.RINGBUF_HDR_SZ, 8);
            const n = @min(len, out.len);
            @memcpy(out[0..n], r.data[at + uapi.RINGBUF_HDR_SZ ..][0..n]);
            @atomicStore(u64, @volatileCast(r.consumer), cons + total, .release);
            if (raw & uapi.RINGBUF_DISCARD_BIT != 0) continue;
            return out[0..n];
        }
    }
};

test "processed insns from a verifier log" {
    try std.testing.expectEqual(@as(u32, 42), parseProcessed("...\nprocessed 42 insns (limit 1000000) max_states_per_insn 0\n"));
    try std.testing.expectEqual(@as(u32, 0), parseProcessed("nothing here"));
}
