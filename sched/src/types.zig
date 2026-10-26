//! sched/src/types.zig: the data that the BPF programs and the loader share: the layout of
//! the `.rodata` configuration, the `.bss` counters, the per-task storage and the ring buffer
//! records. Types only, no code: the loader imports this file for the host, the BPF programs
//! import it as the module `types`. The `c_name` of each struct is its name in the generated BTF.

pub const max_cpus = 256;
pub const max_llcs = 32;

/// vh_sched.o `.rodata`: filled by the loader from the topology of the running machine
/// (sched/src/topo.zig) and `--set cfg.FIELD=VALUE`, then frozen. Everything the BPF side knows
/// about the machine comes from here: no compile-time constants (docs/uni/ROADMAP.md, U4).
pub const Cfg = extern struct {
    pub const c_name = "vh_cfg";
    /// the full slice, and the shortest one a crowded LLC shrinks it to
    slice_ns: u64,
    slice_min_ns: u64,
    /// when not 0: report an error at this enqueue (the error path and the exit path test)
    fail_after: u64,
    /// the lag a task may keep behind the LLC's vtime: slice_ns * (1 + lat_bonus_max) at most
    lat_bonus_max: u32,
    /// another LLC's DSQ is stolen from only with at least this many tasks waiting there
    steal_min: u32,
    nr_cpus: u32,
    nr_llcs: u32,
    /// the big cores of a hybrid CPU (capacity above the smallest): interactive tasks prefer them
    nr_big: u32,
    /// bit 0: prefer a big core for an interactive task; bit 1: steal across LLCs
    flags: u32,
    /// task_struct offsets from the running kernel's BTF (the loader fills them)
    off_scx_weight: u32,
    off_scx_dsq_vtime: u32,
    off_scx_slice: u32,
    off_cpus_ptr: u32,
    /// the LLC of each CPU (an index into the DSQs 0..nr_llcs-1)
    cpu_llc: [max_cpus]u8,
    /// 1 when the CPU is a big core
    cpu_big: [max_cpus]u8,
    /// the big cores in order, for the bounded search
    big_list: [max_cpus]u16,
    /// the number of CPUs in each LLC, and the NUMA node its DSQ is created on
    llc_cpus: [max_llcs]u16,
    llc_node: [max_llcs]i32,
};

pub const FLAG_PREFER_BIG: u32 = 1;
pub const FLAG_STEAL: u32 = 2;

/// vh_sched.o `.bss`: counters, read by the loader through the mmap of the map
pub const Stats = extern struct {
    pub const c_name = "vh_stats";
    nr_select: u64,
    /// select_cpu found an idle CPU: the task went straight to its local DSQ
    nr_direct: u64,
    /// an interactive task got an idle big core the default selection did not pick
    nr_big: u64,
    nr_enqueue: u64,
    /// enqueues with a shortened slice (a crowded LLC)
    nr_short_slice: u64,
    /// enqueues of a task counted interactive (a lag bonus)
    nr_interactive: u64,
    nr_dispatch: u64,
    /// dispatch took a task from the CPU's own LLC DSQ
    nr_local: u64,
    /// dispatch stole a task from another LLC's DSQ
    nr_steal: u64,
    nr_reenqueue: u64,
    init_rc: i64,
    exit_seq: u64,
    exit_kind: i64,
    exit_code: i64,
    exit_flags: u64,
    /// the vtime of each LLC, for the report
    vtime: [max_llcs]u64,
};

/// the per-task storage (BPF_MAP_TYPE_TASK_STORAGE), one per task that sched_ext manages
pub const TaskCtx = extern struct {
    pub const c_name = "vh_task_ctx";
    /// when the task last started running (ns)
    run_start_ns: u64,
    /// an exponential average of how long it runs before it stops (ns): short means interactive
    avg_run_ns: u64,
    /// how often it has run
    nr_runs: u64,
    /// the LLC it was last enqueued in
    llc: u32,
    _pad: u32,
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
