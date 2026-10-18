//! sched/src/types.zig: the data that the BPF programs and the loader share: the layout of
//! the `.rodata` configuration, the `.bss` counters and the ring buffer records. Types only,
//! no code: the loader imports this file for the host, the BPF programs import it as the
//! module `types`. The `c_name` of each struct is its name in the generated BTF.

/// vh_sched.o `.rodata`: filled by the loader (`--set cfg.FIELD=VALUE`) and frozen
pub const Cfg = extern struct {
    pub const c_name = "vh_cfg";
    slice_ns: u64,
    shared_dsq: u64,
    /// when not 0: report an error at this enqueue (the error path and the exit path test)
    fail_after: u64,
    nr_cpus: u32,
    _pad: u32,
};

/// vh_sched.o `.bss`: counters, read by the loader through the mmap of the map
pub const Stats = extern struct {
    pub const c_name = "vh_stats";
    nr_select: u64,
    nr_direct: u64,
    nr_enqueue: u64,
    nr_dispatch: u64,
    nr_dispatch_hit: u64,
    init_rc: i64,
    exit_seq: u64,
    exit_kind: i64,
    exit_code: i64,
    exit_flags: u64,
};

/// the record `exit` writes into the ring buffer
pub const ExitRec = extern struct {
    pub const c_name = "vh_exit_rec";
    kind: i64,
    exit_code: i64,
    flags: u64,
};

/// tcp_ca_probe.o `.bss`
pub const ProbeStats = extern struct {
    pub const c_name = "vh_probe_stats";
    nr_ssthresh: u64,
    nr_undo_cwnd: u64,
    nr_cong_avoid: u64,
};
