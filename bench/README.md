# bench/ — measurements

The honest method is fixed in [docs/ROADMAP.md](../docs/ROADMAP.md#measurements-bench-an-honest-method):
metrics fixed before measuring, variants alternated in random order with the warm-up
discarded, at least 30 boots (KVM, pinned vCPUs) and at least 10 long runs, median, p95 and a
bootstrap 95 % CI; "faster" only when the CI excludes 0 and the difference is at least 3 %.
On the GF63: mains power, a fixed EPP, cooled below 50 °C, frequency, temperature and RAPL
logged.

```
bench/
  init/                boot to the "all ready" kmsg marker, supervisor CPU, PSS, wakeups, shutdown time
  pkg/                 a local mirror in a netns with tc netem (30 ms / 100 Mbit and 0 ms)
  sched/               schbench p99, 144 Hz deadline misses under make -j12, MangoHud CSV, RAPL
  boot/                firmware -> Limine -> kernel -> init -> ready -> desktop; kernel size, initcalls
  session/             tools/vh-session-usage, RefursWM frame time
  results/             raw CSV of every run (committed)
```

`docs/19-benchmarks.md` reports the numbers from v0.1 on. The first tools here come with
v0.1; until then `tools/vh-bench` and `tools/vh-session-usage` are the measurements.
