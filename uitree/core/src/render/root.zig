//! The renderer tree (protocols/render.md): the change stream encoder and
//! the 9P tree renderers attach to.

pub const stream = @import("stream.zig");
pub const hub = @import("hub.zig");
pub const replica = @import("replica.zig");
pub const check = @import("check.zig");
pub const dial = @import("dial.zig");
pub const term = @import("term.zig");
pub const termview = @import("termview.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
