#!/usr/bin/env python3
"""Test rig [VM-TEST]: qemu x86_64 + OVMF (Secure Boot) + swtpm (TPM 2.0, CRB) + VT-d + NVMe.

Works on Linux and macOS (qemu from Homebrew) and drives the VM over the serial console,
with no human involved. Scenarios:

  vhvm.py install  --iso void-live.iso   -- a clean installation with the installer of this repo
  vhvm.py boot                            -- boot the installed system: Limine -> UKI ->
                                            LUKS passphrase -> admin login -> commands from --run
  vhvm.py shell                           -- the same, then an interactive console

VM passwords: LUKS "vh-test-luks", users "vh-test-pass" (test rig only).
Rig directory: --dir (disk disk.qcow2, OVMF variables vars.fd, TPM state).
"""
import argparse
import codecs
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

LUKS_PASS = "vh-test-luks"
USER_PASS = "vh-test-pass"
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
# the repository directory inside the VM, whatever the checkout is called on the host
VM_REPO_NAME = "void-hardperf-light"


def find_firmware():
    cands = [
        ("/opt/homebrew/share/qemu/edk2-x86_64-secure-code.fd", "/opt/homebrew/share/qemu/edk2-i386-vars.fd"),
        ("/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd", "/usr/share/edk2/x64/OVMF_VARS.4m.fd"),
        ("/usr/share/OVMF/OVMF_CODE_4M.secboot.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
        ("/usr/share/qemu/edk2-x86_64-secure-code.fd", "/usr/share/qemu/edk2-i386-vars.fd"),
    ]
    for code, vars_ in cands:
        if os.path.exists(code) and os.path.exists(vars_):
            return code, vars_
    sys.exit("no OVMF firmware with Secure Boot found")


class Serial:
    """The VM's serial console: wait for text, send lines."""

    def __init__(self, path, log):
        for _ in range(100):
            try:
                self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.s.connect(path)
                break
            except OSError:
                time.sleep(0.2)
        else:
            sys.exit("no serial console socket")
        self.buf = ""
        self.alltext = ""     # everything printed during the session: parsed by tests/vm/check.py
        self.dec = codecs.getincrementaldecoder("utf-8")("replace")  # a character may arrive in pieces
        self.log = open(log, "a", encoding="utf-8", errors="replace")

    def _read(self, timeout):
        self.s.settimeout(timeout)
        try:
            data = self.s.recv(65536)
        except socket.timeout:
            return False
        if not data:
            raise EOFError("the VM powered off")
        text = self.dec.decode(data).replace("\r", "")
        self.buf += text
        self.alltext += text
        self.log.write(text)
        self.log.flush()
        return True

    def expect(self, pattern, timeout=300):
        rx = re.compile(pattern)
        end = time.time() + timeout
        while True:
            m = rx.search(self.buf)
            if m:
                self.buf = self.buf[m.end():]
                return m
            left = end - time.time()
            if left <= 0:
                raise TimeoutError(f"timed out waiting for {pattern!r}; tail: {self.buf[-400:]!r}")
            self._read(min(left, 5))

    def send(self, line, delay=0.05):
        for ch in line + "\n":   # slowly: getty under TCG drops characters easily
            self.s.sendall(ch.encode())
            time.sleep(delay)

    def sh(self, cmd, timeout=600, check=True, password=None):
        """Run a command in the VM shell and return its exit code (via a marker). If the
        command asks for a password (doas), answer with password."""
        tag = f"__VH{int(time.time() * 1000) % 10**9}__"
        self.buf = ""
        if "\n" in cmd:
            # heredoc: the marker goes on its own line, otherwise it would break the heredoc terminator
            self.send(f"{cmd}\necho {tag}rc=$?")
        else:
            # one line: otherwise doas would read the marker line as the password
            self.send(f"{cmd}; echo {tag}rc=$?")
        while True:
            m = self.expect(re.escape(tag) + r"rc=(\d+)|doas \([^)]*\) password: ?", timeout)
            if m.group(1) is not None:
                break
            if password is None:
                raise RuntimeError("the command asked for the doas password")
            time.sleep(0.5)
            self.send(password)
        rc = int(m.group(1))
        if check and rc != 0:
            raise RuntimeError(f"command '{cmd[:80]}' returned {rc}")
        return rc


class VM:
    def __init__(self, d, mem, smp):
        self.d = os.path.abspath(d)
        os.makedirs(self.d, exist_ok=True)
        self.code, vars_tmpl = find_firmware()
        self.vars = os.path.join(self.d, "vars.fd")
        if not os.path.exists(self.vars):
            shutil.copyfile(vars_tmpl, self.vars)   # empty variables: Setup Mode
        self.disk = os.path.join(self.d, "disk.qcow2")
        self.mem, self.smp = mem, smp
        self.procs = []
        # a UNIX socket path is limited to ~104 bytes: sockets go into a short directory
        self.sockdir = tempfile.mkdtemp(prefix="vh", dir="/tmp")

    def new_disk(self, size="32G"):
        for f in (self.disk, self.vars):
            if os.path.exists(f):
                os.remove(f)
        shutil.copyfile(find_firmware()[1], self.vars)
        shutil.rmtree(os.path.join(self.d, "tpm"), ignore_errors=True)
        subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", self.disk, size], check=True)

    def start(self, extra):
        tpmdir = os.path.join(self.d, "tpm")
        os.makedirs(tpmdir, exist_ok=True)
        tpmsock = os.path.join(self.sockdir, "tpm")
        sersock = os.path.join(self.sockdir, "serial")
        monsock = os.path.join(self.sockdir, "monitor")
        for s in (tpmsock, sersock, monsock):
            if os.path.exists(s):
                os.remove(s)
        self.procs.append(subprocess.Popen(
            ["swtpm", "socket", "--tpm2", "--tpmstate", f"dir={tpmdir}",
             "--ctrl", f"type=unixio,path={tpmsock}", "--flags", "startup-clear"]))
        for _ in range(50):
            if os.path.exists(tpmsock):
                break
            time.sleep(0.1)
        cmd = [
            "qemu-system-x86_64", "-machine", "q35,smm=on", "-accel", os.environ.get("VH_ACCEL", "tcg"),
            "-cpu", "max", "-smp", str(self.smp), "-m", str(self.mem),
            # an emulated VT-d (a DMAR table) before any PCI device: the rig has the full
            # protection of the security gate (VH_SECURITY=strict); no interrupt remapping, so
            # no split irqchip is needed [VERIFY under TCG and KVM]
            "-device", "intel-iommu,intremap=off",
            "-global", "driver=cfi.pflash01,property=secure,value=on",
            "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={self.code}",
            "-drive", f"if=pflash,format=raw,unit=1,file={self.vars}",
            "-drive", f"file={self.disk},if=none,id=nvm,discard=unmap,cache=unsafe",
            "-device", "nvme,serial=VHTEST01,drive=nvm",
            "-chardev", f"socket,id=chrtpm,path={tpmsock}",
            "-tpmdev", "emulator,id=tpm0,chardev=chrtpm", "-device", "tpm-crb,tpmdev=tpm0",
            "-nic", "user,model=e1000",
            "-serial", f"unix:{sersock},server=on,wait=off",
            "-monitor", f"unix:{monsock},server=on,wait=off",
            "-device", "virtio-vga", "-display", "none",
        ] + extra
        self.procs.append(subprocess.Popen(cmd))
        return Serial(sersock, os.path.join(self.d, "serial.log"))

    def monitor(self, command):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(os.path.join(self.sockdir, "monitor"))
        s.sendall((command + "\n").encode())
        time.sleep(1)
        s.close()

    def stop(self):
        for p in reversed(self.procs):
            try:
                p.wait(timeout=120)
            except subprocess.TimeoutExpired:
                p.kill()
        shutil.rmtree(self.sockdir, ignore_errors=True)


def make_repo_iso(out):
    """The repository as a tar archive on the VM's second CD drive: file modes are preserved."""
    stage = tempfile.mkdtemp()
    flags = ["--no-xattrs"] + (["--no-fflags", "--no-mac-metadata"] if sys.platform == "darwin" else [])
    subprocess.run(["tar", *flags, "-cf", os.path.join(stage, "vh.tar"),
                    "--exclude", ".git", "--exclude", "tests/vm/work", "--exclude", "__pycache__",
                    # the installer builds everything itself: Zig caches and build/ are not needed in the VM
                    "--exclude", ".zig-cache", "--exclude", "zig-out", "--exclude", "zig-pkg",
                    "--exclude", f"{os.path.basename(REPO)}/build",
                    "-C", os.path.dirname(REPO), os.path.basename(REPO)], check=True,
                   env=dict(os.environ, COPYFILE_DISABLE="1"))
    if os.path.exists(out):
        os.remove(out)
    if shutil.which("xorriso"):
        cmd = ["xorriso", "-as", "mkisofs", "-R", "-quiet", "-V", "VHREPO", "-o", out, stage]
    elif shutil.which("hdiutil"):
        cmd = ["hdiutil", "makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "VHREPO",
               "-o", out, stage]
    else:
        cmd = ["genisoimage", "-R", "-quiet", "-V", "VHREPO", "-o", out, stage]
    subprocess.run(cmd, check=True)
    shutil.rmtree(stage)


def login(ser, user, password):
    ser.expect(r"login: ?$|login:\s*$", 1800)
    ser.send(user)
    ser.expect(r"[Pp]assword: ?", 60)
    ser.send(password)
    ser.expect(r"[#$] ?$", 120)
    ser.send("exec bash")      # root's shell in the live environment is dash
    time.sleep(2)
    ser.send("export PS1='vh# ' TERM=dumb; stty -echo cols 250")
    ser.expect(r"vh# ", 60)


def cmd_install(a):
    vm = VM(a.dir, a.mem, a.smp)
    vm.new_disk()
    repo_iso = os.path.join(vm.d, "repo.iso")
    make_repo_iso(repo_iso)
    work = tempfile.mkdtemp(dir=vm.d)
    subprocess.run(["tar", "-xf", a.iso, "-C", work, "boot/vmlinuz", "boot/initrd"], check=True)
    append = ("root=live:CDLABEL=VOID_LIVE ro init=/sbin/init rd.luks=0 rd.md=0 rd.dm=0 "
              "loglevel=4 console=ttyS0,115200 rd.live.overlay.overlayfs=1")
    ser = vm.start(["-cdrom", a.iso,
                    "-drive", f"file={repo_iso},if=none,id=repo,media=cdrom,readonly=on",
                    "-device", "ide-cd,drive=repo",
                    "-kernel", f"{work}/boot/vmlinuz", "-initrd", f"{work}/boot/initrd",
                    "-append", append])
    try:
        login(ser, "root", "voidlinux")
        name = os.path.basename(REPO)
        ser.sh("mkdir -p /tmp/r && mount -o ro /dev/sr1 /tmp/r && tar -xf /tmp/r/vh.tar -C /root && umount /tmp/r && "
               # the directory in the VM is always /root/void-hardperf-light, whatever the checkout is called
               f"{{ [ {name} = {VM_REPO_NAME} ] || mv /root/{name} /root/{VM_REPO_NAME}; }}")
        conf = "\n".join([
            'VH_DISK="/dev/nvme0n1"',
            'VH_EXTRA_CMDLINE="console=tty0 console=ttyS0,115200"',
            'VH_LUKS_ITER_MS="1000"',      # TCG is slow; on hardware 3000 (the default)
            'VH_LIMINE_TIMEOUT="1"',
            'VH_TEST_SERIAL="yes"',
        ] + a.conf)
        ser.sh(f"cat > /root/{VM_REPO_NAME}/vh.conf <<'EOF'\n{conf}\nEOF")
        ser.sh(f"cd /root/{VM_REPO_NAME} && VH_YES=1 VH_TEST_PASSPHRASE='{LUKS_PASS}' "
               f"VH_TEST_PASSWORD='{USER_PASS}' bash install/10-install.sh 2>&1 | tee /root/install.log; "
               "test ${PIPESTATUS[0]} = 0", timeout=a.timeout)
        ser.sh("sync; umount -R /mnt; cryptsetup close cryptroot", check=False)
        print("\nINSTALL PASSED", flush=True)
        ser.send("poweroff")
    finally:
        vm.stop()


def boot_and_login(a, vm):
    extra = []
    if a.repo:
        # a fresh copy of the repository on a CD: in the VM, mount /dev/sr0 and tar -xf vh.tar
        repo_iso = os.path.join(vm.d, "repo.iso")
        make_repo_iso(repo_iso)
        extra = ["-drive", f"file={repo_iso},if=none,id=repo,media=cdrom,readonly=on",
                 "-device", "ide-cd,drive=repo"]
    ser = vm.start(extra)
    # the initramfs (dracut crypt) asks for the LUKS passphrase on the last console: ttyS0
    ser.expect(r"[Pp]assword|[Pp]assphrase", 1800)
    time.sleep(2)
    ser.send(LUKS_PASS)
    # login: tty1 is the everyday user (graphics), tty2 the admin; ttyS0 has no getty by
    # default, the test configuration enables agetty-ttyS0
    login(ser, a.user, USER_PASS)
    return ser


def cmd_boot(a, interactive=False):
    vm = VM(a.dir, a.mem, a.smp)
    ser = boot_and_login(a, vm)
    try:
        for c in a.run:
            rc = ser.sh(c, timeout=a.timeout, check=False, password=USER_PASS)
            print(f"\n== '{c}' -> {rc}", flush=True)
        if interactive:
            print("interactive console: socat - UNIX-CONNECT:" + os.path.join(vm.sockdir, "serial"))
            input("Enter to power the VM off ")
        if a.user == "root":
            ser.send("poweroff")
        else:
            ser.send("doas poweroff")
            try:
                ser.expect(r"doas \([^)]*\) password: ?", 30)
                time.sleep(0.5)
                ser.send(USER_PASS)
            except (TimeoutError, EOFError):
                pass
    finally:
        vm.stop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["install", "boot", "shell"])
    ap.add_argument("--dir", default=os.path.join(REPO, "tests", "vm", "work"))
    ap.add_argument("--iso")
    ap.add_argument("--mem", type=int, default=3072)
    ap.add_argument("--smp", type=int, default=4)
    ap.add_argument("--timeout", type=int, default=4 * 3600)
    ap.add_argument("--conf", action="append", default=[], help="an extra vh.conf line")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--run", action="append", default=[])
    ap.add_argument("--repo", action="store_true", help="attach a fresh copy of the repository as a CD")
    a = ap.parse_args()
    if a.action == "install":
        if not a.iso:
            ap.error("--iso is required")
        cmd_install(a)
    else:
        cmd_boot(a, interactive=(a.action == "shell"))


if __name__ == "__main__":
    main()
