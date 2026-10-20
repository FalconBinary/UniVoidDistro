"""The installation path of a new machine: base, ctools, enroll, sb, lock."""
import re

from vmlib import as_user, audit, boot, check, run, shutdown


def step_base(a):
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "cat /proc/cmdline")
        check("cmdline from the UKI (lockdown, lsm)", "lockdown=confidentiality" in out and "lsm=landlock" in out)
        rc, out = run(ser, "cat /sys/kernel/security/lsm; echo; cat /sys/kernel/security/lockdown")
        check("LSM: apparmor active, no bpf", "apparmor" in out and ",bpf" not in out)
        check("lockdown: confidentiality", "[confidentiality]" in out)
        rc, out = run(ser, "doas sv status /var/service/*")
        bad = [l for l in out.splitlines() if l.startswith(("down:", "fail:", "warning:"))]
        check("all runit services running", not bad, "; ".join(bad))
        rc, out = run(ser, "ok=1; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do getent hosts voidlinux.org && { ok=0; break; }; sleep 5; done; test $ok = 0")
        check("DNS through unbound (DoT)", rc == 0)
        rc, out = run(ser, "ok=1; for i in $(seq 1 24); do doas chronyc -n -N authdata | awk 'NR>2 && $2==\"NTS\" && $4>0 {f=1} END {exit !f}' && { ok=0; break; }; sleep 5; done; doas chronyc -N authdata; test $ok = 0")
        check("chrony: NTS sources with keys", rc == 0)
        # vh-kconf check of this boot (the vh-check service, 5 s after the services start): the rig
        # is the machine of /etc/vh/hw.zon, every device has its driver and no firmware failed.
        # The rig has no Wi-Fi: cfg80211, which dhcpcd's nl80211 lookup loaded until
        # rootfs/etc/modprobe.d/vh-cfg80211.conf, asked for the trimmed regulatory.db at every boot
        rc, out = run(ser, "for i in $(seq 1 30); do test -e /run/vh/check.done && break; sleep 2; done; "
                           "cat /run/vh/check.done; doas cat /run/vh/check 2>/dev/null; "
                           "grep -E '^(cfg80211|mac80211) ' /proc/modules || echo 'no 802.11 stack'")
        check("vh-kconf check: the rig's own machine, every driver, no firmware failure",
              "VH_CHECK machine=same devices=0 firmware=0 lost=0" in out, out[-600:].replace("\n", " | "))
        check("no cfg80211 without Wi-Fi", "no 802.11 stack" in out, out[-200:].replace("\n", " | "))
        audit(ser, "vh-audit")
        rc, out = run(ser, "ls /usr/local/bin; ls -l /usr/local/bin/vh-wlfilter /usr/local/libexec/vh/browser-sandbox")
        check("RefursWM and RefursLine installed", "refurswm" in out and "refursline" in out)
        check("scripts executable", out.count("-rwxr-xr-x") >= 2)
        rc, out = run(ser, "cd /usr/local/bin && grep -v '^#' /etc/vh/desktop.sha256 | sha256sum -c; "
                           "ls /usr/local/share/refurswm/libinput | wc -l; xbps-query mangowc >/dev/null; echo mango=$?; "
                           "ldd /usr/local/bin/refurswm | awk '{print $1}' | sort | tr '\\n' ' '; echo; "
                           "ldd /usr/local/bin/refursline 2>&1")
        check("RefursWM/RefursLine: sha256 as in /etc/vh/desktop.sha256", out.count(": OK") == 2, out[:300])
        check("mango not installed", "mango=2" in out or "mango=1" in out)
        check("RefursLine is a static binary without libc", "not a dynamic" in out or "statically" in out)
        print(out)
        rc, out = run(ser, "doas xbps-pkgdb -a; echo pkgdb=$?")
        check("xbps-pkgdb -a (with firmware noextract)", "pkgdb=0" in out, out.strip().splitlines()[-1] if out.strip() else "")
        rc, out = run(ser, "du -sm /usr/lib/firmware; doas du -sxm / 2>/dev/null | tail -1; free -m; ls -d /proc/[0-9]* | wc -l; swapon --show")
        print(out)
        rc, out = run(ser, "doas nft list ruleset | grep -c . ; doas nft list set inet vh people_tmp")
        check("nftables: table and strict-mode sets", rc == 0)
        rc, out = run(ser, "id -nG user")
        check("groups: user not in wheel/input/video", not re.search(r"\b(wheel|input|video)\b", out.split("\n", 1)[-1]))
        rc, out = run(ser, "doas sh -c 'grep -c . /sys/kernel/security/apparmor/profiles; cat /sys/kernel/security/apparmor/profiles'")
        check("AppArmor profiles loaded", "vh.firefox" in out and "vh.unbound" in out)
        rc, out = run(ser, "install -m 0755 /root/vh/tools/vh-bench /tmp/vh-bench && "
                           + as_user("admin", "cd /tmp && sh /tmp/vh-bench"), timeout=900)
        check("tools/vh-bench works (dash)", "Report:" in out and "zstd" in out, out[-500:].replace("\n", " | "))
        # at boot vh-acpid may start before socklog-unix and lose its first lines (vlogger
        # without /dev/log): restart, as in the ctools step
        rc, out = run(ser, "doas sh -c 'sv restart vh-acpid; sleep 3; grep -ah vh-acpid /var/log/socklog/*/current | tail -3; "
                           "grep -c \"Power Button\" /proc/bus/input/devices; ls /sys/bus/acpi/drivers/tiny-power-button 2>/dev/null'")
        if "LNXPWRBN" in out:
            # the fixed button alone (q35; hwdb rule acpi.power-button.fixed): kernel 6.18 drives it with
            # tiny_power_button, which signals init; /etc/runit/ctrlaltdel hands it to vh-acpid
            check("the fixed power button: tiny_power_button drives it, vh-acpid waits for SIGUSR1",
                  "SIGUSR1" in out, out[-300:].replace("\n", " | "))
        else:
            check("vh-acpid found the power button", "power:" in out)
        # the last check, since it powers the VM off: the ACPI power button pressed the way a
        # hypervisor presses it (system_powerdown), and POWER_KEY=poweroff: a regular poweroff
        mark = len(ser.alltext)
        vm.monitor("system_powerdown")
        try:
            ser.expect(r"reboot: Power down", 240)
        except (TimeoutError, EOFError):
            pass
        tail = ser.alltext[mark:]
        check("the power button (system_powerdown): a regular poweroff", "reboot: Power down" in tail,
              tail[-300:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)


def step_ctools(a):
    """The Zig tools in the real system: ELF without python3, daemons, UKI rebuild through
    vh-limine-update and a boot from the new UKI (docs/17)."""
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "command -v python3 perl || echo NO_INTERPRETERS; "
                           "for f in /usr/local/bin/vh-wlfilter /usr/local/sbin/vh-acpid /usr/local/sbin/vh-limine-update "
                           "/usr/local/sbin/vh-pkg /usr/local/sbin/vh-deep-clean /usr/local/libexec/vh/vh-seccomp; do "
                           "printf '%s ' $f; head -c 4 $f | od -An -c | tr -d ' \\n'; echo; done")
        check("no python3 and perl", "NO_INTERPRETERS" in out, out[-200:])
        check("tools are ELF", out.count("177ELF") == 6, out[-400:].replace("\n", " | "))
        rc, out = run(ser, "/usr/local/libexec/vh/vh-seccomp --selftest")
        check("vh-seccomp --selftest (Zig)", rc == 0 and "selftest: OK" in out)
        rc, out = run(ser, "sv restart vh-acpid; sleep 3; sv status vh-acpid; "
                           "grep -ah vh-acpid /var/log/socklog/*/current | tail -6; grep VmRSS /proc/$(pgrep -x vh-acpid)/status")
        check("vh-acpid (Zig) runs and found the power button", "run: vh-acpid" in out and "power:" in out,
              out[-300:].replace("\n", " | "))
        rc, out = run(ser, "xbps-reconfigure -f $(. /etc/vh/vh.env; echo $VH_KERNEL) 2>&1 | tail -8", timeout=1800)
        check("xbps-reconfigure of the kernel -> vh-limine-update (Zig)", "enrolled into Limine" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, "mount -o ro /boot/efi && sbctl verify; r=$?; grep -c '#' /boot/efi/EFI/BOOT/limine.conf; "
                           "umount /boot/efi; test $r = 0")
        check("everything signed after the rebuild", rc == 0 and "not signed" not in out, out[-300:].replace("\n", " | "))
        audit(ser, "vh-audit without FAIL (including 'no interpreters')", want_zero_fails=True)
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)                     # boot from the UKI and Limine written by the Zig tool
    try:
        rc, out = run(ser, "cat /proc/cmdline; sv status vh-acpid")
        check("boot after the UKI rebuild", "lockdown=confidentiality" in out and "run: vh-acpid" in out)
    finally:
        shutdown(vm, ser)


def step_enroll(a):
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "printf 'enroll\\n' | doas /root/vh/install/20-firstboot.sh")
        check("20-firstboot: keys enrolled", "keys enrolled" in out, out[-300:].replace("\n", " "))
    finally:
        shutdown(vm, ser)


def step_sb(a):
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "doas sbctl status")
        check("Secure Boot enabled", re.search(r"Secure Boot:\s+.*Enabled", out) is not None, "")
        rc, out = run(ser, "doas mount -o ro /boot/efi && doas sbctl verify; r=$?; doas umount /boot/efi; test $r = 0")
        check("sbctl verify: everything signed", rc == 0 and "not signed" not in out)
        rc, out = run(ser, "cat /proc/cmdline")
        check("cmdline under Secure Boot comes only from the UKI", "lockdown=confidentiality" in out)
        rc, out = run(ser, "doas /root/vh/install/20-firstboot.sh")
        check("20-firstboot: signature check", rc == 0)
    finally:
        shutdown(vm, ser)


def step_lock(a):
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "printf 'lock\\n' | doas /root/vh/install/30-lock.sh")
        check("30-lock.sh", rc == 0)
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "cat /proc/sys/kernel/modules_disabled; doas sv status /var/service/*")
        check("modules_disabled=1 by stage 2", out.strip().splitlines()[0].strip().endswith("1") if out.strip() else False)
        bad = [l for l in out.splitlines() if l.startswith(("down:", "fail:"))]
        check("services running after the module lock", not bad, "; ".join(bad))
        rc, out = run(ser, "ok=1; for i in 1 2 3 4 5 6; do getent hosts voidlinux.org && { ok=0; break; }; sleep 5; done; test $ok = 0")
        check("DNS after the module lock", rc == 0)
    finally:
        shutdown(vm, ser)


STEPS = {"base": step_base, "ctools": step_ctools, "enroll": step_enroll, "sb": step_sb, "lock": step_lock}
