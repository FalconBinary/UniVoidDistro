"""The rolling release's gate (docs/uni/rolling.md): an installation of the previous image takes our
packages from the signed repository of this build, with the command the document gives."""
import hashlib
import os
import re
import subprocess
import sys
import time

import vhvm
from vmlib import check, boot, run, shutdown

PORT = 8321
# the runner, as QEMU's user network shows it to the VM
URL = f"http://10.0.2.2:{PORT}"
OWN = ["univoid", "thor", "vh-tools", "vh-init", "vh-sched", "vh-session", "vh-data", "vh-installer", "vh-base", "vh-etc"]


def adopt_command(fp, sha):
    """The document's command, with the rig's repository and key in place of the published ones: what
    an admin types is what the gate ran."""
    with open(os.path.join(vhvm.REPO, "docs", "uni", "rolling.md")) as f:
        cmd = re.search(r"<!-- the command of an installation of v0\.2\.0 -->\n```sh\n(.*?)\n```", f.read(), re.S).group(1)
    cmd = re.sub(r"https://raw\.githubusercontent\.com/\S+?\.plist", f"{URL}/gate-key/key.plist", cmd)
    cmd = re.sub(r"[0-9A-Za-z_]+(?=  /tmp/vh-key)", sha, cmd)
    cmd = re.sub(r"/var/db/xbps/keys/\S+?\.plist", f"/var/db/xbps/keys/{fp}.plist", cmd)
    cmd = re.sub(r"repository=https://\S+?(?=\\n)", f"repository={URL}", cmd)
    # the rig has a root shell and no one to answer "Continue?"
    return cmd.replace("doas ", "", 1).replace("vh-update --adopt", "vh-update --adopt -y")


def step_update(a):
    """An installation of the previous image (vhvm.py install --own-installer): the command of
    docs/uni/rolling.md against this build's signed repository (VH_UPDATE_REPO), vh-update; every own
    package is installed, its files as packaged, the migrations ran. The reboot and check.py base follow."""
    repo = os.environ.get("VH_UPDATE_REPO", os.path.join(vhvm.REPO, "build", "own-repo"))
    with open(os.path.join(repo, "gate-key", "fingerprint")) as f:
        fp = f.read().strip()
    with open(os.path.join(repo, "gate-key", "key.plist"), "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    srv = subprocess.Popen([sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1", "--directory", repo],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    vm, ser = boot(a)
    try:
        rc, out = run(ser, "xbps-query -p pkgver thor; xbps-query -o /usr/local/sbin/vh-update; echo before=$?; "
                           "grep -c tiny-power-button /etc/runit/ctrlaltdel")
        check("the previous image's installation: vh-update has no owner", "vh-base" not in out, out[-200:].replace("\n", " | "))
        rc, out = run(ser, adopt_command(fp, sha) + "; echo ADOPT_RC=$?", timeout=3600)
        check("the document's command, then our packages over its files", "ADOPT_RC=0" in out, out[-1500:].replace("\n", " | "))
        rc, out = run(ser, "for p in " + " ".join(OWN) + "; do xbps-query -p pkgver $p || echo MISSING $p; done; "
                           "xbps-query -l | awk '{print $2}' | grep -c '^vh-desktop-'")
        check("every own package installed, one desktop build", "MISSING" not in out and re.search(r"^1\s*$", out, re.M) is not None,
              out[-500:].replace("\n", " | "))
        rc, out = run(ser, "for f in /usr/local/sbin/vh-update /usr/local/sbin/vh-init /usr/local/sbin/vh-sched /usr/local/sbin/vh-game "
                           "/usr/local/bin/refurswm /root/vh/hwdb/gpu.zon /root/vh/install/10-install.sh /etc/kernel.d/post-install/90-vh-uki; do "
                           "xbps-query -o $f | cut -d: -f1; done")
        for own in ("vh-base-", "vh-init-", "vh-sched-", "vh-session-", "vh-desktop-", "vh-data-", "vh-installer-", "vh-etc-"):
            check(f"a file owned by {own[:-1]}", own in out, out[-400:].replace("\n", " | "))
        rc, out = run(ser, "xbps-pkgdb " + " ".join(OWN) + "; echo PKGDB_RC=$?", timeout=900)
        check("the files are as packaged (xbps-pkgdb)", "PKGDB_RC=0" in out, out[-500:].replace("\n", " | "))
        rc, out = run(ser, "stat -c %a /root/vh; find /etc -name '*.new-*' -type f | head; ls /var/db/xbps/keys | grep -c " + fp + "; "
                           "cat /var/lib/vh/migrated; grep -c vh-ctrlaltdel /etc/runit/ctrlaltdel; grep -c 90-vh-uki /etc/thor/keep.conf")
        check("/root/vh is 0700", re.search(r"^700\s*$", out, re.M) is not None, out[:100].replace("\n", " | "))
        check("the migration of /etc/runit/ctrlaltdel ran", "0001-ctrlaltdel" in out, out[-300:].replace("\n", " | "))
        # the defect of PR 8: thor without -y closed stdin, so its question was never answered
        rc, out = run(ser, "printf 'y\\n' | thor install tree > /tmp/t.log 2>&1; echo THOR_RC=$?; xbps-query tree >/dev/null && echo HAS_TREE; "
                           "xbps-remove -y tree >/dev/null", timeout=600)
        check("thor without -y answers its question (the new thor is the one that runs)", "HAS_TREE" in out, out[-300:].replace("\n", " | "))
        rc, out = run(ser, "vh-update -y 2>&1 | tail -3; echo UPDATE_RC=$?", timeout=3600)
        check("vh-update again", "UPDATE_RC=0" in out, out[-500:].replace("\n", " | "))
    finally:
        shutdown(vm, ser)
        srv.terminate()


STEPS = {"update": step_update}
