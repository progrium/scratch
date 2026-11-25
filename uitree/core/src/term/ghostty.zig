//! The libghostty-vt backend of engine.zig (C1), over ghostty/vt.h.
//!
//! Owner: the engine backends (T2). Until T2 lands this is a placeholder:
//! building with -Dterminal=ghostty fails here, and the default build
//! (plain) never looks at it.

pub const Ghostty = @compileError("the ghostty terminal backend is not written yet (T2); build with -Dterminal=plain");
