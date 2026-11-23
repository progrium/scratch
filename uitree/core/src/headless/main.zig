//! uitree-headless: the core with no renderer. Serves `$ui` over 9P, runs
//! the app in h9, and answers like a host whose windows are never drawn.
//! The conformance suite runs against this binary.
//!
//! Owner: workstream W4 (serve). Scaffold: prints its version.

const std = @import("std");
const core = @import("uitcore");

pub fn main() !void {
    std.debug.print("uitree-headless (abi {d}): not implemented yet\n", .{core.abi.abi_version});
}
