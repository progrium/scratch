//! proto: the line grammar of protocols/core.md and components.md.
//!
//! Owner: workstream W2 (proto). The tokenizer is in the scaffold because
//! every other module needs it. W2 adds: ctl (verbs, attributes, `new`
//! lines, batches), style syntax, event lines, errors, documents (`.ui`),
//! data-file line formats. No allocation outlives the caller's arena.

pub const tokenize = @import("tokenize.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
