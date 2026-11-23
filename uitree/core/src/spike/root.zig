//! spike: the W0 throwaway. A minimal tree and a minimal 9P2000 server,
//! just enough to run the counter end to end through uitcore.h. W3's
//! `tree` and W4's `ninep` replace both; delete this directory then.

pub const tree = @import("tree.zig");
pub const ninep = @import("ninep.zig");

pub const Tree = tree.Tree;
pub const Error = tree.Error;

test {
    @import("std").testing.refAllDecls(@This());
}
