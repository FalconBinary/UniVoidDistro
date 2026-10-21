"""Track G: the gaming session (vh-game, docs/uni/game.md): install with the plan of the rig
(lavapipe: the rig has no 3D), the session vh-game-enter makes, its sound (QEMU gets a sound
card for this step: the session's own PipeWire plays through it, the card's output lands in a WAV
file on this host; the everyday user's PipeWire and the session's take the card in turn), the
login of game on tty3 through the VM's keyboard, remove, and the whole system compared before
the install and after the removal, across a reboot. Step gameboot (G3): the gaming boot, the
twin of the stock UKI and its entry, vh-game play, the x86_64 filter on every process tree but
tty3's, a 32-bit program, and the system and the ESP compared before and after."""
import array
import os
import re
import struct
import time

import vhvm
from vmlib import AUDIT_RX, VM_SRC, as_user, boot, check, put_file, run, shq, shutdown

ROOT = "/var/lib/vh/roots/game"
# what changes between two boots by itself: the logs, chrony's drift, dhcpcd's lease, the seed
# of seedrng, the state unbound keeps in its DNSSEC root key (RFC 5011), the hardware clock's
# drift that stage 3 writes, runsv's state of the services whose supervise directory is on the
# disk (the system's own, /etc/sv/vh-*: pid and status at every start), and vh-kconf check's
# view of the machine, which every boot of the stock kernel writes anew: its MemTotal differs by
# a few KiB from one boot to the next (kvm-smoke 39639874481), the gaming boot's lists the
# controllers' drivers; each boot's copy is kept and compared below. Directories are compared
# without their size (XFS keeps a directory's size)
# /root/.vh-game-test keeps this step's own files across the reboot (/var/tmp is in memory)
TEST_DIR = "/root/.vh-game-test"
VOLATILE = ("/var/log", "/var/lib/chrony", "/var/db/dhcpcd", "/var/lib/dhcpcd", "/var/lib/seedrng", "/etc/unbound/var",
            "/etc/adjtime", "/etc/sv/*/supervise", "/root/.cache", "/var/lib/vh/check/stock.zon", TEST_DIR)
PRUNE = " -o ".join(f"-path '{p}'" for p in VOLATILE)
SNAPSHOT_CMD = ("{ find / -xdev \\( " + PRUNE + " \\) -prune -o \\( -type d -printf '%p\\td\\t%m\\t%U\\t%G\\n' \\) "
                "-o -printf '%p\\t%y\\t%m\\t%U\\t%G\\t%s\\t%l\\n' | LC_ALL=C sort; "
                "find / -xdev \\( " + PRUNE + " \\) -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; "
                # every extended ACL too (vh-root gives game one entry on /var/lib/vh)
                "find / -xdev \\( " + PRUNE + " \\) -prune -o -print0 | LC_ALL=C sort -z | xargs -0 getfacl -s -p 2>/dev/null; } > ")


def snapshot(out):
    """every file of the system but the volatile ones: path, type, mode, owner, size, link, sha256"""
    return SNAPSHOT_CMD + out
NS = ("user", "mnt", "pid", "net", "ipc", "uts", "cgroup")


def enter(cmd):
    """a command through the session vh-game-enter makes, as game (the same code as the login)"""
    return as_user("game", f"/usr/local/bin/vh-game-enter {cmd}")


def audio(a, n):
    """QEMU's sound card for boot N of the step: an HD Audio controller and a codec with a
    playback and a capture PCM (the laptops' sound is the same driver family); what the guest
    plays lands in a WAV file on this host. Returns the file and QEMU's arguments."""
    path = os.path.join(os.path.abspath(a.dir), f"game-audio-{n}.wav")
    if os.path.exists(path):
        os.remove(path)
    return path, ["-audiodev", f"wav,id=snd0,path={path}", "-device", "intel-hda", "-device", "hda-duplex,audiodev=snd0"]


def peak(path):
    """the loudest 16-bit sample of a WAV file QEMU wrote; 0 for silence or no file"""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return 0
    i = data.find(b"data")
    if i < 0:
        return 0
    pcm = data[i + 8:]
    s = array.array("h")
    s.frombytes(pcm[:len(pcm) // 2 * 2])
    return max((abs(x) for x in s), default=0)


def acl_counts(names):
    """for each node of /dev/snd: NAME and how many entries for game with rw its ACL has"""
    return "; ".join(f"echo \"{n} $(getfacl -p /dev/snd/{n} 2>/dev/null | grep -c '^user:game:rw-')\"" for n in names)


def keys(vm, text):
    """type TEXT on the VM's keyboard (QEMU's sendkey): letters, digits and '-'"""
    for ch in text:
        name = {"-": "minus", " ": "spc", ".": "dot", "/": "slash"}.get(ch, ch)
        vm.monitor(f"sendkey {name}")
        time.sleep(0.2)


def fails(ser, name):
    """vh-audit's FAIL count (and the FAIL lines)"""
    rc, out = run(ser, "doas vh-audit", timeout=900)
    m = AUDIT_RX.search(out)
    lines = [l for l in out.splitlines() if l.startswith("[FAIL]")]
    print(f"--- {name}: {m.group(0) if m else 'no summary'}\n" + "\n".join(lines))
    return (int(m.group(2)) if m else -1), lines


def step_game(a):
    """vh-game: install, the session, its sound, the login on tty3, remove: the system as before"""
    wav1, card = audio(a, 1)
    vm, ser = boot(a, extra=card)
    try:
        base_fails, base_lines = fails(ser, "vh-audit before the gaming session")
        # vh-kconf check writes the stock kernel's view of the machine (/var/lib/vh/check/stock.zon)
        # a few seconds into every boot, and the sound card is new to this machine at the step's
        # first boot: the snapshot waits for this boot's check (run 39586240773 took it before)
        rc, out = run(ser, "for i in $(seq 1 60); do test -e /run/vh/check.done && break; sleep 2; done; cat /run/vh/check.done")
        check("this boot's vh-kconf check is done before the snapshot", "VH_CHECK " in out, out[-200:].replace("\n", " | "))
        rc, out = run(ser, f"rm -rf {TEST_DIR} && install -d -m 0700 {TEST_DIR} && " + snapshot(f"{TEST_DIR}/before") +
                      f"; grep -c . {TEST_DIR}/before; nft list ruleset > {TEST_DIR}/nft-before; cp /etc/vh/hw.zon {TEST_DIR}/hw-before; "
                      f"cp /var/lib/vh/check/stock.zon {TEST_DIR}/stock-1.zon", timeout=3600)
        check("snapshot of the system before the install", rc == 0, out.strip().splitlines()[-1] if out.strip() else "")
        rc, out = run(ser, f"printf '%s\\n' '{vhvm.USER_PASS}' | vh-game install --password-stdin 2>&1 | tail -40", timeout=5400)
        m = re.search(r"VH_GAME installed user=game uid=(\d+) root=\S+ packages=(\S+)", out)
        check("vh-game install", m is not None, out[-1500:].replace("\n", " | "))
        check("the plan's Vulkan driver of a VM without 3D: lavapipe", m is not None and "mesa-vulkan-lavapipe" in m.group(2),
              m.group(2) if m else "")
        rc, out = run(ser, f"vh-game status; vh-root list; id game; findmnt -no TARGET,OPTIONS /home/game /var/lib/vh/roots; "
                           f"stat -c '%a %U %G' {ROOT}; du -sm {ROOT}; ls {ROOT}/var/cache/xbps 2>/dev/null | wc -l")
        print(out)
        check("vh-game status: installed, tty3 off", "VH_GAME status installed=yes tty=off" in out, out[-300:].replace("\n", " | "))
        check("the root: 0750 root:game", "750 root game" in out)
        # the sound card: game gets its control and playback nodes (an ACL entry each), never the
        # capture node (the microphone) or the codec's hwdep
        rc, out = run(ser, "cat /proc/asound/cards; ls /dev/snd; " + acl_counts(("controlC0", "pcmC0D0p", "pcmC0D0c", "hwC0D0")) +
                      "; vh-game status | tail -1")
        print(out)
        check("the sound card's control and playback nodes for game, not its capture node or hwdep (vh-game status: sound=2)",
              all(re.search(p, out, re.M) for p in (r"^controlC0 1\b", r"^pcmC0D0p 1\b", r"^pcmC0D0c 0\b", r"^hwC0D0 0\b", r" sound=2$")),
              out[-400:].replace("\n", " | "))
        rc, out = run(ser, as_user("game", f"test -r {ROOT}/etc/passwd && test -x {ROOT}/usr/bin && echo REACHES") +
                      f"; stat -c '%a %n' /var/lib/vh /var/lib/vh/roots {ROOT} {ROOT}/etc")
        check("game reaches its root (doas's umask is 077)", "REACHES" in out, out[-300:].replace("\n", " | "))
        rc, out = run(ser, as_user("user", f"test -x {ROOT} && echo USER_REACHES; true") + "; getfacl -p /var/lib/vh")
        check("another user does not reach it: /var/lib/vh lets game alone through (an ACL)",
              "USER_REACHES" not in out and "user:game:--x" in out, out[-300:].replace("\n", " | "))
        n_fails, lines = fails(ser, "vh-audit with the gaming session")
        check("vh-audit: no new FAIL with the gaming session", n_fails == base_fails and n_fails >= 0,
              " | ".join(l for l in lines if l not in base_lines))
        # the session as the login makes it (the same program), from inside
        rc, out = run(ser, enter("--check"), timeout=300)
        print(out)
        check("vh-game-enter --check: every check", "VH_GAME_ENTER ok=" in out and re.search(r"VH_GAME_ENTER ok=\d+ fail=0", out) is not None,
              " | ".join(l for l in out.splitlines() if l.startswith("FAIL")))
        # the root has no grep (bash, coreutils, Mesa, Vulkan and gamescope only): the host filters
        rc, out = run(ser, enter("-c 'vulkaninfo --summary 2>&1'") + " | grep -E 'deviceName|driverName|apiVersion|ERROR' | head -8", timeout=300)
        print(out)
        check("Vulkan in the gaming root (lavapipe on the CPU)", "llvmpipe" in out.lower() or "lavapipe" in out.lower(), out[-300:].replace("\n", " | "))
        rc, out = run(ser, enter("-c 'for h in /home/*; do echo \"HOME_SEEN=$h\"; done; [ -e /etc/vh ] && echo ETC_VH=yes || echo ETC_VH=no; "
                                 "echo \"MAP=$(cat /proc/self/uid_map)\"; echo DEV: /dev/*'"))
        check("the session sees its home only, not the system's /etc/vh",
              out.count("HOME_SEEN=") == 1 and "HOME_SEEN=/home/game" in out and "ETC_VH=no" in out, out[-300:].replace("\n", " | "))
        # the session's own sound server: the card's sink, no microphone, sound out through pulse
        # and through PipeWire's own protocol (this boot nothing else plays: the WAV is the session's)
        rc, out = run(ser, enter("-c 'bash -s'") + f" < {VM_SRC}/tests/session/sound-play.sh", timeout=300)
        print(out)
        sinks = re.search(r"SINKS=(.*)", out)
        sources = re.search(r"SOURCES=(.*)", out)
        check("the session's own PipeWire has the sound card's sink", sinks is not None and "alsa_output" in sinks.group(1),
              out[-500:].replace("\n", " | "))
        check("the session's PipeWire has no microphone: no source but the sink's monitor",
              sources is not None and "alsa_input" not in sources.group(1) and all(s.endswith(".monitor") for s in sources.group(1).split()),
              sources.group(1) if sources else "")
        check("a game's sound goes out through the session's pulse server and through PipeWire's protocol",
              "PULSE_PLAYED" in out and "NATIVE_PLAYED" in out, out[-500:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
    # silence is 0: noise at the sink's full volume peaks near 32767, at WirePlumber's first
    # volume (0.4, cubic) near 2000
    loud = peak(wav1)
    check("what the session played came out of the sound card (QEMU's WAV file)", loud > 1000, f"peak {loud} of 32767")

    _, card = audio(a, 2)
    vm, ser = boot(a, extra=card)
    try:
        rc, out = run(ser, "findmnt -no OPTIONS /home/game; findmnt -no OPTIONS /var/lib/vh/roots; pgrep -a agetty")
        mounts = [l for l in out.splitlines() if "nosuid" in l]
        check("after a reboot: both mounts from fstab, nosuid, nodev", len(mounts) >= 2 and all("nodev" in l for l in mounts), out[-300:].replace("\n", " | "))
        check("after a reboot: no getty on tty3 (vh-game tty on starts it)", "tty3" not in out, out[-300:].replace("\n", " | "))
        rc, out = run(ser, acl_counts(("controlC0", "pcmC0D0p", "pcmC0D0c")))
        check("after a reboot: the udev rule gave game the card's control and playback nodes, not the capture node",
              all(re.search(p, out, re.M) for p in (r"^controlC0 1\b", r"^pcmC0D0p 1\b", r"^pcmC0D0c 0\b")), out[-300:].replace("\n", " | "))
        # one sound card, two PipeWires: the everyday user's (as the desktop starts it) and the
        # session's take it in turn
        rc, out = run(ser, f"bash {VM_SRC}/tests/session/sound-turns.sh user", timeout=600)
        print(out)
        busy = re.search(r"^BUSY=(.*)", out, re.M)
        free = re.search(r"^FREE=(.*)", out, re.M)
        after = re.search(r"^FREE_AFTER=(\d+)", out, re.M)
        check("the everyday user's PipeWire has the card", re.search(r"^USER_SINKS=.*alsa_output", out, re.M) is not None,
              out[-300:].replace("\n", " | "))
        check("while the user's PipeWire plays, the session waits for the card (no sink of it)",
              busy is not None and "alsa_output" not in busy.group(1), busy.group(1) if busy else "")
        check("the session takes the card once the user's PipeWire lets it go, and plays",
              free is not None and "alsa_output" in free.group(1) and "PLAYED_AFTER" in out,
              f"after {after.group(1) if after else '?'} s: {free.group(1) if free else ''}")
        check("while the session plays, the user's PipeWire finds the card busy",
              re.search(r"^USER_BUSY_LOG=[1-9]", out, re.M) is not None, out[-400:].replace("\n", " | "))
        rc, out = run(ser, "vh-game tty on; sleep 3; pgrep -a agetty")
        check("vh-game tty on: a getty on tty3", "tty3" in out, out[-300:].replace("\n", " | "))
        # the login of game on tty3, typed on the VM's keyboard: agetty, login, PAM (pam_access,
        # pam_shells, the password), then vh-game-enter as the login shell
        vm.monitor("sendkey ctrl-alt-f3")
        time.sleep(3)
        keys(vm, "game")
        vm.monitor("sendkey ret")
        time.sleep(4)
        keys(vm, vhvm.USER_PASS)
        vm.monitor("sendkey ret")
        rc, out = run(ser, "p=; for i in $(seq 1 40); do p=$(pgrep -u game -x bash | head -1); [ -n \"$p\" ] && break; sleep 1; done; echo pid=$p; "
                           "[ -n \"$p\" ] && { for n in " + " ".join(NS) + "; do echo \"$n $(readlink /proc/1/ns/$n) $(readlink /proc/$p/ns/$n)\"; done; "
                           "grep -E '^(NoNewPrivs|Seccomp|CapEff|CapBnd)' /proc/$p/status; cat /proc/$p/root/etc/vh-root; "
                           "readlink /proc/$p/fd/0; ps -o pid,ppid,user,args -u game; }", timeout=300)
        print(out)
        got = re.search(r"pid=(\d+)", out)
        check("the login of game on tty3 starts its session", got is not None, out[-400:].replace("\n", " | "))
        if got:
            same = [l.split()[0] for l in out.splitlines() if len(l.split()) == 3 and l.split()[0] in NS and l.split()[1] == l.split()[2]]
            check("the login's session: user, mount, PID, network, IPC, UTS and cgroup namespaces of its own", not same, " ".join(same))
            check("the login's session: no new privileges, no capability, no seccomp filter",
                  re.search(r"NoNewPrivs:\s*1", out) and re.search(r"Seccomp:\s*0", out) and re.search(r"CapEff:\s*0+\b", out) is not None,
                  out[-400:].replace("\n", " | "))
            check("the login's session runs in the gaming root, on tty3", "profile=game" in out and "/dev/tty3" in out)
            # its own sound server, in its namespaces
            rc, out = run(ser, f"b={got.group(1)}; for c in pipewire wireplumber; do for q in $(pgrep -u game -x $c); do "
                               "echo \"$c $(readlink /proc/$q/ns/pid) $(readlink /proc/$b/ns/pid) $(tr '\\0' ' ' < /proc/$q/cmdline)\"; done; done")
            print(out)
            # the first line comes after the shell's prompt: found by its shape, not its start
            procs = re.findall(r"(pipewire|wireplumber) (pid:\[\d+\]) (pid:\[\d+\]) ([^\n]*)", out)
            check("the login's session runs its own PipeWire, WirePlumber and pulse server, in its namespaces",
                  any(p[0] == "wireplumber" for p in procs) and any("pipewire-pulse.conf" in p[3] for p in procs)
                  and any(p[0] == "pipewire" and "-c" not in p[3].split() for p in procs) and all(p[1] == p[2] for p in procs),
                  out[-400:].replace("\n", " | "))
        # tty off: the getty goes, and with its hangup the session
        rc, out = run(ser, "vh-game tty off; sleep 3; echo procs=$(pgrep -u game | wc -l) gettys=$(pgrep -a agetty | grep -c tty3)")
        check("vh-game tty off: the getty and the session end", "procs=0 gettys=0" in out, out[-300:].replace("\n", " | "))
        vm.monitor("sendkey ctrl-alt-f1")
        rc, out = run(ser, keep_view(2) + f"; echo '--- the stock view: the first boot against this one'; diff {TEST_DIR}/stock-1.zon {TEST_DIR}/stock-2.zon | head -30; echo VIEWS_DONE")
        print(out)
        rc, out = run(ser, "vh-game remove --yes 2>&1 | tail -5", timeout=1800)
        check("vh-game remove", "VH_GAME removed" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, snapshot(f"{TEST_DIR}/after") + "; "
                      f"if cmp -s {TEST_DIR}/before {TEST_DIR}/after; then echo FILES_SAME; else echo DIFFERS:; diff {TEST_DIR}/before {TEST_DIR}/after | "
                      "sed -n 's/^[<>] //p' | awk -F'\\t|  ' '{print $1 ~ /^[0-9a-f]{64}$/ ? $2 : $1}' | LC_ALL=C sort -u | head -80; fi; "
                      f"nft list ruleset | cmp -s - {TEST_DIR}/nft-before && echo NFT_SAME; "
                      f"cmp -s /etc/vh/hw.zon {TEST_DIR}/hw-before && echo HW_SAME; "
                      "getent passwd game || echo NO_GAME", timeout=3600)
        print(out)
        check("after the removal the system is the system before the install, byte for byte", "FILES_SAME" in out,
              out[-1200:].replace("\n", " | "))
        check("the nft ruleset, hw.zon, no user game", "NFT_SAME" in out and "HW_SAME" in out and "NO_GAME" in out)
        # /dev is no part of the comparison: the card's nodes are checked here
        rc, out = run(ser, "echo \"ACL_LEFT=$(getfacl -s -p /dev/snd/* 2>/dev/null | grep -c '^user:')\"; stat -c '%a %n' /dev/snd/controlC0 /dev/snd/pcmC0D0p")
        check("after the removal: no ACL entry left on the sound card's nodes, 0660 as udev made them",
              "ACL_LEFT=0" in out and out.count("660 /dev/snd/") == 2, out[-300:].replace("\n", " | "))
        n_fails, lines = fails(ser, "vh-audit after the removal")
        check("vh-audit after the removal: as before", n_fails == base_fails, " | ".join(lines))
        run(ser, f"rm -rf {TEST_DIR}")
    finally:
        shutdown(vm, ser)


# ---------------------------------------------------------------- G3: the gaming boot

def ia32_elf():
    """A 32-bit program without libc, made here: write(1, "IA32_OK\n") and exit(0) through
    int $0x80. The everyday boot cannot load it (ia32_emulation=0), the gaming boot's x86_64
    filter kills it outside the gaming session, the session runs it."""
    base, at = 0x08048000, 52 + 32
    msg = b"IA32_OK\n"
    code = (b"\xb8\x04\x00\x00\x00" + b"\xbb\x01\x00\x00\x00"          # eax = 4 (write), ebx = 1 (stdout)
            + b"\xb9" + struct.pack("<I", base + at + 31)              # ecx = the message
            + b"\xba" + struct.pack("<I", len(msg)) + b"\xcd\x80"       # edx = its length; int $0x80
            + b"\xb8\x01\x00\x00\x00" + b"\x31\xdb" + b"\xcd\x80")       # eax = 1 (exit), ebx = 0; int $0x80
    assert len(code) == 31
    size = at + len(code) + len(msg)
    ehdr = b"\x7fELF\x01\x01\x01" + bytes(9) + struct.pack("<HHIIIIIHHHHHH", 2, 3, 1, base + at, 52, 0, 0, 52, 32, 1, 0, 0, 0)
    phdr = struct.pack("<IIIIIIII", 1, 0, base, base, size, size, 5, 0x1000)
    return ehdr + phdr + code + msg


def esp_snap(out):
    """every path of the ESP and every file's sha256 (the ESP is noauto: mounted read-only for it)"""
    return ("mount -o ro /boot/efi && { find /boot/efi -print | LC_ALL=C sort; "
            "find /boot/efi -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; } > " + out + "; umount /boot/efi")


def seccomp_of(label, pattern):
    """'LABEL: Seccomp:N' of the first process whose command line matches PATTERN (pgrep -f)"""
    return ("p=$(pgrep -f " + shq(pattern) + " | head -1); echo \"" + label + ": $(grep -s '^Seccomp:' /proc/$p/status | tr -d '\\t ')\"")


# vh-kconf check writes the stock kernel's view of the machine (/var/lib/vh/check/stock.zon) a
# few seconds into every boot of the stock kernel; each boot's copy stays in TEST_DIR for the end
CHECK_WAIT = "for i in $(seq 1 60); do test -e /run/vh/check.done && break; sleep 2; done"


def keep_view(n):
    return CHECK_WAIT + f"; cp /var/lib/vh/check/stock.zon {TEST_DIR}/stock-{n}.zon; cat /run/vh/check.done"


def step_gameboot(a):
    """vh-game boot on: the twin of the stock UKI and its entry; vh-game play: the gaming boot,
    once, with ia32 for the gaming session alone (the x86_64 filter on every other process
    tree), the login of game on tty3 by itself; the everyday boot after it as before; remove:
    the system and the ESP as before the install."""
    vm, ser = boot(a)
    try:
        base_fails, base_lines = fails(ser, "vh-audit before the gaming session")
        rc, out = run(ser, "for i in $(seq 1 60); do test -e /run/vh/check.done && break; sleep 2; done; cat /run/vh/check.done; "
                           "echo \"SECURE_BOOT=$(od -An -tu1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $NF}')\"")
        print(out)
        rc, out = run(ser, f"rm -rf {TEST_DIR} && install -d -m 0700 {TEST_DIR} && " + snapshot(f"{TEST_DIR}/before") + "; " +
                      esp_snap(f"{TEST_DIR}/esp-before") + f"; grep -c . {TEST_DIR}/before {TEST_DIR}/esp-before; " + keep_view(1), timeout=3600)
        check("snapshots of the system and of the ESP before the install", rc == 0, out.strip().splitlines()[-1] if out.strip() else "")
        rc, out = run(ser, f"printf '%s\\n' '{vhvm.USER_PASS}' | vh-game install --password-stdin 2>&1 | tail -5", timeout=5400)
        check("vh-game install", "VH_GAME installed" in out, out[-800:].replace("\n", " | "))
        rc, out = run(ser, "vh-game boot on 2>&1 | tail -12", timeout=900)
        print(out)
        check("vh-game boot on", "VH_GAME boot on" in out, out[-800:].replace("\n", " | "))
        rc, out = run(ser, "mount -o ro /boot/efi && { s=$(ls /boot/efi/EFI/void/linux-*.efi | grep -v -- -vh_ | sort -V | tail -1); "
                           "t=/boot/efi/EFI/vh-game/$(basename $s); echo \"FILES=$(ls /boot/efi/EFI/vh-game | tr '\\n' ' ')\"; echo \"TWIN=$(basename $t)\"; "
                           "echo \"CMD_STOCK=$(grep -ao 'ia32_emulation=[01]' $s | tr '\\n' ' ')\"; echo \"CMD_TWIN=$(grep -ao 'ia32_emulation=[01]' $t | tr '\\n' ' ')\"; "
                           "echo \"SIZES=$(stat -c %s $s $t | tr '\\n' ' ')\"; grep '^/' /boot/efi/EFI/BOOT/limine.conf; }; umount /boot/efi")
        print(out)
        twin = re.search(r"TWIN=(linux-\S+\.efi)", out)
        files = re.search(r"FILES=(.*)", out)
        check("the twin of the newest stock UKI alone in EFI/vh-game", twin is not None and files is not None and files.group(1).split() == [twin.group(1)],
              out[-400:].replace("\n", " | "))
        check("its command line: ia32_emulation=1 where the stock UKI's has 0",
              re.search(r"^CMD_STOCK=ia32_emulation=0 *$", out, re.M) is not None and re.search(r"^CMD_TWIN=ia32_emulation=1 *$", out, re.M) is not None,
              out[-400:].replace("\n", " | "))
        entries = [l.strip() for l in out.splitlines() if l.startswith("/")]
        check("the gaming entry last in Limine's menu", bool(entries) and entries[-1].endswith("(games)") and not entries[0].endswith("(games)"), " | ".join(entries))
        put_file(ser, "/home/game/ia32-test", ia32_elf())
        # the session runs it at its login: a login shell reads ~/.bash_profile
        rc, out = run(ser, "chown game:game /home/game/ia32-test && chmod 0755 /home/game/ia32-test && "
                           "echo '/home/game/ia32-test > /home/game/ia32.out 2>&1; echo \"rc=$?\" >> /home/game/ia32.out' > /home/game/.bash_profile && "
                           "chown game:game /home/game/.bash_profile && /home/game/ia32-test; echo \"EVERYDAY_RC=$?\"")
        print(out)
        check("the everyday boot cannot run a 32-bit program (ia32_emulation=0)", re.search(r"EVERYDAY_RC=126", out) is not None and "IA32_OK" not in out,
              out[-300:].replace("\n", " | "))
        rc, out = run(ser, "vh-game play --no-reboot 2>&1 | tail -3; vh-limine-update --status")
        print(out)
        check("vh-game play: the next boot is the gaming one (Limine's one-shot entry)",
              re.search(r"LoaderEntryOneShot: \S+--games-;", out) is not None, out[-500:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)

    # the gaming boot
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "vh-limine-update --status; cat /proc/cmdline; vh-game status | tail -2; findmnt /etc/runit/2 || echo NOT_A_MOUNT; "
                           "echo \"HOME_OPTS=$(findmnt -no OPTIONS /home/game)\"; " + keep_view(2))
        print(out)
        home = re.search(r"HOME_OPTS=(\S*)", out)
        check("the home of game after a reboot (fstab): nosuid, nodev, exec",
              home is not None and "nosuid" in home.group(1) and "nodev" in home.group(1) and "noexec" not in home.group(1), home.group(1) if home else out[-300:])
        check("Limine started the gaming entry", re.search(r"started: \S+--games-;", out) is not None and "this boot is the gaming one" in out,
              out[-500:].replace("\n", " | "))
        check("its command line: ia32_emulation=1", " ia32_emulation=1" in out and " ia32_emulation=0" not in out)
        check("vh-game status: the gaming boot, the login of game on tty3 by itself",
              re.search(r"VH_GAME status installed=yes tty=on .* boot=on this=game ", out) is not None, out[-300:].replace("\n", " | "))
        check("stage 2 runs runit-void's /etc/runit/2 again (the bind mount is gone)", "NOT_A_MOUNT" in out)
        rc, out = run(ser, "; ".join([seccomp_of("runsvdir", "^runsvdir"), seccomp_of("runsv-tty3", "^runsv /etc/sv/agetty-tty3"),
                                      seccomp_of("getty-tty3", "agetty.* tty3"), seccomp_of("getty-tty1", "agetty.* tty1"),
                                      seccomp_of("runsv-udevd", "^runsv udevd"), "echo \"shell: $(grep '^Seccomp:' /proc/$$/status | tr -d '\\t ')\""]) +
                      "; echo \"PADS=$(lsmod | grep -cE '^(xpad|joydev|hid_playstation|hid_nintendo|hid_steam) ')\"")
        print(out)
        check("every process tree under the x86_64 filter: runsvdir, the services, the gettys, this shell",
              all(re.search(p, out) for p in (r"runsvdir: Seccomp:2", r"getty-tty1: Seccomp:2", r"runsv-udevd: Seccomp:2", r"shell: Seccomp:2")),
              out[-600:].replace("\n", " | "))
        check("but the login of game on tty3: its runsv and agetty without it",
              re.search(r"runsv-tty3: Seccomp:0", out) is not None and re.search(r"getty-tty3: Seccomp:0", out) is not None, out[-600:].replace("\n", " | "))
        pads = re.search(r"PADS=(\d+)", out)
        check("the controllers' drivers loaded before the module lock", pads is not None and int(pads.group(1)) >= 3, out[-200:])
        rc, out = run(ser, "/home/game/ia32-test; echo \"FILTERED_RC=$?\"")
        print(out)
        check("outside the gaming session a 32-bit program is killed at its first system call (SIGSYS)",
              re.search(r"FILTERED_RC=159", out) is not None and "IA32_OK" not in out, out[-300:].replace("\n", " | "))
        # the login of game on tty3, typed on the VM's keyboard: its session runs the program
        vm.monitor("sendkey ctrl-alt-f3")
        time.sleep(3)
        keys(vm, "game")
        vm.monitor("sendkey ret")
        time.sleep(4)
        keys(vm, vhvm.USER_PASS)
        vm.monitor("sendkey ret")
        rc, out = run(ser, "for i in $(seq 1 60); do grep -q '^rc=' /home/game/ia32.out 2>/dev/null && break; sleep 1; done; cat /home/game/ia32.out; "
                           "p=$(pgrep -u game -x bash | head -1); grep -E '^(Seccomp|NoNewPrivs):' /proc/$p/status", timeout=300)
        print(out)
        check("the gaming session runs the 32-bit program", "IA32_OK" in out and re.search(r"^rc=0$", out, re.M) is not None, out[-300:].replace("\n", " | "))
        check("the gaming session: no seccomp filter, no new privileges",
              re.search(r"Seccomp:\s*0", out) is not None and re.search(r"NoNewPrivs:\s*1", out) is not None, out[-300:].replace("\n", " | "))
        rc, out = run(ser, "vh-game tty off >/dev/null 2>&1; vh-game tty on 2>&1 | tail -2; echo \"GETTYS=$(pgrep -a agetty | grep -c tty3)\"")
        print(out)
        check("vh-game tty on from a filtered shell of the gaming boot is refused",
              "starts with the boot only" in out and "GETTYS=0" in out, out[-300:].replace("\n", " | "))
        vm.monitor("sendkey ctrl-alt-f1")
        n_fails, lines = fails(ser, "vh-audit in the gaming boot")
        check("vh-audit in the gaming boot: no new FAIL", n_fails == base_fails and n_fails >= 0, " | ".join(l for l in lines if l not in base_lines))
    finally:
        shutdown(vm, ser)

    # the everyday boot after it
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "vh-limine-update --status; cat /proc/cmdline; vh-game status | tail -1; " + seccomp_of("runsvdir", "^runsvdir") +
                      "; echo \"GETTYS=$(pgrep -a agetty | grep -c tty3)\"; /home/game/ia32-test; echo \"EVERYDAY_RC=$?\"")
        print(out)
        sel = re.search(r"started: (\S+);", out)
        check("the boot after the gaming one is the everyday one, ia32 off",
              sel is not None and not sel.group(1).endswith("--games-") and " ia32_emulation=0" in out and "this=everyday" in out, out[-500:].replace("\n", " | "))
        check("the everyday boot: no filter, no getty on tty3, no 32-bit program",
              re.search(r"runsvdir: Seccomp:0", out) is not None and "GETTYS=0" in out and re.search(r"EVERYDAY_RC=126", out) is not None,
              out[-500:].replace("\n", " | "))
        rc, out = run(ser, keep_view(3) + f"; echo '--- the stock view: the first boot against the gaming boot'; diff {TEST_DIR}/stock-1.zon {TEST_DIR}/stock-2.zon | head -30; "
                           f"echo '--- the first boot against this one'; diff {TEST_DIR}/stock-1.zon {TEST_DIR}/stock-3.zon | head -30; echo VIEWS_DONE")
        print(out)
        rc, out = run(ser, "vh-game remove --yes 2>&1 | grep -E '^VH_GAME|vh-game:|limine.conf|gaming'", timeout=1800)
        print(out)
        check("vh-game remove, the gaming boot off with it", "VH_GAME boot off" in out and "VH_GAME removed" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, snapshot(f"{TEST_DIR}/after") + "; " + esp_snap(f"{TEST_DIR}/esp-after") + "; "
                      f"if cmp -s {TEST_DIR}/before {TEST_DIR}/after; then echo FILES_SAME; else echo DIFFERS:; diff {TEST_DIR}/before {TEST_DIR}/after | "
                      "sed -n 's/^[<>] //p' | awk -F'\\t|  ' '{print $1 ~ /^[0-9a-f]{64}$/ ? $2 : $1}' | LC_ALL=C sort -u | head -60; fi; "
                      f"cmp -s {TEST_DIR}/esp-before {TEST_DIR}/esp-after && echo ESP_SAME || {{ echo ESP_DIFF:; diff {TEST_DIR}/esp-before {TEST_DIR}/esp-after; }}",
                      timeout=3600)
        print(out)
        check("after the removal the system is the system before the install, byte for byte", "FILES_SAME" in out, out[-1200:].replace("\n", " | "))
        # Limine's BOOTX64.EFI is a clean copy with limine.conf's hash enrolled, signed anew at every
        # run of vh-limine-update: with limine.conf the same, only a signature with a time in it
        # could differ
        diff = [l for l in out.split("ESP_DIFF:")[-1].splitlines() if l.startswith(("<", ">"))] if "ESP_DIFF:" in out else []
        check("and the ESP: the same files, byte for byte (the twin gone, limine.conf and every UKI as before)",
              "ESP_SAME" in out or (diff and all(l.rstrip().endswith("/EFI/BOOT/BOOTX64.EFI") for l in diff)), " | ".join(diff[:12]))
        if diff:
            print("note: Limine's BOOTX64.EFI differs after the removal (signed anew), limine.conf and every other file do not")
        n_fails, lines = fails(ser, "vh-audit after the removal")
        check("vh-audit after the removal: as before", n_fails == base_fails, " | ".join(lines))
        run(ser, f"rm -rf {TEST_DIR}")
    finally:
        shutdown(vm, ser)


# ---------------------------------------------------------------- G3b: the gaming kernel

# the files of a game-kernel run (its artifact game-kernel-qemu-q35-KVER): kvm-smoke downloads
# them here (its input game_kernel_run)
GAME_KERNEL = os.path.join(vhvm.REPO, "build", "game-kernel")


def step_gamekernel(a):
    """The gaming kernel as vh-game kernel build builds it (a game-kernel run's files in
    build/game-kernel): vh-kconf install makes it the gaming entry, before the stock UKI's twin;
    vh-game play boots it: its own release, ia32 on, the module key's certificate built in,
    loadable modules locked after stage 1, lockdown, the x86_64 filter on every process tree
    but the gaming session's; vh-kconf check judges it as a machine kernel; remove: the system
    and the ESP as before the install."""
    import sys
    build = os.path.join(GAME_KERNEL, "BUILD")
    if not os.path.isfile(build):
        sys.exit("no build/game-kernel: kvm-smoke with game_kernel_run (the id of a game-kernel run)")
    with open(build) as f:
        m = re.search(r"linux-([0-9.]+),", f.read())
    kver = m.group(1)
    release = f"{kver}-vh-game"
    gid = f"Void-Linux-{release}_1--games-"
    src = f"{VM_SRC}/build/game-kernel"
    vm, ser = boot(a)
    try:
        base_fails, base_lines = fails(ser, "vh-audit before the gaming session")
        rc, out = run(ser, f"rm -rf {TEST_DIR} && install -d -m 0700 {TEST_DIR} && " + CHECK_WAIT + "; " + snapshot(f"{TEST_DIR}/before") + "; " +
                      esp_snap(f"{TEST_DIR}/esp-before") + "; " + keep_view(1), timeout=3600)
        check("snapshots of the system and of the ESP before the install", rc == 0, out.strip().splitlines()[-1] if out.strip() else "")
        rc, out = run(ser, f"printf '%s\\n' '{vhvm.USER_PASS}' | vh-game install --password-stdin 2>&1 | tail -3; vh-game boot on 2>&1 | tail -2", timeout=5400)
        check("vh-game install and boot on", "VH_GAME installed" in out and "VH_GAME boot on" in out, out[-600:].replace("\n", " | "))
        rc, out = run(ser, f"vh-kconf install {src} 2>&1 | tail -25", timeout=1800)
        print(out)
        check(f"vh-kconf install: the gaming kernel {release} into the gaming series", f"linux-{release}_1.efi installed" in out, out[-800:].replace("\n", " | "))
        rc, out = run(ser, "mount -o ro /boot/efi && { ls /boot/efi/EFI/vh-game; grep '^/' /boot/efi/EFI/BOOT/limine.conf; "
                           f"echo \"CMD=$(grep -ao 'ia32_emulation=[01]' /boot/efi/EFI/vh-game/linux-{release}_1.efi | tr '\\n' ' ')\"; }}; umount /boot/efi")
        print(out)
        entries = [l.strip() for l in out.splitlines() if l.startswith("/")]
        check("the gaming kernel's entry before the twin's, both last",
              len(entries) >= 3 and entries[-2] == f"/Void Linux {release}_1 (games)" and entries[-1].endswith("(games)") and "-vh-game" not in entries[-1],
              " | ".join(entries))
        check("its command line: ia32_emulation=1", re.search(r"^CMD=ia32_emulation=1 *$", out, re.M) is not None, out[-300:].replace("\n", " | "))
        put_file(ser, "/home/game/ia32-test", ia32_elf())
        run(ser, "chown game:game /home/game/ia32-test && chmod 0755 /home/game/ia32-test && "
                 "echo '/home/game/ia32-test > /home/game/ia32.out 2>&1; echo \"rc=$?\" >> /home/game/ia32.out' > /home/game/.bash_profile && "
                 "chown game:game /home/game/.bash_profile")
        rc, out = run(ser, "vh-game play --no-reboot 2>&1 | tail -2; vh-limine-update --status")
        check("vh-game play: the next boot is the gaming kernel's", f"LoaderEntryOneShot: {gid};" in out, out[-400:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)

    vm, ser = boot(a)
    try:
        rc, out = run(ser, "vh-limine-update --status | grep -E 'this boot|gaming'; uname -r; cat /proc/cmdline; cat /sys/kernel/security/lockdown; "
                           "echo \"MODLOCK=$(cat /proc/sys/kernel/modules_disabled 2>/dev/null)\"; dmesg | grep -E 'X.509|module X.509|compiled-in' | head -8; "
                           "vh-game status | tail -1; " + CHECK_WAIT + "; cat /run/vh/check.done; "
                           f"cmp -s /var/lib/vh/check/stock.zon {TEST_DIR}/stock-1.zon && echo STOCK_VIEW_KEPT")
        print(out)
        check(f"Limine booted the gaming kernel: {release}", f"started: {gid};" in out and re.search(rf"^{re.escape(release)}$", out, re.M) is not None,
              out[-600:].replace("\n", " | "))
        check("ia32 on, lockdown confidentiality, loadable modules locked after stage 1",
              " ia32_emulation=1" in out and "[confidentiality]" in out and "MODLOCK=1" in out, out[-600:].replace("\n", " | "))
        check("its module certificate is the vh-game key's, built in", "vh-game module key" in out, out[-600:].replace("\n", " | "))
        check("vh-game status: the gaming boot, tty3's login on", re.search(r"tty=on .* boot=on this=game ", out) is not None, out[-300:].replace("\n", " | "))
        check("vh-kconf check judges it as a machine kernel and leaves the stock kernel's view as it was",
              "VH_CHECK machine=same" in out and "STOCK_VIEW_KEPT" in out, out[-400:].replace("\n", " | "))
        rc, out = run(ser, "; ".join([seccomp_of("runsvdir", "^runsvdir"), seccomp_of("getty-tty3", "agetty.* tty3"), seccomp_of("getty-tty1", "agetty.* tty1")]) +
                      "; /home/game/ia32-test; echo \"FILTERED_RC=$?\"")
        print(out)
        check("the x86_64 filter on runsvdir and tty1's getty, not on tty3's; a 32-bit program killed outside the session",
              all(re.search(p, out) for p in (r"runsvdir: Seccomp:2", r"getty-tty1: Seccomp:2", r"getty-tty3: Seccomp:0", r"FILTERED_RC=159")),
              out[-500:].replace("\n", " | "))
        vm.monitor("sendkey ctrl-alt-f3")
        time.sleep(3)
        keys(vm, "game")
        vm.monitor("sendkey ret")
        time.sleep(4)
        keys(vm, vhvm.USER_PASS)
        vm.monitor("sendkey ret")
        rc, out = run(ser, "for i in $(seq 1 60); do grep -q '^rc=' /home/game/ia32.out 2>/dev/null && break; sleep 1; done; cat /home/game/ia32.out", timeout=300)
        check("the gaming session on the gaming kernel runs the 32-bit program", "IA32_OK" in out and re.search(r"^rc=0$", out, re.M) is not None,
              out[-300:].replace("\n", " | "))
        vm.monitor("sendkey ctrl-alt-f1")
        n_fails, lines = fails(ser, "vh-audit on the gaming kernel")
        check("vh-audit on the gaming kernel: no new FAIL", n_fails == base_fails and n_fails >= 0, " | ".join(l for l in lines if l not in base_lines))
    finally:
        shutdown(vm, ser)

    vm, ser = boot(a)
    try:
        rc, out = run(ser, "uname -r; cat /proc/cmdline; " + CHECK_WAIT + "; " + keep_view(3))
        check("the boot after it is the everyday one: the stock kernel, ia32 off", re.search(r"^\d+\.\d+\.\d+_\d+$", out, re.M) is not None and " ia32_emulation=0" in out,
              out[-400:].replace("\n", " | "))
        rc, out = run(ser, "vh-game remove --yes 2>&1 | grep -E '^VH_GAME|vh-game:|limine.conf|gaming'", timeout=1800)
        print(out)
        check("vh-game remove: the gaming boot, the gaming kernel and its records go", "VH_GAME boot off" in out and "VH_GAME removed" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, snapshot(f"{TEST_DIR}/after") + "; " + esp_snap(f"{TEST_DIR}/esp-after") + "; "
                      f"if cmp -s {TEST_DIR}/before {TEST_DIR}/after; then echo FILES_SAME; else echo DIFFERS:; diff {TEST_DIR}/before {TEST_DIR}/after | "
                      "sed -n 's/^[<>] //p' | awk -F'\\t|  ' '{print $1 ~ /^[0-9a-f]{64}$/ ? $2 : $1}' | LC_ALL=C sort -u | head -60; fi; "
                      f"cmp -s {TEST_DIR}/esp-before {TEST_DIR}/esp-after && echo ESP_SAME || {{ echo ESP_DIFF:; diff {TEST_DIR}/esp-before {TEST_DIR}/esp-after; }}",
                      timeout=3600)
        print(out)
        check("after the removal the system is the system before the install, byte for byte", "FILES_SAME" in out, out[-1200:].replace("\n", " | "))
        diff = [l for l in out.split("ESP_DIFF:")[-1].splitlines() if l.startswith(("<", ">"))] if "ESP_DIFF:" in out else []
        check("and the ESP: the same files, byte for byte (Limine's BOOTX64.EFI may carry a new signature)",
              "ESP_SAME" in out or (diff and all(l.rstrip().endswith("/EFI/BOOT/BOOTX64.EFI") for l in diff)), " | ".join(diff[:12]))
        n_fails, lines = fails(ser, "vh-audit after the removal")
        check("vh-audit after the removal: as before", n_fails == base_fails, " | ".join(lines))
        run(ser, f"rm -rf {TEST_DIR}")
    finally:
        shutdown(vm, ser)


STEPS = {"game": step_game, "gameboot": step_gameboot, "gamekernel": step_gamekernel}
