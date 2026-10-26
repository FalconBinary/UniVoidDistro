"""Track K (U3): the boot assessment of a machine UKI on the rig, and vh-kconf install of a real
machine kernel (docs/uni/kernel.md)."""
import os
import re
import sys

import vhvm
from vmlib import VM_SRC, boot, check, run, shutdown

# the services judge a boot a few seconds after they start: vh-check first, then vh-boot-assess
JUDGED = ("for i in $(seq 1 90); do grep -qx \"TRIAL_LAST=$(cat /proc/sys/kernel/random/boot_id)\" "
          "/var/lib/vh/boot-assess 2>/dev/null && break; sleep 2; done; vh-limine-update --status")


def started(out):
    """the entry this boot started, as --status reports LoaderEntrySelected"""
    m = re.search(r"started: (\S+);", out)
    return m.group(1) if m else ""


def reset_at_prompt(vm, ser):
    """the trial's initramfs asks for the passphrase: a hard reset there, as a hang and a power
    cycle would do; then the passphrase prompt of the boot after it"""
    vm.monitor("system_reset")
    ser.buf = ""
    ser.expect(r"[Pp]assword|[Pp]assphrase", 1800)


def step_assess(a):
    """The boot assessment, with a copy of the stock UKI as the machine UKI (a real machine
    kernel needs vh-kconf install): what Limine 12 reports through the Boot Loader Interface,
    the one-shot entry, three good boots to LoaderEntryDefault with limine.conf unchanged, the
    default booted, --demote, and a trial reset at its passphrase prompt whose next boot is the
    default by itself."""
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "vh-limine-update --status")
        check("Limine reports the Boot Loader Interface with one-shot entries",
              "Limine" in out and "one-shot entries: yes" in out, out[-300:].replace("\n", " | "))
        stock = started(out)
        check("this boot started the stock entry", stock.startswith("Void-Linux-") and "machine-kernel" not in stock, stock)
        rc, out = run(ser, "v=$(uname -r); b=${v%_*}; echo \"MID=Void-Linux-$b-vh_1--machine-kernel- UKI=linux-$b-vh_1.efi\"; "
                           "mount /boot/efi && cp /boot/efi/EFI/void/linux-$v.efi /boot/efi/EFI/void/linux-$b-vh_1.efi && "
                           "vh-limine-update --new $b-vh_1; r=$?; sha256sum /boot/efi/EFI/BOOT/limine.conf; umount /boot/efi; test $r = 0",
                      timeout=600)
        m = re.search(r"MID=(\S+) UKI=(\S+)", out)
        mid, name = (m.group(1), m.group(2)) if m else ("?", "?")
        check("--new: the machine UKI is on trial, set for the next boot", rc == 0 and "on trial: the next boot tries it" in out,
              out[-400:].replace("\n", " | "))
        conf = re.search(r"^([0-9a-f]{64})  /boot/efi/EFI/BOOT/limine.conf", out, re.M)
    finally:
        shutdown(vm, ser)
    for n in (1, 2, 3):
        vm, ser = boot(a)
        try:
            rc, out = run(ser, JUDGED, timeout=300)
            check(f"trial boot {n}: Limine started the machine entry (the one-shot entry)", started(out) == mid, started(out))
            if n < 3:
                check(f"trial boot {n}: {n} of 3 good boots, set again", f"{n} of 3 good boots, set for the next boot" in out,
                      out[-400:].replace("\n", " | "))
            else:
                check("trial boot 3: Limine's default now", "the default: the machine kernel" in out and f"LoaderEntryDefault: {mid}" in out,
                      out[-400:].replace("\n", " | "))
        finally:
            shutdown(vm, ser)
    vm, ser = boot(a)
    try:
        rc, out = run(ser, JUDGED, timeout=300)
        check("the next boot: Limine's default is the machine entry", started(out) == mid and "on trial: none" in out, started(out))
        rc, out = run(ser, "mount -o ro /boot/efi && sha256sum /boot/efi/EFI/BOOT/limine.conf; umount /boot/efi")
        check("the promotion did not change limine.conf", conf is not None and conf.group(1) in out, out[-200:])
        rc, out = run(ser, "vh-limine-update --demote")
        check("--demote", rc == 0 and "is no longer the default" in out, out[-300:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)
    try:
        rc, out = run(ser, JUDGED, timeout=300)
        check("after --demote the stock entry boots", started(out) == stock, started(out))
        rc, out = run(ser, f"vh-limine-update --retry {name}")
        check("--retry NAME: on trial again, set", rc == 0 and "the next boot tries it" in out, out[-300:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a, on_prompt=reset_at_prompt)
    try:
        rc, out = run(ser, JUDGED, timeout=300)
        check("the boot after a reset trial is the default by itself", started(out) == stock, started(out))
        check("the reset trial is recorded as failed", "failed its trial" in out and "did not reach the end of the boot" in out,
              out[-400:].replace("\n", " | "))
        rc, out = run(ser, f"mount /boot/efi && rm -f /boot/efi/EFI/void/{name} && vh-limine-update; r=$?; umount /boot/efi; "
                           "vh-limine-update --status; test $r = 0", timeout=600)
        check("the copy removed: the trial forgotten, the stock UKI alone", rc == 0 and "on trial: none" in out, out[-300:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)


# the files of a kernel-custom run for qemu-q35 (its artifact kernel-custom-qemu-q35-KVER): the
# kvm-smoke workflow downloads them here (its input kernel_run), by hand: gh run download
ART = os.path.join(vhvm.REPO, "build", "kernel-custom")


def final_cmdline(out):
    """the command line vh-kconf install computed: the line after its "+" and "-" lines"""
    m = re.search(r"^command line: from \S+\n(?:  [-+=] .*\n)*  (.*)$", out, re.M)
    return m.group(1) if m else ""


def need_run_files(a):
    """the preconditions of a step that installs build/kernel-custom's kernel"""
    if not os.path.isfile(os.path.join(ART, "SHA256SUMS")):
        sys.exit(f"no run's files in {ART}: the artifact kernel-custom-qemu-q35-KVER of a kernel-custom run "
                 "(kvm-smoke: the input kernel_run; by hand: gh run download RUN -n kernel-custom-qemu-q35-KVER -D build/kernel-custom)")
    if not getattr(a, "repo", False):
        sys.exit("the step needs --repo: the run's files and vh-kconf travel with the working copy")
    if not os.path.isfile(os.path.join(vhvm.REPO, "build", "vh-kconf")):
        sys.exit("no build/vh-kconf: sh tests/zig/build.sh")


def install_trial(ser):
    """vh-kconf install of build/kernel-custom's kernel with the working copy's vh-kconf: the machine
    UKI on trial, set for the next boot. Returns (the Limine entry id, the UKI's name)."""
    d = f"{VM_SRC}/build/kernel-custom"
    rc, out = run(ser, f"install -m 0755 {VM_SRC}/build/vh-kconf /usr/local/sbin/vh-kconf && vh-kconf install --hw {d}/qemu-q35.zon {d}", timeout=1800)
    m = re.search(r"vh-kconf install: linux-(\S+)\.efi installed", out)
    ver = m.group(1) if m else "?"
    check("vh-kconf install: the machine UKI is on the ESP and on trial, set for the next boot",
          rc == 0 and m is not None and "on trial: the next boot tries it" in out, out[-400:].replace("\n", " | "))
    return f"Void-Linux-{ver}--machine-kernel-", f"linux-{ver}.efi"


def remove_trial(ser, name):
    """the machine UKI removed from the ESP: the trial forgotten, the stock UKI alone"""
    rc, out = run(ser, f"mount /boot/efi && rm -f /boot/efi/EFI/void/{name} && vh-limine-update; r=$?; umount /boot/efi; "
                       "vh-limine-update --status; test $r = 0", timeout=600)
    check("the machine UKI removed: the trial forgotten, the stock UKI alone", rc == 0 and "on trial: none" in out, out[-300:].replace("\n", " | "))


def step_machine(a):
    """vh-kconf install of a real machine kernel: the qemu-q35 kernel of a kernel-custom run (its
    files in build/kernel-custom) becomes a machine UKI on trial; it boots, vh-kconf check finds
    the rig with every driver, three good boots make it Limine's default, vh-audit's boot and plan
    areas have no FAIL about modules on it, --demote and the removal of the UKI give the stock UKI
    back. The run's kernel is built from kernel/hw/qemu-q35.zon, the rig's /etc/vh/hw.zon of a
    kvm-smoke run (vhvm.py pins the CPU, so it is this rig's too): --hw names that file, and the
    boot assessment judges the kernel against this installation's own /etc/vh/hw.zon."""
    if not os.path.isfile(os.path.join(ART, "SHA256SUMS")):
        sys.exit(f"no run's files in {ART}: the artifact kernel-custom-qemu-q35-KVER of a kernel-custom run "
                 "(kvm-smoke: the input kernel_run; by hand: gh run download RUN -n kernel-custom-qemu-q35-KVER -D build/kernel-custom)")
    if not getattr(a, "repo", False):
        sys.exit("the machine step needs --repo: the run's files and vh-kconf travel with the working copy")
    if not os.path.isfile(os.path.join(vhvm.REPO, "build", "vh-kconf")):
        sys.exit("no build/vh-kconf: sh tests/zig/build.sh")
    d = f"{VM_SRC}/build/kernel-custom"
    vm, ser = boot(a)
    try:
        rc, out = run(ser, f"install -m 0755 {VM_SRC}/build/vh-kconf /usr/local/sbin/vh-kconf && vh-kconf version")
        check("the working copy's vh-kconf", rc == 0, out[-200:])
        rc, out = run(ser, f"vh-kconf install --dry-run --hw {d}/qemu-q35.zon {d}", timeout=600)
        cmd = final_cmdline(out)
        check("install --dry-run: the run's files verified, nothing written", rc == 0 and "verified:" in out and "nothing was written" in out,
              out[-500:].replace("\n", " | "))
        check("the machine command line: the stock one without module_blacklist= and module.sig_enforce=1",
              "root=UUID=" in cmd and "module_blacklist=" not in cmd and "module.sig_enforce" not in cmd, cmd)
        rc, out = run(ser, f"vh-kconf install --hw {d}/qemu-q35.zon {d}", timeout=1800)
        m = re.search(r"vh-kconf install: linux-(\S+)\.efi installed", out)
        ver = m.group(1) if m else "?"
        name = f"linux-{ver}.efi"
        check("install: dracut --no-kernel built the UKI, .linux and .cmdline checked", ".linux is the verified bzImage" in out,
              out[-400:].replace("\n", " | "))
        check("install: the machine UKI is on the ESP and on trial, set for the next boot",
              rc == 0 and m is not None and "on trial: the next boot tries it" in out, out[-400:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
    mid = f"Void-Linux-{ver}--machine-kernel-"
    for n in (1, 2, 3):
        vm, ser = boot(a)
        try:
            rc, out = run(ser, JUDGED, timeout=300)
            check(f"trial boot {n}: Limine started the machine entry (the one-shot entry)", started(out) == mid, started(out))
            rc, kv = run(ser, "uname -r; test -e /proc/modules && echo MODULES || echo NOMODULES; cat /run/vh/check.done")
            check(f"trial boot {n}: the machine kernel runs, without loadable modules", "-vh\n" in kv and "NOMODULES" in kv, kv[-200:])
            # what vh-kconf check found, device by device (written only when it has something to say);
            # no firmware failure: without Wi-Fi the kernel has no cfg80211 (features/wifi), which
            # built in asked for a regulatory.db the plan does not keep
            rc, found = run(ser, "cat /run/vh/check 2>/dev/null || echo 'no /run/vh/check'")
            check(f"trial boot {n}: vh-kconf check finds the rig with every driver and no firmware failure",
                  "machine=same" in kv and "lost=0" in kv and "firmware=0" in kv,
                  (kv[-120:] + "\n" + found[-900:]).replace("\n", " | "))
            if n < 3:
                check(f"trial boot {n}: {n} of 3 good boots, set again", f"{n} of 3 good boots, set for the next boot" in out,
                      out[-400:].replace("\n", " | "))
            else:
                check("trial boot 3: Limine's default now", "the default: the machine kernel" in out and f"LoaderEntryDefault: {mid}" in out,
                      out[-400:].replace("\n", " | "))
        finally:
            shutdown(vm, ser)
    vm, ser = boot(a)
    try:
        rc, out = run(ser, JUDGED, timeout=300)
        check("the next boot: Limine's default is the machine entry", started(out) == mid and "on trial: none" in out, started(out))
        rc, out = run(ser, "doas vh-audit boot plan", timeout=600)
        fails = [ln for ln in out.splitlines() if ln.startswith("[FAIL]") and re.search(r"sig_enforce|module|modules_disabled", ln)]
        check("vh-audit on the machine kernel: no FAIL about module.sig_enforce, the module lock or module_blacklist=", not fails,
              " | ".join(fails))
        check("vh-audit: the machine kernel's own lines", "no loadable modules in this kernel" in out and "cannot be loaded" in out,
              out[-300:].replace("\n", " | "))
        rc, out = run(ser, "vh-limine-update --demote")
        check("--demote", rc == 0 and "is no longer the default" in out, out[-300:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
    vm, ser = boot(a)
    try:
        rc, out = run(ser, JUDGED, timeout=300)
        check("after --demote the stock entry boots", started(out).startswith("Void-Linux-") and "machine-kernel" not in started(out), started(out))
        rc, out = run(ser, f"mount /boot/efi && rm -f /boot/efi/EFI/void/{name} && vh-limine-update; r=$?; umount /boot/efi; "
                           "vh-limine-update --status; test $r = 0", timeout=600)
        check("the machine UKI removed: the stock UKI alone", rc == 0 and "on trial: none" in out and "the default: the newest stock UKI" in out,
              out[-300:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)


STEPS = {"assess": step_assess, "machine": step_machine}
