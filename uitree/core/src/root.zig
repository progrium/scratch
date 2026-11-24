//! libuitcore: the uitree core. Owns the tree, the line grammar, the type
//! catalog, the 9P server and h9. Renderers (GPUI in Rust, the terminal in
//! Zig) reach it only through the C ABI in include/uitcore.h (abi.zig).
//! See ../ARCHITECTURE.md.

pub const proto = @import("proto/root.zig");
pub const types = @import("types/root.zig");
pub const tree = @import("tree/root.zig");
pub const ninep = @import("ninep/root.zig");
pub const machine = @import("machine/root.zig");
pub const abi = @import("abi.zig");
pub const render = @import("render/root.zig");
pub const web = @import("web.zig");

comptime {
    // Keep the C exports in every artifact that links the core.
    _ = abi;
    _ = web;
}

test {
    @import("std").testing.refAllDecls(@This());
}
