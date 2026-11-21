//! The style word table and theme token names, as data with no GPUI types.
//! Owned by W5a. `TABLE` and `THEME_TOKENS` are generated from gpui and
//! gpui-component at the revs pinned in the workspace Cargo.toml, by
//! `gen/gen.sh`. The generated files are `src/table.rs` and `src/theme.rs`;
//! don't edit them by hand.
//!
//! # How the host reads the table
//!
//! * `ArgKind::None` words are `fn(self) -> Self` calls (`flex_col`,
//!   `rounded_md`, `v_flex`). A `None` word written with `=value` is a bad value.
//! * `ArgKind::Length` takes px, `%` or `rem`. gpui's argument type differs by
//!   method (`Length` allows `auto`, `DefiniteLength` allows `%`,
//!   `AbsoluteLength` allows neither); the host reports a bad value when the
//!   method's type can't hold the unit. `line_height` follows gpui-shell: a
//!   bare number is a multiplier of the font size, not pixels.
//! * `ArgKind::Number` is a bare number (`flex_grow`, `opacity`, `col_span`).
//!   `font_weight` takes 100 to 900.
//! * `ArgKind::Color` takes a theme token (`THEME_TOKENS`) or `#rrggbb[aa]`.
//! * `ArgKind::Text` takes one word (`font_family=monospace`).
//! * `shadow` is `Many([Length, Length, Length, Color])`: x, y, blur, color,
//!   as in `shadow=0,4,12,#0003`.
//! * `kit: true` words come from GPUI Kit. `v_flex`, `h_flex`, `debug_*` and
//!   the `font_*` weights are `StyledExt` calls that work on any element. Size
//!   words (`SIZE_WORDS`) and variant words (`VARIANT_WORDS`) only mean
//!   something on a component that is `Sizable` or has that variant; on a raw
//!   `div` the host fails them with `unknown style word`.
#![allow(dead_code)]

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArgKind {
    None,
    Length,
    Number,
    Color,
    /// One word of text (`font_family`).
    Text,
    Many(&'static [ArgKind]),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StyleEntry {
    pub name: &'static str,
    pub arg: ArgKind,
    /// True for GPUI Kit helpers (`v_flex`, size and variant words), false for gpui `Styled`.
    pub kit: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Mode {
    Light,
    Dark,
}

include!("table.rs");
include!("theme.rs");

pub fn lookup(name: &str) -> Option<&'static StyleEntry> {
    TABLE
        .binary_search_by(|e| e.name.cmp(name))
        .ok()
        .map(|i| &TABLE[i])
}

/// True for a GPUI Kit size word (`xs` `sm` `md` `lg`).
pub fn is_size_word(name: &str) -> bool {
    SIZE_WORDS.contains(&name)
}

/// The GPUI Kit enums or `*Variants` traits that take `name` as a variant,
/// for example `["ButtonVariant", "ButtonVariants", "TagVariant"]` for
/// `primary`. Empty if it is not a variant word.
pub fn variant_owners(name: &str) -> &'static [&'static str] {
    VARIANT_WORDS
        .binary_search_by(|(w, _)| w.cmp(&name))
        .map(|i| VARIANT_WORDS[i].1)
        .unwrap_or(&[])
}

/// True if `name` is a `ThemeColor` token.
pub fn is_theme_token(name: &str) -> bool {
    THEME_TOKENS.contains(&name)
}

/// Default `(token, "#rrggbb[aa]")` pairs for a mode, in `THEME_TOKENS` order.
pub fn default_theme(mode: Mode) -> &'static [(&'static str, &'static str)] {
    match mode {
        Mode::Light => LIGHT,
        Mode::Dark => DARK,
    }
}

/// The default value of one token, as `#rrggbb[aa]`.
pub fn default_token(mode: Mode, token: &str) -> Option<&'static str> {
    default_theme(mode)
        .iter()
        .find(|(t, _)| *t == token)
        .map(|(_, v)| *v)
}

/// The mode of a theme in GPUI Kit's registry, by theme name
/// (`Tokyo Night`) or by set name (`Catppuccin`, which picks the set's first
/// theme). Names compare exactly.
pub fn find_theme(name: &str) -> Option<(&'static str, Mode)> {
    for (set, themes) in THEME_SETS {
        if let Some(t) = themes.iter().find(|(n, _)| *n == name) {
            return Some(*t);
        }
        if *set == name {
            return themes.first().copied();
        }
    }
    None
}

#[cfg(test)]
mod tests;
