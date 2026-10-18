"""Track I: vh-stage1 in place of /etc/runit/1 (init/, docs/runbook-gf63.md)."""
import os
import re
import sys

import vhvm
from vmlib import VM_SRC, audit, boot, check, run, shutdown


def step_stage1(a):
    """vh-stage1 installed over runit-void's stage 1: the kmsg marker, every runit service
    up, vh-audit without new FAILs, the stage1 audit area, then the rollback. Needs --repo
    and build/init/bin/vh-stage1 (sh tests/init/build.sh)."""
    if not os.path.isfile(os.path.join(vhvm.REPO, "build", "init", "bin", "vh-stage1")):
        sys.exit("no build/init/bin/vh-stage1: sh tests/init/build.sh")
    if not getattr(a, "repo", False):
        sys.exit("the stage1 step needs --repo (the binary comes from the repository copy)")
    vm, ser = boot(a)
    try:
        m = audit(ser, "vh-audit before vh-stage1 (the reference FAIL count)")
        before = int(m.group(2)) if m else None
        rc, out = run(ser, f"install -m 0755 {VM_SRC}/build/init/bin/vh-stage1 /usr/local/sbin/vh-stage1 && "
                           "vh-stage1 --install; echo in=$?; vh-stage1 --status; echo st=$?")
        check("vh-stage1 --install keeps the previous stage 1 as 1.orig",
              "in=0" in out and "kept the previous stage 1 as /etc/runit/1.orig" in out and "st=0" in out,
              out[-500:].replace("\n", " | "))
        rc, out = run(ser, "cat /etc/vh/stage1.conf")
        check("stage1.conf from the rendered core-services", "VH_ZRAM_ALGO=" in out and "VH_SHM_SIZE=" in out, out[-300:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)                     # the first boot through vh-stage1
    try:
        rc, out = run(ser, "dmesg | grep -a 'vh-stage1:'; vh-stage1 --status; echo st=$?")
        check("kmsg marker 'vh-stage1: done in N ms' without errors",
              re.search(r"vh-stage1: done in \d+ ms \(0 errors\)", out) is not None, out[-700:].replace("\n", " | "))
        check("the per-step times are in kmsg", "vh-stage1: steps " in out and "udev-settle=" in out)
        check("--status: vh-stage1 ran this boot", "st=0" in out and "done " in out)
        rc, out = run(ser, "sv status /var/service/*")
        bad = [l for l in out.splitlines() if l.startswith(("down:", "fail:", "warning:"))]
        check("all runit services running under vh-stage1", not bad, "; ".join(bad))
        rc, out = run(ser, "findmnt -no TARGET,OPTIONS /proc /dev/shm /run /home /tmp /var/tmp /dev; swapon --show; "
                           "cat /run/vh/power; ls -ld /run/vh-sandbox; nft list tables; "
                           "cat /sys/kernel/mm/transparent_hugepage/defrag; sysctl -n kernel.kptr_restrict net.ipv4.tcp_congestion_control; "
                           "hostname; ls -l /run/utmp; who -b; cat /var/lib/seedrng/seed.* | wc -c; ls -la /var/log/dmesg.log")
        check("/proc: hidepid=invisible", "hidepid=invisible" in out)
        check("noexec on /dev/shm, /run, /tmp, /var/tmp, /home", out.count("noexec") >= 5, out[:600].replace("\n", " | "))
        check("zram swap active", "zram0" in out)
        check("sandbox directory, power profile, nft table, THP, sysctl, hostname, utmp, seed, dmesg log",
              all(x in out for x in ("vh-sandbox", "table inet vh", "defer+madvise", "bbr", "system boot", "dmesg.log")),
              out[-900:].replace("\n", " | "))
        m2 = audit(ser, "vh-audit with vh-stage1")
        after = int(m2.group(2)) if m2 else None
        check("vh-audit: no new FAILs", before is not None and after is not None and after <= before, f"before {before}, after {after}")
        rc, out = run(ser, "vh-audit stage1")
        check("vh-audit stage1 area: ok lines, no FAIL", "[FAIL]" not in out and "stage 1 is vh-stage1" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, "vh-stage1 --rollback; echo rb=$?")
        check("vh-stage1 --rollback", "rb=0" in out and "restored /etc/runit/1" in out, out[-300:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)                     # back on runit-void's stage 1
    try:
        rc, out = run(ser, "dmesg | grep -ac 'vh-stage1: done'; sv status /var/service/* | grep -vc '^run:'; vh-stage1 --status; echo st=$?")
        lines = out.strip().splitlines()
        check("after the rollback: no marker, every service up, --status reports the shell script",
              len(lines) >= 2 and lines[0].strip() == "0" and lines[1].strip() == "0" and "st=1" in out and "shell script" in out,
              out[-400:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)


STEPS = {"stage1": step_stage1}
