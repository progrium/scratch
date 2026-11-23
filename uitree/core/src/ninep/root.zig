//! ninep: the 9P2000 server for `$ui`, on hyper9's dotl/wire.zig framing,
//! thread per connection, blocking `events` reads on a condition variable.
//! Also `/debug` and the transports (fd, unix socket, tcp).
//!
//! Owner: workstream W4 (serve). Talks to the tree only through the op
//! queue and published snapshots, never by touching a Tree directly.

test {
    @import("std").testing.refAllDecls(@This());
}
