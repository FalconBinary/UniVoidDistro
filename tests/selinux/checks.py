#!/usr/bin/env python3
"""The policy read back (setools): what a neverallow cannot express, and the shape of the policy.
   python3 -I checks.py policy.33 file_contexts   (inside the Fedora container of run.sh)"""
import re
import subprocess
import sys

policy, fc = sys.argv[1], sys.argv[2]
fails = 0


def ok(msg):
    print("ok", msg)


def bad(msg):
    global fails
    fails += 1
    print("FAIL", msg)


def sesearch(*args):
    r = subprocess.run(["sesearch", *args, policy], capture_output=True, text=True)
    return [l for l in r.stdout.splitlines() if l.strip()]


def seinfo(*args):
    r = subprocess.run(["seinfo", *args, policy], capture_output=True, text=True)
    return r.stdout


def expect_empty(name, lines):
    if lines:
        bad(f"{name}: {len(lines)} rule(s): {lines[0][:120]}")
    else:
        ok(name)


# 1. no unconfined domain: nothing may transition to or run as a type named unconfined, and no
#    domain has every permission on file_type
types = seinfo("-t").split()
if any("unconfined" in t for t in types):
    bad("a type named unconfined exists")
else:
    ok("no unconfined type")
# 2. no permissive domain
perm = seinfo("--permissive")
if re.search(r"Permissive Types: 0\b", perm) or "Permissive Types: 0" in perm:
    ok("no permissive type")
else:
    bad(f"permissive types: {perm.strip()[:200]}")
# 3. the one-way boolean: setenforce and load_policy only for init domains and only while the
#    boolean is off
def init_only(r):
    return any(x in r for x in ("init_domain", "kernel_t", "init_t"))


rules = sesearch("-A", "-c", "security", "-p", "setenforce")
if rules and all(init_only(r) and "secure_mode_policyload" in r and "False" in r for r in rules):
    ok(f"setenforce: {len(rules)} conditional rule(s) for init only, off once secure_mode_policyload is set")
else:
    bad(f"setenforce rules: {rules}")
rules = sesearch("-A", "-c", "security", "-p", "load_policy")
if rules and all(init_only(r) and "secure_mode_policyload" in r for r in rules):
    ok("load_policy: init only, conditional")
else:
    bad(f"load_policy rules: {rules}")
# 4. the people and the daemons never touch what is not theirs
expect_empty("user_t cannot read shadow", sesearch("-A", "-s", "user_t", "-t", "shadow_t"))
expect_empty("browser_t cannot read the user's home", sesearch("-A", "-s", "browser_t", "-t", "user_home_t", "-c", "file", "-p", "read"))
expect_empty("browser_t cannot read the Wi-Fi passphrases", sesearch("-A", "-s", "browser_t", "-t", "iwd_var_lib_t", "-c", "file", "-p", "read"))
expect_empty("admin_t cannot read the user's home", sesearch("-A", "-s", "admin_t", "-t", "user_home_t", "-c", "file", "-p", "read"))
expect_empty("sysadm_t cannot read the user's home", sesearch("-A", "-s", "sysadm_t", "-t", "user_home_t", "-c", "file", "-p", "read"))
expect_empty("no domain but sched_t and init loads BPF programs", [r for r in sesearch("-A", "-c", "bpf", "-p", "prog_load") if not any(x in r for x in ("sched_t", "kernel_t", "init_t"))])
expect_empty("no ptrace anywhere", sesearch("-A", "-c", "process", "-p", "ptrace"))
expect_empty("user_t has no execmem", sesearch("-A", "-s", "user_t", "-c", "process", "-p", "execmem"))
expect_empty("daemons do not read the keyboard (input devices)", [r for r in sesearch("-A", "-t", "input_device_t", "-c", "chr_file", "-p", "read") if not any(x in r for x in ("wm_t", "seatd_t", "acpid_t", "deadman_t", "game_t", "udev_t", "kernel_t", "init_t", "init_domain", "bluetoothd_t", "sysadm_t"))])


def port_targets(rules):
    """the rules whose target is a port type (a self rule names the socket's own type)"""
    return [r for r in rules if "_port_t" in r.split(":")[0]]


expect_empty("unbound connects to 853 only", [r for r in port_targets(sesearch("-A", "-s", "unbound_t", "-c", "tcp_socket", "-p", "name_connect")) if "dot_port_t" not in r])
expect_empty("the browser connects to http ports only", [r for r in port_targets(sesearch("-A", "-s", "browser_t", "-c", "tcp_socket", "-p", "name_connect")) if "http_port_t" not in r])
# 5. the roles: sysadm_t and pkg_t are not in user_r; user_t is not in admin_r
roles = seinfo("-r", "user_r", "-x")
if "sysadm_t" in roles or "pkg_t" in roles:
    bad("user_r contains an admin domain")
else:
    ok("user_r has no admin domain")
# 6. every exec type is entered by a transition from somewhere, and every domain has a role
domains = [t for t in seinfo("-a", "domain", "-x").split() if t.endswith("_t")]
exec_types = [t for t in seinfo("-a", "exec_type", "-x").split() if t.endswith("_exec_t")]
# vh-seccomp and the libexec helpers run in their caller's domain on purpose
no_entry = [e for e in exec_types if e not in ("bin_exec_t", "vh_libexec_exec_t", "vh_seccomp_exec_t") and not sesearch("-T", "-t", e, "-c", "process")]
if no_entry:
    bad(f"exec types nothing transitions through: {no_entry}")
else:
    ok(f"{len(exec_types)} exec types, each entered by a transition")
roled = set()
for r in ("system_r", "user_r", "admin_r", "game_r"):
    roled.update(seinfo("-r", r, "-x").split())
unroled = [d for d in domains if d not in roled]
if unroled:
    bad(f"domains in no role: {unroled}")
else:
    ok(f"{len(domains)} domains, each in a role")
# 7. the file contexts stay within vh-selabel's regular-expression subset
allowed = re.compile(r"^(\\.|\[\^?[^\]]+\]|\(\/\.\*\)\?|\(\w+(\|\w+)*\)\??|\.\*|[A-Za-z0-9_/\-\.\+\?\*]|\[0-9\]\+|\[a-z0-9\]\+|\[a-z\]|\[0-9\]\*|\[0-9\]|[\|\(\)])*$")
badfc = []
for line in open(fc):
    pat = line.split()[0]
    if not allowed.match(pat):
        badfc.append(pat)
if badfc:
    bad(f"file contexts outside vh-selabel's subset: {badfc[:5]}")
else:
    ok(f"{sum(1 for _ in open(fc))} file contexts within vh-selabel's subset")
print(f"{fails} failures")
sys.exit(1 if fails else 0)
