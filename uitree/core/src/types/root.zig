//! types: the component catalog as data (protocols/components.md § The
//! descriptor).
//!
//! Owner: workstream W1 (types). Parses `types/NAME/spec` descriptor text
//! into a Catalog the tree validates `new`, `set`, verbs and events
//! against, and serves at `$ui/types`. Also parses `style-words` and
//! `theme-tokens`. Knows nothing about any renderer.

test {
    @import("std").testing.refAllDecls(@This());
}
