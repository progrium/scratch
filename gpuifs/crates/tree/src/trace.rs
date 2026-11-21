//! The root `trace` file: one line per applied write, newest last. Old lines
//! fall off once the buffer passes 1 MiB.

use std::collections::VecDeque;

use bytes::Bytes;

const TRACE_CAP: usize = 1 << 20;
/// Text values longer than this are cut in trace lines.
const VALUE_CUT: usize = 64;

#[derive(Debug, Default)]
pub(crate) struct TraceBuf {
    lines: VecDeque<String>,
    bytes: usize,
}

impl TraceBuf {
    pub fn push(&mut self, line: String) {
        self.bytes += line.len() + 1;
        self.lines.push_back(line);
        while self.bytes > TRACE_CAP {
            match self.lines.pop_front() {
                Some(l) => self.bytes -= l.len() + 1,
                None => break,
            }
        }
    }

    pub fn contents(&self) -> Bytes {
        let mut out = Vec::with_capacity(self.bytes);
        for l in &self.lines {
            out.extend_from_slice(l.as_bytes());
            out.push(b'\n');
        }
        Bytes::from(out)
    }
}

/// A text value for a trace line, quoted and cut.
pub(crate) fn show_value(data: &[u8]) -> String {
    let s = String::from_utf8_lossy(data);
    let s = s.strip_suffix('\n').unwrap_or(&s);
    let mut cut: String = s.chars().take(VALUE_CUT).collect();
    if cut.len() < s.len() {
        cut.push_str("...");
    }
    let cut = cut.replace('\n', "\\n");
    proto::quote(&cut).into_owned()
}

/// A `ctl` command as one trace line, with secrets hidden.
pub(crate) fn show_command(c: &proto::Command, secret: bool) -> String {
    let mut out = c.verb.clone();
    for a in &c.args {
        out.push(' ');
        out.push_str(&proto::quote(a));
    }
    for (k, v) in &c.props {
        out.push(' ');
        out.push_str(k);
        out.push('=');
        if secret && k == "value" {
            out.push_str("<secret>");
        } else {
            out.push_str(&proto::quote(v));
        }
    }
    out
}
