//! spike: the W0 throwaway. A minimal tree, just enough to run the counter
//! end to end through uitcore.h, served by W4's `ninep` through `fs.zig`.
//! W3's `tree` replaces it; delete this directory then.

pub const tree = @import("tree.zig");
pub const fs = @import("fs.zig");

pub const Tree = tree.Tree;
pub const Error = tree.Error;

test {
    @import("std").testing.refAllDecls(@This());
}
