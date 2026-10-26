//! vh-shell: the login shell of an account that decides its SELinux domain (docs/uni/selinux.md).
//! Installed twice, as /usr/local/bin/vh-usersh and /usr/local/bin/vh-adminsh, two files with
//! two labels (user_shell_exec_t, admin_shell_exec_t): login's exec of the account's shell is
//! the one point where the policy can tell the everyday user from the admin without a PAM
//! module, by the file it executes. The program itself only runs bash with the same arguments
//! (a leading "-" kept: a login shell), so an account with it as the shell behaves exactly as
//! one with /bin/bash. Under AppArmor it is the same two execs, nothing more.
const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const vh = @import("vh");

pub const shell = "/usr/bin/bash";

pub fn main(init: std.process.Init.Minimal) void {
    _ = vh.init(init, "vh-shell");
    var it = init.args.iterate();
    const argv0 = it.next() orelse "vh-shell";
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    // "-vh-usersh" (a login shell) becomes "-bash"; "vh-usersh" becomes "bash"
    argv.append(vh.gpa, if (argv0.len > 0 and argv0[0] == '-') "-bash" else "bash") catch vh.oom();
    while (it.next()) |a| argv.append(vh.gpa, a.ptr) catch vh.oom();
    const cargv = argv.toOwnedSliceSentinel(vh.gpa, null) catch vh.oom();
    const rc = linux.execve(shell, cargv.ptr, vh.envp);
    vh.errno = linux.errno(rc);
    vh.die("{s}: {s}", .{ shell, vh.serr() });
}

test "the login shell's argv0" {
    try std.testing.expect(mem.eql(u8, "-bash", if ("-vh-usersh"[0] == '-') "-bash" else "bash"));
}
