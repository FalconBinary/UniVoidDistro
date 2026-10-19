#!/usr/bin/env python3
"""Stage-1 wall time: runit-void's shell stage 1 against vh-stage1, on the QEMU rig
(tests/vm/vhvm.py install first; tests/zig/build.sh and tests/init/build.sh for build/).

  python3 bench/init/stage1_boot.py --boots 10 [--accel kvm|tcg] [--dir tests/vm/work] [--tag NAME]

Method (docs/ROADMAP.md, "Measurements"): the two variants alternate in a random order
(seeded), the first boot of each variant is the warm-up and is discarded, every boot is a
cold boot of the VM. Both variants mark their start and their end in the kernel log:
the shell variant is the stock /etc/runit/1 plus two echo lines (bench/init/1.shell-marked),
vh-stage1 writes its own markers. From dmesg of every boot:

  start_s    the stage-1 start marker        done_s   the stage-1 end marker
  stage1_ms  done - start: the measured quantity
  self_ms    vh-stage1's own "done in N ms"  steps    its per-step times (vh-stage1 only)
  init_s     the kernel's "Run /init as init process" line: the initramfs start, kept for
             reference only (the time to stage 1 from there holds the LUKS passphrase wait)

Output: bench/results/stage1-TAG.csv (every boot, warm-ups marked) and the summary: median,
p95, the bootstrap 95 % CI of the difference of medians, and the verdict by the rule
"faster only if the CI excludes 0 and the difference is at least 3 %". The VM is left on
the stock stage 1 (the pristine script is restored, 1.orig removed).
"""
import argparse
import csv
import os
import random
import re
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tests", "vm"))
import vhvm  # noqa: E402
import vmlib  # noqa: E402

MARKED = "/root/vh-bench-1.shell"           # the marked script inside the VM
STOCK = "/root/vh-bench-1.stock"            # the pristine /etc/runit/1 of the VM
TS = re.compile(r"^\[\s*(\d+\.\d+)\]\s*(.*)$")


def kmsg_times(out):
    """{name: seconds} of the markers in a dmesg listing, plus the vh-stage1 fields."""
    r = {}
    for line in out.splitlines():
        m = TS.match(line.strip())
        if not m:
            continue
        ts, text = float(m.group(1)), m.group(2)
        if "Run /sbin/init as init process" in text or "Run /init as init process" in text:
            r.setdefault("init", ts)
        elif "vh-bench: stage1 start" in text or "vh-stage1: start" in text:
            r.setdefault("start", ts)
        elif "vh-bench: stage1 done" in text:
            r.setdefault("done", ts)
        elif "vh-stage1: done in" in text:
            r.setdefault("done", ts)
            mm = re.search(r"done in (\d+) ms", text)
            if mm:
                r["self_ms"] = int(mm.group(1))
        elif "vh-stage1: steps" in text:
            r["steps"] = (r.get("steps", "") + " " + text.split("steps", 1)[1].replace("(cont.)", "")).strip()
    return r


def percentile(xs, p):
    """nearest-rank percentile"""
    s = sorted(xs)
    k = max(1, int(round(p / 100 * len(s))))
    return s[min(k, len(s)) - 1]


def bootstrap_ci(a, b, n=10000, seed=1):
    """95 % CI of median(b) - median(a) by resampling both samples"""
    rng = random.Random(seed)
    diffs = []
    for _ in range(n):
        ra = [rng.choice(a) for _ in a]
        rb = [rng.choice(b) for _ in b]
        diffs.append(statistics.median(rb) - statistics.median(ra))
    diffs.sort()
    return diffs[int(0.025 * n)], diffs[int(0.975 * n)]


def switch_variant(ser, variant):
    """the stage 1 of the NEXT boot"""
    if variant == "shell":
        vmlib.run(ser, f"install -m 0755 {MARKED} /etc/runit/1")
    else:
        vmlib.run(ser, "install -m 0755 /usr/local/sbin/vh-stage1 /etc/runit/1")


def summary(rows, title):
    """the table of the measured boots: median, p95, the bootstrap CI, the verdict"""
    shell = [r["stage1_ms"] for r in rows if r["variant"] == "shell" and not r["warmup"]]
    zig = [r["stage1_ms"] for r in rows if r["variant"] == "zig" and not r["warmup"]]
    print(f"{title}: {len(shell)} + {len(zig)} measured boots\n")
    if not shell or not zig:
        print("not enough boots of both variants")
        return
    lo, hi = bootstrap_ci(shell, zig)
    d = statistics.median(zig) - statistics.median(shell)
    pct = 100 * d / statistics.median(shell)
    verdict = "faster" if hi < 0 and pct <= -3 else "slower" if lo > 0 and pct >= 3 else "no claim"
    print("| stage 1, done - start (ms) | runit-void shell | vh-stage1 | difference | 95 % CI |")
    print("|---|---|---|---|---|")
    print(f"| median | {statistics.median(shell):.0f} | {statistics.median(zig):.0f} | {d:+.0f} ({pct:+.1f} %) | [{lo:+.0f}, {hi:+.0f}] |")
    print(f"| p95 | {percentile(shell, 95):.0f} | {percentile(zig, 95):.0f} | | |")
    print(f"| min / max | {min(shell):.0f} / {max(shell):.0f} | {min(zig):.0f} / {max(zig):.0f} | | |")
    print(f"| verdict (CI excludes 0 and at least 3 %) | | | {verdict} | |")
    steps = [r["steps"] for r in rows if r["variant"] == "zig" and not r["warmup"] and r["steps"]]
    if steps:
        per = {}
        for s in steps:
            for kv in s.split():
                k, v = kv.split("=")
                per.setdefault(k, []).append(float(v))
        print("\nvh-stage1 steps, median ms: " + " ".join(f"{k}={statistics.median(v):.0f}" for k, v in per.items()))


def rows_from_dmesg(path, variant):
    """a file of dmesg excerpts of several boots (docs/runbook-gf63.md): one boot starts
    at each "Run /sbin/init" line; the first boot is the warm-up"""
    boots = []
    cur = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if "as init process" in line and cur:
                boots.append(cur)
                cur = []
            cur.append(line)
    if cur:
        boots.append(cur)
    rows = []
    for i, b in enumerate(boots):
        t = kmsg_times("".join(b))
        if "start" not in t or "done" not in t:
            print(f"{path}: boot {i}: markers missing, skipped")
            continue
        rows.append({"boot": i, "variant": variant, "warmup": int(i == 0), "init_s": t.get("init", ""),
                     "start_s": t["start"], "done_s": t["done"],
                     "stage1_ms": round((t["done"] - t["start"]) * 1000, 1),
                     "init_ms": round((t["done"] - t["init"]) * 1000, 1) if "init" in t else "",
                     "self_ms": t.get("self_ms", ""), "steps": t.get("steps", "")})
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--boots", type=int, default=10, help="measured boots per variant (plus one warm-up each)")
    ap.add_argument("--accel", default=os.environ.get("VH_ACCEL", "tcg"), help="qemu accelerator: kvm on Linux, tcg on a Mac")
    ap.add_argument("--dir", default=os.path.join(REPO, "tests", "vm", "work"))
    ap.add_argument("--mem", type=int, default=3072)
    ap.add_argument("--smp", type=int, default=4)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--seed", type=int, default=20261019)
    ap.add_argument("--tag", default=None, help="results file name: bench/results/stage1-TAG.csv")
    ap.add_argument("--from-dmesg", nargs=2, metavar=("SHELL", "ZIG"),
                    help="no VM: the table from two files of dmesg excerpts collected on a machine (the runbook)")
    a = ap.parse_args()
    if a.from_dmesg:
        rows = rows_from_dmesg(a.from_dmesg[0], "shell") + rows_from_dmesg(a.from_dmesg[1], "zig")
        tag = a.tag or "dmesg-" + time.strftime("%Y%m%d")
        out_csv = os.path.join(REPO, "bench", "results", f"stage1-{tag}.csv")
        os.makedirs(os.path.dirname(out_csv), exist_ok=True)
        with open(out_csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["boot", "variant", "warmup", "init_s", "start_s", "done_s", "stage1_ms", "init_ms", "self_ms", "steps"])
            w.writeheader()
            w.writerows(rows)
        print(f"results: {out_csv}")
        summary(rows, "from dmesg")
        return
    os.environ["VH_ACCEL"] = a.accel
    if not os.path.isfile(os.path.join(REPO, "build", "init", "bin", "vh-stage1")):
        sys.exit("no build/init/bin/vh-stage1: sh tests/init/build.sh")
    tag = a.tag or f"{a.accel}-{time.strftime('%Y%m%d')}"
    out_csv = os.path.join(REPO, "bench", "results", f"stage1-{tag}.csv")
    os.makedirs(os.path.dirname(out_csv), exist_ok=True)

    # the order: a random interleaving, each variant's first boot is its warm-up
    rng = random.Random(a.seed)
    order = ["shell", "zig"] * (a.boots + 1)
    rng.shuffle(order)
    print(f"order: {' '.join(order)}", flush=True)

    # boot 0 with the repository: the binary and the marked script into the VM, the stock script kept
    a.repo = True
    vm, ser = vmlib.boot(a)
    vmlib.run(ser, f"install -m 0755 {vmlib.VM_SRC}/build/init/bin/vh-stage1 /usr/local/sbin/vh-stage1 && "
                   f"install -m 0755 {vmlib.VM_SRC}/bench/init/1.shell-marked {MARKED} && "
                   f"{{ [ -e {STOCK} ] || cp -p /etc/runit/1 {STOCK}; }} && rm -f /etc/runit/1.orig && "
                   f"head -c 2 {STOCK} | grep -q '#!' && echo STOCK_OK")
    rc, out = vmlib.run(ser, "cat /proc/cpuinfo | grep -m1 'model name'; uname -r; nproc; free -m | head -2")
    print(out)
    switch_variant(ser, order[0])
    vmlib.shutdown(vm, ser)
    a.repo = False

    rows = []
    seen = {"shell": 0, "zig": 0}
    fields = ["boot", "variant", "warmup", "init_s", "start_s", "done_s", "stage1_ms", "init_ms", "self_ms", "steps"]
    with open(out_csv, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for i, variant in enumerate(order):
            vm, ser = vmlib.boot(a)
            try:
                rc, out = vmlib.run(ser, "dmesg | grep -a 'Run /sbin/init\\|Run /init\\|vh-bench: stage1\\|vh-stage1:'")
                t = kmsg_times(out)
                if "start" not in t or "done" not in t:
                    print(f"boot {i}: markers missing: {out[-400:]!r}", flush=True)
                    sys.exit(1)
                warm = seen[variant] == 0
                seen[variant] += 1
                row = {
                    "boot": i, "variant": variant, "warmup": int(warm),
                    "init_s": t.get("init", ""), "start_s": t["start"], "done_s": t["done"],
                    "stage1_ms": round((t["done"] - t["start"]) * 1000, 1),
                    "init_ms": round((t["done"] - t["init"]) * 1000, 1) if "init" in t else "",
                    "self_ms": t.get("self_ms", ""), "steps": t.get("steps", ""),
                }
                rows.append(row)
                w.writerow(row)
                f.flush()
                print(f"boot {i} {variant}{' (warm-up)' if warm else ''}: stage1 {row['stage1_ms']} ms"
                      + (f", self {row['self_ms']} ms" if row["self_ms"] != "" else ""), flush=True)
                if i + 1 < len(order):
                    switch_variant(ser, order[i + 1])
                else:
                    vmlib.run(ser, f"install -m 0755 {STOCK} /etc/runit/1 && rm -f /etc/runit/1.orig")
            finally:
                vmlib.shutdown(vm, ser)

    print(f"\nresults: {out_csv}")
    summary(rows, f"accelerator {a.accel}, {a.smp} vCPUs, {a.mem} MB")


if __name__ == "__main__":
    main()
