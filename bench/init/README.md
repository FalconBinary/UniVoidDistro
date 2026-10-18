# bench/init — stage 1

`stage1_boot.py` measures the wall time of runit's stage 1 on the QEMU rig: runit-void's
shell `/etc/runit/1` (with the core-services of this system) against `vh-stage1` (init/).
The method and the rules are in [docs/ROADMAP.md](../../docs/ROADMAP.md#measurements-bench-an-honest-method);
the numbers are published in [docs/19-benchmarks.md](../../docs/19-benchmarks.md).

```sh
python3 tests/vm/vhvm.py install --iso void-live.iso   # once: the rig (hours under TCG)
sh tests/zig/build.sh && sh tests/init/build.sh         # build/: the tools, thor, vh-stage1
python3 bench/init/stage1_boot.py --boots 10            # --accel kvm on Linux; tcg on a Mac
```

- `1.shell-marked`: the stock `/etc/runit/1` of runit-void-20250212_4 plus two `echo` lines
  into `/dev/kmsg`, so that the shell variant has the same markers as vh-stage1 (the two
  built-ins cost well under a millisecond).
- Every boot is a cold boot; the variants alternate in a random order (seeded); the first
  boot of each variant is the warm-up and is discarded.
- The result CSV holds every boot: `bench/results/stage1-TAG.csv`.
- On the GF63 the same numbers come from `dmesg` of real boots: the runbook
  ([docs/runbook-gf63.md](../../docs/runbook-gf63.md)) says how.
