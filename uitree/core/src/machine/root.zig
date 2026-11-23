//! machine: running the app inside an h9 sandbox (hyper9's h9.Machine),
//! with `$ui` mounted into its namespace. Replaces uitreefs's h9sys crate
//! and its C shim.
//!
//! Owner: the spike (W0) lands the first version; W4 (serve) owns it after.

test {
    @import("std").testing.refAllDecls(@This());
}
