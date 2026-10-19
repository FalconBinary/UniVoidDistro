#!/usr/bin/env python3
"""Checks of the installed system on the test rig (after "vhvm.py install").

  check.py base       -- boot without Secure Boot: basic checks, vh-audit, network, DNS, NTS
  check.py enroll     -- enrol our own keys (20-firstboot.sh in Setup Mode)
  check.py sb         -- boot with Secure Boot on: signatures, cmdline only from the UKI
  check.py lock       -- stage 3 (30-lock.sh) and modules_disabled after the reboot
  check.py desktop    -- RefursWM headless, the bar, the Wayland filter, the sandboxed browser under AppArmor
  check.py strictnet  -- optional/strict-net: people's network, temporary allowances
  check.py deadman    -- optional/deadman: RAM dump after poweroff, without the module and with it
  check.py totp       -- optional/tpm2-totp on swtpm: generation, the code before the passphrase, PCR 14
  check.py assess     -- the boot assessment of a machine UKI (a copy of the stock UKI), docs/uni/kernel.md
  check.py machine    -- vh-kconf install of a kernel-custom run's qemu-q35 kernel (build/kernel-custom)
                         through the boot assessment
  check.py all        -- the installation path in order (vmlib.ALL)
  check.py --list     -- every step the registry knows

Each step is a separate VM boot. Steps are discovered from tests/vm/steps/*.py (one module
per area and per track). The result: "PASS/FAIL ..." lines at the end of the output.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import vhvm  # noqa: E402
import vmlib  # noqa: E402


def main():
    reg = vmlib.discover()
    ap = argparse.ArgumentParser()
    ap.add_argument("step", nargs="?", choices=sorted(reg) + ["all"])
    ap.add_argument("--list", action="store_true", help="list the steps and exit")
    ap.add_argument("--dir", default=os.path.join(vhvm.REPO, "tests", "vm", "work"))
    ap.add_argument("--mem", type=int, default=3072)
    ap.add_argument("--smp", type=int, default=4)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--repo", action="store_true", help="refresh /root/vh in the system from the working copy")
    a = ap.parse_args()
    if a.list:
        for name in sorted(reg):
            doc = (reg[name].__doc__ or "").strip().split("\n")[0]
            print(f"{name:12} {doc}")
        return
    if not a.step:
        ap.error("a step is required (or --list)")
    missing = [s for s in vmlib.ALL if s not in reg]
    if missing:
        sys.exit(f"vmlib.ALL names unknown steps: {missing}")
    for name in (vmlib.ALL if a.step == "all" else [a.step]):
        reg[name](a)
    print("\n==== SUMMARY")
    for n, ok, d in vmlib.RESULTS:
        print(f"{'PASS' if ok else 'FAIL'}: {n}")
    sys.exit(0 if all(ok for _, ok, _ in vmlib.RESULTS) else 1)


if __name__ == "__main__":
    main()
