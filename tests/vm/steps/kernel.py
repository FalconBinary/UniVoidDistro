"""Track K (U3): the boot assessment of a machine UKI on the rig (docs/uni/kernel.md)."""
import re

from vmlib import boot, check, run, shutdown

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


STEPS = {"assess": step_assess}
