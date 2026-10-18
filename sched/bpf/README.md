# sched/bpf/ — the BPF part of vh-sched

SPDX-License-Identifier: GPL-2.0-only

Everything in this directory is licensed **GPL-2.0-only**, unlike the rest of the repository
(GPL-3.0): the kernel's BPF verifier allows GPL-only kfuncs (`scx_bpf_dsq_insert`,
`scx_bpf_dsq_move_to_local`, ...) only to programs that declare a GPL-compatible licence, and
the licence string in the program's `license` section must match.

Every source file here carries the header:

```zig
// SPDX-License-Identifier: GPL-2.0-only
```

Rules for this code (from the roadmap): Zig `bpfel-freestanding`, ReleaseFast (memory safety
comes from the verifier); a panic handler that calls `scx_bpf_error`; one ELF section per
callback; helpers as `inline fn` (no bpf-to-bpf calls); external symbols are kfuncs with the
6.13+ names; kernel types are field offsets taken from the BTF of **this** kernel; the
topology (6C/12T, one LLC, SMT pairs) is a build constant. The CI lint of the `.o` file
rejects u128, signed division without `-mcpu=v4`, compiler-rt and memcpy calls, and a stack
above 512 bytes, and reports `insn_processed`.
