"""Track G: the gaming session (vh-game, docs/uni/game.md): install with the plan of the rig
(lavapipe: the rig has no 3D), the session vh-game-enter makes, its sound (QEMU gets a sound
card for this step: the session's own PipeWire plays through it, the card's output lands in a WAV
file on this host; the everyday user's PipeWire and the session's take the card in turn), the
login of game on tty3 through the VM's keyboard, remove, and the whole system compared before
the install and after the removal, across a reboot."""
import array
import os
import re
import time

import vhvm
from vmlib import AUDIT_RX, VM_SRC, as_user, boot, check, run, shq, shutdown

ROOT = "/var/lib/vh/roots/game"
# what changes between two boots by itself: the logs, chrony's drift, dhcpcd's lease, the seed
# of seedrng, the state unbound keeps in its DNSSEC root key (RFC 5011), the hardware clock's
# drift that stage 3 writes, runsv's state of the services whose supervise directory is on the
# disk (the system's own, /etc/sv/vh-*: pid and status at every start). Directories are
# compared without their size (XFS keeps a directory's size)
# /root/.vh-game-test keeps this step's own files across the reboot (/var/tmp is in memory)
TEST_DIR = "/root/.vh-game-test"
VOLATILE = ("/var/log", "/var/lib/chrony", "/var/db/dhcpcd", "/var/lib/dhcpcd", "/var/lib/seedrng", "/etc/unbound/var",
            "/etc/adjtime", "/etc/sv/*/supervise", "/root/.cache", TEST_DIR)
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
        rc, out = run(ser, f"rm -rf {TEST_DIR} && install -d -m 0700 {TEST_DIR} && " + snapshot(f"{TEST_DIR}/before") +
                      f"; grep -c . {TEST_DIR}/before; nft list ruleset > {TEST_DIR}/nft-before; cp /etc/vh/hw.zon {TEST_DIR}/hw-before", timeout=3600)
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
    loud = peak(wav1)
    check("what the session played came out of the sound card (QEMU's WAV file)", loud > 8000, f"peak {loud} of 32767")

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
            procs = [l.split() for l in out.splitlines() if l.split()[:1] in (["pipewire"], ["wireplumber"]) and len(l.split()) >= 4]
            check("the login's session runs its own PipeWire, WirePlumber and pulse server, in its namespaces",
                  any(p[0] == "wireplumber" for p in procs) and any("pipewire-pulse.conf" in p for p in procs)
                  and any(p[0] == "pipewire" and "-c" not in p for p in procs) and all(p[1] == p[2] for p in procs),
                  out[-400:].replace("\n", " | "))
        # tty off: the getty goes, and with its hangup the session
        rc, out = run(ser, "vh-game tty off; sleep 3; echo procs=$(pgrep -u game | wc -l) gettys=$(pgrep -a agetty | grep -c tty3)")
        check("vh-game tty off: the getty and the session end", "procs=0 gettys=0" in out, out[-300:].replace("\n", " | "))
        vm.monitor("sendkey ctrl-alt-f1")
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
        rc, out = run(ser, "getfacl -s -p /dev/snd/* 2>/dev/null | grep -c '^user:'; stat -c '%a %n' /dev/snd/controlC0 /dev/snd/pcmC0D0p")
        check("after the removal: no ACL entry left on the sound card's nodes, 0660 as udev made them",
              re.search(r"^0$", out, re.M) is not None and out.count("660 /dev/snd/") == 2, out[-300:].replace("\n", " | "))
        n_fails, lines = fails(ser, "vh-audit after the removal")
        check("vh-audit after the removal: as before", n_fails == base_fails, " | ".join(lines))
        run(ser, f"rm -rf {TEST_DIR}")
    finally:
        shutdown(vm, ser)


STEPS = {"game": step_game}
