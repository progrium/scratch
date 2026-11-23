//! tree: nodes, ops (all-or-nothing, copy-then-swap, an arena per op),
//! batches, snapshots, the event bus, requests, trace.
//!
//! Owner: workstream W3 (tree). Single-threaded: only the owner thread (the
//! one that called uit_create) touches a Tree. Other threads reach it
//! through the op queue in abi.zig / ninep.

test {
    @import("std").testing.refAllDecls(@This());
}
