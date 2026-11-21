//! The style word table and theme token names, as data with no GPUI types.
//! Owned by W5a. `TABLE` and `THEME_TOKENS` are generated from gpui and
//! gpui-component at the revs pinned in the workspace Cargo.toml.
#![allow(unused_variables, dead_code)]

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArgKind {
    None,
    Length,
    Number,
    Color,
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

/// Every style word, sorted by name.
pub static TABLE: &[StyleEntry] = &[];

pub fn lookup(name: &str) -> Option<&'static StyleEntry> {
    todo!("W5a")
}

/// `ThemeColor` field names.
pub static THEME_TOKENS: &[&str] = &[];

/// Default `(token, "#rrggbb[aa]")` pairs for a mode.
pub fn default_theme(mode: Mode) -> &'static [(&'static str, &'static str)] {
    todo!("W5a")
}
