"""Track E: the SELinux policy of this system on the VM rig (docs/uni/selinux.md): permissive on
the machine kernel built with features/selinux, under vh-init, on an installation with VH_MAC=selinux."""
import argparse
import re
import time

import vhvm
from steps.init import ctl_status, parse_status, pid1
from steps.kernel import JUDGED, install_trial, need_run_files, started
from vmlib import audit, boot, check, keys, run, shutdown

# the domain each program must run in (selinux/policy/*.cil), by its comm
DOMAINS = {"vh-init": "init_t", "udevd": "udev_t", "dbus-daemon": "dbusd_t", "socklog": "syslogd_t", "nanoklogd": "syslogd_t",
           "agetty": "getty_t", "unbound": "unbound_t", "chronyd": "chronyd_t", "seatd": "seatd_t", "dhcpcd": "dhcpcd_t",
           "vh-acpid": "acpid_t", "vh-sched": "sched_t", "login": "login_t", "refurswm": "wm_t", "refursline": "bar_t",
           "vh-wlfilter": "wlfilter_t", "pipewire": "pipewire_t", "wireplumber": "pipewire_t", "pipewire-pulse": "pipewire_t"}
# every process: pid, U (a program) or K (a kernel thread: no exe), its context, its comm
# (hidepid=invisible: the root shell sees them all)
PROCS = ("for p in /proc/[0-9]*; do c=$(cat $p/comm 2>/dev/null) || continue; k=U; readlink $p/exe >/dev/null 2>&1 || k=K; "
         "echo \"${p#/proc/} $k $(tr -d '\\0' < $p/attr/current 2>/dev/null) $c\"; done")
DENIALS = "echo DENIALS=$(dmesg | grep -ac 'avc:  denied'); vh-selinux denials; echo ====RAW; dmesg | grep -a 'avc:  denied'"


def procs(out):
    """[(pid, type, comm)] of PROCS' output, the kernel threads left out"""
    found = []
    for l in out.replace("\r", "").splitlines():
        m = re.match(r"(?:vh# )?(\d+) ([UK]) (\S+):(\S+):(\S+):(\S+) (.+)$", l)
        if m and m.group(2) == "U":
            found.append((int(m.group(1)), m.group(5), m.group(7).strip()))
    return found


def denials(out):
    m = re.search(r"DENIALS=(\d+)", out)
    return int(m.group(1)) if m else -1


def step_selinux(a):
    """SELinux permissive (docs/uni/selinux.md) on the machine kernel of build/kernel-custom (features
    selinux) under vh-init: the labels survive the stock kernel's boots; on the trial boot the policy is
    loaded by stage 1 and locked (secure_mode_policyload), every file is labelled as file_contexts says
    (vh-selabel --check /), every daemon runs in its domain, then a login on tty1 (typed on the VM's
    keyboard) starts the desktop as user_t and wm_t; the AVC denials of the boot, the login and the
    desktop are listed in full (the serial log), and the step passes only with none. Needs an
    installation with VH_MAC=selinux (kvm-smoke: mac=selinux), vh-init as PID 1 (the vhinit step
    before this one) and --repo."""
    need_run_files(a)
    vm, ser = boot(a)
    try:
        check("PID 1 is vh-init (the vhinit step before this one)", pid1(ser) == "vh-init")
        rc, out = run(ser, "cat /etc/vh/selinux/mode /etc/vh/selinux/BUILD; ls -l /etc/vh/selinux; grep -o 'lsm=[^ ]*' /proc/cmdline; vh-selinux status")
        check("installed with VH_MAC=selinux: the policy files, permissive, selinux before apparmor in lsm=",
              "permissive" in out and "file_contexts" in out and "lsm=landlock,lockdown,yama,selinux,apparmor" in out and "active: no" in out,
              out[-500:].replace("\n", " | "))
        # the stock kernel labels nothing it makes (adjtime, the logs, the shim): what differs here
        # is what the machine kernel's stage 1 relabels at its boot; the count is the record
        rc, out = run(ser, "vh-selabel --check --one-fs / > /tmp/chk.txt; echo chk=$?; head -8 /tmp/chk.txt; tail -1 /tmp/chk.txt")
        print(f"--- the stock kernel's boots left unlabelled: {out[-700:]}")
        rc, out = run(ser, "vh-ctl enable vh-sched")      # sched_t on the machine kernel
        mid, name = install_trial(ser)
    finally:
        shutdown(vm, ser)
    # the machine kernel, on trial: SELinux is its first exclusive LSM. Without --repo: the
    # refresh writes programs as the admin, which the policy forbids by design (neverallow 7),
    # and would fill the denials with the rig's own doing; the tools of the previous boot stay
    vm, ser = boot(argparse.Namespace(**{**vars(a), "repo": False}))
    try:
        rc, out = run(ser, JUDGED, timeout=300)
        check("the trial boot: Limine started the machine entry (the one-shot entry)", started(out) == mid, started(out))
        check("PID 1 is vh-init on the machine kernel", pid1(ser) == "vh-init")
        rc, out = run(ser, "uname -r; echo LSM=$(cat /sys/kernel/security/lsm); cat /run/vh/selinux; vh-selinux status; cat /sys/fs/selinux/checkreqprot; "
                           "cat /var/lib/vh/selinux.last")
        lsm = re.search(r"LSM=(\S+)", out)
        check("SELinux is the active LSM of the machine kernel, AppArmor is not", lsm is not None and "selinux" in lsm.group(1) and "apparmor" not in lsm.group(1) and "active: yes" in out,
              out[-600:].replace("\n", " | "))
        check("stage 1 loaded the policy, permissive this boot and the next", "enforcing: 0 (this boot); permissive at the next boot" in out and "loaded: policy /etc/vh/selinux/policy." in out,
              out[-600:].replace("\n", " | "))
        check("secure_mode_policyload is set: no policy load, no setenforce until the next boot", "secure_mode_policyload: 1" in out, out[-400:].replace("\n", " | "))
        check("the admin's root shell (doas -s) runs as sysadm_t", re.search(r"this shell: \S+:sysadm_t:", out) is not None, out[-300:].replace("\n", " | "))
        rc, out = run(ser, "vh-init --status | grep -a 'stage 1 done\\|steps'")
        print(f"--- stage 1 on the machine kernel (the relabel after a boot without the policy): {out.replace(chr(10), ' | ')[-700:]}")
        rc, out = run(ser, "vh-selabel --check / > /tmp/chk.txt; echo chk=$?; grep -v /usr/lib/modules/ /tmp/chk.txt | head -30; tail -1 /tmp/chk.txt; "
                           "for d in / /run /dev /tmp /dev/shm /var/tmp /run/vh /run/udev; do echo \"$d $(tr -d '\\0' < /proc/self/attr/current >/dev/null; getfattr -h --only-values -n security.selinux $d 2>/dev/null || echo ?)\"; done")
        check("vh-selabel --check /: every label as file_contexts says, the tmpfs mounts of stage 1 included", "chk=0" in out, out[-700:].replace("\n", " | "))
        rc, out = run(ser, PROCS)
        print(out)
        found = procs(out)
        wrong = [f"{c}[{p}]={t}" for p, t, c in found if c in DOMAINS and t != DOMAINS[c] and p != 1]
        seen = {c for p, t, c in found}
        p1 = [t for p, t, c in found if p == 1]
        check("PID 1 runs as kernel_t (the policy's loader), the manager and the daemons in their domains",
              p1 == ["kernel_t"] and not wrong and "vh-init" in seen, f"PID 1 {p1}; wrong: {'; '.join(wrong)[-500:]}")
        # a program still in an init domain ran from stage 1 or the manager without a transition on its exec
        unknown = sorted({f"{c}={t}" for p, t, c in found if t in ("kernel_t", "init_t", "initrc_t") and p != 1 and c != "vh-init"})
        print(f"--- programs in an init domain (no transition on their exec): {unknown}")
        st, out = ctl_status(ser)
        bad = [f"{n}({s})" for n, s in st.items() if s not in ("up", "done", "delayed")]
        check("every service up under SELinux permissive", st and not bad, "; ".join(bad)[-400:])
        rc, out = run(ser, "vh-ctl status vh-sched; vh-sched state")
        check("vh-sched loaded the scheduler as sched_t (BPF under the policy)", parse_status(out).get("vh-sched") == "up" and "state=enabled" in out, out[-300:].replace("\n", " | "))
        rc, out = run(ser, DENIALS)
        at_boot = denials(out)
        print(f"--- AVC denials after the boot: {at_boot}\n{out}")
        # the login of the everyday user on tty1, typed on the VM's keyboard (agetty, login, PAM,
        # vh-usersh = user_t), which goes straight into the desktop (zz-vh.sh: exec vh-session;
        # RefursWM on the virtio GPU, the pixman renderer when EGL does not come up)
        vm.monitor("sendkey ctrl-alt-f1")
        time.sleep(2)
        keys(vm, "user")
        vm.monitor("sendkey ret")
        time.sleep(4)
        keys(vm, vhvm.USER_PASS)
        vm.monitor("sendkey ret")
        rc, out = run(ser, "for i in $(seq 1 90); do pgrep -u user -x refurswm >/dev/null && break; sleep 1; done; sleep 20; "
                           "ps -o pid,ppid,user,tty,args -u user; cat /run/user/$(id -u user)/refurswm.log 2>/dev/null | tail -8; " + PROCS, timeout=600)
        found = procs(out)
        user = {c: t for p, t, c in found if c in ("vh-session", "refurswm", "refursline", "vh-wlfilter", "bash", "pipewire", "wireplumber")}
        print(f"--- the user's processes: {user}")
        check("the login on tty1: the desktop runs as wm_t, started from user_t", user.get("refurswm") == "wm_t" and "user_t" in [t for p, t, c in found if c in ("vh-session", "bash")],
              out[-600:].replace("\n", " | "))
        wrong = [f"{c}[{p}]={t}" for p, t, c in found if c in DOMAINS and t != DOMAINS[c] and p != 1]
        check("the session's programs in their domains (bar, filter, PipeWire)", not wrong, "; ".join(wrong)[-500:])
        rc, out = run(ser, DENIALS)
        after = denials(out)
        print(f"--- AVC denials after the login and the desktop: {after}\n{out}")
        check("zero AVC denials after the boot, the login on tty1 and the start of the desktop (permissive)", after == 0,
              f"{at_boot} after the boot, {after} after the login and the desktop (the lines above, with the CIL each one asks for)")
        rc, out = run(ser, "doas vh-audit selinux", timeout=600)
        check("vh-audit selinux area: no FAIL", "[FAIL]" not in out and "SELinux is active" in out, out[-500:].replace("\n", " | "))
        audit(ser, "vh-audit on the machine kernel with SELinux permissive")
        run(ser, "pkill -u user; true")
    finally:
        shutdown(vm, ser)


STEPS = {"selinux": step_selinux}
