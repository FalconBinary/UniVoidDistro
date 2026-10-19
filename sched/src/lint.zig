//! sched/src/lint.zig: the lint of the BPF object (docs/ROADMAP.md, S, "The .o lint in CI"):
//! no u128 (compiler-rt calls), no signed division without -mcpu=v4, no compiler-rt or
//! memcpy calls, no bpf-to-bpf calls (helpers are inline fn), no panic path that reaches
//! __bpf_trap, no legacy packet loads, a stack of at most 512 bytes per program. Prints one
//! line per program with its size, stack, helpers and kfuncs. No kernel needed: it runs on
//! the build machine and in CI.
const std = @import("std");
const vh = @import("vh");
const uapi = @import("bpf_uapi");
const elf = @import("elf");

pub const max_stack = 512;

pub const Report = struct { programs: u32 = 0, errors: u32 = 0, insns: u32 = 0 };

fn isCompilerRt(name: []const u8) bool {
    if (vh.startsWith(name, "__")) return true; // __udivti3, __multi3, __bpf_trap, ...
    const libc = [_][]const u8{ "memcpy", "memset", "memmove", "memcmp", "bcmp", "strlen" };
    for (libc) |l| if (vh.eql(name, l)) return true;
    return false;
}

fn helperName(id: i32) []const u8 {
    const h: uapi.Helper = @enumFromInt(id);
    return switch (h) {
        _ => "?",
        else => @tagName(h),
    };
}

/// Whether register `r` is read before it is written in the instructions that follow
/// (a straight-line approximation: a jump or an exit ends the scan).
fn readsBeforeWrite(insns: []align(1) const uapi.Insn, r: u4) bool {
    var i: usize = 0;
    while (i < insns.len) : (i += 1) {
        const in = insns[i];
        const class = in.code & 7;
        switch (class) {
            uapi.CLASS_ALU, uapi.CLASS_ALU64 => {
                const op = in.code & 0xf0;
                if (in.code & 0x08 == uapi.SRC_X and in.src() == r) return true;
                if (in.dst() == r) return op != uapi.ALU_MOV; // a mov writes without reading
            },
            uapi.CLASS_LDX => {
                if (in.src() == r) return true;
                if (in.dst() == r) return false;
            },
            uapi.CLASS_ST, uapi.CLASS_STX => {
                if (in.dst() == r or (class == uapi.CLASS_STX and in.src() == r)) return true;
            },
            uapi.CLASS_LD => {
                if (in.dst() == r) return false;
                if (in.code == uapi.OP_LD_IMM64) i += 1;
            },
            uapi.CLASS_JMP, uapi.CLASS_JMP32 => {
                if (in.code == uapi.OP_CALL) return r == 1 or r == 2 or r == 3 or r == 4 or r == 5; // arguments are read
                if (in.code == uapi.OP_EXIT) return r == 0;
                if (in.dst() == r or (in.code & 0x08 == uapi.SRC_X and in.src() == r)) return true;
                return false;
            },
            else => {},
        }
    }
    return false;
}

pub fn run(o: elf.Object) Report {
    var rep: Report = .{};
    if (o.hdr.machine != elf.EM_BPF) {
        vh.out("lint: not a BPF object (machine {d})\n", .{o.hdr.machine});
        rep.errors += 1;
        return rep;
    }
    for (o.shdrs, 0..) |sh, si| {
        const idx: u32 = @intCast(si);
        if (sh.type != elf.SHT_PROGBITS or sh.flags & elf.SHF_EXECINSTR == 0) continue;
        const name = o.sectionName(idx);
        if (sh.size == 0) continue;
        const code = o.sectionData(idx);
        const fsym = o.symbolAt(idx, 0, elf.STT_FUNC);
        const func = if (fsym) |s| o.symName(s) else "?";
        if (!vh.startsWith(name, "struct_ops/") and !vh.startsWith(name, "struct_ops.s/")) {
            vh.out("lint: {s}: {s}: code outside a struct_ops section: a function that was not inlined\n", .{ name, func });
            rep.errors += 1;
        }
        rep.programs += 1;
        const insns = std.mem.bytesAsSlice(uapi.Insn, code);
        rep.insns += @intCast(insns.len);
        var stack: u32 = 0;
        var errs: u32 = 0;
        var helpers: [32]i32 = undefined;
        var nh: usize = 0;
        var kfuncs: [32][]const u8 = undefined;
        var nk: usize = 0;
        // the symbols behind the calls
        for (o.relocs(idx)) |r| {
            if (r.sym() >= o.symtab.len) continue;
            const s = o.symtab[r.sym()];
            const sname = o.symName(s);
            if (r.kind() != elf.R_BPF_64_32) continue;
            if (s.shndx != elf.SHN_UNDEF) {
                vh.out("lint: {s}: {s}: bpf-to-bpf call to {s} (helpers must be inline fn)\n", .{ name, func, sname });
                errs += 1;
            } else if (vh.eql(sname, "__bpf_trap")) {
                vh.out("lint: {s}: {s}: a panic or unreachable path reaches __bpf_trap (the verifier rejects it when reachable)\n", .{ name, func });
                errs += 1;
            } else if (isCompilerRt(sname)) {
                vh.out("lint: {s}: {s}: call to {s}: compiler-rt or libc (u128, wide shifts, memcpy of a large struct?)\n", .{ name, func, sname });
                errs += 1;
            } else {
                if (nk < kfuncs.len) {
                    kfuncs[nk] = sname;
                    nk += 1;
                }
            }
        }
        var i: usize = 0;
        var has_exit = false;
        while (i < insns.len) : (i += 1) {
            const in = insns[i];
            const class = in.code & 7;
            switch (class) {
                uapi.CLASS_LD => {
                    const mode = in.code & 0xe0;
                    if (mode == uapi.MODE_ABS or mode == uapi.MODE_IND) {
                        vh.out("lint: {s}: {s}: insn {d}: legacy packet load\n", .{ name, func, i });
                        errs += 1;
                    }
                    if (in.code == uapi.OP_LD_IMM64) i += 1; // two slots
                },
                uapi.CLASS_LDX, uapi.CLASS_ST, uapi.CLASS_STX => {
                    const base: u4 = if (class == uapi.CLASS_LDX) in.src() else in.dst();
                    if (base == 10 and in.off < 0) stack = @max(stack, @as(u32, @intCast(-@as(i32, in.off))));
                    // an atomic without BPF_FETCH leaves the operand register untouched; LLVM
                    // (a .monotonic @atomicRmw) may still read it as the result
                    if (class == uapi.CLASS_STX and in.code & 0xe0 == uapi.MODE_ATOMIC and in.imm & 1 == 0 and readsBeforeWrite(insns[i + 1 ..], in.src())) {
                        vh.out("lint: {s}: {s}: insn {d}: atomic without BPF_FETCH, then r{d} is read as its result (use .seq_cst)\n", .{ name, func, i, in.src() });
                        errs += 1;
                    }
                },
                uapi.CLASS_ALU, uapi.CLASS_ALU64 => {
                    const op = in.code & 0xf0;
                    if ((op == uapi.ALU_DIV or op == uapi.ALU_MOD) and in.off == 1) {
                        vh.out("lint: {s}: {s}: insn {d}: signed division (needs -mcpu=v4)\n", .{ name, func, i });
                        errs += 1;
                    }
                    // rX = r10; rX += -N: a pointer into the frame
                    if (op == uapi.ALU_MOV and in.code & 0x08 == uapi.SRC_X and in.src() == 10 and i + 1 < insns.len) {
                        const nx = insns[i + 1];
                        if ((nx.code & 7) == uapi.CLASS_ALU64 and (nx.code & 0xf0) == uapi.ALU_ADD and nx.code & 0x08 == uapi.SRC_K and nx.dst() == in.dst() and nx.imm < 0)
                            stack = @max(stack, @as(u32, @intCast(-nx.imm)));
                    }
                },
                uapi.CLASS_JMP, uapi.CLASS_JMP32 => {
                    if (in.code == uapi.OP_CALL and in.src() == 0) {
                        if (nh < helpers.len) {
                            helpers[nh] = in.imm;
                            nh += 1;
                        }
                    }
                    if (in.code == uapi.OP_EXIT) has_exit = true;
                },
                else => {},
            }
        }
        if (stack > max_stack) {
            vh.out("lint: {s}: {s}: stack {d} bytes, the limit is {d}\n", .{ name, func, stack, max_stack });
            errs += 1;
        }
        if (!has_exit) {
            vh.out("lint: {s}: {s}: no exit instruction\n", .{ name, func });
            errs += 1;
        }
        vh.out("lint: {s}: {s}: {d} insns, stack {d}, helpers [", .{ name, func, insns.len, stack });
        for (helpers[0..nh], 0..) |h, k| vh.out("{s}{s}", .{ if (k > 0) " " else "", helperName(h) });
        vh.out("], kfuncs [", .{});
        for (kfuncs[0..nk], 0..) |k, j| vh.out("{s}{s}", .{ if (j > 0) " " else "", k });
        vh.out("]{s}\n", .{if (errs > 0) " FAIL" else ""});
        rep.errors += errs;
    }
    // every undefined symbol must be a kfunc (an unexpected one is compiler-rt)
    for (o.symtab) |s| {
        if (s.shndx != elf.SHN_UNDEF or s.name == 0) continue;
        const sname = o.symName(s);
        if (isCompilerRt(sname) and !vh.eql(sname, "__bpf_trap")) {
            vh.out("lint: undefined symbol {s}: compiler-rt or libc\n", .{sname});
            rep.errors += 1;
        }
    }
    if (o.findSection("license") == null) {
        vh.out("lint: no license section\n", .{});
        rep.errors += 1;
    }
    vh.out("lint: {d} programs, {d} insns, {d} errors\n", .{ rep.programs, rep.insns, rep.errors });
    return rep;
}
