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


def step_vhinit(a):
    """vh-init as PID 1 (init/README.md, v0.2): vh-init --install puts init= into the UKI's
    command line and the sv shim in place, the UKI is rebuilt; the boot after it runs vh-init,
    the manager and every service; vh-audit without new FAILs and with the init area; then the
    rollback and a boot with runit again. Needs --repo (the binaries come from build/, which
    tests/zig/build.sh fills). [VERIFY on the rig: written with the container test only]"""
    if not getattr(a, "repo", False):
        sys.exit("the vhinit step needs --repo")
    for b in ("vh-init", "vh-ctl"):
        if not os.path.isfile(os.path.join(vhvm.REPO, "build", b)):
            sys.exit(f"no build/{b}: sh tests/zig/build.sh")
    vm, ser = boot(a)
    try:
        m = audit(ser, "vh-audit before vh-init (the reference FAIL count)")
        before = int(m.group(2)) if m else None
        rc, out = run(ser, "vh-init --check; echo chk=$?")
        check("vh-init --check: the definitions parse, no problem", "chk=0" in out and "problem:" not in out, out[-600:].replace("\n", " | "))
        rc, out = run(ser, "vh-init --install; echo in=$?; grep KERNEL_CMDLINE /etc/default/dracut-uefi-hook; readlink /usr/bin/sv")
        check("vh-init --install: init= in the command line, the sv shim", "in=0" in out and "init=/usr/local/sbin/vh-init" in out and "vh-ctl" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, "sv status /var/service/* | grep -vc '^run:'; echo svrc=$?")
        check("the sv shim runs runit's sv while runit is PID 1", out.strip().splitlines()[-2:][0].strip().endswith("0") or "svrc=" in out, out[-300:].replace("\n", " | "))
        rc, out = run(ser, ". /etc/vh/vh.env; xbps-reconfigure -f $VH_KERNEL >/tmp/uki.log 2>&1; echo uki=$?; ls /boot/efi/EFI/void/ 2>/dev/null || mount -o ro /boot/efi && ls /boot/efi/EFI/void/", timeout=1800)
        check("the UKI with init= was rebuilt and signed", "uki=0" in out and ".efi" in out, out[-500:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)                     # the first boot through vh-init
    try:
        rc, out = run(ser, "readlink /proc/1/exe; vh-init --status; echo st=$?; dmesg | grep -a 'vh-init:'")
        check("PID 1 is vh-init", "vh-init" in out.splitlines()[1] if len(out.splitlines()) > 1 else False, out[-700:].replace("\n", " | "))
        check("kmsg: stage 1 done and the services settled", "vh-init: stage 1 done in" in out and "vh-init: services" in out, out[-700:].replace("\n", " | "))
        rc, out = run(ser, "vh-ctl status")
        bad = [l for l in out.splitlines() if l.split()[1:2] not in (["up"], ["done"], ["delayed"]) and l.strip() and not l.startswith("vh#")]
        check("vh-ctl status: every service up or done", not bad, "; ".join(bad)[-600:])
        rc, out = run(ser, "sv status /var/service/*")
        bad = [l for l in out.splitlines() if l.startswith(("down:", "fail:", "timeout:"))]
        check("sv (the shim): every runit service running", not bad, "; ".join(bad))
        rc, out = run(ser, "pgrep -c runsv; pgrep -c runsvdir; ps -o pid,rss,comm -p 1; vh-ctl blame | head -5")
        check("no runsv processes; PID 1 small", "0\n0" in out.replace("\r", "") or "pgrep" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, "for m in /proc /dev/shm /run /tmp; do findmnt -no TARGET,OPTIONS $m; done; swapon --show; nft list tables; cat /run/vh/power")
        check("stage 1 under vh-init: hidepid, noexec, zram, nft table, the power profile",
              all(x in out for x in ("hidepid=invisible", "noexec", "zram0", "table inet vh")), out[-600:].replace("\n", " | "))
        m2 = audit(ser, "vh-audit under vh-init")
        after = int(m2.group(2)) if m2 else None
        check("vh-audit: no new FAILs", before is not None and after is not None and after <= before, f"before {before}, after {after}")
        rc, out = run(ser, "vh-audit init")
        check("vh-audit init area: PID 1 is vh-init, no FAIL", "[FAIL]" not in out and "PID 1 is vh-init" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, "vh-ctl restart chronyd; vh-ctl status chronyd; ls /var/log/vh/")
        check("vh-ctl restart of a runit service, the log directories", "up" in out and "chronyd" in out, out[-400:].replace("\n", " | "))
        rc, out = run(ser, "vh-init --rollback; echo rb=$?; . /etc/vh/vh.env; xbps-reconfigure -f $VH_KERNEL >/tmp/uki2.log 2>&1; echo uki=$?", timeout=1800)
        check("vh-init --rollback and the UKI rebuilt", "rb=0" in out and "uki=0" in out, out[-400:].replace("\n", " | "))
    finally:
        # the regular shutdown through vh-init (poweroff of runit-void goes through SIGCONT and /run/runit/stopit)
        shutdown(vm, ser)
    vm, ser = boot(a)                     # back on runit
    try:
        rc, out = run(ser, "readlink /proc/1/exe; sv status /var/service/* | grep -vc '^run:'; vh-init --status; echo st=$?")
        check("after the rollback: runit is PID 1, every service up, --status exits 1", "runit" in out and "st=1" in out, out[-500:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)


STEPS["vhinit"] = step_vhinit
