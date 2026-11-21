//! Every text format in gpuifs, parsed and printed, with no knowledge of the
//! tree. Owned by W1. Signatures are the contract in PLAN.md § Contracts.
//!
//! - [`tokenize`] / [`quote`]: Plan 9's one quoting rule (DESIGN § Quoting).
//! - [`parse_ctl`] / [`Command`]: `ctl` writes, one command per line.
//! - [`parse_style`] / [`StyleWord`]: style syntax (DESIGN § Style language).
//! - [`Event`]: event lines (DESIGN § Events).
//! - [`ErrorKind`] / [`Error`]: the fixed error phrases (DESIGN § Errors).
//! - [`doc`]: subtree documents. [`lines`]: the line formats of data files.

use std::fmt;

pub mod doc;
pub mod lines;
mod tok;

pub use tok::{quote, tokenize};

/// The limits of DESIGN § Errors and limits that are about text sizes.
pub mod limits {
    /// One `ctl` write.
    pub const CTL_WRITE: usize = 64 * 1024;
    /// A text property file (`value`, `text`).
    pub const TEXT_FILE: usize = 16 * 1024 * 1024;
    /// A data file (`items`, `rows`, `ops`).
    pub const DATA_FILE: usize = 64 * 1024 * 1024;
    /// An image or `pixels` write.
    pub const IMAGE: usize = 16 * 1024 * 1024;
    /// Queued action events per subscription.
    pub const ACTION_QUEUE: usize = 4096;
    /// Node depth.
    pub const NODE_DEPTH: usize = 64;
    /// The read size clients should use on `events`.
    pub const EVENTS_READ: usize = 8 * 1024;
}

// ---------------------------------------------------------------------------
// ctl

/// One `ctl` line: a verb, positional args, and `prop=value` pairs.
///
/// A word is a `prop=value` pair when it has an unquoted `=` after a name
/// that starts with a letter or `_` and doesn't end in `-` (so `cmd-=` and a
/// bare `=` stay positional, as keymaps need). Everything else is positional.
/// `'a=b'` is positional too, since its `=` is quoted.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Command {
    pub verb: String,
    pub args: Vec<String>,
    pub props: Vec<(String, String)>,
}

impl Command {
    pub fn new(verb: impl Into<String>) -> Self {
        Command {
            verb: verb.into(),
            ..Default::default()
        }
    }

    /// Parse one line. A blank line is `bad syntax: empty command`.
    pub fn parse(line: &str) -> Result<Self, Error> {
        let toks = tok::tokens(line)?;
        let mut it = toks.into_iter();
        let verb = match it.next() {
            None => return Err(Error::new(ErrorKind::BadSyntax, "empty command")),
            Some(t) if t.prop_split().is_some() => {
                return Err(Error::new(
                    ErrorKind::BadSyntax,
                    format!("missing verb before {}", t.text),
                ));
            }
            Some(t) => t.text,
        };
        let mut c = Command::new(verb);
        for t in it {
            match t.into_prop() {
                Ok((k, v)) => c.props.push((k, v)),
                Err(word) => c.args.push(word),
            }
        }
        Ok(c)
    }

    /// The first value of `name=`, if any.
    pub fn prop(&self, name: &str) -> Option<&str> {
        self.props
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    pub fn arg(&self, i: usize) -> Option<&str> {
        self.args.get(i).map(|s| s.as_str())
    }
}

/// The canonical line: `verb args... prop=value...`, quoted as needed, with
/// no newline. `Command::parse` reads it back unchanged.
impl fmt::Display for Command {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&tok::quote_word(&self.verb))?;
        for a in &self.args {
            write!(f, " {}", tok::quote_word(a))?;
        }
        for (k, v) in &self.props {
            write!(f, " {}={}", k, quote(v))?;
        }
        Ok(())
    }
}

/// One `Command` per line; a write's lines parse all or nothing. Blank lines
/// are skipped. Over [`limits::CTL_WRITE`] is `too large`.
pub fn parse_ctl(write: &[u8]) -> Result<Vec<Command>, Error> {
    if write.len() > limits::CTL_WRITE {
        return Err(Error::new(
            ErrorKind::TooLarge,
            format!("ctl write of {} bytes", write.len()),
        ));
    }
    let s =
        std::str::from_utf8(write).map_err(|_| Error::new(ErrorKind::BadSyntax, "not UTF-8"))?;
    let lines: Vec<&str> = s
        .split('\n')
        .filter(|l| !l.chars().all(tok::is_blank))
        .collect();
    let many = lines.len() > 1;
    lines
        .iter()
        .enumerate()
        .map(|(i, l)| Command::parse(l).map_err(|e| if many { e.at_line(i + 1) } else { e }))
        .collect()
}

// ---------------------------------------------------------------------------
// style

/// One style word (DESIGN § Style language). Syntax only: whether `name`
/// exists is `style::lookup`.
///
/// `group:card` is `StyleWord { name: "group", group: Some("card"), .. }`:
/// the element joins GPUI group `card`. `group-hover(card):bg=accent` is
/// `state: Some(GroupHover("card"))` with `name: "bg"`.
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

impl StateSel {
    fn from_prefix(p: &str) -> Option<Self> {
        Some(match p {
            "hover" => StateSel::Hover,
            "active" => StateSel::Active,
            "focus" => StateSel::Focus,
            "disabled" => StateSel::Disabled,
            "drop-over" => StateSel::DropOver,
            _ => return None,
        })
    }
}

impl fmt::Display for StateSel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StateSel::Hover => f.write_str("hover"),
            StateSel::Active => f.write_str("active"),
            StateSel::Focus => f.write_str("focus"),
            StateSel::Disabled => f.write_str("disabled"),
            StateSel::DropOver => f.write_str("drop-over"),
            StateSel::GroupHover(g) => write!(f, "group-hover({g})"),
        }
    }
}

/// `n` (pixels), `n%`, `nrem`, `#rrggbb[aa]`, or a theme token name. A
/// plain word like `wide` is a `Token`; whether it names a real token, or
/// fits the method's argument kind, is for the tree to decide.
#[derive(Debug, Clone, PartialEq)]
pub enum StyleArg {
    Px(f32),
    Percent(f32),
    Rem(f32),
    Color(Rgba),
    Token(String),
}

impl StyleArg {
    pub fn parse(s: &str) -> Result<Self, Error> {
        if s.is_empty() {
            return Err(Error::new(ErrorKind::BadSyntax, "empty style argument"));
        }
        if s.starts_with('#') {
            return Rgba::parse(s).map(StyleArg::Color);
        }
        let first = s.as_bytes()[0];
        if first.is_ascii_digit() || matches!(first, b'-' | b'+' | b'.') {
            let (num, mk): (&str, fn(f32) -> StyleArg) = if let Some(n) = s.strip_suffix('%') {
                (n, StyleArg::Percent)
            } else if let Some(n) = s.strip_suffix("rem") {
                (n, StyleArg::Rem)
            } else if let Some(n) = s.strip_suffix("px") {
                (n, StyleArg::Px)
            } else {
                (s, StyleArg::Px)
            };
            return parse_number(num)
                .map(mk)
                .map_err(|_| Error::new(ErrorKind::BadValue, s));
        }
        if is_token(s) {
            Ok(StyleArg::Token(s.to_string()))
        } else {
            Err(Error::new(
                ErrorKind::BadSyntax,
                format!("style argument {s}"),
            ))
        }
    }
}

impl fmt::Display for StyleArg {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StyleArg::Px(n) => write!(f, "{n}"),
            StyleArg::Percent(n) => write!(f, "{n}%"),
            StyleArg::Rem(n) => write!(f, "{n}rem"),
            StyleArg::Color(c) => write!(f, "{c}"),
            StyleArg::Token(t) => f.write_str(t),
        }
    }
}

/// `#rrggbb[aa]`, without any GPUI type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rgba {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Rgba {
    /// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`. Anything else is `bad value`.
    pub fn parse(s: &str) -> Result<Self, Error> {
        let bad = || Error::new(ErrorKind::BadValue, s.to_string());
        let hex = s.strip_prefix('#').ok_or_else(bad)?;
        if !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(bad());
        }
        let nib = |i: usize| u8::from_str_radix(&hex[i..i + 1], 16).unwrap() * 17;
        let byte = |i: usize| u8::from_str_radix(&hex[i..i + 2], 16).unwrap();
        Ok(match hex.len() {
            3 => Rgba {
                r: nib(0),
                g: nib(1),
                b: nib(2),
                a: 255,
            },
            4 => Rgba {
                r: nib(0),
                g: nib(1),
                b: nib(2),
                a: nib(3),
            },
            6 => Rgba {
                r: byte(0),
                g: byte(2),
                b: byte(4),
                a: 255,
            },
            8 => Rgba {
                r: byte(0),
                g: byte(2),
                b: byte(4),
                a: byte(6),
            },
            _ => return Err(bad()),
        })
    }
}

/// `#rrggbb` when opaque, `#rrggbbaa` otherwise.
impl fmt::Display for Rgba {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "#{:02x}{:02x}{:02x}", self.r, self.g, self.b)?;
        if self.a != 255 {
            write!(f, "{:02x}", self.a)?;
        }
        Ok(())
    }
}

impl StyleWord {
    /// One blank-free word.
    pub fn parse(word: &str) -> Result<Self, Error> {
        let mut rest = word;
        let mut state = None;
        if let Some(r) = rest.strip_prefix("group-hover(") {
            let close = r
                .find(')')
                .ok_or_else(|| Error::new(ErrorKind::BadSyntax, word.to_string()))?;
            let g = &r[..close];
            let after = r[close + 1..]
                .strip_prefix(':')
                .ok_or_else(|| Error::new(ErrorKind::BadSyntax, word.to_string()))?;
            if !is_name(g) {
                return Err(Error::new(ErrorKind::BadSyntax, word.to_string()));
            }
            state = Some(StateSel::GroupHover(g.to_string()));
            rest = after;
        } else if let Some((p, r)) = rest.split_once(':') {
            if p == "group" {
                if !is_name(r) {
                    return Err(Error::new(ErrorKind::BadSyntax, word.to_string()));
                }
                return Ok(StyleWord {
                    state: None,
                    group: Some(r.to_string()),
                    name: "group".into(),
                    args: vec![],
                });
            }
            state = Some(
                StateSel::from_prefix(p)
                    .ok_or_else(|| Error::new(ErrorKind::UnknownStyleWord, word.to_string()))?,
            );
            rest = r;
        }
        let (name, args) = match rest.split_once('=') {
            Some((n, a)) => {
                let args = a
                    .split(',')
                    .map(StyleArg::parse)
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|e| {
                        if e.kind == ErrorKind::BadSyntax {
                            Error::new(ErrorKind::BadSyntax, word.to_string())
                        } else {
                            e
                        }
                    })?;
                (n, args)
            }
            None => (rest, vec![]),
        };
        if !is_name(name) {
            return Err(Error::new(ErrorKind::BadSyntax, word.to_string()));
        }
        Ok(StyleWord {
            state,
            group: None,
            name: name.to_string(),
            args,
        })
    }
}

impl fmt::Display for StyleWord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(s) = &self.state {
            write!(f, "{s}:")?;
        }
        if let (Some(g), true) = (&self.group, self.args.is_empty()) {
            return write!(f, "{}:{}", self.name, g);
        }
        f.write_str(&self.name)?;
        for (i, a) in self.args.iter().enumerate() {
            write!(f, "{}{}", if i == 0 { "=" } else { "," }, a)?;
        }
        Ok(())
    }
}

/// Style words separated by blanks. Fails on the first bad word.
pub fn parse_style(s: &str) -> Result<Vec<StyleWord>, Error> {
    s.split(tok::is_blank)
        .filter(|w| !w.is_empty())
        .map(StyleWord::parse)
        .collect()
}

/// A style method or prefix name: ASCII letters, digits, `_` and `-`.
fn is_name(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// A theme token or word argument: starts with a letter or `_`.
fn is_token(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && (b[0].is_ascii_alphabetic() || b[0] == b'_')
        && b.iter()
            .all(|&c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-' | b'.'))
}

/// A decimal number: optional sign, digits, optional fraction. No exponents,
/// no `inf` or `nan`.
pub fn parse_number(s: &str) -> Result<f32, Error> {
    let bad = || Error::new(ErrorKind::BadValue, s.to_string());
    let body = s.strip_prefix(['-', '+']).unwrap_or(s);
    let mut dot = false;
    let mut digit = false;
    for b in body.bytes() {
        match b {
            b'0'..=b'9' => digit = true,
            b'.' if !dot => dot = true,
            _ => return Err(bad()),
        }
    }
    if !digit {
        return Err(bad());
    }
    let n: f32 = s.parse().map_err(|_| bad())?;
    if n.is_finite() { Ok(n) } else { Err(bad()) }
}

// ---------------------------------------------------------------------------
// events

/// An event before it gets its sequence number.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Event {
    pub name: String,
    pub attrs: Vec<(String, String)>,
}

impl Event {
    pub fn new(name: impl Into<String>) -> Self {
        Event {
            name: name.into(),
            attrs: vec![],
        }
    }

    pub fn attr(mut self, k: impl Into<String>, v: impl Into<String>) -> Self {
        self.attrs.push((k.into(), v.into()));
        self
    }

    pub fn get(&self, k: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|(n, _)| n == k)
            .map(|(_, v)| v.as_str())
    }

    /// `name k=v ... seq=N\n`, with values quoted only when needed, as in
    /// DESIGN § Events (`change win=main node=root/prefs/lang/in tag='' value=go seq=119`).
    /// An event is one line, so a newline in a value is written as a space.
    pub fn to_line(&self, seq: u64) -> String {
        format!("{self} seq={seq}\n")
    }

    /// Read one event line back: the event and its `seq=`, if it has one.
    /// A trailing newline is allowed.
    pub fn parse_line(line: &str) -> Result<(Event, Option<u64>), Error> {
        let c = Command::parse(line.strip_suffix('\n').unwrap_or(line))?;
        if !c.args.is_empty() {
            return Err(Error::new(
                ErrorKind::BadSyntax,
                format!("event word {}", c.args[0]),
            ));
        }
        let mut seq = None;
        let mut attrs = Vec::with_capacity(c.props.len());
        for (k, v) in c.props {
            if k == "seq" && seq.is_none() {
                seq = Some(
                    v.parse()
                        .map_err(|_| Error::new(ErrorKind::BadValue, format!("seq={v}")))?,
                );
            } else {
                attrs.push((k, v));
            }
        }
        Ok((
            Event {
                name: c.verb,
                attrs,
            },
            seq,
        ))
    }
}

/// `name k=v ...` without `seq=` or a newline (for `gone` and tests).
impl fmt::Display for Event {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&tok::quote_word(&self.name))?;
        for (k, v) in &self.attrs {
            if v.contains(['\n', '\r']) {
                write!(f, " {}={}", k, quote(&v.replace(['\n', '\r'], " ")))?;
            } else {
                write!(f, " {}={}", k, quote(v))?;
            }
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// errors

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
    pub const ALL: [ErrorKind; 12] = [
        ErrorKind::UnknownCommand,
        ErrorKind::BadSyntax,
        ErrorKind::UnknownStyleWord,
        ErrorKind::UnknownType,
        ErrorKind::TypeIsFixed,
        ErrorKind::InUse,
        ErrorKind::NotFound,
        ErrorKind::BadValue,
        ErrorKind::TooLarge,
        ErrorKind::ShortRead,
        ErrorKind::NoBatch,
        ErrorKind::AppGone,
    ];

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

    pub fn from_phrase(p: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.phrase() == p)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub kind: ErrorKind,
    pub detail: String,
}

impl Error {
    pub fn new(kind: ErrorKind, detail: impl Into<String>) -> Self {
        Error {
            kind,
            detail: detail.into(),
        }
    }

    /// Read a 9P error string back (`unknown style word: flexx`).
    pub fn parse(s: &str) -> Option<Self> {
        let (p, d) = match s.split_once(": ") {
            Some((p, d)) => (p, d),
            None => (s, ""),
        };
        ErrorKind::from_phrase(p).map(|k| Error::new(k, d))
    }

    /// Prefix the detail with `line N` (1-based) for multi-line writes.
    pub fn at_line(mut self, n: usize) -> Self {
        self.detail = if self.detail.is_empty() {
            format!("line {n}")
        } else {
            format!("line {n}: {}", self.detail)
        };
        self
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
