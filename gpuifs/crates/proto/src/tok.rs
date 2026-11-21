//! Plan 9 `tokenize` and `quote` (DESIGN § Quoting).
//!
//! Words split on blanks (space, tab, CR, LF). A `'` anywhere in a word
//! starts a quoted run, which ends at the next lone `'`; inside it, blanks
//! are ordinary and `''` is one literal quote. So `title='Sign in'`,
//! `'it''s'` and `''` (the empty word) all work as in Plan 9. Unlike Plan 9,
//! an unterminated quote is `bad syntax` rather than running to the end.

use std::borrow::Cow;

use crate::{Error, ErrorKind};

pub(crate) fn is_blank(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\r' | '\n')
}

/// One word, with where its first unquoted `=` was and whether any of it was
/// quoted.
#[derive(Debug, Clone)]
pub(crate) struct Tok {
    pub text: String,
    /// Byte offset in `text` of the first `=` that was outside quotes.
    pub eq: Option<usize>,
    /// The word had a quote in it.
    pub quoted: bool,
}

impl Tok {
    /// `(key, value)` if this word is a `prop=value` pair: an unquoted `=`
    /// after a key that starts with a letter or `_` and doesn't end in `-`.
    pub fn prop_split(&self) -> Option<(&str, &str)> {
        let i = self.eq?;
        let k = &self.text[..i];
        let first = k.chars().next()?;
        if !(first.is_alphabetic() || first == '_') || k.ends_with('-') {
            return None;
        }
        Some((k, &self.text[i + 1..]))
    }

    pub fn into_prop(self) -> Result<(String, String), String> {
        match self.prop_split() {
            Some((k, v)) => Ok((k.to_string(), v.to_string())),
            None => Err(self.text),
        }
    }
}

pub(crate) fn tokens(s: &str) -> Result<Vec<Tok>, Error> {
    let mut out = Vec::new();
    let mut it = s.chars().peekable();
    loop {
        while it.peek().is_some_and(|&c| is_blank(c)) {
            it.next();
        }
        if it.peek().is_none() {
            return Ok(out);
        }
        let mut t = Tok {
            text: String::new(),
            eq: None,
            quoted: false,
        };
        let mut inq = false;
        while let Some(&c) = it.peek() {
            if inq {
                it.next();
                if c == '\'' {
                    if it.peek() == Some(&'\'') {
                        it.next();
                        t.text.push('\'');
                    } else {
                        inq = false;
                    }
                } else {
                    t.text.push(c);
                }
            } else {
                if is_blank(c) {
                    break;
                }
                it.next();
                if c == '\'' {
                    inq = true;
                    t.quoted = true;
                } else {
                    if c == '=' && t.eq.is_none() {
                        t.eq = Some(t.text.len());
                    }
                    t.text.push(c);
                }
            }
        }
        if inq {
            return Err(Error::new(ErrorKind::BadSyntax, "unterminated quote"));
        }
        out.push(t);
    }
}

/// Plan 9 `tokenize` (DESIGN § Quoting), including `''`.
pub fn tokenize(s: &str) -> Result<Vec<String>, Error> {
    Ok(tokens(s)?.into_iter().map(|t| t.text).collect())
}

fn needs_quote(s: &str) -> bool {
    s.is_empty() || s.chars().any(|c| c <= ' ' || c == '\'')
}

fn quoted(s: &str) -> String {
    let mut q = String::with_capacity(s.len() + 2);
    q.push('\'');
    for c in s.chars() {
        if c == '\'' {
            q.push('\'');
        }
        q.push(c);
    }
    q.push('\'');
    q
}

/// Plan 9 `quote`: returns `s` unchanged when it needs no quoting (it is not
/// empty and has no blank, control character or `'`).
pub fn quote(s: &str) -> Cow<'_, str> {
    if needs_quote(s) {
        Cow::Owned(quoted(s))
    } else {
        Cow::Borrowed(s)
    }
}

/// `quote`, plus quoting a word with `=` in it so it stays positional.
pub(crate) fn quote_word(s: &str) -> Cow<'_, str> {
    if needs_quote(s) || s.contains('=') {
        Cow::Owned(quoted(s))
    } else {
        Cow::Borrowed(s)
    }
}

/// `quote`, forced on, for values that would otherwise read as something
/// else (`<<END` in a tree document).
pub(crate) fn quote_always(s: &str) -> String {
    quoted(s)
}
