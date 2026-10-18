//! zig/lib/bpf_uapi.zig: the BPF system call interface, written down from
//! include/uapi/linux/bpf.h of Linux 6.18.57, only the parts the vh-sched loader uses.
//! std.os.linux.BPF is not used: its ProgLoadAttr ends at attach_btf_id (no fd_array,
//! log_true_size) and misspells it. Every structure here is our own and every offset is
//! checked at compile time against the numbers the 6.18 headers print (sched/tools/uapi_sizes.c
//! in the spike notes; the tests at the end are those numbers).
const std = @import("std");
const linux = std.os.linux;

pub const obj_name_len = 16;
/// sizeof(union bpf_attr) in 6.18
pub const attr_size = 168;

pub const Cmd = enum(u32) {
    map_create = 0,
    map_lookup_elem = 1,
    map_update_elem = 2,
    map_delete_elem = 3,
    map_get_next_key = 4,
    prog_load = 5,
    obj_pin = 6,
    obj_get = 7,
    prog_attach = 8,
    prog_detach = 9,
    prog_test_run = 10,
    prog_get_next_id = 11,
    map_get_next_id = 12,
    prog_get_fd_by_id = 13,
    map_get_fd_by_id = 14,
    obj_get_info_by_fd = 15,
    prog_query = 16,
    raw_tracepoint_open = 17,
    btf_load = 18,
    btf_get_fd_by_id = 19,
    task_fd_query = 20,
    map_lookup_and_delete_elem = 21,
    map_freeze = 22,
    btf_get_next_id = 23,
    map_lookup_batch = 24,
    map_lookup_and_delete_batch = 25,
    map_update_batch = 26,
    map_delete_batch = 27,
    link_create = 28,
    link_update = 29,
    link_get_fd_by_id = 30,
    link_get_next_id = 31,
    enable_stats = 32,
    iter_create = 33,
    link_detach = 34,
    prog_bind_map = 35,
    token_create = 36,
    prog_stream_read_by_fd = 37,
};

pub const MapType = enum(u32) {
    unspec = 0,
    hash = 1,
    array = 2,
    prog_array = 3,
    perf_event_array = 4,
    percpu_hash = 5,
    percpu_array = 6,
    stack_trace = 7,
    cgroup_array = 8,
    lru_hash = 9,
    lru_percpu_hash = 10,
    lpm_trie = 11,
    array_of_maps = 12,
    hash_of_maps = 13,
    devmap = 14,
    sockmap = 15,
    cpumap = 16,
    xskmap = 17,
    sockhash = 18,
    cgroup_storage_deprecated = 19,
    reuseport_sockarray = 20,
    percpu_cgroup_storage_deprecated = 21,
    queue = 22,
    stack = 23,
    sk_storage = 24,
    devmap_hash = 25,
    struct_ops = 26,
    ringbuf = 27,
    inode_storage = 28,
    task_storage = 29,
    bloom_filter = 30,
    user_ringbuf = 31,
    cgrp_storage = 32,
    arena = 33,
    _,
};

pub const ProgType = enum(u32) {
    unspec = 0,
    socket_filter = 1,
    kprobe = 2,
    sched_cls = 3,
    sched_act = 4,
    tracepoint = 5,
    xdp = 6,
    perf_event = 7,
    cgroup_skb = 8,
    cgroup_sock = 9,
    lwt_in = 10,
    lwt_out = 11,
    lwt_xmit = 12,
    sock_ops = 13,
    sk_skb = 14,
    cgroup_device = 15,
    sk_msg = 16,
    raw_tracepoint = 17,
    cgroup_sock_addr = 18,
    lwt_seg6local = 19,
    lirc_mode2 = 20,
    sk_reuseport = 21,
    flow_dissector = 22,
    cgroup_sysctl = 23,
    raw_tracepoint_writable = 24,
    cgroup_sockopt = 25,
    tracing = 26,
    struct_ops = 27,
    ext = 28,
    lsm = 29,
    sk_lookup = 30,
    syscall = 31,
    netfilter = 32,
    _,
};

/// enum bpf_attach_type, the two values the loader uses
pub const attach_trace_fentry: u32 = 24;
pub const attach_struct_ops: u32 = 44;
/// enum bpf_link_type
pub const link_type_struct_ops: u32 = 9;

// BPF_PROG_LOAD prog_flags
pub const F_STRICT_ALIGNMENT: u32 = 1 << 0;
pub const F_SLEEPABLE: u32 = 1 << 4;
// BPF_MAP_CREATE map_flags
pub const F_RDONLY_PROG: u32 = 1 << 7;
pub const F_MMAPABLE: u32 = 1 << 10;
pub const F_LINK: u32 = 1 << 13;
pub const F_VTYPE_BTF_OBJ_FD: u32 = 1 << 15;
pub const F_TOKEN_FD: u32 = 1 << 16;

// insn[0].src_reg of ld_imm64
pub const PSEUDO_MAP_FD: u8 = 1;
pub const PSEUDO_MAP_VALUE: u8 = 2;
pub const PSEUDO_BTF_ID: u8 = 3;
pub const PSEUDO_FUNC: u8 = 4;
pub const PSEUDO_MAP_IDX: u8 = 5;
pub const PSEUDO_MAP_IDX_VALUE: u8 = 6;
// call.src_reg
pub const PSEUDO_CALL: u8 = 1;
pub const PSEUDO_KFUNC_CALL: u8 = 2;

/// the helpers vh-sched allows (enum bpf_func_id)
pub const Helper = enum(i32) {
    map_lookup_elem = 1,
    map_update_elem = 2,
    map_delete_elem = 3,
    ktime_get_ns = 5,
    trace_printk = 6,
    get_prandom_u32 = 7,
    get_smp_processor_id = 8,
    probe_read_kernel = 113,
    probe_read_kernel_str = 115,
    jiffies64 = 118,
    ktime_get_boot_ns = 125,
    ringbuf_output = 130,
    ringbuf_reserve = 131,
    ringbuf_submit = 132,
    ringbuf_discard = 133,
    ringbuf_query = 134,
    this_cpu_ptr = 154,
    get_current_task_btf = 158,
    ktime_get_coarse_ns = 160,
    loop = 181,
    _,
};

// ringbuf record header
pub const RINGBUF_BUSY_BIT: u32 = 1 << 31;
pub const RINGBUF_DISCARD_BIT: u32 = 1 << 30;
pub const RINGBUF_HDR_SZ: u32 = 8;

// ---------------------------------------------------------------- instructions

/// struct bpf_insn
pub const Insn = extern struct {
    code: u8,
    /// dst_reg in the low 4 bits, src_reg in the high 4 (little-endian bitfield order)
    regs: u8,
    off: i16,
    imm: i32,

    pub fn dst(i: Insn) u4 {
        return @truncate(i.regs);
    }
    pub fn src(i: Insn) u4 {
        return @truncate(i.regs >> 4);
    }
    pub fn setSrc(i: *Insn, s: u4) void {
        i.regs = (i.regs & 0x0f) | (@as(u8, s) << 4);
    }
    pub fn class(i: Insn) u3 {
        return @truncate(i.code);
    }
};

// instruction classes (code & 7)
pub const CLASS_LD: u8 = 0;
pub const CLASS_LDX: u8 = 1;
pub const CLASS_ST: u8 = 2;
pub const CLASS_STX: u8 = 3;
pub const CLASS_ALU: u8 = 4;
pub const CLASS_JMP: u8 = 5;
pub const CLASS_JMP32: u8 = 6;
pub const CLASS_ALU64: u8 = 7;
// ld/ldx/st/stx: size (code & 0x18) and mode (code & 0xe0)
pub const SIZE_W: u8 = 0x00;
pub const SIZE_H: u8 = 0x08;
pub const SIZE_B: u8 = 0x10;
pub const SIZE_DW: u8 = 0x18;
pub const MODE_IMM: u8 = 0x00;
pub const MODE_ABS: u8 = 0x20;
pub const MODE_IND: u8 = 0x40;
pub const MODE_MEM: u8 = 0x60;
pub const MODE_MEMSX: u8 = 0x80;
pub const MODE_ATOMIC: u8 = 0xc0;
// alu/jmp: operation (code & 0xf0) and source (code & 0x08)
pub const SRC_K: u8 = 0x00;
pub const SRC_X: u8 = 0x08;
pub const ALU_ADD: u8 = 0x00;
pub const ALU_SUB: u8 = 0x10;
pub const ALU_MUL: u8 = 0x20;
pub const ALU_DIV: u8 = 0x30;
pub const ALU_OR: u8 = 0x40;
pub const ALU_AND: u8 = 0x50;
pub const ALU_LSH: u8 = 0x60;
pub const ALU_RSH: u8 = 0x70;
pub const ALU_NEG: u8 = 0x80;
pub const ALU_MOD: u8 = 0x90;
pub const ALU_XOR: u8 = 0xa0;
pub const ALU_MOV: u8 = 0xb0;
pub const ALU_ARSH: u8 = 0xc0;
pub const ALU_END: u8 = 0xd0;
pub const JMP_JA: u8 = 0x00;
pub const JMP_CALL: u8 = 0x80;
pub const JMP_EXIT: u8 = 0x90;
/// the whole opcode of the frequent cases
pub const OP_LD_IMM64: u8 = CLASS_LD | SIZE_DW | MODE_IMM; // 0x18
pub const OP_CALL: u8 = CLASS_JMP | JMP_CALL; // 0x85
pub const OP_EXIT: u8 = CLASS_JMP | JMP_EXIT; // 0x95

// ---------------------------------------------------------------- union bpf_attr

/// BPF_MAP_CREATE
pub const MapCreate = extern struct {
    map_type: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
    map_flags: u32,
    inner_map_fd: u32,
    numa_node: u32,
    map_name: [obj_name_len]u8,
    map_ifindex: u32,
    btf_fd: u32,
    btf_key_type_id: u32,
    btf_value_type_id: u32,
    btf_vmlinux_value_type_id: u32,
    map_extra: u64 align(8),
    value_type_btf_obj_fd: i32,
    map_token_fd: i32,
    excl_prog_hash: u64 align(8),
    excl_prog_hash_size: u32,
};

/// BPF_MAP_*_ELEM and BPF_MAP_FREEZE
pub const MapElem = extern struct {
    map_fd: u32,
    key: u64 align(8),
    /// value, or next_key
    value: u64 align(8),
    flags: u64,
};

/// BPF_PROG_LOAD
pub const ProgLoad = extern struct {
    prog_type: u32,
    insn_cnt: u32,
    insns: u64 align(8),
    license: u64 align(8),
    log_level: u32,
    log_size: u32,
    log_buf: u64 align(8),
    kern_version: u32,
    prog_flags: u32,
    prog_name: [obj_name_len]u8,
    prog_ifindex: u32,
    expected_attach_type: u32,
    prog_btf_fd: u32,
    func_info_rec_size: u32,
    func_info: u64 align(8),
    func_info_cnt: u32,
    line_info_rec_size: u32,
    line_info: u64 align(8),
    line_info_cnt: u32,
    attach_btf_id: u32,
    /// attach_prog_fd, or attach_btf_obj_fd
    attach_btf_obj_fd: u32,
    core_relo_cnt: u32,
    fd_array: u64 align(8),
    core_relos: u64 align(8),
    core_relo_rec_size: u32,
    /// output: the size the log needed
    log_true_size: u32,
    prog_token_fd: i32,
    fd_array_cnt: u32,
    signature: u64 align(8),
    signature_size: u32,
    keyring_id: i32,
};

/// BPF_BTF_LOAD
pub const BtfLoad = extern struct {
    btf: u64 align(8),
    btf_log_buf: u64 align(8),
    btf_size: u32,
    btf_log_size: u32,
    btf_log_level: u32,
    btf_log_true_size: u32,
    btf_flags: u32,
    btf_token_fd: i32,
};

/// BPF_OBJ_GET_INFO_BY_FD
pub const GetInfo = extern struct {
    bpf_fd: u32,
    info_len: u32,
    info: u64 align(8),
};

/// BPF_LINK_CREATE, the part a struct_ops link uses
pub const LinkCreate = extern struct {
    /// prog_fd, or map_fd for a struct_ops link
    prog_fd: u32,
    target_fd: u32,
    attach_type: u32,
    flags: u32,
    target_btf_id: u32,
};

/// BPF_LINK_DETACH
pub const LinkDetach = extern struct {
    link_fd: u32,
};

pub const Attr = extern union {
    map_create: MapCreate,
    elem: MapElem,
    prog_load: ProgLoad,
    btf_load: BtfLoad,
    info: GetInfo,
    link_create: LinkCreate,
    link_detach: LinkDetach,
    raw: [attr_size]u8,

    pub const zero: Attr = .{ .raw = @splat(0) };
};

/// struct bpf_link_info, the part a struct_ops link fills
pub const LinkInfo = extern struct {
    type: u32,
    id: u32,
    prog_id: u32,
    pad: u32,
    u: extern union {
        struct_ops: extern struct { map_id: u32 },
        raw: [48]u8,
    },
};

/// struct bpf_map_info
pub const MapInfo = extern struct {
    type: u32,
    id: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
    map_flags: u32,
    name: [obj_name_len]u8,
    ifindex: u32,
    btf_vmlinux_value_type_id: u32,
    netns_dev: u64 align(8),
    netns_ino: u64 align(8),
    btf_id: u32,
    btf_key_type_id: u32,
    btf_value_type_id: u32,
    btf_vmlinux_id: u32,
    map_extra: u64 align(8),
    hash: u64 align(8),
    hash_size: u32,
};

// ---------------------------------------------------------------- the system call

pub const E = linux.E;

/// bpf(2): the fd (or 0) on success, the errno otherwise.
pub var errno: E = .SUCCESS;

pub fn call(cmd: Cmd, attr: *Attr) error{Sys}!usize {
    const rc = linux.syscall3(.bpf, @intFromEnum(cmd), @intFromPtr(attr), attr_size);
    errno = linux.errno(rc);
    if (errno != .SUCCESS) return error.Sys;
    return rc;
}

/// The error as a name for messages: "EINVAL".
pub fn errName(e: E) []const u8 {
    return @tagName(e);
}

// ---------------------------------------------------------------- 6.18 size and offset checks

comptime {
    const assert = std.debug.assert;
    assert(@sizeOf(Attr) == attr_size);
    assert(@sizeOf(Insn) == 8);
    assert(@sizeOf(LinkInfo) == 64);
    assert(@offsetOf(LinkInfo, "u") == 16);
    assert(@sizeOf(MapInfo) == 104);
    assert(@offsetOf(MapInfo, "hash") == 88);

    assert(@offsetOf(MapCreate, "btf_vmlinux_value_type_id") == 60);
    assert(@offsetOf(MapCreate, "map_extra") == 64);
    assert(@offsetOf(MapCreate, "value_type_btf_obj_fd") == 72);
    assert(@offsetOf(MapCreate, "map_token_fd") == 76);
    assert(@offsetOf(MapCreate, "excl_prog_hash") == 80);
    assert(@offsetOf(MapCreate, "excl_prog_hash_size") == 88);

    assert(@offsetOf(MapElem, "key") == 8);
    assert(@offsetOf(MapElem, "value") == 16);
    assert(@offsetOf(MapElem, "flags") == 24);

    assert(@offsetOf(ProgLoad, "insns") == 8);
    assert(@offsetOf(ProgLoad, "license") == 16);
    assert(@offsetOf(ProgLoad, "log_buf") == 32);
    assert(@offsetOf(ProgLoad, "prog_name") == 48);
    assert(@offsetOf(ProgLoad, "expected_attach_type") == 68);
    assert(@offsetOf(ProgLoad, "prog_btf_fd") == 72);
    assert(@offsetOf(ProgLoad, "attach_btf_id") == 108);
    assert(@offsetOf(ProgLoad, "attach_btf_obj_fd") == 112);
    assert(@offsetOf(ProgLoad, "fd_array") == 120);
    assert(@offsetOf(ProgLoad, "log_true_size") == 140);
    assert(@offsetOf(ProgLoad, "prog_token_fd") == 144);
    assert(@offsetOf(ProgLoad, "fd_array_cnt") == 148);
    assert(@offsetOf(ProgLoad, "signature") == 152);
    assert(@offsetOf(ProgLoad, "keyring_id") == 164);
    assert(@sizeOf(ProgLoad) == 168);

    assert(@offsetOf(BtfLoad, "btf_log_buf") == 8);
    assert(@offsetOf(BtfLoad, "btf_size") == 16);
    assert(@offsetOf(BtfLoad, "btf_log_true_size") == 28);
    assert(@offsetOf(BtfLoad, "btf_flags") == 32);
    assert(@offsetOf(BtfLoad, "btf_token_fd") == 36);

    assert(@offsetOf(GetInfo, "info_len") == 4);
    assert(@offsetOf(GetInfo, "info") == 8);

    assert(@offsetOf(LinkCreate, "target_fd") == 4);
    assert(@offsetOf(LinkCreate, "attach_type") == 8);
    assert(@offsetOf(LinkCreate, "flags") == 12);
    assert(@offsetOf(LinkCreate, "target_btf_id") == 16);
}

test "6.18 enum values" {
    try std.testing.expectEqual(@as(u32, 28), @intFromEnum(Cmd.link_create));
    try std.testing.expectEqual(@as(u32, 34), @intFromEnum(Cmd.link_detach));
    try std.testing.expectEqual(@as(u32, 26), @intFromEnum(MapType.struct_ops));
    try std.testing.expectEqual(@as(u32, 27), @intFromEnum(MapType.ringbuf));
    try std.testing.expectEqual(@as(u32, 27), @intFromEnum(ProgType.struct_ops));
    try std.testing.expectEqual(@as(u32, 8192), F_LINK);
    try std.testing.expectEqual(@as(u32, 32768), F_VTYPE_BTF_OBJ_FD);
}

test "insn register fields" {
    var i: Insn = .{ .code = OP_CALL, .regs = 0x10, .off = 0, .imm = -1 };
    try std.testing.expectEqual(@as(u4, 0), i.dst());
    try std.testing.expectEqual(@as(u4, 1), i.src());
    i.setSrc(PSEUDO_KFUNC_CALL);
    try std.testing.expectEqual(@as(u8, 0x20), i.regs);
    try std.testing.expectEqual(@as(u3, CLASS_JMP), i.class());
}
