//! The renderer tree (protocols/render.md): the change stream encoder and
//! the 9P tree renderers attach to.

pub const stream = @import("stream.zig");
pub const hub = @import("hub.zig");
pub const replica = @import("replica.zig");
pub const check = @import("check.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
