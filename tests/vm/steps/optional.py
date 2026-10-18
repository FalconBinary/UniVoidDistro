"""The optional/ modules: strict-net, deadman, tpm2-totp, dns-pin, viewers, home-lockdown, session-apparmor."""
import os
import re
import time

import vhvm
from vmlib import TOTP_PASS, as_user, boot, check, pf, root_shell, run, shutdown


def step_strictnet(a):
    """optional/strict-net: people have no network and no DNS; temporary allowances expire."""
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "doas /root/vh/optional/strict-net/enable")
        check("strict-net: enabled", rc == 0, out[-200:].replace("\n", " "))
        rc, _ = run(ser, as_user("admin", "getent hosts voidlinux.org"))
        check("strict-net: the admin has no DNS", rc != 0)
        rc, _ = run(ser, "getent hosts voidlinux.org")
        check("strict-net: root has no DNS without vh-net", rc != 0)
        rc, _ = run(ser, as_user("browser", "getent hosts voidlinux.org"))
        check("strict-net: the browser may use DNS", rc == 0)
        rc, _ = run(ser, "vh-net allow admin 2 && " + as_user("admin", "getent hosts voidlinux.org"))
        check("strict-net: vh-net allow grants network for a while", rc == 0)
        rc, _ = run(ser, "vh-net revoke admin; " + as_user("admin", "getent hosts voidlinux.org"))
        check("strict-net: revoke takes it back", rc != 0)
        rc, out = run(ser, "doas vh-net xbps 5 && doas xbps-install -Sn 2>&1 | tail -2", timeout=300)
        check("strict-net: vh-net xbps opens the mirrors for root", rc == 0)
        rc, out = run(ser, "doas vh-net status")
        print(out)
        rc, _ = run(ser, "/root/vh/optional/strict-net/disable && " + as_user("admin", "getent hosts voidlinux.org"))
        check("strict-net: disable returns to the base layer", rc == 0)
    finally:
        shutdown(vm, ser)


def find_in_dump(path, needles):
    """Search for byte strings in the VM memory dump (mmap, not loaded into RAM)."""
    import mmap
    found = {}
    with open(path, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
        for name, n in needles.items():
            found[name] = m.find(n) >= 0
    return found


# The needles are assembled from pieces too: with --repo this file is unpacked inside the VM,
# and a whole string in the source would be found in the dump as a false marker.
MARK_READ, MARK_PROC, MARK_DIRTY = (("VH" + "MARK" + s).encode() for s in ("_READ_7f3a", "_PROC_91c2", "_DIRTY_c40e"))


def dump_after_poweroff(a, tag, prepare_cmds):
    """Boot, run commands, power off; instead of rebooting or shutting down the VM pauses:
    dump the RAM and look for the volume key and the markers."""
    vm, ser = boot(a, ["-action", "reboot=shutdown", "-action", "shutdown=pause"])
    try:
        rc, out = run(ser, "printf '%s' 'vh-test-luks' | doas cryptsetup luksDump --dump-volume-key --batch-mode "
                           "--key-file - /dev/nvme0n1p2 | sed -n 's/^MK dump:\\s*//p;/^\\s\\+[0-9a-f][0-9a-f] /p'")
        hexkey = "".join(re.findall(r"\b[0-9a-f]{2}\b", out.split("### ")[-1]))
        key = bytes.fromhex(hexkey[:128]) if len(hexkey) >= 128 else b""
        for c in prepare_cmds:
            run(ser, as_user("admin", c))
        ser.send("poweroff")
        # wait for the VM to pause (poweroff or reboot -> pause), then dump
        dump = os.path.join(vm.d, f"mem-{tag}.elf")
        if os.path.exists(dump):
            os.remove(dump)
        time.sleep(60)
        vm.monitor(f"dump-guest-memory -d {dump}")
        last = -1
        for _ in range(300):
            time.sleep(2)
            sz = os.path.getsize(dump) if os.path.exists(dump) else 0
            if sz > 0 and sz == last:
                break
            last = sz
        import mmap
        with open(dump, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
            for needle in (MARK_READ, MARK_PROC, MARK_DIRTY):
                pos, n = m.find(needle), 0
                while pos >= 0 and n < 3:
                    ctx = m[max(0, pos - 120):pos + 40]
                    print(f"--- {needle.decode()} @{pos}:", repr(bytes(c if 32 <= c < 127 else 46 for c in ctx)))
                    pos, n = m.find(needle, pos + len(needle)), n + 1
        res = find_in_dump(dump, {
            "volume key (first 32 bytes)": key[:32] if key else b"\x00NOKEY\x00",
            "marker of a file that was read": MARK_READ,
            "marker in process memory": MARK_PROC,
            "marker of a file that was written": MARK_DIRTY,
        })
        os.remove(dump)
        return bool(key), res
    finally:
        vm.monitor("quit")
        vm.stop()


# The marker is assembled inside the VM from pieces: the full string is never typed over the
# serial console (its echo would stay in the UART buffer, which the kernel does not free, and
# the test would find the marker there rather than in the data)
MARKERS = [
    "a=VHMARK; printf \"${a}_READ_7f3a%.0s\" $(seq 1 2000) > /home/admin/read.txt; sync; cat /home/admin/read.txt >/dev/null",
    # a marker in the process heap: the string lives in bash's memory while it waits in sleep
    "( a=VHMARK; m=$(printf \"${a}_PROC_91c2%.0s\" $(seq 1 4000)); sleep 9999; echo ${#m} ) &",
    "a=VHMARK; printf \"${a}_DIRTY_c40e%.0s\" $(seq 1 2000) > /home/admin/dirty.txt",
]


def step_deadman(a):
    """optional/deadman: a RAM dump after a regular poweroff, without the module and with it."""
    ok_key, base = dump_after_poweroff(a, "base", MARKERS)
    check("rig: volume key obtained for the search", ok_key)
    print("without deadman:", base)
    check("without deadman the key IS in RAM after poweroff (the search method works)", base["volume key (first 32 bytes)"])
    vm, ser = boot(a)
    try:
        rc, out = run(ser, pf("none\nn\n") + " | /root/vh/optional/deadman/enable", timeout=1800)
        check("deadman: enabled", rc == 0, out[-300:].replace("\n", " "))
    finally:
        shutdown(vm, ser)
    ok_key, res = dump_after_poweroff(a, "deadman", MARKERS)
    print("with deadman:", res)
    for name, present in res.items():
        check(f"deadman: not in RAM after poweroff: {name}", not present)


def step_deadmandump(a):
    """Only the RAM dump after poweroff, with optional/deadman already enabled."""
    ok_key, res = dump_after_poweroff(a, "deadman", MARKERS)
    check("rig: volume key obtained for the search", ok_key)
    print("with deadman:", res)
    for name, present in res.items():
        check(f"deadman: not in RAM after poweroff: {name}", not present)


def step_totp(a):
    """optional/tpm2-totp on swtpm: generation in the initramfs, the code before the LUKS passphrase, PCR 14."""
    vm, ser = boot(a)
    try:
        rc, out = run(ser, pf("saved\n") + " | /root/vh/optional/tpm2-totp/enable", timeout=2400)
        check("tpm2-totp: enabled (lockout, dracut module, UKI)", rc == 0, out[-300:].replace("\n", " "))
    finally:
        shutdown(vm, ser)
    # boot 1: after the LUKS passphrase the initramfs generates the secret
    vm = vhvm.VM(a.dir, a.mem, a.smp)
    ser = vm.start([])
    try:
        ser.expect(r"[Pp]assphrase", 1800)
        time.sleep(2)
        ser.send(vhvm.LUKS_PASS)
        ser.expect(r"Recovery password: ", 600)
        time.sleep(1)
        ser.send(TOTP_PASS)
        ser.expect(r"Again: ", 60)
        time.sleep(1)
        ser.send(TOTP_PASS)
        m = ser.expect(r"Press Enter[^\n]*", 600)
        check("tpm2-totp: secret generated in the initramfs (QR shown)", "otpauth://" in ser.alltext or "█" in ser.alltext)
        ser.send("")
        vhvm.login(ser, "admin", vhvm.USER_PASS)
        root_shell(ser)
        rc, out = run(ser, "tpm2_pcrread sha256:14")
        check("tpm2-totp: PCR 14 extended after the display", "0x0000000000000000000000000000000000000000000000000000000000000000" not in out)
        rc, out = run(ser, "tpm2-totp -p 0,2,4,7,14 calculate")
        check("tpm2-totp: the running system cannot compute the code", rc != 0)
        rc, out = run(ser, "test ! -e /var/lib/vh/totp-generate")
        check("tpm2-totp: generation flag cleared", rc == 0)
    finally:
        shutdown(vm, ser)
    # boot 2: the code is shown before the passphrase prompt
    vm = vhvm.VM(a.dir, a.mem, a.smp)
    ser = vm.start([])
    try:
        ser.expect(r"[Cc]ompare the TOTP code", 1800)
        m = ser.expect(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d: (\d{6})", 300)
        check("tpm2-totp: TOTP code shown before the LUKS passphrase", True, m.group(1))
        ser.expect(r"[Pp]assphrase", 600)
        time.sleep(2)
        ser.send(vhvm.LUKS_PASS)
        m = ser.expect(r"login: ?$|Type RESEAL: ", 900)
        check("tpm2-totp: no reseal needed after generation", m.group(0).startswith("login"))
        if not m.group(0).startswith("login"):
            ser.send("RESEAL")
            ser.expect(r"[Rr]ecovery password[^:]*: ", 60)
            time.sleep(1)
            ser.send(TOTP_PASS)
        else:
            ser.buf = "login: "
        vhvm.login(ser, "admin", vhvm.USER_PASS)
        root_shell(ser)
    finally:
        shutdown(vm, ser)


def step_modules(a):
    """Quick module checks: dns-pin, viewers, home-lockdown, session-apparmor."""
    vm, ser = boot(a)
    try:
        # DoT server names in unbound.conf as right after installation (in case of earlier runs)
        run(ser, "sed -i -e 's/^\\(\\s*forward-addr: 9.9.9.9@853#\\).*/\\1dns.quad9.net/' "
                 "-e 's/^\\(\\s*forward-addr: 149.112.112.112@853#\\).*/\\1dns.quad9.net/' "
                 "-e 's/^\\(\\s*forward-addr: 194.242.2.2@853#\\).*/\\1dns.mullvad.net/' /etc/unbound/unbound.conf; "
                 "sv restart unbound; sleep 3; grep forward-addr /etc/unbound/unbound.conf")
        rc, out = run(ser, "printf 'pin\\n' | /root/vh/optional/dns-pin/enable", timeout=600)
        check("dns-pin: pin written, DNS works", rc == 0 and "works" in out, out[-300:].replace("\n", " "))
        rc, out = run(ser, "grep -c BEGIN /etc/unbound/ca-pin.pem /etc/chrony/nts-pin.pem")
        print(out)
        rc, out = run(ser, "cp -a /etc/unbound/unbound.conf /root/unbound.conf.test; "
                           "sed -i 's/@853#[a-z.]*/@853#example.com/' /etc/unbound/unbound.conf; "
                           "sv restart unbound; sleep 3; getent hosts kernel.org")
        check("dns-pin: a foreign name in forward-addr breaks resolving (fails closed)", rc != 0)
        run(ser, "cp -a /root/unbound.conf.test /etc/unbound/unbound.conf; /root/vh/optional/dns-pin/disable; "
                 "sleep 3; getent hosts voidlinux.org")
        rc, out = run(ser, "/root/vh/optional/viewers/enable", timeout=1200)
        check("viewers: enabled", rc == 0, out[-200:].replace("\n", " "))
        rc, out = run(ser, as_user("user", "printf 'VH-OPEN-OK\\n' > /home/xfer/t.txt; vh-open /home/xfer/t.txt < /dev/null | cat"))
        check("viewers: vh-open shows text in the sandbox (bwrap + seccomp + fd)", "VH-OPEN-OK" in out, out[-300:].replace("\n", " "))
        rc, out = run(ser, as_user("user", "ln -sf /etc/passwd /home/xfer/evil.txt; vh-open /home/xfer/evil.txt < /dev/null | cat"))
        check("viewers: symlink rejected", "not a regular file" in out and "root:x:" not in out)
        rc, out = run(ser, "printf 'lock\\n' | /root/vh/optional/home-lockdown/enable")
        check("home-lockdown: enabled", rc == 0, out[-200:].replace("\n", " "))
        rc, out = run(ser, as_user("user", "touch /home/user/.bash_login"))
        check("home-lockdown: ~/.bash_login cannot be created", rc != 0)
        rc, out = run(ser, as_user("user", "touch /home/user/Documents/x && echo ok"))
        check("home-lockdown: ~/Documents is writable", rc == 0)
        run(ser, "/root/vh/optional/home-lockdown/disable")
        rc, out = run(ser, "sed 's/@VH_AA_MODE@/, complain/' /root/vh/optional/session-apparmor/vh.local.session "
                           "> /tmp/vh.session.aa && apparmor_parser -Q -K /tmp/vh.session.aa")
        check("session-apparmor: the profile compiles", rc == 0, out[-300:].replace("\n", " "))
    finally:
        shutdown(vm, ser)


STEPS = {"strictnet": step_strictnet, "deadman": step_deadman, "deadmandump": step_deadmandump,
         "totp": step_totp, "modules": step_modules}
