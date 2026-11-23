//! tree: nodes, ops (all-or-nothing, copy-then-swap), batches, snapshots,
//! the event bus, requests, trace (interface I4).
//!
//! Owner: workstream W3 (tree).
//!
//! The owner thread holds the `Tree` and applies ops (`Tree.apply`, or
//! `OpQueue.drain` for ops other threads queued), then `publish`es a
//! `Snapshot` that 9P threads `acquire` and read. `events` and `trace`
//! readers `subscribe` on `tree.bus` and read their `Stream`, which blocks.

pub const state = @import("state.zig");
pub const bus = @import("bus.zig");
pub const path = @import("path.zig");
pub const trace = @import("trace.zig");
pub const doc = @import("doc.zig");
pub const snapshot = @import("snapshot.zig");
pub const queue = @import("queue.zig");
pub const files = @import("files.zig");
const treem = @import("tree.zig");

pub const Tree = treem.Tree;
pub const Config = treem.Config;
pub const Op = treem.Op;
pub const Session = treem.Session;
pub const Handle = state.Handle;
pub const HostCmd = treem.HostCmd;
pub const CmdTag = treem.CmdTag;
pub const Changes = treem.Changes;
pub const PropChange = treem.PropChange;
pub const EventIn = treem.EventIn;
pub const Snapshot = snapshot.Snapshot;
pub const Stat = snapshot.Stat;
pub const Kind = snapshot.Kind;
pub const OpQueue = queue.OpQueue;
pub const Ack = queue.Ack;
pub const Stream = bus.Stream;
pub const Target = bus.Target;
pub const batch_timeout_ns = treem.batch_timeout_ns;
pub const request_timeout_ns = treem.request_timeout_ns;

test {
    @import("std").testing.refAllDecls(@This());
    _ = treem;
    _ = @import("tests.zig");
}
