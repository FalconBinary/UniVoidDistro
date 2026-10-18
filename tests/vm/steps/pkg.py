"""Packages: thor replacing xbps, vh-pkg over thor, vh-deep-clean (docs/12, docs/18)."""
from vmlib import VM_SRC, as_user, audit, boot, check, run, shutdown


def step_pkg(a):
    """vh-pkg over thor: a denied package is not installed; after an allow SUID is stripped
    already at unpack; removal."""
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "{ [ -e /etc/vh/optional/strict-net ] && vh-net xbps 30; true; }; vh-pkg add -y fuse3; echo PKG_RC=$?; xbps-query fuse3 >/dev/null 2>&1 || echo NO_FUSE3", timeout=900)
        check("vh-pkg: fuse3 from the deny list is not installed", "PKG_RC=0" not in out and "NO_FUSE3" in out and "denied" in out,
              out[-400:].replace("\n", " | "))
        rc, out = run(ser, "echo y | thor allow fuse3 && vh-pkg add -y fuse3; echo PKG_RC=$?", timeout=900)
        check("vh-pkg add after thor allow: installed", "PKG_RC=0" in out, out[-600:].replace("\n", " | "))
        rc, out = run(ser, "ls -l /usr/bin/fusermount3; grep fusermount3 /var/log/thor.log | tail -2; ls /etc/udev/rules.d/")
        check("SUID of fusermount3 stripped at unpack (thor)", "-rwsr" not in out and "SUID/SGID stripped: /usr/bin/fusermount3" in out,
              out[-300:].replace("\n", " | "))
        rc, out = run(ser, "vh-pkg rm fuse3; xbps-query fuse3; echo q=$?; sed -i '/^fuse3$/d' /etc/thor/allow.conf")
        check("vh-pkg rm: package removed", "q=2" in out or "q=1" in out)
    finally:
        shutdown(vm, ser)


def step_thor(a):
    """Moving an installed system to thor (as on the laptop over an older installation): the
    package from the local repository replaces xbps, the baseline comes from the installed
    packages, enforce policy; then an install through thor, vh-audit and a reboot."""
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "{ [ -e /etc/vh/optional/strict-net ] && vh-net xbps 60; true; }; "
                           f"mkdir -p /var/lib/thor/repo /etc/thor && cp {VM_SRC}/build/thor-repo/* /var/lib/thor/repo/ && "
                           "printf 'repository=/var/lib/thor/repo\\n' > /etc/xbps.d/01-thor.conf && "
                           "printf 'mode=enforce\\n' > /etc/thor/policy.conf && "
                           "xbps-install -Sy thor 2>&1 | tail -4; echo rc=$?", timeout=1800)
        rc, out = run(ser, "xbps-query -p pkgver thor; xbps-query -p pkgver xbps; thor --version; "
                           "grep -c thor_unpack_entry /usr/lib/libxbps.so.6")
        check("thor replaced xbps and libxbps", "thor-0.60.7" in out and "\nxbps-0.60.7" not in out and "thor 0.60.7" in out,
              out[-300:].replace("\n", " | "))
        rc, out = run(ser, "thor baseline && grep -c / /etc/thor/baseline && grep -E 'kernel.d|dracut' /etc/thor/baseline | head -5")
        check("thor baseline: kernel hooks and dracut modules of the base system", rc == 0 and "kernel.d" in out and "dracut" in out,
              out[-400:].replace("\n", " | "))
        rc, out = run(ser, "xbps-pkgdb -a; echo pkgdb=$?", timeout=900)
        check("xbps-pkgdb -a after the replacement", "pkgdb=0" in out, out[-300:].replace("\n", " | "))
        rc, out = run(ser, "{ [ -e /etc/vh/optional/strict-net ] && vh-net xbps 30; true; }; rm -f /var/cache/xbps/tree-* /var/cache/xbps/htop-*; thor install -y tree htop > /tmp/ti.log 2>&1; "
                           "grep -v '^x86_64-repodata\\|^\\[\\*\\]\\|unpacking\\|configuring\\|installed succ\\|verifying\\|collecting\\|^$' /tmp/ti.log | head -12; "
                           "xbps-query tree >/dev/null && echo HAS_TREE", timeout=1800)
        check("thor install: parallel download and install",
              "HAS_TREE" in out and "Downloading 2 packages" in out and "Downloaded" in out and "] tree-" in out and "] htop-" in out,
              out[-600:].replace("\n", " | "))
        rc, out = run(ser, "thor install -y polkit; echo POLKIT_RC=$?; xbps-query polkit >/dev/null 2>&1 || echo NO_POLKIT", timeout=900)
        check("thor: polkit denied", "denied" in out and "POLKIT_RC=0" not in out and "NO_POLKIT" in out,
              out[-300:].replace("\n", " | "))
        rc, out = run(ser, "xbps-reconfigure -f $(. /etc/vh/vh.env; echo $VH_KERNEL) 2>&1 | tail -6", timeout=1800)
        check("xbps-reconfigure of the kernel with thor -> UKI and Limine", "enrolled into Limine" in out, out[-500:].replace("\n", " | "))
        audit(ser, "vh-audit with thor without FAIL", want_zero_fails=True)
        run(ser, "thor remove -y tree htop >/dev/null 2>&1; true", timeout=600)
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "cat /proc/cmdline; sv status vh-acpid unbound; thor policy")
        check("boot with thor", "lockdown=confidentiality" in out and "run: vh-acpid" in out and "mode: enforce" in out,
              out[-300:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)


def step_clean(a):
    """vh-deep-clean in the real system: the junk of every group is removed, what is needed is
    intact, vh-audit has no new FAILs, the system boots, restore brings the backup back (docs/12)."""
    vm, ser = boot(a)
    try:
        run(ser, "{ [ -e /etc/vh/optional/strict-net ] && vh-net xbps 30; true; }; xbps-install -SAy tree >/dev/null 2>&1; "
                 "echo x > /etc/vhtest.conf.new-1.0_1; "
                 "ln -sfn /etc/sv/vhghost /etc/runit/runsvdir/default/vhghost; "
                 "mkdir -p /usr/lib/modules/6.0.0_1 && echo x > /usr/lib/modules/6.0.0_1/modules.dep", timeout=900)
        run(ser, as_user("user", "mkdir -p /home/user/.cache/vhjunk /home/user/.local/share/Trash/files && "
                                 "head -c 200000 /dev/urandom > /home/user/.cache/vhjunk/blob && "
                                 "echo t > /home/user/.local/share/Trash/files/old.txt"))
        rc, out = run(ser, "xbps-query tree >/dev/null && echo HAS_TREE; ls /var/lib/vh-browser/trusted/profile/prefs.js "
                           "2>/dev/null && echo HAS_PROFILE; uname -r")
        had_profile = "HAS_PROFILE" in out
        check("rig: junk created", "HAS_TREE" in out, out[-200:].replace("\n", " | "))
        rc, out = run(ser, "vh-deep-clean --user", timeout=600)
        check("plan: every junk group shown",
              rc == 0 and all(x in out for x in ("tree-", "vhtest.conf.new-1.0_1", "vhghost", "6.0.0_1", "/home/user/.cache", "Trash")),
              out[-1500:].replace("\n", " | "))
        rc, out = run(ser, "xbps-query tree >/dev/null && test -e /etc/vhtest.conf.new-1.0_1 && echo UNCHANGED")
        check("the plan changed nothing", "UNCHANGED" in out)
        rc, out = run(ser, "vh-deep-clean --apply -y --user", timeout=1800)
        check("--apply: exit 0, vh-audit and xbps-pkgdb without new errors",
              rc == 0 and "System is in order" in out and "no new FAILs" in out, out[-1500:].replace("\n", " | "))
        rc, out = run(ser, "xbps-query tree >/dev/null || echo NO_TREE; test -e /etc/vhtest.conf.new-1.0_1 || echo NO_NEW; "
                           "test -L /etc/runit/runsvdir/default/vhghost || echo NO_GHOST; "
                           "test -e /usr/lib/modules/6.0.0_1 || echo NO_STALE; test -d /usr/lib/modules/$(uname -r) && echo RUN_KERNEL; "
                           "test -e /home/user/.cache/vhjunk || echo NO_JUNK; "
                           "test -e /home/user/.local/share/Trash/files/old.txt || echo NO_TRASH; "
                           "ls /var/lib/vh-browser/trusted/profile/prefs.js 2>/dev/null && echo HAS_PROFILE; "
                           "test -z \"$(ls -A /var/cache/xbps)\" && echo CACHE_EMPTY")
        for mark, name in (("NO_TREE", "orphan removed"), ("NO_NEW", ".new file removed"), ("NO_GHOST", "dangling service link removed"),
                           ("NO_STALE", "module directory without a kernel removed"), ("RUN_KERNEL", "modules of the running kernel intact"),
                           ("NO_JUNK", "user's ~/.cache cleaned"), ("NO_TRASH", "trash emptied"),
                           ("CACHE_EMPTY", "xbps cache empty")):
            check(f"--apply: {name}", mark in out)
        check("--apply: Firefox profile intact", not had_profile or "HAS_PROFILE" in out)
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "cat /proc/cmdline; sv status vh-acpid unbound")
        check("boot after the clean-up", "lockdown=confidentiality" in out and "run: vh-acpid" in out and "run: unbound" in out,
              out[-300:].replace("\n", " | "))
        audit(ser, "vh-audit after the reboot without FAIL", want_zero_fails=True)
        rc, out = run(ser, "vh-deep-clean restore; test -e /etc/vhtest.conf.new-1.0_1 && test -L /etc/runit/runsvdir/default/vhghost "
                           "&& echo RESTORED; rm -f /etc/vhtest.conf.new-1.0_1 /etc/runit/runsvdir/default/vhghost")
        check("restore brought the backup back", "RESTORED" in out, out[-300:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)


STEPS = {"pkg": step_pkg, "thor": step_thor, "clean": step_clean}
