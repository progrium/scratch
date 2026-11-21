//! Every text format in gpuifs, parsed and printed, with no knowledge of the
//! tree. Owned by W1. Signatures are the contract in PLAN.md § Contracts.
#![allow(unused_variables, dead_code)]

use std::borrow::Cow;
use std::fmt;

pub mod doc;
pub mod lines;

/// Plan 9 `tokenize` (DESIGN § Quoting), including `''`.
pub fn tokenize(s: &str) -> Result<Vec<String>, Error> {
    todo!("W1")
}

/// Plan 9 `quote`: returns `s` unchanged when it needs no quoting.
pub fn quote(s: &str) -> Cow<'_, str> {
    todo!("W1")
}

/// One `ctl` line: a verb, positional args, and `prop=value` pairs.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Command {
    pub verb: String,
    pub args: Vec<String>,
    pub props: Vec<(String, String)>,
}

/// One `Command` per line; a write's lines parse all or nothing.
pub fn parse_ctl(write: &[u8]) -> Result<Vec<Command>, Error> {
    todo!("W1")
}

/// One style word (DESIGN § Style language). Syntax only: whether `name`
/// exists is `style::lookup`.
#[derive(Debug, Clone, PartialEq)]
pub struct StyleWord {
    pub state: Option<StateSel>,
    pub group: Option<String>,
    pub name: String,
    pub args: Vec<StyleArg>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StateSel {
    Hover,
    Active,
    Focus,
    Disabled,
    DropOver,
    GroupHover(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum StyleArg {
    Px(f32),
    Percent(f32),
    Rem(f32),
    Color(Rgba),
    Token(String),
}

/// `#rrggbb[aa]`, without any GPUI type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rgba {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

pub fn parse_style(s: &str) -> Result<Vec<StyleWord>, Error> {
    todo!("W1")
}

/// An event before it gets its sequence number.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Event {
    pub name: String,
    pub attrs: Vec<(String, String)>,
}

impl Event {
    /// `name seq=N k=v ...` with values quoted only when needed, plus `\n`.
    pub fn to_line(&self, seq: u64) -> String {
        todo!("W1")
    }
}

/// The fixed error phrases of DESIGN § Errors and limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorKind {
    UnknownCommand,
    BadSyntax,
    UnknownStyleWord,
    UnknownType,
    TypeIsFixed,
    InUse,
    NotFound,
    BadValue,
    TooLarge,
    ShortRead,
    NoBatch,
    AppGone,
}

impl ErrorKind {
    pub fn phrase(self) -> &'static str {
        match self {
            ErrorKind::UnknownCommand => "unknown command",
            ErrorKind::BadSyntax => "bad syntax",
            ErrorKind::UnknownStyleWord => "unknown style word",
            ErrorKind::UnknownType => "unknown type",
            ErrorKind::TypeIsFixed => "type is fixed",
            ErrorKind::InUse => "in use",
            ErrorKind::NotFound => "not found",
            ErrorKind::BadValue => "bad value",
            ErrorKind::TooLarge => "too large",
            ErrorKind::ShortRead => "short read",
            ErrorKind::NoBatch => "no batch",
            ErrorKind::AppGone => "app gone",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub kind: ErrorKind,
    pub detail: String,
}

impl Error {
    pub fn new(kind: ErrorKind, detail: impl Into<String>) -> Self {
        Error { kind, detail: detail.into() }
    }
}

/// `phrase: detail`, or just `phrase` when there is no detail.
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.detail.is_empty() {
            f.write_str(self.kind.phrase())
        } else {
            write!(f, "{}: {}", self.kind.phrase(), self.detail)
        }
    }
}

impl std::error::Error for Error {}
