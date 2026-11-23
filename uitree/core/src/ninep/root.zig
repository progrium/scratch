//! ninep: the 9P2000 server for `$ui`, on hyper9's dotl/wire.zig framing,
//! thread per connection, blocking `events` reads. Also `/debug` and the
//! transports (fd, unix socket, tcp).
//!
//! Owner: workstream W4 (serve). The server talks to the tree only
//! through `Fs` (fs.zig): paths in, bytes and protocol error text out.

pub const fs = @import("fs.zig");
pub const server = @import("server.zig");
pub const transport = @import("transport.zig");
pub const client = @import("client.zig");
pub const dir = @import("dir.zig");
pub const memfs = @import("memfs.zig");
pub const mux = @import("mux.zig");
pub const debug = @import("debug.zig");
pub const host = @import("host.zig");
pub const ns = @import("ns.zig");

pub const Fs = fs.Fs;
pub const Server = server.Server;
pub const Client = client.Client;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("server_test.zig");
}
