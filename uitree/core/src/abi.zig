//! The C ABI, include/uitcore.h. Owner: the spike (W0) writes and freezes
//! it; after the freeze a change needs a bump of UIT_ABI_VERSION and a note
//! to every renderer workstream.
//!
//! Rules (ARCHITECTURE.md § The ABI): one owner thread; the core wakes, the
//! renderer pumps; borrowed reads valid until the next uit_pump; no
//! callbacks into the renderer during a pump except wake; errors are
//! negative codes plus uit_last_error; panics abort, nothing unwinds.

const std = @import("std");

/// Must match UIT_ABI_VERSION in include/uitcore.h.
pub const abi_version: u32 = 0;

export fn uit_abi_version() u32 {
    return abi_version;
}

test "header and abi.zig agree on the version" {
    const h = @embedFile("uitcore.h");
    try std.testing.expect(std.mem.indexOf(u8, h, std.fmt.comptimePrint("#define UIT_ABI_VERSION {d}u", .{abi_version})) != null);
}
