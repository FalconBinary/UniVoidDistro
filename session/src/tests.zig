//! The unit tests of session/: every file's own tests. The sessions themselves, which need
//! root and namespaces, are tests/session/run.sh (a privileged container) and the VM rig's
//! step game (tests/vm/steps/session.py).
test {
    _ = @import("common.zig");
    _ = @import("lines.zig");
    _ = @import("accounts.zig");
    _ = @import("rmtree.zig");
    _ = @import("acl.zig");
    _ = @import("roots.zig");
    _ = @import("sys.zig");
    _ = @import("enter.zig");
    _ = @import("game.zig");
    _ = @import("root.zig");
}
