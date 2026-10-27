"""Track I: vh-stage1 in place of /etc/runit/1 (init/, docs/runbook-gf63.md)."""
import os
import re
import sys

import vhvm
from vmlib import VM_SRC, audit, boot, check, devname_unused, run, shutdown
# the boot assessment's helpers (steps/kernel.py): the state of this boot judged, the entry this
# boot started, a reset at the passphrase prompt
from steps.kernel import JUDGED, reset_at_prompt, started


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


STATUS_RX = re.compile(r"^(\S+)\s+(" + "|".join(STATES) + r")\s+pid \+(\d+)\s+(\d+)s")


def parse_status(out):
    """vh-ctl's status lines ("NAME STATE pid +PID Ns [restarts N] [(wanted down)]") as {name: state}"""
    st = {}
    for l in lines(out):
        m = STATUS_RX.match(l)
        if m:
            st[m.group(1)] = m.group(2)
    return st


def ctl_status(ser):
    """vh-ctl status as {name: state}, and the raw output"""
    rc, out = run(ser, "vh-ctl status")
    return parse_status(out), out


def sv_status(ser):
    """sv status /var/service/* (runit's sv, or the shim) as {name: "run" | "down" | "fail" | ...}"""
    rc, out = run(ser, "sv status /var/service/*")
    st = {}
    for l in lines(out):
        m = re.match(r"(run|down|fail|warning|timeout|ok): ([^:]+):", l)
        if m:
            st[m.group(2).rsplit("/", 1)[-1]] = m.group(1)     # runit's sv names the path it was given
    return st, out


# the identifier Limine gives the init twin's entry, "Void Linux VER (vh-init)" (lib/assess.zig)
INIT_ID_RX = re.compile(r"^Void-Linux-(\S+)--vh-init-$")


def step_vhinit(a):
    """vh-init as PID 1 (init/README.md, v0.2) through the boot assessment (docs/uni/kernel.md):
    vh-init --install writes /etc/vh/init-boot and runs vh-limine-update, which gives the newest
    stock UKI a twin with init= appended to its command line (the same kernel and initrd), signed,
    "Void Linux VER (vh-init)" in Limine's menu and on trial through the one-shot entry; the stock
    UKI (runit) is untouched and the hook unedited. The first trial boot is reset at its passphrase
    prompt: the boot after it runs runit by itself and records the failure; --retry; the trial boot
    then runs vh-init, the manager and every service of /var/service and /etc/vh/services/enabled
    (vh-ctl status and the sv shim agree; vh-audit without new FAILs and with the init area; the
    stage-1 time of the kernel log; a poweroff through runit-void's command ends in stage 3 and
    reboot(2)), and the service counts it: 1 of 3 good boots, set again. vh-init stays PID 1 for
    the steps after this one (base is the second good boot; vhinit-rollback the third, the default,
    then the way back). Needs --repo (the binaries come from build/, which tests/zig/build.sh fills)."""
    if not getattr(a, "repo", False):
        sys.exit("the vhinit step needs --repo")
    for b in ("vh-init", "vh-ctl", "vh-limine-update"):
        if not os.path.isfile(os.path.join(vhvm.REPO, "build", b)):
            sys.exit(f"no build/{b}: sh tests/zig/build.sh")
    vm, ser = boot(a)
    try:
        check("before: PID 1 is runit", pid1(ser) == "runit")
        m = audit(ser, "vh-audit before vh-init (the reference FAIL count)")
        before = int(m.group(2)) if m else None
        rc, out = run(ser, "vh-init --version; vh-init --check; echo chk=$?")
        check("vh-init --check: the definitions parse, no problem", "chk=0" in out and "problem:" not in out, out[-600:].replace("\n", " | "))
        rc, out = run(ser, "mount -o ro /boot/efi; sha256sum /boot/efi/EFI/void/linux-*.efi; umount /boot/efi; vh-limine-update --status")
        sums_before = dict(re.findall(r"^([0-9a-f]{64})  (/boot/efi/EFI/void/\S+)", out.replace("\r", ""), re.M))
        stock = started(out)
        check("before: this boot started the stock entry; no UKI with vh-init on the ESP, Limine takes one-shot entries",
              stock.startswith("Void-Linux-") and "vh-init" not in stock and sums_before and not any(p.endswith("-vh-init.efi") for p in sums_before) and "one-shot entries: yes" in out,
              f"{stock}; {sorted(sums_before.values())}")
        rc, out = run(ser, "vh-init --install; echo in=$?; readlink /usr/bin/sv; cat /etc/xbps.d/31-vh-init.conf; grep init= /etc/default/dracut-uefi-hook || echo HOOK-CLEAN; cat /etc/vh/init-boot | head -1", timeout=900)
        m = re.search(r"the UKI with vh-init (linux-(\S+)-vh-init\.efi): the stock UKI (linux-\S+\.efi)", out)
        name, ver, stock_name = (m.group(1), m.group(2), m.group(3)) if m else ("?", "?", "?")
        iid = f"Void-Linux-{ver}--vh-init-"
        check("vh-init --install: the twin made and on trial, the sv shim, the noextract file, the hook untouched, the marker",
              "in=0" in out and m is not None and f"the stock kernel {ver} with vh-init is on trial: the next boot tries it once" in out
              and "vh-ctl" in out and "noextract=/usr/bin/sv" in out and "HOOK-CLEAN" in out and "vh-init is wanted as PID 1" in out,
              out[-900:].replace("\n", " | "))
        rc, out = run(ser, "vh-limine-update --status; vh-init --status; echo st=$?; mount -o ro /boot/efi; ls /boot/efi/EFI/void/; "
                           "sha256sum /boot/efi/EFI/void/linux-*.efi; grep -ac init=/usr/local/sbin/vh-init /boot/efi/EFI/void/linux-*.efi; umount /boot/efi")
        check("vh-limine-update --status: on trial, 0 of 3, set for the next boot through the one-shot entry",
              f"on trial: the stock kernel {ver} with vh-init ({name}), 0 of 3 good boots, set for the next boot" in out and f"LoaderEntryOneShot: {iid}" in out
              and "the default: the newest stock UKI" in out and "vh-init (init/README.md): wanted" in out, out[-900:].replace("\n", " | "))
        check("vh-init --status: runit is PID 1 (exit 1), the marker present, the trial", "st=1" in out and "present (vh-init is wanted" in out and f"on trial: {name}, 0 of 3 good boots, set for the next boot" in out,
              out[-700:].replace("\n", " | "))
        sums_after = dict(re.findall(r"^([0-9a-f]{64})  (/boot/efi/EFI/void/\S+)", out.replace("\r", ""), re.M))
        counts = dict(re.findall(r"^/boot/efi/EFI/void/(\S+):(\d+)", out.replace("\r", ""), re.M))
        check("the stock UKIs are untouched (the same bytes), the twin beside them carries init=, no stock UKI does",
              sums_before and all(sums_after.get(p) == h for h, p in sums_before.items()) and f"/boot/efi/EFI/void/{name}" in sums_after.values()
              and counts.get(name) == "1" and all(c == "0" for n, c in counts.items() if n != name),
              f"before {sorted(sums_before.values())}; after {sorted(sums_after.values())}; init= counts {counts}")
        rc, out = run(ser, "sv status /var/service/*; echo ===; sv status /var/service/* | grep -c '^run:'; sv status /var/service/* | grep -vc '^run:'")
        nums = [l.strip() for l in lines(out.split("===")[-1]) if l.strip().isdigit()]
        check("the sv shim runs runit's sv while runit is PID 1 (every service run:)", len(nums) == 2 and nums[1] == "0" and int(nums[0]) > 5, out[-300:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
    # the first trial boot, reset at its passphrase prompt (the initramfs is the stock one): what a
    # hang and a power cycle do; Limine consumed the one-shot entry, so the boot after it is the
    # stock UKI, runit, with nothing chosen in the menu
    vm, ser = boot(a, on_prompt=reset_at_prompt)
    try:
        check("after the reset trial boot: runit is PID 1 by itself", pid1(ser) == "runit")
        rc, out = run(ser, JUDGED, timeout=300)
        check("the reset trial: the stock entry booted, the trial is recorded as failed, the reason given",
              started(out) == stock and f"failed its trial: the stock kernel {ver} with vh-init ({name})" in out and "did not reach the end of the boot" in out,
              out[-700:].replace("\n", " | "))
        rc, out = run(ser, "vh-init --status; echo st=$?; cat /run/vh/boot-assess")
        check("vh-init --status after the failed trial: runit, the failure and --retry named", "st=1" in out and "failed its trial" in out and f"--retry {name}" in out,
              out[-600:].replace("\n", " | "))
        rc, out = run(ser, "vh-limine-update --retry")
        check("--retry: on trial again, set for the next boot", rc == 0 and f"the stock kernel {ver} with vh-init is on trial again: the next boot tries it" in out, out[-400:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)                     # the first good trial boot: vh-init through the one-shot entry
    try:
        check("PID 1 is vh-init", pid1(ser) == "vh-init")
        rc, out = run(ser, JUDGED, timeout=300)
        check("trial boot 1: Limine started the vh-init entry (the one-shot entry); the service counted it and set it again",
              started(out) == iid and "1 of 3 good boots, set for the next boot" in out and f"LoaderEntryOneShot: {iid}" in out, out[-600:].replace("\n", " | "))
        rc, out = run(ser, "cat /proc/cmdline; vh-init --status; echo st=$?; dmesg | grep -a 'vh-init: \\|vh-stage1: '")
        check("init= in the command line; --status reports vh-init, the trial and the manager",
              "init=/usr/local/sbin/vh-init" in out and "st=0" in out and "manager:" in out and f"on trial: {name}, 1 of 3 good boots" in out, out[-900:].replace("\n", " | "))
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
        rc, out = run(ser, "vh-audit init; vh-audit boot | grep -a 'vh-init\\|boot assessment'")
        check("vh-audit: the init area clean, the boot area counts the UKI with vh-init and the trial",
              "[FAIL]" not in out and "PID 1 is vh-init" in out and "UKIs with vh-init on the ESP: 1" in out and "boot assessment: on trial" in out, out[-700:].replace("\n", " | "))
        rc, out = run(ser, "vh-ctl restart chronyd -w 10; vh-ctl status chronyd; sv status chronyd; ls /var/log/vh/; tail -2 /var/log/vh/vh-acpid/current")
        check("vh-ctl restart of a runit service; sv sees it; the log directories", parse_status(out).get("chronyd") == "up" and "run: chronyd" in out and "vh-acpid" in out, out[-400:].replace("\n", " | "))
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
    """The rest of vh-init's assessment and the way back (init/README.md): the trial boots up to the
    third good one (the base step between vhinit and this one is the second), after which vh-init
    is Limine's default with limine.conf unchanged; the boot of the default; then vh-init
    --rollback: the twin demoted, /etc/vh/init-boot removed, vh-limine-update deletes the twin and
    its entry and forgets the trial, runit's sv is back and the noextract file gone; the boot after
    it runs runit with every service up."""
    for n in range(1, 5):
        vm, ser = boot(a)
        try:
            check(f"trial boot {n} of the rest: PID 1 is vh-init", pid1(ser) == "vh-init")
            rc, out = run(ser, JUDGED, timeout=300)
            sel = started(out)
            check(f"trial boot {n} of the rest: Limine started the vh-init entry", INIT_ID_RX.match(sel) is not None, sel)
            if re.search(r"the default: the stock kernel \S+ with vh-init", out):
                check("the third good boot: vh-init is Limine's default (LoaderEntryDefault), on trial: none",
                      f"LoaderEntryDefault: {sel}" in out and "on trial: none" in out, out[-500:].replace("\n", " | "))
                break
            check(f"trial boot {n} of the rest: counted and set again", re.search(r"[12] of 3 good boots, set for the next boot", out) is not None, out[-500:].replace("\n", " | "))
        finally:
            shutdown(vm, ser)
    else:
        check("vh-init became Limine's default within four boots", False)
    vm, ser = boot(a)                     # Limine's default: no one-shot entry
    try:
        check("the default boots vh-init", pid1(ser) == "vh-init")
        rc, out = run(ser, JUDGED, timeout=300)
        sel = started(out)
        check("this boot: Limine's default entry is vh-init's, no one-shot entry, nothing on trial",
              INIT_ID_RX.match(sel) is not None and f"LoaderEntryDefault: {sel}" in out and "LoaderEntryOneShot: -" in out and "on trial: none" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, "vh-init --status; echo st=$?; mount -o ro /boot/efi; sha256sum /boot/efi/EFI/BOOT/limine.conf; umount /boot/efi; cat /run/vh/boot-assess 2>/dev/null || echo NO-NEWS")
        check("vh-init --status: vh-init is PID 1 and Limine's default; the service has no news", "st=0" in out and "Limine's default: linux-" in out and "passed its 3 boots" in out and "NO-NEWS" in out,
              out[-600:].replace("\n", " | "))
        rc, out = run(ser, "vh-audit boot | grep -a 'vh-init\\|boot assessment'")
        check("vh-audit: the default passed its assessment", "boot assessment: the default passed it" in out and "UKIs with vh-init on the ESP: 1" in out, out[-400:].replace("\n", " | "))
        rc, out = run(ser, "vh-init --rollback; echo rb=$?; readlink /usr/bin/sv || echo 'sv is a file'; ls /etc/vh/init-boot /etc/xbps.d/31-vh-init.conf 2>&1", timeout=900)
        check("vh-init --rollback: demoted, the marker and the twin gone, runit's sv back, the noextract file away",
              "rb=0" in out and "is no longer the default" in out and "deleting the UKI with vh-init" in out and "sv is a file" in out and out.count("No such file") >= 2,
              out[-900:].replace("\n", " | "))
        rc, out = run(ser, "vh-limine-update --status; echo ===; mount -o ro /boot/efi; ls /boot/efi/EFI/void/; umount /boot/efi")
        esp = [w for l in lines(out.split("===")[-1]) for w in l.split() if w.startswith("linux-") and w.endswith(".efi")]
        check("after the rollback: the stock UKI is the default, nothing is on trial, no UKI with vh-init on the ESP",
              "the default: the newest stock UKI" in out and "on trial: none" in out and "LoaderEntryDefault: -" in out and esp and not any(e.endswith("-vh-init.efi") for e in esp),
              (out[-500:] + " ESP: " + " ".join(esp)).replace("\n", " | "))
    finally:
        shutdown(vm, ser)                 # the regular shutdown through vh-init
    vm, ser = boot(a)                     # back on runit
    try:
        check("after the rollback: runit is PID 1", pid1(ser) == "runit")
        rc, out = run(ser, "vh-limine-update --status; sv status /var/service/* | grep -vc '^run:'; vh-init --status; echo st=$?; vh-audit boot | grep -a 'vh-init\\|boot assessment'")
        nums = [l.strip() for l in lines(out) if l.strip().isdigit()]
        sel = started(out)
        check("the stock entry booted, every runit service up, --status exits 1 and names runit and no UKI with vh-init; the audit agrees",
              sel.startswith("Void-Linux-") and "vh-init" not in sel and nums[:1] == ["0"] and "st=1" in out and "PID 1: runit" in out
              and "no UKI with vh-init (doas vh-init --install)" in out and "no UKI with vh-init on the ESP" in out, out[-700:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)


STEPS["vhinit"] = step_vhinit
STEPS["vhinit-rollback"] = step_vhinit_rollback
