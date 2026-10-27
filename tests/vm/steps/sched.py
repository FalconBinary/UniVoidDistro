"""Track S (U4): vh-sched, the sched_ext scheduler, as the service vh-sched.svc of vh-init on the
machine kernel of a kernel-custom run (sched/README.md, rootfs/etc/vh/services/vh-sched.svc)."""
import re

from steps.init import ctl_status, parse_status, pid1
from steps.kernel import JUDGED, install_trial, need_run_files, remove_trial, started
from vmlib import boot, check, run, shutdown


def step_sched(a):
    """vh-sched under vh-init on the machine kernel (build/kernel-custom, CONFIG_SCHED_CLASS_EXT):
    enabled on the stock kernel, where the loader has nothing to load and the manager waits with a
    backoff; on the machine kernel's trial boot the service is up from the start and the scheduler
    runs the whole system (switch_all=1); vh-ctl stop gives the kernel's own scheduler back, start
    loads it again; then the service is disabled and the machine UKI removed. Needs vh-init as
    PID 1 (the vhinit step before this one) and --repo."""
    need_run_files(a)
    vm, ser = boot(a)
    try:
        check("PID 1 is vh-init (the vhinit step before this one)", pid1(ser) == "vh-init")
        rc, out = run(ser, "uname -r; test -d /sys/kernel/sched_ext && echo SCX=yes || echo SCX=no; vh-sched --version; "
                           "ls -l /usr/local/lib/vh/vh_sched.o; vh-sched lint /usr/local/lib/vh/vh_sched.o; echo lint=$?")
        check("the stock kernel has no sched_ext; the loader and its object are installed, the lint passes",
              "SCX=no" in out and "lint=0" in out and "vh-sched " in out and "vh_sched.o" in out, out[-400:].replace("\n", " | "))
        rc, out = run(ser, "vh-sched topology")
        print(out)
        rc, out = run(ser, "vh-ctl enable vh-sched; sleep 5; vh-ctl status vh-sched; tail -3 /var/log/vh/vh-sched/current 2>/dev/null")
        check("vh-ctl enable vh-sched: enabled; on the stock kernel the loader exits and the manager waits with a backoff",
              "enabled vh-sched" in out and parse_status(out).get("vh-sched") != "up" and "no sched_ext in this kernel" in out, out[-400:].replace("\n", " | "))
        mid, name = install_trial(ser)
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)                     # the machine kernel, on trial
    try:
        rc, out = run(ser, JUDGED, timeout=300)
        check("the trial boot: Limine started the machine entry (the one-shot entry)", started(out) == mid, started(out))
        check("PID 1 is vh-init on the machine kernel", pid1(ser) == "vh-init")
        rc, out = run(ser, "uname -r; cat /run/vh/check.done; vh-ctl status vh-sched; vh-sched state; "
                           "cat /sys/kernel/sched_ext/state /sys/kernel/sched_ext/switch_all /sys/kernel/sched_ext/root/ops 2>&1; vh-ctl blame | grep -a vh-sched")
        check("the machine kernel runs (-vh), vh-kconf check finds the rig with every driver", "-vh" in out and "machine=same" in out and "lost=0" in out, out[-300:].replace("\n", " | "))
        check("the vh-sched service is up from the boot and the scheduler runs the whole system (switch_all=1)",
              parse_status(out).get("vh-sched") == "up" and "state=enabled switch_all=1" in out and "root/ops=vh_sched" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, "tail -8 /var/log/vh/vh-sched/current")
        print(out)
        rc, out = run(ser, "vh-ctl stop vh-sched -w 15; vh-ctl status vh-sched; vh-sched state; tail -3 /var/log/vh/vh-sched/current")
        check("vh-ctl stop vh-sched: the loader exits on SIGTERM (SCX_EXIT_UNREG) and the kernel is back on its own scheduler",
              parse_status(out).get("vh-sched") == "down" and "(wanted down)" in out and "SCX_EXIT_UNREG" in out and "state=disabled" in out, out[-500:].replace("\n", " | "))
        # the service is ready when the loader has attached the link (vh-sched.svc: ready = fd 3)
        rc, out = run(ser, "vh-ctl start vh-sched -w 15; vh-ctl status vh-sched; vh-sched state")
        check("vh-ctl start vh-sched: loaded again, ready once the link is attached", parse_status(out).get("vh-sched") == "up" and "state=enabled switch_all=1" in out, out[-400:].replace("\n", " | "))
        st, out = ctl_status(ser)
        bad = [f"{n}({s})" for n, s in st.items() if s not in ("up", "done", "delayed")]
        check("every service up under vh-init on the machine kernel", st and not bad, "; ".join(bad)[-400:])
        rc, out = run(ser, "doas vh-audit init", timeout=600)
        check("vh-audit init area: no FAIL", "[FAIL]" not in out and "PID 1 is vh-init" in out, out[-400:].replace("\n", " | "))
        rc, out = run(ser, "vh-ctl disable vh-sched; sleep 3; vh-ctl status vh-sched 2>&1 | head -2; echo STATE=$(cat /sys/kernel/sched_ext/state)")
        check("vh-ctl disable vh-sched: the service stopped and gone, the kernel's own scheduler",
              "disabled vh-sched" in out and parse_status(out).get("vh-sched") != "up" and "STATE=disabled" in out, out[-300:].replace("\n", " | "))
        remove_trial(ser, name)
    finally:
        shutdown(vm, ser)


STEPS = {"sched": step_sched}
