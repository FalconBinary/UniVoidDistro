"""Track I: vh-stage1 in place of /etc/runit/1 (init/, docs/runbook-gf63.md)."""
import os
import re
import sys

import vhvm
from vmlib import VM_SRC, audit, boot, check, devname_unused, run, shutdown


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
        left = devname_unused(ser)
        check("vh-stage1 loads no devname module the rig does not use (modprobe -b)", left == [],
              "/proc/modules not read" if left is None else " ".join(left))
        rc, out = run(ser, "sv status /var/service/*")
        bad = [l for l in out.splitlines() if l.startswith(("down:", "fail:", "warning:"))]
        check("all runit services running under vh-stage1", not bad, "; ".join(bad))
        rc, out = run(ser, "for m in /proc /dev/shm /run /home /tmp /var/tmp /dev; do findmnt -no TARGET,OPTIONS $m; done; swapon --show; "
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
        # the first line of the output carries the shell prompt
        nums = [l.replace("vh# ", "").strip() for l in out.strip().splitlines()[:2]]
        check("after the rollback: no marker, every service up, --status reports the shell script",
              nums == ["0", "0"] and "st=1" in out and "shell script" in out, out[-400:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)


STEPS = {"stage1": step_stage1}

STATES = ("waiting", "delayed", "starting", "up", "stopping", "finishing", "down", "failed", "done")


def lines(out):
    """the lines of a command's output without the shell prompt that may lead the first one"""
    return [l[4:] if l.startswith("vh# ") else l for l in out.replace("\r", "").splitlines()]


def pid1(ser):
    """which init is PID 1: "vh-init", "runit", or the path"""
    rc, out = run(ser, "readlink /proc/1/exe")
    return "vh-init" if "vh-init" in out else ("runit" if "runit" in out else out.strip()[-60:])


def ctl_status(ser):
    """vh-ctl status as {name: state}, and the raw output"""
    rc, out = run(ser, "vh-ctl status")
    st = {}
    for l in lines(out):
        w = l.split()
        if len(w) >= 8 and w[1] in STATES and w[5] in ("want-up", "want-down"):
            st[w[0]] = w[1]
    return st, out


def sv_status(ser):
    """sv status /var/service/* (runit's sv, or the shim) as {name: "run" | "down" | "fail" | ...}"""
    rc, out = run(ser, "sv status /var/service/*")
    st = {}
    for l in lines(out):
        m = re.match(r"(run|down|fail|warning|timeout|ok): ([^:]+):", l)
        if m:
            st[m.group(2).rsplit("/", 1)[-1]] = m.group(1)     # runit's sv names the path it was given
    return st, out


def step_vhinit(a):
    """vh-init as PID 1 (init/README.md, v0.2): vh-init --install puts init= into the UKI's
    command line and the sv shim in place, the UKI is rebuilt (the previous one stays in Limine as
    the fallback, KEEP=2); the boot after it runs vh-init, the manager and every service of
    /var/service and /etc/vh/services/enabled; vh-ctl status and the sv shim agree; vh-audit
    without new FAILs and with the init area; the stage-1 time of the kernel log; a poweroff
    through runit-void's command ends in stage 3 and reboot(2). vh-init stays PID 1 for the steps
    after this one (sched, selinux); vhinit-rollback gives runit back. Needs --repo (the binaries
    come from build/, which tests/zig/build.sh fills)."""
    if not getattr(a, "repo", False):
        sys.exit("the vhinit step needs --repo")
    for b in ("vh-init", "vh-ctl"):
        if not os.path.isfile(os.path.join(vhvm.REPO, "build", b)):
            sys.exit(f"no build/{b}: sh tests/zig/build.sh")
    vm, ser = boot(a)
    try:
        check("before: PID 1 is runit", pid1(ser) == "runit")
        m = audit(ser, "vh-audit before vh-init (the reference FAIL count)")
        before = int(m.group(2)) if m else None
        rc, out = run(ser, "vh-init --version; vh-init --check; echo chk=$?")
        check("vh-init --check: the definitions parse, no problem", "chk=0" in out and "problem:" not in out, out[-600:].replace("\n", " | "))
        rc, out = run(ser, "vh-init --install; echo in=$?; grep KERNEL_CMDLINE /etc/default/dracut-uefi-hook; readlink /usr/bin/sv")
        check("vh-init --install: init= in the command line, the sv shim", "in=0" in out and "init=/usr/local/sbin/vh-init" in out and "vh-ctl" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, "sv status /var/service/*; echo ===; sv status /var/service/* | grep -c '^run:'; sv status /var/service/* | grep -vc '^run:'")
        nums = [l.strip() for l in lines(out.split("===")[-1]) if l.strip().isdigit()]
        check("the sv shim runs runit's sv while runit is PID 1 (every service run:)", len(nums) == 2 and nums[1] == "0" and int(nums[0]) > 5, out[-300:].replace("\n", " | "))
        # the rebuild replaces this kernel version's UKI: one file of this version, enrolled
        rc, out = run(ser, ". /etc/vh/vh.env; xbps-reconfigure -f $VH_KERNEL >/tmp/uki.log 2>&1; echo uki=$?; grep -a 'Limine\\|UKI\\|sign' /tmp/uki.log | tail -4; "
                           "mount -o ro /boot/efi; ls /boot/efi/EFI/void/; umount /boot/efi", timeout=1800)
        check("the UKI with init= was rebuilt, signed and enrolled", "uki=0" in out and "enrolled into Limine" in out and ".efi" in out, out[-500:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)                     # the first boot through vh-init
    try:
        check("PID 1 is vh-init", pid1(ser) == "vh-init")
        rc, out = run(ser, "cat /proc/cmdline; vh-init --status; echo st=$?; dmesg | grep -a 'vh-init: \\|vh-stage1: '")
        check("init= in the command line; --status reports vh-init and the manager", "init=/usr/local/sbin/vh-init" in out and "st=0" in out and "manager:" in out, out[-700:].replace("\n", " | "))
        m1 = re.search(r"vh-init: stage 1 done in (\d+) ms \((\d+) errors\)", out)
        m2 = re.search(r"vh-init: services (\d+) ms after the manager started", out)
        check("kmsg: stage 1 done without errors, the services settled",
              m1 is not None and m1.group(2) == "0" and m2 is not None,
              f"stage 1 {m1.group(1) if m1 else '?'} ms, {m1.group(2) if m1 else '?'} errors; services settled {m2.group(1) if m2 else '?'} ms after the manager started")
        steps = re.search(r"steps (.*)", out)
        print(f"--- VHINIT_TIMES stage1_ms={m1.group(1) if m1 else '?'} services_ms={m2.group(1) if m2 else '?'} steps: {steps.group(1) if steps else '?'}")
        st, out = ctl_status(ser)
        print(out)
        bad = [f"{n}({s})" for n, s in st.items() if s not in ("up", "done", "delayed")]
        check("vh-ctl status: every service up, done (a oneshot) or delayed (a timer)", st and not bad, "; ".join(bad)[-600:])
        rc, out = run(ser, "ls /var/service; echo ===; ls /etc/vh/services/enabled 2>/dev/null")
        parts = out.split("===")
        words = lambda text: [w for l in lines(text) for w in l.split() if not w.startswith("__VH")]
        enabled = set(words(parts[0])) | {w[:-4] if w.endswith(".svc") else w for w in words(parts[1])}
        missing = sorted(n for n in enabled if n not in st)
        extra = sorted(n for n in st if n not in enabled)
        check("every service of /var/service and /etc/vh/services/enabled has a state, none else", not missing and not extra,
              f"enabled {len(enabled)}, states {len(st)}; missing {missing}; extra {extra}")
        sv, out = sv_status(ser)
        disagree = []
        for n in sorted(enabled):
            c, s = st.get(n), sv.get(n)
            want = "run" if c in ("up", "starting", "stopping", "finishing") else "fail" if c == "failed" else "down"
            if s != want:
                disagree.append(f"{n}: vh-ctl {c}, sv {s}")
        check("sv status (the shim) agrees with vh-ctl status for every service", not disagree, "; ".join(disagree)[-600:])
        rc, out = run(ser, "pgrep -c runsv; pgrep -c runsvdir; ps -o pid,rss,comm -p 1; vh-ctl blame | head -8")
        nums = [l.strip() for l in lines(out) if l.strip().isdigit()]
        check("no runsv or runsvdir processes; PID 1 small", nums[:2] == ["0", "0"], out[-500:].replace("\n", " | "))
        rc, out = run(ser, "for m in /proc /dev/shm /run /tmp; do findmnt -no TARGET,OPTIONS $m; done; swapon --show; nft list tables; cat /run/vh/power; "
                           "cat /sys/kernel/mm/transparent_hugepage/defrag; sysctl -n net.ipv4.tcp_congestion_control; ls -ld /run/vh-sandbox; ls -la /var/log/dmesg.log")
        check("stage 1 under vh-init: hidepid, noexec, zram, nft table, the power profile, THP, sysctl, the sandbox directory, the dmesg log",
              all(x in out for x in ("hidepid=invisible", "noexec", "zram0", "table inet vh", "defer+madvise", "bbr", "vh-sandbox", "dmesg.log")), out[-600:].replace("\n", " | "))
        m2 = audit(ser, "vh-audit under vh-init")
        after = int(m2.group(2)) if m2 else None
        check("vh-audit: no new FAILs", before is not None and after is not None and after <= before, f"before {before}, after {after}")
        rc, out = run(ser, "vh-audit init")
        check("vh-audit init area: PID 1 is vh-init, no FAIL", "[FAIL]" not in out and "PID 1 is vh-init" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, "vh-ctl restart chronyd -w 10; vh-ctl status chronyd; sv status chronyd; ls /var/log/vh/; tail -2 /var/log/vh/vh-acpid/current")
        check("vh-ctl restart of a runit service; sv sees it; the log directories", re.search(r"chronyd up \d+", out) is not None and "run: chronyd" in out and "vh-acpid" in out, out[-400:].replace("\n", " | "))
        # the poweroff of runit-void (/run/runit/stopit and SIGCONT): the manager stops the services,
        # PID 1 runs stage 3 and calls reboot(2); stage 3's notes go to the console, the kernel's
        # "Power down" is the last line
        mark = len(ser.alltext)
        ser.send("poweroff")
        try:
            ser.expect(r"reboot: Power down", 240)
        except (TimeoutError, EOFError):
            pass
        tail = ser.alltext[mark:]
        check("poweroff: the services stopped, stage 3 ran and reboot(2) powered the machine off",
              "stage 3: poweroff" in tail and re.search(r"stage 3 done in \d+ ms", tail) is not None and "reboot: Power down" in tail,
              tail[-500:].replace("\n", " | "))
        m3 = re.search(r"stage 3 done in (\d+) ms", tail)
        print(f"--- VHINIT_TIMES stage3_ms={m3.group(1) if m3 else '?'}")
    finally:
        shutdown(vm, ser)


def step_vhinit_rollback(a):
    """vh-init --rollback on a system that boots vh-init: init= out of the command line, runit's sv
    back, the UKI rebuilt; the boot after it runs runit with every service up."""
    vm, ser = boot(a)
    try:
        check("before the rollback: PID 1 is vh-init", pid1(ser) == "vh-init")
        rc, out = run(ser, "vh-init --rollback; echo rb=$?; readlink /usr/bin/sv || echo 'sv is a file'; . /etc/vh/vh.env; xbps-reconfigure -f $VH_KERNEL >/tmp/uki2.log 2>&1; echo uki=$?", timeout=1800)
        check("vh-init --rollback and the UKI rebuilt", "rb=0" in out and "uki=0" in out and "sv is a file" in out, out[-400:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)                 # the regular shutdown through vh-init
    vm, ser = boot(a)                     # back on runit
    try:
        check("after the rollback: runit is PID 1", pid1(ser) == "runit")
        rc, out = run(ser, "sv status /var/service/* | grep -vc '^run:'; vh-init --status; echo st=$?")
        nums = [l.strip() for l in lines(out) if l.strip().isdigit()]
        check("every runit service up, --status exits 1 and names runit", nums[:1] == ["0"] and "st=1" in out and "PID 1: runit" in out, out[-400:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)


STEPS["vhinit"] = step_vhinit
STEPS["vhinit-rollback"] = step_vhinit_rollback
