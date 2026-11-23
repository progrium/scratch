//! proto: the line grammar of protocols/core.md and components.md
//! (interface I2 in ../../../ARCHITECTURE.md).
//!
//! Owner: workstream W2 (proto). Parsers take an arena and text and return
//! plain structs that point into the arena; there is no global state and
//! nothing is checked against types (the catalog, W1, does that).
//!
//! Each fallible parser comes as `parse(arena, text)` and as
//! `parseDiag(arena, text, ?*Diag)`, which also reports the protocol
//! error's code and detail. The Zig errors are `err.Error`; map one back
//! with `err.Code.fromError`.

pub const tokenize = @import("tokenize.zig");
pub const err = @import("err.zig");
pub const ctl = @import("ctl.zig");
pub const style = @import("style.zig");
pub const event = @import("event.zig");

pub const Tok = tokenize.Tok;
pub const Code = err.Code;
pub const Diag = err.Diag;
pub const Error = err.Error;
pub const limits = err.limits;
pub const Attr = ctl.Attr;
pub const Ctl = ctl.Ctl;
pub const Verb = ctl.Verb;
pub const StyleWord = style.StyleWord;
pub const Event = event.Event;

test {
    @import("std").testing.refAllDecls(@This());
}
