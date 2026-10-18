"""The desktop: RefursWM headless, the bar, the Wayland filter, the sandboxed browser."""
import re

from vmlib import boot, check, run, session_usage, shutdown


def step_desktop(a):
    """RefursWM without a screen (headless, pixman) -> bar -> vh-wlfilter -> vh-browse -> doas -> bwrap -> Firefox."""
    vm, ser = boot(a)
    U = "setpriv --reuid=user --regid=user --init-groups env -i HOME=/home/user " \
        "XDG_RUNTIME_DIR=/run/user/$(id -u user) PATH=/usr/local/bin:/usr/bin LANG=C.UTF-8"
    try:
        # test rig: no screen and no seatd (headless backend, pixman renderer)
        run(ser, "install -d -m 0700 -o user -g user /run/user/$(id -u user); "
                 "chmod 2750 /run/vh-sandbox; ls -ld /run/vh-sandbox")   # as 11-vh-runtime.sh: the rig may predate it
        rc, out = run(ser, f"{U} WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1 "
                           "sh -c '/usr/local/bin/refurswm >/tmp/vh-refurswm.log 2>&1 &'; sleep 30; doas ls -l /run/vh-sandbox; "
                           "ls -l /run/user/$(id -u user)/; pgrep -u user -l . | sort -k2 | uniq -f1; "
                           "doas grep -a -E 'running on|sandbox:|cannot run' /tmp/vh-refurswm.log")
        check("RefursWM (headless) started, sandbox socket present", "refurswm" in out and "wayland-0-sandbox" in out)
        check("RefursWM: its own sandbox (Landlock + seccomp)", re.search(r"sandbox: landlock", out) is not None)
        check("vh-wlfilter: socket of group browser, 0660", re.search(r"srw-rw---- 1 user browser .* wayland", out) is not None)
        check("RefursLine bar running", "refursline" in out)
        check("autostart without 'cannot run'", "cannot run" not in out, out[-400:].replace("\n", " | "))
        out = session_usage(ser, "user", 60)
        m = re.search(r"^TOTAL (\d+) 0 (\d+) (\d+)", out, re.M)
        check("idle session measurement", m is not None, out[-300:].replace("\n", " | "))
        rc, out = run(ser, f"{U} WAYLAND_DISPLAY=wayland-0 sh -c 'vh-browse untrusted >/tmp/vh-ff.log 2>&1 &'; "
                           "sleep 90; pgrep -u browser -l firefox | head; "
                           "for p in $(pgrep -u browser firefox | head -3); do doas cat /proc/$p/attr/current; echo; "
                           "doas grep -E 'Seccomp:|NoNewPrivs|CapEff' /proc/$p/status; done", timeout=600)
        check("Firefox runs as user browser", "firefox" in out)
        session_usage(ser, "browser", 30)
        check("Firefox under the vh.firefox profile (enforce)", "vh.firefox (enforce)" in out)
        check("Firefox: no_new_privs, no capabilities", "NoNewPrivs:\t1" in out and "CapEff:\t0000000000000000" in out)
        rc, out = run(ser, "doas sh -c 'cat /tmp/vh-ff.log; grep -a vh-wlfilter /tmp/vh-refurswm.log | tail -5'")
        check("vh-wlfilter without protocol errors", "client disconnected" not in out, out[-400:].replace("\n", " | "))
        rc, out = run(ser, "doas sh -c 'grep -ah DENIED /var/log/socklog/kernel/current | grep -v chronyd | tail -15'")
        print(out)
        rc, out = run(ser, "p=$(pgrep -u browser firefox | head -1); ls /proc/$p/root/ /proc/$p/root/home/browser; "
                           "echo interrupts=$(nsenter -t $p -m cat /proc/interrupts | wc -c); "
                           "grep -E ' /tmp | /dev/shm ' /proc/$p/mountinfo; grep Seccomp: /proc/$p/status")
        check("sandbox: /proc/interrupts empty", "interrupts=0" in out)
        check("sandbox: /tmp and /dev/shm noexec", len(re.findall(r" /(tmp|dev/shm) .*noexec", out)) >= 2)
        check("sandbox: the bwrap seccomp filter is active", "Seccomp:\t2" in out)
        run(ser, "doas pkill -u browser; doas pkill -u user; true")
    finally:
        shutdown(vm, ser)


STEPS = {"desktop": step_desktop}
