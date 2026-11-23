//! The safe face of `uitcore.h`.
//!
//! [`Core`] owns a `UitCore`. It is `!Send`: it lives on the thread that
//! made it, which is the ABI's owner thread. Reads return data borrowed
//! from `&self`, and [`Core::pump`] takes `&mut self`, so the borrow
//! checker enforces "valid until the next pump". [`Waker`] is the one
//! `Send` piece: the core calls it from its 9P threads.

use std::ffi::c_void;
use std::marker::PhantomData;
use std::os::raw::c_int;

pub use uitcore_sys as sys;

#[cfg(feature = "test-client")]
pub mod client;
use sys::UitStr;

pub type Node = u32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub code: i32,
    /// The protocol's text, when the core gave one.
    pub text: String,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.text.is_empty() { write!(f, "uitcore error {}", self.code) } else { write!(f, "{}", self.text) }
    }
}
impl std::error::Error for Error {}

fn s(x: &str) -> UitStr {
    UitStr::from_str(x)
}

/// Called from core threads when there is work for `pump`.
pub type Waker = Box<dyn Fn() + Send + Sync + 'static>;

unsafe extern "C" fn wake_tramp(ctx: *mut c_void) {
    let w = unsafe { &*(ctx as *const Waker) };
    w();
}

pub struct Config<'a> {
    pub types: &'a str,
    pub style_words: &'a str,
    pub theme_tokens: &'a str,
    pub system_dark: bool,
}

pub struct Core {
    raw: *mut sys::UitCore,
    // Boxed twice so the pointer handed to C is stable and thin.
    _waker: Box<Waker>,
    _not_send: PhantomData<*const ()>,
}

/// A borrowed string as UTF-8; invalid bytes become U+FFFD.
fn text<'a>(u: UitStr) -> std::borrow::Cow<'a, str> {
    String::from_utf8_lossy(unsafe { u.as_bytes() })
}

fn utf8<'a>(u: UitStr) -> &'a str {
    std::str::from_utf8(unsafe { u.as_bytes() }).unwrap_or("")
}

/// An answer the core passed as text (`close`, `keep`): its words.
pub fn answer_ctl(t: &str) -> Ctl {
    let words = split_words(t);
    let mut c = Ctl::default();
    for (i, w) in words.into_iter().enumerate() {
        if i == 0 {
            c.verb = w;
        } else if let Some((k, v)) = w.split_once('=') {
            c.attrs.push((k.to_string(), v.to_string()));
        } else {
            c.args.push(w);
        }
    }
    c
}

/// Blank-separated words with single quotes, `''` a literal quote.
fn split_words(l: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut any = false;
    let mut q = false;
    let mut it = l.chars().peekable();
    while let Some(ch) = it.next() {
        if q {
            if ch == '\'' {
                if it.peek() == Some(&'\'') {
                    cur.push('\'');
                    it.next();
                } else {
                    q = false;
                }
            } else {
                cur.push(ch);
            }
        } else if ch == '\'' {
            q = true;
            any = true;
        } else if ch == ' ' || ch == '\t' {
            if any || !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            any = false;
        } else {
            cur.push(ch);
        }
    }
    if any || !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// The renderer-side stand-in for `uit_lines` while the core lacks it.
fn fallback_lines(t: &str) -> Vec<Line> {
    t.split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            let body = l.trim_start_matches(' ');
            let indent = ((l.len() - body.len()) / 2) as u32;
            let fields = if body.contains('\t') {
                body.split('\t').map(str::to_string).collect()
            } else if body.starts_with("# ") {
                vec!["#".to_string(), body[2..].to_string()]
            } else {
                split_words(body)
            };
            Line { fields, indent }
        })
        .collect()
}

fn slice<'a, T>(p: *const T, n: usize) -> &'a [T] {
    if p.is_null() || n == 0 { &[] } else { unsafe { std::slice::from_raw_parts(p, n) } }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Arg<'a> {
    None,
    Px(f32),
    Percent(f32),
    Rem(f32),
    Number(f32),
    /// 0xRRGGBBAA, and the token it came from (empty for a literal).
    Rgba(u32, &'a str),
    Text(&'a str),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Base,
    Hover,
    Active,
    Focus,
    Disabled,
    DropOver,
    GroupHover,
    Other(u32),
}

pub struct StyleWord<'a> {
    pub name: &'a str,
    pub state: State,
    pub group: &'a str,
    raw: &'a [sys::UitStyleArg],
}

impl<'a> StyleWord<'a> {
    pub fn args(&self) -> impl Iterator<Item = Arg<'a>> + '_ {
        self.raw.iter().map(|a| {
            let t = || std::str::from_utf8(unsafe { a.text.as_bytes() }).unwrap_or("");
            match a.kind {
                sys::UIT_ARG_PX => Arg::Px(a.a),
                sys::UIT_ARG_PERCENT => Arg::Percent(a.a),
                sys::UIT_ARG_REM => Arg::Rem(a.a),
                sys::UIT_ARG_NUMBER => Arg::Number(a.a),
                sys::UIT_ARG_RGBA => Arg::Rgba(a.rgba, t()),
                sys::UIT_ARG_TEXT => Arg::Text(t()),
                _ => Arg::None,
            }
        })
    }
    pub fn n_args(&self) -> usize {
        self.raw.len()
    }
}

/// A pre-parsed `ctl` line, copied out of the pump.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Ctl {
    pub verb: String,
    pub args: Vec<String>,
    pub attrs: Vec<(String, String)>,
}

impl Ctl {
    pub fn new(verb: impl Into<String>) -> Ctl {
        Ctl { verb: verb.into(), ..Default::default() }
    }
    pub fn arg(&self, i: usize) -> Option<&str> {
        self.args.get(i).map(String::as_str)
    }
    pub fn attr(&self, k: &str) -> Option<&str> {
        self.attrs.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str())
    }
    fn copy(c: &sys::UitCtl) -> Ctl {
        Ctl {
            verb: text(c.verb).into_owned(),
            args: slice(c.args, c.n_args).iter().map(|a| text(*a).into_owned()).collect(),
            attrs: slice(c.attrs, c.n_attrs).iter().map(|a| (text(a.name).into_owned(), text(a.value).into_owned())).collect(),
        }
    }
}

/// A host command, copied out of the pump so it can outlive it.
#[derive(Debug, Clone)]
pub enum HostCmd {
    Window { win: String },
    WindowCtl { win: String, ctl: Ctl },
    Quit,
    Menus,
    Keymap,
    Theme,
    /// `enabled`, `check`: `None` unchanged. `check`: 0 off, 1 on, 2 mixed.
    SetAction { id: String, enabled: Option<bool>, check: Option<i32> },
    Overlay { win: String, node: Node, name: String, open: bool },
    Focus { win: String, node: Node },
    /// The text to publish, from the command's `answer`.
    Clipboard { text: String },
    ComponentVerb { node: Node, ctl: Ctl },
    Answer { seq: u64, answer: Ctl },
    Redraw { win: String },
    ThemeLoad { path: String },
    Other(u32),
}

/// One line of a data file, split into fields by the core.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Line {
    pub fields: Vec<String>,
    pub indent: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyBinding {
    pub keystroke: String,
    pub action: String,
    pub context: String,
    pub global: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuKind {
    Item,
    Sep,
    Sub,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MenuItem {
    pub kind: MenuKind,
    pub depth: u32,
    pub id: String,
    pub label: String,
    pub key: String,
    pub icon: String,
    pub role: String,
    pub menu: String,
    pub enabled: bool,
    /// -1 none, 0 off, 1 on, 2 mixed.
    pub check: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DragKind {
    Start,
    Over,
    Drop,
    End,
}

/// What a pump changed (copied: it is small, and the host acts on it
/// after handing control back to GPUI).
#[derive(Debug, Default, Clone)]
pub struct Changes {
    pub dirty: Vec<String>,
    pub created: Vec<Node>,
    pub removed: Vec<Node>,
    pub props: Vec<(Node, String)>,
    pub cmds: Vec<HostCmd>,
    pub exited: Option<String>,
}

pub struct MachineArgs<'a> {
    pub prog: &'a str,
    pub argv: &'a [&'a str],
    pub root: &'a str,
    pub cwd: &'a str,
    pub env: &'a [&'a str],
}

impl Core {
    /// Makes a core; this thread becomes its owner.
    pub fn new(cfg: &Config, waker: Waker) -> Result<Core, Error> {
        let got = unsafe { sys::uit_abi_version() };
        if got != sys::UIT_ABI_VERSION {
            return Err(Error { code: sys::UIT_EVERSION, text: format!("libuitcore is ABI {got}, bindings are {}", sys::UIT_ABI_VERSION) });
        }
        let waker = Box::new(waker);
        let c = sys::UitConfig {
            abi_version: sys::UIT_ABI_VERSION,
            types: s(cfg.types),
            style_words: s(cfg.style_words),
            theme_tokens: s(cfg.theme_tokens),
            system_dark: cfg.system_dark as u32,
            wake: Some(wake_tramp),
            wake_ctx: &*waker as *const Waker as *mut c_void,
        };
        let mut raw = std::ptr::null_mut();
        let r = unsafe { sys::uit_create(&c, &mut raw) };
        if r != 0 {
            return Err(Error { code: r, text: String::new() });
        }
        Ok(Core { raw, _waker: waker, _not_send: PhantomData })
    }

    pub fn raw(&self) -> *mut sys::UitCore {
        self.raw
    }

    fn check(&self, r: c_int) -> Result<(), Error> {
        if r >= 0 {
            return Ok(());
        }
        Err(Error { code: r, text: text(unsafe { sys::uit_last_error(self.raw) }).into_owned() })
    }

    /// Listens on a fresh private unix socket; returns its dial string.
    pub fn listen(&mut self) -> Result<String, Error> {
        let mut d = UitStr::EMPTY;
        self.check(unsafe { sys::uit_listen(self.raw, UitStr::EMPTY, &mut d) })?;
        Ok(text(d).into_owned())
    }

    pub fn run_machine(&mut self, a: &MachineArgs) -> Result<(), Error> {
        let argv: Vec<UitStr> = a.argv.iter().map(|x| s(x)).collect();
        let env: Vec<UitStr> = a.env.iter().map(|x| s(x)).collect();
        let m = sys::UitMachineArgs {
            prog: s(a.prog),
            argv: argv.as_ptr(),
            argc: argv.len(),
            root: s(a.root),
            cwd: s(a.cwd),
            dirs: std::ptr::null(),
            n_dirs: 0,
            env: env.as_ptr(),
            n_env: env.len(),
            h9_flags: std::ptr::null(),
            n_h9_flags: 0,
            out_fd: -1,
            err_fd: -1,
        };
        self.check(unsafe { sys::uit_run_machine(self.raw, &m) })
    }

    /// Applies queued ops. Every borrow from before ends here.
    pub fn pump(&mut self) -> Result<Changes, Error> {
        let mut ch = sys::UitChanges::default();
        self.check(unsafe { sys::uit_pump(self.raw, &mut ch) })?;
        let mut out = Changes::default();
        out.dirty = slice(ch.dirty_windows, ch.n_dirty).iter().map(|w| text(*w).into_owned()).collect();
        out.created = slice(ch.created, ch.n_created).to_vec();
        out.removed = slice(ch.removed, ch.n_removed).to_vec();
        out.props = slice(ch.props, ch.n_props).iter().map(|p| (p.node, text(p.file).into_owned())).collect();
        for c in slice(ch.cmds, ch.n_cmds) {
            let win = || text(c.win).into_owned();
            out.cmds.push(match c.tag {
                sys::UIT_CMD_WINDOW => HostCmd::Window { win: win() },
                sys::UIT_CMD_WINDOW_CTL => HostCmd::WindowCtl { win: win(), ctl: Ctl::copy(&c.ctl) },
                sys::UIT_CMD_QUIT => HostCmd::Quit,
                sys::UIT_CMD_MENUS => HostCmd::Menus,
                sys::UIT_CMD_KEYMAP => HostCmd::Keymap,
                sys::UIT_CMD_THEME => HostCmd::Theme,
                sys::UIT_CMD_REDRAW => HostCmd::Redraw { win: win() },
                sys::UIT_CMD_SET_ACTION => HostCmd::SetAction {
                    id: text(c.name).into_owned(),
                    enabled: (c.flag >= 0).then_some(c.flag != 0),
                    check: (c.flag2 >= 0).then_some(c.flag2),
                },
                sys::UIT_CMD_OVERLAY => HostCmd::Overlay { win: win(), node: c.node, name: text(c.name).into_owned(), open: c.flag != 0 },
                sys::UIT_CMD_FOCUS => HostCmd::Focus { win: win(), node: c.node },
                sys::UIT_CMD_CLIPBOARD => HostCmd::Clipboard { text: text(c.answer).into_owned() },
                sys::UIT_CMD_COMPONENT_VERB => HostCmd::ComponentVerb { node: c.node, ctl: Ctl::copy(&c.ctl) },
                sys::UIT_CMD_ANSWER => HostCmd::Answer {
                    seq: c.seq,
                    answer: if c.ctl.verb.len > 0 { Ctl::copy(&c.ctl) } else { answer_ctl(&text(c.answer)) },
                },
                sys::UIT_CMD_THEME_LOAD => HostCmd::ThemeLoad { path: text(c.name).into_owned() },
                t => HostCmd::Other(t),
            });
        }
        if ch.exited != 0 {
            out.exited = Some(text(ch.exit_status).into_owned());
        }
        Ok(out)
    }

    pub fn window_root(&self, win: &str) -> Node {
        unsafe { sys::uit_window_root(self.raw, s(win)) }
    }

    pub fn children(&self, n: Node) -> &[Node] {
        let mut p = std::ptr::null();
        let k = unsafe { sys::uit_children(self.raw, n, &mut p) };
        slice(p, k)
    }

    pub fn type_of(&self, n: Node) -> &str {
        std::str::from_utf8(unsafe { sys::uit_type(self.raw, n).as_bytes() }).unwrap_or("")
    }

    pub fn path(&self, n: Node) -> &str {
        std::str::from_utf8(unsafe { sys::uit_path(self.raw, n).as_bytes() }).unwrap_or("")
    }

    /// A prop file's value, `None` when unset.
    pub fn prop(&self, n: Node, file: &str) -> Option<&str> {
        let mut out = UitStr::EMPTY;
        let r = unsafe { sys::uit_prop(self.raw, n, s(file), &mut out) };
        (r == 1).then(|| std::str::from_utf8(unsafe { out.as_bytes() }).unwrap_or(""))
    }

    /// A prop file's bytes (binary props such as an image's `data`).
    pub fn prop_bytes(&self, n: Node, file: &str) -> Option<&[u8]> {
        let mut out = UitStr::EMPTY;
        let r = unsafe { sys::uit_prop(self.raw, n, s(file), &mut out) };
        (r == 1).then(|| unsafe { out.as_bytes() })
    }

    pub fn style(&self, n: Node) -> impl Iterator<Item = StyleWord<'_>> {
        let mut p = std::ptr::null();
        let mut k = 0usize;
        unsafe { sys::uit_style(self.raw, n, &mut p, &mut k) };
        slice(p, k).iter().map(|w| StyleWord {
            name: std::str::from_utf8(unsafe { w.name.as_bytes() }).unwrap_or(""),
            state: match w.state {
                sys::UIT_STATE_BASE => State::Base,
                sys::UIT_STATE_HOVER => State::Hover,
                sys::UIT_STATE_ACTIVE => State::Active,
                sys::UIT_STATE_FOCUS => State::Focus,
                sys::UIT_STATE_DISABLED => State::Disabled,
                sys::UIT_STATE_DROP_OVER => State::DropOver,
                sys::UIT_STATE_GROUP_HOVER => State::GroupHover,
                x => State::Other(x),
            },
            group: std::str::from_utf8(unsafe { w.group.as_bytes() }).unwrap_or(""),
            raw: slice(w.args, w.n_args),
        })
    }

    pub fn token(&self, name: &str) -> Option<u32> {
        let mut v = 0u32;
        (unsafe { sys::uit_token(self.raw, s(name), &mut v) } == 1).then_some(v)
    }

    pub fn emit(&self, n: Node, name: &str, attrs: &[(&str, &str)]) -> Result<(), Error> {
        let a: Vec<sys::UitAttr> = attrs.iter().map(|(k, v)| sys::UitAttr { name: s(k), value: s(v) }).collect();
        self.check(unsafe { sys::uit_emit(self.raw, n, s(name), a.as_ptr(), a.len()) })
    }

    /// True if the keystroke matched a binding.
    pub fn key(&self, win: &str, keystroke: &str, focused: Node) -> bool {
        unsafe { sys::uit_key(self.raw, s(win), s(keystroke), focused) == 1 }
    }

    pub fn window_closed(&self, win: &str) {
        unsafe { sys::uit_window_closed(self.raw, s(win)) };
    }

    /// The window names, in creation order.
    pub fn windows(&self) -> Vec<&str> {
        let mut p = std::ptr::null();
        let k = unsafe { sys::uit_windows(self.raw, &mut p) };
        slice(p, k).iter().map(|w| utf8(*w)).collect()
    }

    pub fn overlays(&self, win: &str) -> &[Node] {
        let mut p = std::ptr::null();
        let k = unsafe { sys::uit_overlays(self.raw, s(win), &mut p) };
        slice(p, k)
    }

    pub fn window_of(&self, n: Node) -> &str {
        utf8(unsafe { sys::uit_window_of(self.raw, n) })
    }

    /// A data file split into lines and fields per its format. Copied.
    ///
    /// Until the core implements `uit_lines` (the spike returns
    /// `UIT_ENOTSUP`), this falls back to splitting the prop's text here:
    /// lines on newlines, fields on tabs, or on blanks with the one quoting
    /// rule when the line has no tab. The fallback goes when W3 lands.
    pub fn lines(&self, n: Node, file: &str) -> Vec<Line> {
        let mut out = sys::UitLines { lines: std::ptr::null(), n: 0 };
        let r = unsafe { sys::uit_lines(self.raw, n, s(file), &mut out) };
        if r == sys::UIT_ENOTSUP {
            return self.prop(n, file).map(fallback_lines).unwrap_or_default();
        }
        if r < 0 {
            return Vec::new();
        }
        slice(out.lines, out.n)
            .iter()
            .map(|l| Line { fields: slice(l.fields, l.n_fields).iter().map(|f| text(*f).into_owned()).collect(), indent: l.indent })
            .collect()
    }

    pub fn keys(&self) -> Vec<KeyBinding> {
        let mut p = std::ptr::null();
        let mut k = 0usize;
        if unsafe { sys::uit_keys(self.raw, &mut p, &mut k) } < 0 {
            return Vec::new();
        }
        slice(p, k)
            .iter()
            .map(|b| KeyBinding {
                keystroke: text(b.keystroke).into_owned(),
                action: text(b.action).into_owned(),
                context: text(b.context).into_owned(),
                global: b.global != 0,
            })
            .collect()
    }

    pub fn menu_bar(&self) -> Vec<String> {
        let mut p = std::ptr::null();
        let k = unsafe { sys::uit_menu_bar(self.raw, &mut p) };
        slice(p, k).iter().map(|w| text(*w).into_owned()).collect()
    }

    pub fn menu(&self, name: &str) -> Vec<MenuItem> {
        let mut p = std::ptr::null();
        let mut k = 0usize;
        if unsafe { sys::uit_menu(self.raw, s(name), &mut p, &mut k) } < 0 {
            return Vec::new();
        }
        slice(p, k)
            .iter()
            .map(|m| MenuItem {
                kind: match m.kind {
                    sys::UIT_MENU_SEP => MenuKind::Sep,
                    sys::UIT_MENU_SUB => MenuKind::Sub,
                    _ => MenuKind::Item,
                },
                depth: m.depth,
                id: text(m.id).into_owned(),
                label: text(m.label).into_owned(),
                key: text(m.key).into_owned(),
                icon: text(m.icon).into_owned(),
                role: text(m.role).into_owned(),
                menu: text(m.menu).into_owned(),
                enabled: m.enabled != 0,
                check: m.check,
            })
            .collect()
    }

    pub fn theme_dark(&self) -> bool {
        unsafe { sys::uit_theme_dark(self.raw) != 0 }
    }

    /// Opens a request; `Ok(seq)`, or `Ok(0)` when the core applied the
    /// default answer at once (it then arrives as `HostCmd::Answer` too,
    /// unless the core says otherwise).
    pub fn request(&self, n: Node, name: &str, attrs: &[(&str, &str)], default_answer: &str) -> u64 {
        let a: Vec<sys::UitAttr> = attrs.iter().map(|(k, v)| sys::UitAttr { name: s(k), value: s(v) }).collect();
        unsafe { sys::uit_request(self.raw, n, s(name), a.as_ptr(), a.len(), s(default_answer)) }
    }

    pub fn mirror(&self, n: Node, file: &str, value: &[u8]) -> Result<(), Error> {
        let v = UitStr { ptr: value.as_ptr(), len: value.len() };
        self.check(unsafe { sys::uit_mirror(self.raw, n, s(file), v) })
    }

    /// `UIT_ENOTSUP` from a core that doesn't keep bounds yet is not an error.
    pub fn bounds(&self, n: Node, b: [f32; 4]) {
        unsafe { sys::uit_bounds(self.raw, n, b[0], b[1], b[2], b[3]) };
    }

    pub fn frame_drawn(&self, win: &str) {
        unsafe { sys::uit_frame_drawn(self.raw, s(win)) };
    }

    pub fn menu_action(&self, id: &str) {
        unsafe { sys::uit_menu_action(self.raw, s(id)) };
    }

    pub fn system_dark(&self, dark: bool) {
        unsafe { sys::uit_system_dark(self.raw, dark as u32) };
    }

    /// Transfer layer. `Start` returns the new drag's number.
    pub fn drag(&self, kind: DragKind, drag: u64, n: Node, x: f32, y: f32, attrs: &[(&str, &str)]) -> Result<u64, Error> {
        let a: Vec<sys::UitAttr> = attrs.iter().map(|(k, v)| sys::UitAttr { name: s(k), value: s(v) }).collect();
        let m = sys::UitDragMsg {
            kind: match kind {
                DragKind::Start => sys::UIT_DRAG_START,
                DragKind::Over => sys::UIT_DRAG_OVER,
                DragKind::Drop => sys::UIT_DRAG_DROP,
                DragKind::End => sys::UIT_DRAG_END,
            },
            drag,
            node: n,
            x,
            y,
            attrs: a.as_ptr(),
            n_attrs: a.len(),
        };
        let mut out = drag;
        self.check(unsafe { sys::uit_drag(self.raw, &m, &mut out) })?;
        Ok(out)
    }

    pub fn wake(&self) {
        unsafe { sys::uit_wake_renderer(self.raw) }
    }

    pub fn shutdown(&self) {
        unsafe { sys::uit_shutdown(self.raw) }
    }
}

impl Drop for Core {
    fn drop(&mut self) {
        unsafe { sys::uit_destroy(self.raw) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::os::unix::net::UnixStream;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    // A tiny 9P2000 client, enough to write a ctl and read events.
    fn msg(t: u8, tag: u16, body: &[u8]) -> Vec<u8> {
        let mut m = Vec::new();
        m.extend_from_slice(&((7 + body.len()) as u32).to_le_bytes());
        m.push(t);
        m.extend_from_slice(&tag.to_le_bytes());
        m.extend_from_slice(body);
        m
    }
    fn st(s: &str) -> Vec<u8> {
        let mut v = (s.len() as u16).to_le_bytes().to_vec();
        v.extend_from_slice(s.as_bytes());
        v
    }
    fn rpc(c: &mut UnixStream, m: Vec<u8>) -> Vec<u8> {
        c.write_all(&m).unwrap();
        let mut sz = [0u8; 4];
        c.read_exact(&mut sz).unwrap();
        let mut rest = vec![0u8; u32::from_le_bytes(sz) as usize - 4];
        c.read_exact(&mut rest).unwrap();
        assert_ne!(rest[0], 107, "Rerror: {}", String::from_utf8_lossy(&rest[5..]));
        rest
    }
    fn walk(c: &mut UnixStream, newfid: u32, names: &[&str]) {
        let mut b = Vec::new();
        b.extend_from_slice(&1u32.to_le_bytes());
        b.extend_from_slice(&newfid.to_le_bytes());
        b.extend_from_slice(&(names.len() as u16).to_le_bytes());
        for n in names {
            b.extend(st(n));
        }
        rpc(c, msg(110, 2, &b));
    }

    /// The whole path the counter takes, with no GPU: a 9P client writes
    /// the ctl, the owner thread pumps, the tree shows through the ABI, and
    /// an emitted click comes back on `events`.
    #[test]
    fn ctl_over_9p_then_click_on_events() {
        let wakes = Arc::new(AtomicUsize::new(0));
        let w = wakes.clone();
        let mut core = Core::new(
            &Config { types: "", style_words: "", theme_tokens: "border #e5e5e5 #333333\n", system_dark: false },
            Box::new(move || {
                w.fetch_add(1, Ordering::SeqCst);
            }),
        )
        .unwrap();
        let dial = core.listen().unwrap();
        let path = dial.strip_prefix("unix!").unwrap().to_string();
        let client = std::thread::spawn(move || {
            let mut c = UnixStream::connect(&path).unwrap();
            let mut v = 8192u32.to_le_bytes().to_vec();
            v.extend(st("9P2000"));
            rpc(&mut c, msg(100, 0xffff, &v));
            let mut a = Vec::new();
            a.extend_from_slice(&1u32.to_le_bytes());
            a.extend_from_slice(&u32::MAX.to_le_bytes());
            a.extend(st("u"));
            a.extend(st(""));
            rpc(&mut c, msg(104, 1, &a));
            // events first, so the click lands after resync.
            walk(&mut c, 3, &["events"]);
            let mut o = 3u32.to_le_bytes().to_vec();
            o.push(0);
            rpc(&mut c, msg(112, 3, &o));
            walk(&mut c, 2, &["win", "main", "ctl"]);
            let mut o = 2u32.to_le_bytes().to_vec();
            o.push(1);
            rpc(&mut c, msg(112, 3, &o));
            let text = "new div inc tag=inc on=click : border-1 border-color=border\nnew text inc/t text=+";
            let mut wb = 2u32.to_le_bytes().to_vec();
            wb.extend_from_slice(&0u64.to_le_bytes());
            wb.extend_from_slice(&(text.len() as u32).to_le_bytes());
            wb.extend_from_slice(text.as_bytes());
            rpc(&mut c, msg(118, 4, &wb));
            rpc(&mut c, msg(120, 5, &2u32.to_le_bytes())); // clunk applies it
            let mut lines = String::new();
            while !lines.contains("click") {
                let mut r = 3u32.to_le_bytes().to_vec();
                r.extend_from_slice(&0u64.to_le_bytes());
                r.extend_from_slice(&4096u32.to_le_bytes());
                let rr = rpc(&mut c, msg(116, 6, &r));
                lines.push_str(&String::from_utf8_lossy(&rr[7..]));
            }
            lines
        });
        // The owner thread: pump until the tree has the button, then click.
        let mut clicked = false;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !client.is_finished() {
            assert!(std::time::Instant::now() < deadline, "timed out");
            let ch = core.pump().unwrap();
            if !clicked && !ch.created.is_empty() {
                let root = core.window_root("main");
                let inc = core.children(root)[0];
                assert_eq!(core.type_of(inc), "div");
                assert_eq!(core.prop(inc, "tag"), Some("inc"));
                let st: Vec<_> = core.style(inc).map(|w| (w.name.to_string(), w.args().collect::<Vec<_>>().len())).collect();
                assert_eq!(st, vec![("border-1".to_string(), 0), ("border-color".to_string(), 1)]);
                assert_eq!(core.style(inc).nth(1).unwrap().args().next(), Some(Arg::Rgba(0xe5e5e5ff, "border")));
                let t = core.children(inc)[0];
                assert_eq!(core.prop(t, "text"), Some("+"));
                core.emit(t, "click", &[("button", "left")]).unwrap();
                clicked = true;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let lines = client.join().unwrap();
        assert!(lines.starts_with("resync - - seq=0\n"), "{lines}");
        assert!(lines.contains("click inc inc/t win=main button=left seq=1\n"), "{lines}");
        assert!(wakes.load(Ordering::SeqCst) > 0);
    }
}
