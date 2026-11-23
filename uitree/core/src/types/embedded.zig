//! The descriptors, style words and theme tokens in core/types, compiled
//! in. build.zig imports core/types/embed.zig as `uit_types`, because
//! @embedFile can't reach outside src/.

const embed = @import("uit_types");

pub const Spec = embed.Spec;
pub const specs: []const Spec = &embed.specs;
pub const style_words: []const u8 = embed.style_words;
pub const theme_tokens: []const u8 = embed.theme_tokens;
/// GPUI Kit's theme set as palettes: what renderers register with
/// `uit_themes`, and what uitree-headless registers.
pub const themes: []const u8 = embed.themes;
