#!/usr/bin/env python3
"""The boot assessment of vh-limine-update, end to end (docs/uni/kernel.md), and its gaming boot
(vh-game boot on, docs/uni/game.md): the twin of the newest stock UKI, its entry, --game-once.

    python3 -I tests/zig/assess_test.py VH-LIMINE-UPDATE

Only in a throwaway container with --privileged (tests/zig/run.sh): a tmpfs on /boot/efi with
fake UKIs, stubs for sbctl and limine as in limine_diff.sh, a tmpfs over /sys/firmware in
place of efivarfs (checked before anything runs, so the host's NVRAM is never touched), and a
file bind-mounted over /proc/sys/kernel/random/boot_id so that each simulated boot has its
own id. A boot is simulated as Limine 12.9.3 does it: the one-shot entry is erased when read
and wins, else LoaderEntryDefault if it names an entry, else the first entry; the volatile
variables (LoaderInfo, LoaderFeatures, LoaderEntries, LoaderEntrySelected) are set anew; the
verdict of vh-kconf check goes to /run/vh/check.done; then the late-boot service runs.
"""
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import uuid

TOOL = sys.argv[1]
GUID = "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
EFIVARS = "/sys/firmware/efi/efivars"
ESP = "/boot/efi"
UKI = ESP + "/EFI/void"
CONF = ESP + "/EFI/BOOT/limine.conf"
STATE = "/var/lib/vh/boot-assess"
MSG = "/run/vh/boot-assess"
BOOTID = "/tmp/vh-assess-bootid"
GAME = ESP + "/EFI/vh-game"
MARK = "/etc/vh/game-boot"
GOOD = "VH_CHECK machine=same devices=0 firmware=2 lost=0"
LOST = "VH_CHECK machine=same devices=1 firmware=0 lost=1"
failures = 0


def sh(*cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit(f"setup failed: {cmd}: {r.stderr}")
    return r


def ok(name, cond, detail=""):
    global failures
    print(f"{'ok' if cond else 'FAIL'} {name}{'' if cond else ': ' + detail}")
    if not cond:
        failures += 1


def setup():
    os.makedirs(ESP, exist_ok=True)
    if subprocess.run(["mountpoint", "-q", ESP]).returncode != 0:
        sh("mount", "-t", "tmpfs", "tmpfs", ESP)
    # efivarfs replaced by a tmpfs: nothing below may reach the real variables
    sh("mount", "-t", "tmpfs", "tmpfs", "/sys/firmware")
    os.makedirs(EFIVARS)
    fs = sh("stat", "-f", "-c", "%T", EFIVARS).stdout.strip()
    if fs != "tmpfs":
        sys.exit(f"{EFIVARS} is {fs}, not the test's tmpfs: refusing to run")
    with open(BOOTID, "w") as f:
        f.write(str(uuid.uuid4()) + "\n")
    sh("mount", "--bind", BOOTID, "/proc/sys/kernel/random/boot_id")
    os.makedirs("/usr/share/limine", exist_ok=True)
    with open("/usr/share/limine/BOOTX64.EFI", "wb") as f:
        f.write(os.urandom(4096))
    # sbctl leaves a file it has signed as it is ("already signed"): so does the stub, or every
    # run would look like a rebuilt UKI to the assessment
    for name, body in (("sbctl", 'grep -q vh-test-signed "$2" || printf "vh-test-signed\\n" >> "$2"\n'),
                       ("limine", 'printf "enrolled %s\\n" "$3" >> "$2"\n')):
        with open(f"/usr/bin/{name}", "w") as f:
            f.write("#!/bin/sh\n" + body)
        os.chmod(f"/usr/bin/{name}", 0o755)
    os.makedirs("/var/lib/sbctl/keys/db", exist_ok=True)
    open("/var/lib/sbctl/keys/db/db.key", "w").close()
    os.makedirs("/etc/vh", exist_ok=True)
    with open("/etc/vh/boot.conf", "w") as f:
        f.write("KEEP=2\nTIMEOUT=1\nKEEP_MACHINE=2\nMACHINE_BOOTS=3\n")
    for p in (STATE, "/etc/vh/totp.conf", "/var/lib/vh/totp-reseal"):
        if os.path.exists(p):
            os.remove(p)
    os.makedirs(UKI, exist_ok=True)


def teardown():
    for m in ("/proc/sys/kernel/random/boot_id", "/sys/firmware", ESP):
        subprocess.run(["umount", m])


def uki(name, seed):
    with open(f"{UKI}/{name}", "wb") as f:
        f.write(bytes([seed]) * (1000 + seed))


def pe_uki(name, cmdline, seed):
    """a stock UKI as dracut lays it out with objcopy: a PE32+ image (the optional header with its
    16 data directories), its sections at 512-byte boundaries, the command line NUL-ended"""
    secs = [(b".osrel", b"ID=void\n"), (b".cmdline", cmdline.encode() + b"\0"),
            (b".linux", bytes([seed]) * 3000), (b".initrd", bytes([seed ^ 0x55]) * 5000)]
    opt_size = 240
    data = bytearray(0x40 + 24 + opt_size + 40 * len(secs))
    data[0:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x40)
    data[0x40:0x44] = b"PE\0\0"
    struct.pack_into("<HH", data, 0x44, 0x8664, len(secs))
    struct.pack_into("<H", data, 0x54, opt_size)
    opt = 0x40 + 24
    struct.pack_into("<H", data, opt, 0x20B)
    struct.pack_into("<I", data, opt + 108, 16)
    table = opt + opt_size
    for i, (sname, body) in enumerate(secs):
        while len(data) % 512:
            data.append(0)
        at = len(data)
        data += body
        while len(data) % 512:
            data.append(0)
        h = table + i * 40
        data[h:h + len(sname)] = sname
        struct.pack_into("<IIII", data, h + 8, len(body), 0x1000 * (i + 1), len(data) - at, at)
    with open(f"{UKI}/{name}", "wb") as f:
        f.write(data)


def run(*args):
    r = subprocess.run([TOOL, *args], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


# ---------------------------------------------------------------- EFI variables, as efivarfs holds them

def vpath(name):
    return f"{EFIVARS}/{name}-{GUID}"


def setvar(name, data, attrs=6):
    with open(vpath(name), "wb") as f:
        f.write(attrs.to_bytes(4, "little") + data)


def utf16(s):
    return s.encode("utf-16-le") + b"\0\0"


def getvar(name):
    try:
        with open(vpath(name), "rb") as f:
            d = f.read()
    except FileNotFoundError:
        return None
    return d[4:].decode("utf-16-le").split("\0")[0]


def attrs(name):
    with open(vpath(name), "rb") as f:
        return int.from_bytes(f.read(4), "little")


def delvar(name):
    if os.path.exists(vpath(name)):
        os.remove(vpath(name))


def ident(name):
    """Limine's identifier of a top-level entry (12.9.3, common/menu.c)"""
    out = "".join(c if c.isascii() and (c.isalnum() or c in "+_.@-") else ("." if c == "/" else "-") for c in name)
    return out or "-"


def menu():
    with open(CONF) as f:
        return [ident(l[1:].rstrip("\n")) for l in f if l.startswith("/")]


def mid(ver):
    return ident(f"Void Linux {ver} (machine kernel)")


def gid(ver):
    return ident(f"Void Linux {ver} (games)")


def read(path):
    with open(path, "rb") as f:
        return f.read()


def state():
    try:
        with open(STATE) as f:
            return dict(l.rstrip("\n").split("=", 1) for l in f if "=" in l and not l.startswith("#"))
    except FileNotFoundError:
        return None


def boot(verdict=GOOD, pick=None, service=True, erase=True, entries=None):
    """One boot as Limine 12.9.3 makes it; returns (selected, rc, output of --booted)"""
    with open(BOOTID, "w") as f:
        f.write(str(uuid.uuid4()) + "\n")
    for v in ("LoaderInfo", "LoaderFeatures", "LoaderEntries", "LoaderEntrySelected"):
        delvar(v)
    subprocess.run(["rm", "-rf", "/run/vh"])
    # the identifiers this Limine knows: those of the menu, or a list the test gives
    ids = entries if entries is not None else menu()
    selected = None
    one = getvar("LoaderEntryOneShot")
    if one is not None and erase:
        delvar("LoaderEntryOneShot")
    if one in ids:
        selected = one
    if pick:
        selected = pick
    if selected is None:
        d = getvar("LoaderEntryDefault")
        selected = d if d in ids else ids[0]
    setvar("LoaderInfo", utf16("Limine 12.9.3"))
    setvar("LoaderFeatures", (0x200F).to_bytes(8, "little"))
    setvar("LoaderEntries", b"".join(utf16(i) for i in ids))
    setvar("LoaderEntrySelected", utf16(selected))
    os.makedirs("/run/vh", exist_ok=True)
    with open("/run/vh/check.done", "w") as f:
        f.write(verdict + "\n")
    if not service:
        return selected, 0, ""
    rc, out = run("--booted")
    return selected, rc, out


def message():
    try:
        with open(MSG) as f:
            return f.read()
    except FileNotFoundError:
        return ""


def main():
    setup()
    try:
        scenario()
        game_scenario()
    finally:
        teardown()
    print(f"assess_test: {failures} failure(s)")
    sys.exit(1 if failures else 0)


def scenario():
    uki("linux-6.18.57_1.efi", 1)
    uki("linux-6.18.58_1.efi", 2)
    rc, out = run()
    with open(CONF) as f:
        stock_conf = f.read()
    ok("stock UKIs only: two entries, no machine entry, no default_entry", rc == 0 and len(menu()) == 2 and "machine kernel" not in stock_conf and "default_entry" not in stock_conf, out)
    ok("stock UKIs only: no state file", state() is None)
    _, rc, out = boot()
    ok("the service without a machine kernel does nothing", rc == 0 and state() is None and out == "", out)

    # a machine UKI arrives (vh-kconf install's hook)
    uki("linux-6.18.58-vh_1.efi", 3)
    rc, out = run("--new", "6.18.58-vh_1")
    with open(CONF) as f:
        conf = f.read()
    ok("--new: the stock entries keep their place, names and bytes", rc == 0 and conf.startswith(stock_conf) and menu()[:2] == ["Void-Linux-6.18.58_1", "Void-Linux-6.18.57_1--previous-kernel-"], conf)
    ok("--new: the machine entry after them", menu()[2:] == [mid("6.18.58-vh_1")], str(menu()))
    ok("--new: the one-shot entry names it, non-volatile", getvar("LoaderEntryOneShot") == mid("6.18.58-vh_1") and attrs("LoaderEntryOneShot") == 7, str(getvar("LoaderEntryOneShot")))
    ok("--new: the state: on trial, set by this boot", state()["TRIAL"] == "linux-6.18.58-vh_1.efi" and state()["TRIAL_ARMED"] != "" and state()["TRIAL_GOOD"] == "0", str(state()))
    ok("--new: says so", "on trial: the next boot tries it" in out, out)
    ok("the limine.conf head is upstream's (no default_entry)", "default_entry" not in conf)
    with open(CONF) as f:
        conf_after_new = f.read()
    rc, out = run("--booted")
    ok("the service in the boot that set the trial judges nothing", rc == 0 and state()["TRIAL_GOOD"] == "0" and getvar("LoaderEntryOneShot") is not None, out)

    # three good boots of the trial
    for n in (1, 2):
        sel, rc, out = boot()
        ok(f"trial boot {n}: Limine started the trial", sel == mid("6.18.58-vh_1"))
        ok(f"trial boot {n}: counted and set again", rc == 0 and state()["TRIAL_GOOD"] == str(n) and getvar("LoaderEntryOneShot") == mid("6.18.58-vh_1"), out)
        ok(f"trial boot {n}: the admin's message", f"{n} of 3 good boots" in message(), message())
    sel, rc, out = boot()
    ok("trial boot 3: the default now", sel == mid("6.18.58-vh_1") and getvar("LoaderEntryDefault") == mid("6.18.58-vh_1") and attrs("LoaderEntryDefault") == 7, out)
    ok("trial boot 3: no one-shot entry, the state", getvar("LoaderEntryOneShot") is None and state()["DEFAULT"] == "linux-6.18.58-vh_1.efi" and state()["TRIAL"] == "", str(state()))
    with open(CONF) as f:
        ok("the promotion did not touch limine.conf", f.read() == conf_after_new)
    sel, rc, out = boot()
    ok("the next boot: Limine's default is the machine kernel", sel == mid("6.18.58-vh_1") and rc == 0 and message() == "", out + message())

    # a second machine UKI, which loses a driver
    uki("linux-6.18.59-vh_1.efi", 4)
    rc, out = run("--new", "6.18.59-vh_1")
    ok("a second machine UKI: newest first after the stock entries", menu()[2:] == [mid("6.18.59-vh_1"), mid("6.18.58-vh_1")], str(menu()))
    ok("a second machine UKI: the default stays", getvar("LoaderEntryDefault") == mid("6.18.58-vh_1") and getvar("LoaderEntryOneShot") == mid("6.18.59-vh_1"), out)
    sel, rc, out = boot(verdict=LOST)
    ok("its trial boot lost a driver: failed", sel == mid("6.18.59-vh_1") and state()["TRIAL_STATE"] == "failed" and "1 device(s)" in state()["TRIAL_REASON"], str(state()))
    ok("failed: no one-shot entry, the default unchanged, the admin told", getvar("LoaderEntryOneShot") is None and getvar("LoaderEntryDefault") == mid("6.18.58-vh_1") and "--retry" in message(), message())
    sel, rc, out = boot()
    ok("the boot after it is the default, and the failure is not tried again", sel == mid("6.18.58-vh_1") and getvar("LoaderEntryOneShot") is None and state()["TRIAL_STATE"] == "failed", out)

    # --retry, then a trial that hangs: Limine erased the variable, the service never ran
    rc, out = run("--retry")
    ok("--retry: on trial again, set", rc == 0 and state()["TRIAL_STATE"] == "trying" and getvar("LoaderEntryOneShot") == mid("6.18.59-vh_1"), out)
    sel, _, _ = boot(service=False)
    ok("the hanging trial boot started the trial", sel == mid("6.18.59-vh_1") and getvar("LoaderEntryOneShot") is None)
    sel, rc, out = boot()
    ok("the boot after the hang is the default by itself", sel == mid("6.18.58-vh_1"))
    ok("the hang is recorded", state()["TRIAL_STATE"] == "failed" and "did not reach the end of the boot" in state()["TRIAL_REASON"], str(state()))

    # tpm2-totp: a failed trial asks for a reseal
    with open("/etc/vh/totp.conf", "w") as f:
        f.write("x\n")
    run("--retry")
    sel, rc, out = boot(pick="Void-Linux-6.18.58_1")
    ok("another entry chosen in the menu counts as a failed trial", state()["TRIAL_STATE"] == "failed")
    ok("and asks tpm2-totp for a reseal", os.path.exists("/var/lib/vh/totp-reseal") and "reseal" in out, out)
    ok("a boot of the stock entry while a machine kernel is the default is reported", "--demote" in message(), message())
    os.remove("/etc/vh/totp.conf")
    os.remove("/var/lib/vh/totp-reseal")

    # a Limine that does not erase the one-shot entry, and an identifier it does not list
    run("--retry")
    sel, rc, out = boot(erase=False)
    ok("a Limine that left the one-shot entry: the trial stops", state()["TRIAL_STATE"] == "failed" and "left LoaderEntryOneShot" in state()["TRIAL_REASON"] and getvar("LoaderEntryOneShot") is None, str(state()))
    run("--retry")
    sel, rc, out = boot(entries=["Void-Linux-6.18.58_1"])
    ok("an identifier Limine does not list: not attempted", "not attempted" in state()["TRIAL_REASON"], str(state()))

    # LoaderEntryDefault belongs to the tool
    setvar("LoaderEntryDefault", utf16("Void-Linux-6.18.57_1--previous-kernel-"), 7)
    sel, rc, out = boot()
    ok("a foreign LoaderEntryDefault is set back", getvar("LoaderEntryDefault") == mid("6.18.58-vh_1") and "set back" in out, out)

    # --status and --demote
    rc, out = run("--status")
    ok("--status: the summary line", rc == 0 and re.search(r"^VH_BOOT_ASSESS default=linux-6.18.58-vh_1.efi trial=linux-6.18.59-vh_1.efi state=failed good=0 boots=3 armed=no$", out, re.M) is not None, out)
    rc, out = run("--demote")
    ok("--demote: no default entry, the state", rc == 0 and getvar("LoaderEntryDefault") is None and state()["DEFAULT"] == "", out)
    sel, rc, out = boot()
    ok("after --demote the newest stock UKI boots", sel == "Void-Linux-6.18.58_1", sel)
    rc, out = run("--demote")
    ok("--demote twice: an error", rc != 0)

    # the rotation of the machine series: the newest two, the trial, the running one
    uki("linux-6.18.60-vh_1.efi", 5)
    uki("linux-6.18.61-vh_1.efi", 6)
    setvar("LoaderEntrySelected", utf16(mid("6.18.58-vh_1")))  # as if 58 was booted from the menu
    rc, out = run()
    names = sorted(os.listdir(UKI))
    ok("rotation: the newest two, the trial and the running one stay; the stock series untouched", names == ["linux-6.18.57_1.efi", "linux-6.18.58-vh_1.efi", "linux-6.18.58_1.efi", "linux-6.18.59-vh_1.efi", "linux-6.18.60-vh_1.efi", "linux-6.18.61-vh_1.efi"], str(names) + out)
    setvar("LoaderEntrySelected", utf16("Void-Linux-6.18.58_1"))
    rc, out = run()
    names = sorted(os.listdir(UKI))
    ok("rotation: the one no longer running goes", "linux-6.18.58-vh_1.efi" not in names and "deleting the outdated machine UKI linux-6.18.58-vh_1.efi" in out, str(names) + out)

    # the trial rebuilt in place starts again; a default whose file changed is tried anew
    run("--retry")
    boot()
    ok("one good boot of the trial", state()["TRIAL_GOOD"] == "1")
    uki("linux-6.18.59-vh_1.efi", 9)
    rc, out = run()
    ok("the trial rebuilt in place: its count starts again, set for the next boot", state()["TRIAL_GOOD"] == "0" and getvar("LoaderEntryOneShot") == mid("6.18.59-vh_1") and "starts again" in out, out + str(state()))

    # never a menu without the stock UKI
    with open(CONF) as f:
        before = f.read()
    for n in ("linux-6.18.57_1.efi", "linux-6.18.58_1.efi"):
        os.remove(f"{UKI}/{n}")
    rc, out = run()
    with open(CONF) as f:
        ok("without a stock UKI nothing is written", rc != 0 and "no stock UKI" in out and f.read() == before, out)



def game_scenario():
    """The gaming boot: the newest stock UKI's twin with ia32_emulation=1, the last entry of the
    menu, never the default; --game-once; a kernel update; refused while a trial waits; off."""
    for n in os.listdir(UKI):
        os.remove(f"{UKI}/{n}")
    for v in os.listdir(EFIVARS):
        os.remove(f"{EFIVARS}/{v}")
    for p in (STATE, MARK):
        if os.path.exists(p):
            os.remove(p)
    shutil.rmtree(GAME, ignore_errors=True)
    cmd = "root=UUID=x efi=disable_early_pci_dma ia32_emulation=0 module_blacklist=uhid"
    pe_uki("linux-6.18.57_1.efi", cmd, 1)
    pe_uki("linux-6.18.58_1.efi", cmd, 2)
    rc, out = run()
    with open(CONF) as f:
        off_conf = f.read()
    ok("game: off, no gaming entry and no directory", rc == 0 and "(games)" not in off_conf and not os.path.exists(GAME), out)

    open(MARK, "w").close()
    rc, out = run()
    with open(CONF) as f:
        on_conf = f.read()
    ok("game: on, the twin of the newest stock UKI alone", rc == 0 and sorted(os.listdir(GAME)) == ["linux-6.18.58_1.efi"], out)
    twin, stock = read(f"{GAME}/linux-6.18.58_1.efi"), read(f"{UKI}/linux-6.18.58_1.efi")
    ok("game: the twin is the stock UKI with ia32_emulation=1, nothing else changed or moved",
       len(twin) == len(stock) and twin.count(b"ia32_emulation=1") == 1 and twin.replace(b"ia32_emulation=1", b"ia32_emulation=0") == stock)
    ok("game: the twin is signed (sbctl)", twin.endswith(b"vh-test-signed\n"))
    ok("game: the stock entries as before, the gaming entry last",
       on_conf.startswith(off_conf) and menu() == ["Void-Linux-6.18.58_1", "Void-Linux-6.18.57_1--previous-kernel-", gid("6.18.58_1")], str(menu()))
    want = f"path: boot():/EFI/vh-game/linux-6.18.58_1.efi#{hashlib.blake2b(twin).hexdigest()}"
    ok("game: its path carries the twin's BLAKE2B", want in on_conf, on_conf[-300:])
    mtime = os.stat(f"{GAME}/linux-6.18.58_1.efi").st_mtime_ns
    rc, out = run()
    with open(CONF) as f:
        ok("game: a second run keeps the twin and the menu as they are",
           rc == 0 and os.stat(f"{GAME}/linux-6.18.58_1.efi").st_mtime_ns == mtime and f.read() == on_conf and "the gaming UKI" not in out, out)
    rc, out = run("--status")
    ok("game: --status names the gaming boot", rc == 0 and "the gaming boot (docs/uni/game.md): on" in out, out)

    # vh-game play: the next boot, once
    sel, rc, out = boot()
    ok("game: the default boot is the stock entry", sel == "Void-Linux-6.18.58_1", sel)
    rc, out = run("--game-once")
    ok("game: --game-once sets the one-shot entry to the gaming entry, non-volatile",
       rc == 0 and getvar("LoaderEntryOneShot") == gid("6.18.58_1") and attrs("LoaderEntryOneShot") == 7, out)
    sel, rc, out = boot()
    ok("game: the next boot is the gaming one, once; the service has nothing to judge",
       sel == gid("6.18.58_1") and getvar("LoaderEntryOneShot") is None and rc == 0 and state() is None and message() == "", out)
    sel, rc, out = boot()
    ok("game: the boot after it is the everyday one", sel == "Void-Linux-6.18.58_1", sel)

    # a kernel update between play and the reboot: the twin and the one-shot entry follow it
    run("--game-once")
    pe_uki("linux-6.18.59_1.efi", cmd, 3)
    rc, out = run("--new", "6.18.59_1")
    ok("game: a new stock kernel, its twin; the older twin deleted",
       rc == 0 and sorted(os.listdir(GAME)) == ["linux-6.18.59_1.efi"] and "deleting the gaming UKI linux-6.18.58_1.efi" in out, out)
    ok("game: the one-shot entry follows the new twin", getvar("LoaderEntryOneShot") == gid("6.18.59_1"), str(getvar("LoaderEntryOneShot")))
    sel, rc, out = boot()
    ok("game: and the next boot is its gaming entry", sel == gid("6.18.59_1"), sel)

    # a machine kernel's trial waits for the next boot: play is refused, the trial kept
    uki("linux-6.18.59-vh_1.efi", 7)
    rc, out = run("--new", "6.18.59-vh_1")
    ok("game: a trial is set for the next boot", getvar("LoaderEntryOneShot") == mid("6.18.59-vh_1"), out)
    ok("game: the machine entry before the gaming one", menu()[-2:] == [mid("6.18.59-vh_1"), gid("6.18.59_1")], str(menu()))
    rc, out = run("--game-once")
    ok("game: --game-once while a trial waits is refused", rc != 0 and "trial" in out and getvar("LoaderEntryOneShot") == mid("6.18.59-vh_1"), out)
    os.remove(f"{UKI}/linux-6.18.59-vh_1.efi")
    rc, out = run()
    ok("game: the machine UKI gone, the trial with it", rc == 0 and getvar("LoaderEntryOneShot") is None, out)

    # a stock command line without ia32_emulation=0 makes no twin, and nothing is written
    with open(CONF) as f:
        before = f.read()
    pe_uki("linux-6.18.60_1.efi", "root=UUID=x ro", 4)
    rc, out = run()
    with open(CONF) as f:
        ok("game: no twin of a command line without ia32_emulation=0; limine.conf unchanged",
           rc != 0 and "no gaming UKI" in out and f.read() == before and sorted(os.listdir(GAME)) == ["linux-6.18.59_1.efi"], out)
    os.remove(f"{UKI}/linux-6.18.60_1.efi")

    # off: the twin, the directory, the entry and a one-shot entry of play go
    run("--game-once")
    os.remove(MARK)
    rc, out = run()
    with open(CONF) as f:
        conf = f.read()
    ok("game: off, the twin and its directory are gone", rc == 0 and not os.path.exists(GAME), out)
    ok("game: off, no gaming entry; a one-shot entry of play is taken away",
       "(games)" not in conf and "vh-game" not in conf and getvar("LoaderEntryOneShot") is None, out)
    rc, out = run("--game-once")
    ok("game: --game-once while off is refused", rc != 0 and "off" in out, out)


if __name__ == "__main__":
    main()
