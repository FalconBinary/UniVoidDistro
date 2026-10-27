"""Shared code of the VM checks (tests/vm/check.py) and the step registry.

A step is a function step(a) that boots the VM one or more times and records results with
check(). Steps live in tests/vm/steps/*.py; each module exports STEPS = {"name": func}.
Every track owns its own module (steps/kernel.py, steps/init.py, ...) so parallel work does
not collide in one file. The machine-readable contract the steps rely on:

  vh-audit            last line  VH_AUDIT ok=N fail=N unchecked=N
  vh-limine-update    "enrolled into Limine"
  20-firstboot.sh     "keys enrolled"
  tools/vh-bench      "Report: PATH"
  vh-wlfilter         "client disconnected: ..." on protocol errors
  thor                "Downloading N packages", "Downloaded", "denied", "mode: enforce",
                      "SUID/SGID stripped: PATH"
  vh-deep-clean       "System is in order.", "no new FAILs"
"""
import importlib
import os
import pkgutil
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import vhvm  # noqa: E402

RESULTS = []
TOTP_PASS = "vh-test-totp-recovery"
# the repository copy inside the VM when a step runs with --repo
VM_SRC = f"/tmp/vhn/{vhvm.VM_REPO_NAME}"
# "all": the installation path of a new machine, in order
ALL = ["base", "enroll", "sb", "lock", "desktop"]
AUDIT_RX = re.compile(r"VH_AUDIT ok=(\d+) fail=(\d+) unchecked=(\d+)")


def check(name, ok, detail=""):
    RESULTS.append((name, ok, detail))
    print(f"\n{'PASS' if ok else 'FAIL'}: {name} {detail}", flush=True)


def run(ser, cmd, timeout=900):
    """Run a command in the root shell (doas -s), return (rc, output). "doas " in commands is
    dropped: the shell is already root, and repeated password prompts over the serial
    console lose characters."""
    cmd = re.sub(r"\bdoas\s+", "", cmd)
    ser.log.write(f"\n### {cmd}\n")
    start = len(ser.alltext)
    rc = ser.sh(cmd, timeout=timeout, check=False)
    out = ser.alltext[start:]
    return rc, out


def audit(ser, name, want_zero_fails=False):
    """doas vh-audit, parsed through the VH_AUDIT marker."""
    rc, out = run(ser, "doas vh-audit", timeout=600)
    m = AUDIT_RX.search(out)
    fails = [l for l in out.splitlines() if l.startswith("[FAIL]")]
    ok = m is not None and (not want_zero_fails or m.group(2) == "0")
    check(name, ok, (m.group(0) if m else "no summary") + " | " + " | ".join(fails))
    return m


# Modules of modules.devname that stage 1 loads unless modprobe.d blacklists them, and that the
# rig does not use (no Bluetooth, no sound, VH_VIRT=no): rootfs/etc/modprobe.d/vh-devnodes.conf
# and vh-novirt.conf leave them out (docs/uni/runtime.md, "Kernel modules at boot")
DEVNAME_UNUSED = ("hci_vhci", "bluetooth", "userio", "uinput", "ppp_generic", "nvram", "snd_seq",
                  "snd_timer", "tun", "vhost_net", "vhost_vsock", "vfio")


def devname_unused(ser, path="/proc/modules"):
    """The modules of DEVNAME_UNUSED that path names (the first word of a line, # comments
    skipped), or None when path cannot be read."""
    rc, out = run(ser, f"test -r {path} && echo words: $(awk '!/^#/ {{print $1}}' {path})")
    m = re.search(r"words: (.*)", out)
    return [x for x in DEVNAME_UNUSED if x in m.group(1).split()] if rc == 0 and m else None


def put_file(ser, path, data):
    """A file from the host into the VM: base64 in chunks (ASCII only over the serial console)."""
    import base64
    b = base64.b64encode(data).decode()
    run(ser, f"rm -f {path}.b64")
    for i in range(0, len(b), 900):
        run(ser, f"printf '%s' '{b[i:i + 900]}' >> {path}.b64")
    run(ser, f"base64 -d {path}.b64 > {path} && rm -f {path}.b64")


def session_usage(ser, user, secs):
    """Memory and CPU of user's processes when idle (tools/vh-session-usage)."""
    with open(os.path.join(vhvm.REPO, "tools", "vh-session-usage"), "rb") as f:
        put_file(ser, "/tmp/session-usage.sh", f.read())
    rc, out = run(ser, f"sh /tmp/session-usage.sh {user} {secs}", timeout=secs + 300)
    print(f"--- {user}: memory and CPU over {secs} s idle")
    print(out)
    return out


def pf(text):
    """printf '...' made of ASCII only: non-ASCII bytes as octal escapes. Over the serial
    console, in a shell without a locale, readline takes UTF-8 bytes for Meta keys and
    eats the line."""
    out = "".join(c if c.isascii() and c.isprintable() and c not in "'\\%" else
                  "".join(f"\\{b:03o}" for b in c.encode()) for c in text)
    return f"printf '{out}'"


def as_user(user, cmd):
    """A command as another user (from the root shell): their UID, GID and groups."""
    return f"setpriv --reuid={user} --regid={user} --init-groups sh -c {shq(cmd)}"


def shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def root_shell(ser):
    ser.send("doas -s")
    ser.expect(r"doas \([^)]*\) password: ?", 60)
    time.sleep(1)
    ser.send(vhvm.USER_PASS)
    time.sleep(2)
    # no history: typed commands must not end up in ~/.bash_history (the deadman test looks
    # for markers in RAM; copies from the history file would give a false result)
    ser.send("unset HISTFILE; export PS1='vh# ' TERM=dumb; stty -echo cols 250; "
             "rm -f /root/.bash_history /home/*/.bash_history")
    ser.expect(r"vh# ", 60)


# from build/ the VM needs only the finished programs and build/thor-repo (tests/zig/build.sh)
VM_SKIP_BUILD = ["docker-ctx", "zig-dl", "xbps-dl", "devimg", "zig-test", "zt", "zt2", "zx", "zig-bin",
                 "thor-work", "thor-dest", "kx", "kd", "sx", "ix", "scx", "*.log"]


def keys(vm, text):
    """type TEXT on the VM's keyboard (QEMU's sendkey): letters, digits, '-', ' ', '.', '/'"""
    for ch in text:
        name = {"-": "minus", " ": "spc", ".": "dot", "/": "slash"}.get(ch, ch)
        vm.monitor(f"sendkey {name}")
        time.sleep(0.2)


def boot(a, extra=None, on_prompt=None):
    """Boot the installed system to a root shell. on_prompt(vm, ser) runs when the first
    passphrase prompt appears: a step that interrupts that boot (steps/kernel.py resets a trial
    there) waits for the prompt of the boot after it, and this one goes on from there."""
    vm = vhvm.VM(a.dir, a.mem, a.smp)
    extra = list(extra or [])
    if getattr(a, "repo", False):
        # a fresh copy of the repository as a raw tar on a second NVMe: after 30-lock.sh the
        # isofs module cannot be loaded (modules_disabled), while the NVMe driver is built in
        if not os.path.isfile(os.path.join(vhvm.REPO, "build", "vh-seccomp")):
            sys.exit("no build/: build the tools and thor first: sh tests/zig/build.sh")
        tar = os.path.join(vm.d, "repo.tar")
        flags = ["--no-xattrs"] + (["--no-fflags", "--no-mac-metadata"] if sys.platform == "darwin" else [])
        # the rig itself (the disk image, this tar) lives under tests/vm/work by default: never inside the archive
        # a live ISO kept in the checkout (kvm-smoke downloads it into iso/) stays out too: the VM
        # unpacks this tar into /tmp, a tmpfs of 25% of the RAM, which the ISO filled
        subprocess.run(["tar", *flags, "-cf", tar, "--exclude", ".git", "--exclude", "__pycache__", "--exclude", ".zig-cache",
                        "--exclude", "zig-out", "--exclude", "tests/vm/work", "--exclude", "*.iso",
                        *[x for d in VM_SKIP_BUILD for x in ("--exclude", f"build/{d}")],
                        "-C", os.path.dirname(vhvm.REPO), os.path.basename(vhvm.REPO)], check=True,
                       env=dict(os.environ, COPYFILE_DISABLE="1"))
        extra += ["-drive", f"file={tar},if=none,id=repo,format=raw,readonly=on",
                  "-device", "nvme,serial=VHREPO,drive=repo"]
    ser = vm.start(extra)
    ser.expect(r"[Pp]assword|[Pp]assphrase", 1800)
    if on_prompt:
        on_prompt(vm, ser)
    time.sleep(2)
    ser.send(vhvm.LUKS_PASS)
    # an initramfs with optional/tpm2-totp may ask for the recovery password (generation by flag)
    while True:
        m = ser.expect(r"login: ?$|[Rr]ecovery password[^:]*: |Again: |Press Enter|Type RESEAL: ", 1800)
        t = m.group(0)
        if t.startswith("login"):
            break
        time.sleep(1)
        ser.send("" if t.startswith("Press") else ("RESEAL" if "RESEAL" in t else TOTP_PASS))
    ser.buf = "login: "
    vhvm.login(ser, "admin", vhvm.USER_PASS)
    root_shell(ser)
    if getattr(a, "repo", False):
        run(ser, "rm -rf /tmp/vhn && mkdir /tmp/vhn && "
                 "tar -xf $(readlink -f /dev/disk/by-id/nvme-*VHREPO* | head -1) -C /tmp/vhn && "
                 # the directory is always void-hardperf-light, whatever the checkout is called
                 f"{{ [ -d {VM_SRC} ] || mv /tmp/vhn/* {VM_SRC}; }} && "
                 f"cp -a {VM_SRC}/install {VM_SRC}/optional {VM_SRC}/rootfs {VM_SRC}/tools {VM_SRC}/zig "
                 f"{VM_SRC}/thor /root/vh/ && rm -rf /root/vh/src && "
                 f"cd {VM_SRC}/rootfs/usr/local && find . -type f ! -name '*.in' | "
                 "while read f; do install -m $(stat -c %a \"$f\") \"$f\" \"/usr/local/$f\"; done; cd / && "
                 f"bash /root/vh/install/build-tools.sh --prebuilt {VM_SRC}/build / >/dev/null && "
                 # a system without python3 (docs/17): ignorepkg and removal if a previous install had it
                 f"install -m 0644 {VM_SRC}/rootfs/etc/xbps.d/20-vh-ignorepkg.conf /etc/xbps.d/ && "
                 "{ xbps-remove -Fy python3 >/dev/null 2>&1; true; } && "
                 # with VH_MAC=selinux the refreshed files need their labels, as after vh-update
                 # (docs/uni/selinux.md); on the stock kernel the xattrs are stored, the machine
                 # kernel reads them (kvm-smoke 40349043789 ran the refreshed vh-init unlabelled)
                 "{ [ ! -d /etc/vh/selinux ] || /usr/local/sbin/vh-selabel /usr/local /root/vh /etc/xbps.d | tail -1; }")
    return vm, ser


def shutdown(vm, ser):
    try:
        ser.send("poweroff")
    except OSError:
        pass   # the VM is off already (the base step ends with the power button)
    vm.stop()


def discover():
    """All steps from tests/vm/steps/*.py: {name: func}. A name defined twice is an error."""
    import steps
    reg = {}
    for m in pkgutil.iter_modules(steps.__path__):
        mod = importlib.import_module(f"steps.{m.name}")
        for name, fn in getattr(mod, "STEPS", {}).items():
            if name in reg:
                sys.exit(f"step {name!r} is defined twice (steps/{m.name}.py)")
            reg[name] = fn
    return reg
