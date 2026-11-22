//! Applying ops. Each op runs against a private copy of the state (`Tx`);
//! only a successful op replaces the tree's state, so an op that fails
//! partway through changes nothing.

use std::collections::{BTreeSet, HashSet};
use std::sync::Arc;
use std::time::Instant;

use bytes::Bytes;
use catalog::{LineFormat, PropKind, Slots, Tier, TypeSpec};
use proto::{Command, Error, ErrorKind};

use crate::state::*;
use crate::trace::{ctl_line, write_line};
use crate::{
    Answer, Batch, Changes, EventMsg, HostCmd, Op, Registry, SessionId, Tree, Via, WindowSpec,
};

pub(crate) fn err(kind: ErrorKind, detail: impl Into<String>) -> Error {
    Error::new(kind, detail)
}

fn read_only(path: &str) -> Error {
    err(ErrorKind::BadValue, format!("read-only: {path}"))
}

enum BatchOp {
    Begin(Option<String>),
    End(Option<String>),
}

pub(crate) struct Tx<'t> {
    pub st: State,
    pub reg: &'t Registry,
    tree: &'t Tree,
    session: SessionId,
    host: Vec<HostCmd>,
    trace: Vec<String>,
    batch_ops: Vec<BatchOp>,
    answered: HashSet<u64>,
    /// Events to send once the op is in: `(event, Some(default))` is a request.
    events: Vec<(EventMsg, Option<Answer>)>,
    /// Above zero while applying the props of a `new` or a `tree` document:
    /// those writes are traced as the one line that made them, and send no
    /// echoes.
    quiet: u32,
}

pub(crate) fn apply(tree: &mut Tree, s: SessionId, op: Op) -> Result<Changes, Error> {
    if tree.state.gone {
        return Err(err(ErrorKind::AppGone, ""));
    }
    if op == Op::SessionClosed {
        return Ok(close_session(tree, s));
    }
    let old = tree.state.clone();
    let mut tx = Tx {
        st: (*old).clone(),
        reg: &tree.reg,
        tree,
        session: s,
        host: Vec::new(),
        trace: Vec::new(),
        batch_ops: Vec::new(),
        answered: HashSet::new(),
        events: Vec::new(),
        quiet: 0,
    };
    tx.st.generation = tx.st.generation.wrapping_add(1);
    match &op {
        Op::Write { path, data } => tx.write(path.as_str(), data.clone(), false)?,
        Op::Append { path, data } => tx.write(path.as_str(), data.clone(), true)?,
        Op::Mkdir { path } => tx.mkdir(path.as_str())?,
        Op::Remove { path } => tx.remove(path.as_str())?,
        Op::SessionClosed => unreachable!(),
    }
    let Tx {
        st,
        host,
        trace,
        batch_ops,
        answered,
        events,
        ..
    } = tx;
    tree.state = Arc::new(st);
    for seq in answered {
        tree.requests.remove(&seq);
    }
    let mut host = host;
    for b in batch_ops {
        match b {
            BatchOp::Begin(scope) => tree.batches.push(Batch {
                session: s,
                scope,
                frozen: old.clone(),
                started: tree.now(),
            }),
            BatchOp::End(scope) => {
                if let Some(i) = tree
                    .batches
                    .iter()
                    .position(|b| b.session == s && b.scope == scope)
                {
                    tree.batches.remove(i);
                }
                let wins = match scope {
                    Some(w) => vec![w],
                    None => tree.windows(),
                };
                for w in wins {
                    if !tree.is_frozen(&w) {
                        host.push(HostCmd::Redraw { win: w });
                    }
                }
            }
        }
    }
    {
        let mut t = tree.shared.trace.lock().unwrap();
        for l in trace {
            t.push(l);
        }
    }
    let ch = tree.finish(&old, host);
    for (ev, default) in events {
        match default {
            Some(d) => {
                tree.open_request(ev, d, crate::REQUEST_TIMEOUT);
            }
            None => {
                tree.emit(ev);
            }
        }
    }
    Ok(ch)
}

/// The session's 9P connection went away: abort its batches.
fn close_session(tree: &mut Tree, s: SessionId) -> Changes {
    let old = tree.state.clone();
    let mut host = Vec::new();
    while let Some(i) = tree.batches.iter().rposition(|b| b.session == s) {
        let b = tree.batches.remove(i);
        let st = Arc::make_mut(&mut tree.state);
        restore(st, &b.frozen, b.scope.as_deref());
        let wins = match &b.scope {
            Some(w) => vec![w.clone()],
            None => tree.windows(),
        };
        for w in wins {
            if !tree.is_frozen(&w) {
                host.push(HostCmd::Redraw { win: w });
            }
        }
    }
    tree.finish(&old, host)
}

/// Puts back a window (or everything) as it was in `frozen`.
fn restore(st: &mut State, frozen: &State, scope: Option<&str>) {
    match scope {
        None => {
            let generation = st.generation;
            *st = frozen.clone();
            st.generation = generation.wrapping_add(1);
        }
        Some(w) => {
            let prefix = format!("windows/{w}/");
            st.nodes.retain(|k, _| !k.starts_with(&prefix));
            for (k, n) in frozen
                .nodes
                .range(prefix.clone()..)
                .take_while(|(k, _)| k.starts_with(&prefix))
            {
                st.nodes.insert(k.clone(), n.clone());
            }
            match frozen.windows.get(w) {
                Some(win) => {
                    st.windows.insert(w.to_string(), win.clone());
                }
                None => {
                    st.windows.remove(w);
                }
            }
        }
    }
}

pub(crate) fn remove_window(st: &mut State, w: &str) {
    let prefix = format!("windows/{w}/");
    st.nodes.retain(|k, _| !k.starts_with(&prefix));
    st.windows.remove(w);
}

/// What changed between two states.
pub(crate) fn diff(old: &State, new: &State) -> Changes {
    let mut ch = Changes::default();
    let mut dirty = BTreeSet::new();
    for (k, w) in &new.windows {
        match old.windows.get(k) {
            None => {
                ch.created.push(format!("windows/{k}"));
                dirty.insert(k.clone());
            }
            Some(o) if !Arc::ptr_eq(o, w) => {
                for (f, v) in &w.files {
                    if o.files.get(f) != Some(v) {
                        ch.props.push((format!("windows/{k}"), f.clone()));
                    }
                }
            }
            _ => {}
        }
    }
    for k in old.windows.keys() {
        if !new.windows.contains_key(k) {
            ch.removed.push(format!("windows/{k}"));
        }
    }
    // Both maps are sorted: walk them together.
    let mut a = old.nodes.iter().peekable();
    let mut b = new.nodes.iter().peekable();
    loop {
        match (a.peek(), b.peek()) {
            (None, None) => break,
            (Some((ka, _)), None) => {
                ch.removed.push((*ka).clone());
                a.next();
            }
            (None, Some((kb, _))) => {
                ch.created.push((*kb).clone());
                if let Some(w) = window_of(kb) {
                    dirty.insert(w.to_string());
                }
                b.next();
            }
            (Some((ka, na)), Some((kb, nb))) => match ka.cmp(kb) {
                std::cmp::Ordering::Less => {
                    ch.removed.push((*ka).clone());
                    if let Some(w) = window_of(ka)
                        && new.windows.contains_key(w)
                    {
                        dirty.insert(w.to_string());
                    }
                    a.next();
                }
                std::cmp::Ordering::Greater => {
                    ch.created.push((*kb).clone());
                    if let Some(w) = window_of(kb) {
                        dirty.insert(w.to_string());
                    }
                    b.next();
                }
                std::cmp::Ordering::Equal if na.uid != nb.uid => {
                    // Same path, new node: a delete and a create.
                    ch.removed.push((*ka).clone());
                    ch.created.push((*kb).clone());
                    if let Some(w) = window_of(kb) {
                        dirty.insert(w.to_string());
                    }
                    a.next();
                    b.next();
                }
                std::cmp::Ordering::Equal => {
                    if !Arc::ptr_eq(na, nb) {
                        let mut any = false;
                        if na.ty != nb.ty {
                            ch.props.push(((*kb).clone(), "type".into()));
                            any = true;
                        }
                        if na.order != nb.order {
                            ch.props.push(((*kb).clone(), "order".into()));
                            any = true;
                        }
                        let keys: BTreeSet<&String> =
                            na.files.keys().chain(nb.files.keys()).collect();
                        for f in keys {
                            if na.files.get(f) != nb.files.get(f) {
                                ch.props.push(((*kb).clone(), f.clone()));
                                any = true;
                            }
                        }
                        if (any || na.children != nb.children)
                            && let Some(w) = window_of(kb)
                        {
                            dirty.insert(w.to_string());
                        }
                    }
                    a.next();
                    b.next();
                }
            },
        }
    }
    ch.dirty_windows = dirty
        .into_iter()
        .filter(|w| new.windows.contains_key(w))
        .collect();
    ch
}

fn utf8(data: &[u8]) -> Result<&str, Error> {
    std::str::from_utf8(data).map_err(|_| err(ErrorKind::BadValue, "not utf-8"))
}

/// One trailing newline dropped (PLAN § Design questions 11).
fn chomp(data: &[u8]) -> &[u8] {
    data.strip_suffix(b"\n").unwrap_or(data)
}

fn is_on(v: &str) -> Option<bool> {
    match v {
        "on" | "true" => Some(true),
        "off" | "false" => Some(false),
        _ => None,
    }
}

fn number_list(v: &str) -> bool {
    v.split(|c: char| c == ',' || c.is_whitespace())
        .filter(|x| !x.is_empty())
        .all(|x| x.parse::<f64>().is_ok_and(f64::is_finite))
}

/// `w,h` or `x,y`.
fn pair(v: &str) -> bool {
    let parts: Vec<&str> = v.split(',').collect();
    parts.len() == 2
        && parts
            .iter()
            .all(|x| x.trim().parse::<f64>().is_ok_and(f64::is_finite))
}

pub(crate) fn check_lines(fmt: LineFormat, data: &[u8]) -> Result<(), Error> {
    use proto::lines::*;
    let s = utf8(data)?;
    match fmt {
        LineFormat::Items => parse_lines::<Item>(s).map(drop),
        LineFormat::Columns => parse_lines::<Column>(s).map(drop),
        LineFormat::Rows => parse_lines::<Row>(s).map(drop),
        LineFormat::TreeItems => parse_lines::<TreeItem>(s).map(drop),
        LineFormat::DescItems => parse_lines::<DescItem>(s).map(drop),
        LineFormat::RadioItems => parse_lines::<RadioItem>(s).map(drop),
        LineFormat::Menu => parse_lines::<MenuLine>(s).map(drop),
        LineFormat::Keymap => {
            for b in parse_lines::<KeyBinding>(s)? {
                for k in &b.keys {
                    check_keystroke(k)?;
                }
            }
            Ok(())
        }
        LineFormat::CanvasOps => parse_lines::<CanvasOp>(s).map(drop),
        LineFormat::Diagnostics => parse_lines::<Diagnostic>(s).map(drop),
        LineFormat::Messages => parse_messages(s).map(drop),
        // An answer file: `seq=N`, then completion lines.
        LineFormat::Completions if s.trim().is_empty() => Ok(()),
        LineFormat::Completions => parse_completions(s).map(drop),
    }
}

/// Modifiers GPUI's keystroke syntax takes.
const MODIFIERS: &[&str] = &[
    "cmd",
    "ctrl",
    "alt",
    "shift",
    "fn",
    "super",
    "win",
    "platform",
    "secondary",
];

/// One keystroke in GPUI syntax: modifiers joined by `-`, then a key
/// (`cmd-shift-p`, `ctrl--` for the minus key).
pub(crate) fn check_keystroke(k: &str) -> Result<(), Error> {
    let bad = || err(ErrorKind::BadValue, format!("keystroke: {k}"));
    let (mods, key) = match k.strip_suffix("--") {
        Some(m) => (m, "-"),
        None => match k.rsplit_once('-') {
            Some((m, key)) => (m, key),
            None => ("", k),
        },
    };
    if key.is_empty() || key.chars().any(char::is_whitespace) {
        return Err(bad());
    }
    if !mods.is_empty() && !mods.split('-').all(|m| MODIFIERS.contains(&m)) {
        return Err(bad());
    }
    Ok(())
}

/// Checks and normalizes a prop value.
fn check_prop(kind: PropKind, name: &str, data: &[u8]) -> Result<Bytes, Error> {
    let bad = |what: &str| err(ErrorKind::BadValue, format!("{name}: {what}"));
    let limit = match kind {
        PropKind::Data(_) => MAX_DATA,
        PropKind::Bytes => MAX_BYTES,
        _ => MAX_TEXT,
    };
    if data.len() > limit {
        return Err(err(ErrorKind::TooLarge, name.to_string()));
    }
    Ok(match kind {
        PropKind::Text => Bytes::copy_from_slice(chomp(data)),
        PropKind::Word => {
            let v = utf8(chomp(data))?.trim();
            if v.contains(char::is_whitespace) {
                return Err(bad("one word"));
            }
            Bytes::copy_from_slice(v.as_bytes())
        }
        PropKind::Bool => {
            let v = utf8(data)?.trim();
            if !v.is_empty() && is_on(v).is_none() {
                return Err(bad("on or off"));
            }
            Bytes::copy_from_slice(v.as_bytes())
        }
        PropKind::Number => {
            let v = utf8(data)?.trim();
            if !number_list(v) {
                return Err(bad("a number"));
            }
            Bytes::copy_from_slice(v.as_bytes())
        }
        PropKind::Enum(opts) => {
            let v = utf8(data)?.trim();
            if !v.is_empty() && !opts.contains(&v) {
                return Err(bad(&format!("one of {}", opts.join(" "))));
            }
            Bytes::copy_from_slice(v.as_bytes())
        }
        PropKind::Data(fmt) => {
            check_lines(fmt, data)?;
            Bytes::copy_from_slice(data)
        }
        PropKind::Bytes => Bytes::copy_from_slice(data),
        PropKind::ReadOnly => return Err(read_only(name)),
        PropKind::Child | PropKind::NodePath => {
            let v = utf8(chomp(data))?.trim();
            if v.contains(char::is_whitespace) {
                return Err(bad("one word"));
            }
            Bytes::copy_from_slice(v.as_bytes())
        }
    })
}

fn style_arg_ok(
    kind: style::ArgKind,
    a: &proto::StyleArg,
    tokens_ok: &dyn Fn(&str) -> bool,
) -> bool {
    use proto::StyleArg as A;
    use style::ArgKind as K;
    match kind {
        K::None => false,
        K::Length => matches!(a, A::Px(_) | A::Percent(_) | A::Rem(_)),
        K::Number => matches!(a, A::Px(_)),
        K::Color => match a {
            A::Color(_) => true,
            A::Token(t) => tokens_ok(t),
            _ => false,
        },
        K::Text => matches!(a, A::Token(_)),
        K::Many(_) => false,
    }
}

fn style_args_ok(
    kind: style::ArgKind,
    args: &[proto::StyleArg],
    tokens_ok: &dyn Fn(&str) -> bool,
) -> bool {
    use style::ArgKind as K;
    match kind {
        K::None => args.is_empty(),
        K::Many(ks) => {
            args.len() == ks.len()
                && ks
                    .iter()
                    .zip(args)
                    .all(|(k, a)| style_arg_ok(*k, a, tokens_ok))
        }
        k => args.len() == 1 && style_arg_ok(k, &args[0], tokens_ok),
    }
}

impl Tx<'_> {
    fn log(&mut self, line: String) {
        if self.quiet == 0 {
            self.trace.push(line);
        }
    }

    pub(crate) fn quietly<T>(&mut self, f: impl FnOnce(&mut Self) -> T) -> T {
        self.quiet += 1;
        let r = f(self);
        self.quiet -= 1;
        r
    }

    /// A state event echoing a client write (`via=ctl`).
    fn echo(&mut self, ev: EventMsg) {
        if self.quiet == 0 {
            self.events.push((ev.via(Via::Ctl), None));
        }
    }

    fn spec(&self, path: &str) -> Result<&'static TypeSpec, Error> {
        let n = self
            .st
            .node(path)
            .ok_or_else(|| err(ErrorKind::NotFound, path.to_string()))?;
        self.reg
            .spec_of(&n.ty)
            .ok_or_else(|| err(ErrorKind::UnknownType, n.ty.clone()))
    }

    fn generation(&self) -> u32 {
        self.st.generation
    }

    // ---- dispatch -------------------------------------------------------

    fn write(&mut self, path: &str, data: Bytes, append: bool) -> Result<(), Error> {
        let data =
            if append && !path.ends_with("/append") && path != "ctl" && !path.ends_with("/ctl") {
                let mut cur = self.current(path).unwrap_or_default().to_vec();
                cur.extend_from_slice(&data);
                Bytes::from(cur)
            } else {
                data
            };
        match path {
            "ctl" => return self.ctl_root(&data),
            "version" | "trace" | "events" => return Err(read_only(path)),
            "keymap" => {
                if data.len() > MAX_DATA {
                    return Err(err(ErrorKind::TooLarge, path));
                }
                check_lines(LineFormat::Keymap, &data)?;
                self.log(write_line(path, &data, false));
                self.set_root("keymap", data);
                self.host.push(HostCmd::Keymap);
                return Ok(());
            }
            "clipboard" | "clipboard-files" => {
                if data.len() > MAX_TEXT {
                    return Err(err(ErrorKind::TooLarge, path));
                }
                self.log(write_line(path, &data, false));
                self.set_root(path, data);
                self.host.push(HostCmd::Clipboard);
                return Ok(());
            }
            "theme/tokens" => return self.write_tokens(&data),
            "theme/mode" => {
                let v = utf8(&data)?.trim();
                if v != "light" && v != "dark" {
                    return Err(err(ErrorKind::BadValue, "mode: light or dark"));
                }
                self.set_root("theme/mode", Bytes::copy_from_slice(v.as_bytes()));
                self.host.push(HostCmd::Theme);
                self.log(write_line(path, v.as_bytes(), false));
                return Ok(());
            }
            "theme/name" => {
                let v = Bytes::copy_from_slice(chomp(&data));
                let name = String::from_utf8_lossy(&v).into_owned();
                if !name.is_empty() && style::find_theme(&name).is_none() {
                    return Err(err(ErrorKind::NotFound, format!("theme: {name}")));
                }
                self.log(write_line(path, &data, false));
                self.set_root("theme/name", v);
                self.host.push(HostCmd::Theme);
                return Ok(());
            }
            _ => {}
        }
        if let Some(name) = path.strip_prefix("menus/") {
            return self.write_menu(name, data);
        }
        if let Some(name) = path.strip_prefix("assets/") {
            if !valid_name(name) {
                return Err(err(ErrorKind::BadValue, format!("name: {name}")));
            }
            if data.len() > MAX_BYTES {
                return Err(err(ErrorKind::TooLarge, path));
            }
            self.log(write_line(path, &data, false));
            self.st.assets.insert(
                name.to_string(),
                FileVal {
                    data,
                    version: self.generation(),
                },
            );
            return Ok(());
        }
        if let Some(rest) = path.strip_prefix("drags/") {
            let n = rest
                .strip_suffix("/data")
                .and_then(|n| n.parse::<u64>().ok())
                .filter(|n| self.st.drags.contains_key(n))
                .ok_or_else(|| err(ErrorKind::NotFound, path))?;
            if data.len() > MAX_DATA {
                return Err(err(ErrorKind::TooLarge, path));
            }
            self.log(write_line(path, &data, false));
            self.st.drags.insert(
                n,
                FileVal {
                    data,
                    version: self.generation(),
                },
            );
            return Ok(());
        }
        // windows/<w>/<file>
        if let Some(rest) = path.strip_prefix("windows/")
            && let Some((w, file)) = rest.split_once('/')
            && !file.contains('/')
            && WINDOW_FILES.contains(&file)
        {
            if !self.st.windows.contains_key(w) {
                return Err(err(ErrorKind::NotFound, format!("windows/{w}")));
            }
            return self.write_window_file(w, file, &data);
        }
        let (node, file) = match path.rfind('/') {
            Some(i) => (&path[..i], &path[i + 1..]),
            None => return Err(err(ErrorKind::NotFound, path)),
        };
        if !self.st.nodes.contains_key(node) {
            return Err(err(ErrorKind::NotFound, path));
        }
        let node = node.to_string();
        if append && file == "append" {
            return self.set_file(&node, file, data, true);
        }
        self.set_file(&node, file, data, false)
    }

    /// The current contents of a plain file, for `Append`.
    fn current(&self, path: &str) -> Option<Bytes> {
        crate::snapshot::View::new(&self.st, self.reg, None).read(path)
    }

    fn set_root(&mut self, name: &str, data: Bytes) {
        let version = self.generation();
        self.st
            .root_files
            .insert(name.to_string(), FileVal { data, version });
    }

    fn write_tokens(&mut self, data: &[u8]) -> Result<(), Error> {
        let s = utf8(data)?;
        let mut set = Vec::new();
        for line in s.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            let mut it = line.splitn(2, char::is_whitespace);
            let name = it.next().unwrap();
            let value = it.next().map(str::trim).unwrap_or("");
            if value.is_empty() {
                return Err(err(ErrorKind::BadSyntax, format!("tokens: {line}")));
            }
            if let Some((_, _)) = LENGTH_TOKENS.iter().find(|(t, _)| *t == name) {
                if !number_list(value) || value.contains(',') {
                    return Err(err(ErrorKind::BadValue, format!("{name}: a number")));
                }
            } else if style::THEME_TOKENS.is_empty() || style::is_theme_token(name) {
                proto::Rgba::parse(value)
                    .map_err(|_| err(ErrorKind::BadValue, format!("{name}: a color")))?;
            } else {
                return Err(err(ErrorKind::NotFound, format!("token: {name}")));
            }
            set.push((name.to_string(), value.to_string()));
        }
        self.log(write_line("theme/tokens", data, false));
        for (k, v) in set {
            self.st.tokens.insert(k, v);
        }
        self.st.tokens_version = self.generation();
        self.host.push(HostCmd::Theme);
        Ok(())
    }

    fn write_menu(&mut self, name: &str, data: Bytes) -> Result<(), Error> {
        if !valid_name(name) {
            return Err(err(ErrorKind::BadValue, format!("menu name: {name}")));
        }
        if data.len() > MAX_DATA {
            return Err(err(ErrorKind::TooLarge, format!("menus/{name}")));
        }
        check_lines(LineFormat::Menu, &data)?;
        self.log(write_line(&format!("menus/{name}"), &data, false));
        let fv = FileVal {
            data,
            version: self.generation(),
        };
        match self.st.menus.iter_mut().find(|(n, _)| n == name) {
            Some(m) => m.1 = fv,
            None => self.st.menus.push((name.to_string(), fv)),
        }
        self.host.push(HostCmd::Menus);
        Ok(())
    }

    fn mkdir(&mut self, path: &str) -> Result<(), Error> {
        self.log(format!("mkdir path={path}"));
        if let Some(w) = path.strip_prefix("windows/").filter(|w| !w.contains('/')) {
            let cmd = Command {
                verb: "window".into(),
                args: vec![w.to_string()],
                props: vec![],
            };
            return self.new_window(&cmd);
        }
        let parent =
            parent_of(path).ok_or_else(|| err(ErrorKind::BadValue, format!("mkdir: {path}")))?;
        if !self.st.nodes.contains_key(parent) {
            if self.resolves(path) {
                return Err(err(ErrorKind::InUse, path));
            }
            return Err(err(ErrorKind::NotFound, parent));
        }
        let parent = parent.to_string();
        self.create_child(&parent, "div", base_of(path), &[], true)
    }

    /// Whether `path` names something that already exists.
    fn resolves(&self, path: &str) -> bool {
        crate::snapshot::View::new(&self.st, self.reg, None)
            .kind_of(path)
            .is_some()
    }

    fn remove(&mut self, path: &str) -> Result<(), Error> {
        if let Some(name) = path.strip_prefix("menus/") {
            let before = self.st.menus.len();
            self.st.menus.retain(|(n, _)| n != name);
            if self.st.menus.len() == before {
                return Err(err(ErrorKind::NotFound, path));
            }
            self.host.push(HostCmd::Menus);
            self.log(format!("remove path={path}"));
            return Ok(());
        }
        if let Some(name) = path.strip_prefix("assets/") {
            return match self.st.assets.remove(name) {
                Some(_) => {
                    self.log(format!("remove path={path}"));
                    Ok(())
                }
                None => Err(err(ErrorKind::NotFound, path)),
            };
        }
        if let Some(w) = path.strip_prefix("windows/").filter(|w| !w.contains('/')) {
            if !self.st.windows.contains_key(w) {
                return Err(err(ErrorKind::NotFound, path));
            }
            remove_window(&mut self.st, w);
            self.log(format!("remove path={path}"));
            self.host.push(HostCmd::WindowCtl {
                win: w.to_string(),
                cmd: Command {
                    verb: "destroy".into(),
                    ..Default::default()
                },
            });
            return Ok(());
        }
        if self.st.nodes.contains_key(path) {
            if let Some(rel) = win_relative(path)
                && (rel == "root" || rel == "overlays")
            {
                // `rm -r` of a whole window reaches these; they go with the window.
                return Ok(());
            }
            self.st.remove_subtree(path);
            self.log(format!("remove path={path}"));
            return Ok(());
        }
        // A node's own file (`rm -r` removes them before the directory) or
        // a window file: nothing to do, as long as it exists.
        if self.resolves(path) {
            return Ok(());
        }
        Err(err(ErrorKind::NotFound, path))
    }

    // ---- ctl ------------------------------------------------------------

    fn parse_ctl(&self, data: &[u8]) -> Result<Vec<Command>, Error> {
        if data.len() > MAX_CTL {
            return Err(err(ErrorKind::TooLarge, "ctl write"));
        }
        proto::parse_ctl(data)
    }

    fn ctl_root(&mut self, data: &[u8]) -> Result<(), Error> {
        for c in self.parse_ctl(data)? {
            self.log(ctl_line("ctl", &c, false));
            if c.props.iter().any(|(k, _)| k == "seq") {
                self.answer("", &c)?;
                continue;
            }
            match c.verb.as_str() {
                "window" => self.new_window(&c)?,
                "set" => {
                    let [id] = &c.args[..] else {
                        return Err(err(
                            ErrorKind::BadSyntax,
                            "set id [enabled=on|off] [check=on|off]",
                        ));
                    };
                    let mut enabled = None;
                    let mut check = None;
                    for (k, v) in &c.props {
                        let b =
                            is_on(v).ok_or_else(|| err(ErrorKind::BadValue, format!("{k}={v}")))?;
                        match k.as_str() {
                            "enabled" => enabled = Some(b),
                            "check" => check = Some(b),
                            _ => return Err(err(ErrorKind::BadValue, format!("set: {k}"))),
                        }
                    }
                    self.host.push(HostCmd::SetAction {
                        id: id.clone(),
                        enabled,
                        check,
                    });
                }
                "theme" => match (
                    c.args.first().map(String::as_str),
                    c.args.get(1),
                    c.args.len(),
                ) {
                    (Some("load"), Some(p), 2) => {
                        if !std::path::Path::new(p).is_file() {
                            return Err(err(ErrorKind::NotFound, p.clone()));
                        }
                        self.host.push(HostCmd::ThemeLoad { path: p.clone() })
                    }
                    (Some("mode"), Some(m), 2) if m == "light" || m == "dark" => {
                        self.set_root("theme/mode", Bytes::copy_from_slice(m.as_bytes()));
                        self.host.push(HostCmd::Theme);
                    }
                    (Some("name"), Some(n), 2) if style::find_theme(n).is_some() => {
                        self.set_root("theme/name", Bytes::copy_from_slice(n.as_bytes()));
                        self.host.push(HostCmd::Theme);
                    }
                    (Some("name"), Some(n), 2) => {
                        return Err(err(ErrorKind::NotFound, format!("theme: {n}")));
                    }
                    _ => {
                        return Err(err(
                            ErrorKind::BadSyntax,
                            "theme load path | mode light|dark | name name",
                        ));
                    }
                },
                "quit" => {
                    no_args(&c)?;
                    self.host.push(HostCmd::Quit);
                }
                "begin" => self.begin(None, &c)?,
                "commit" | "abort" => self.end_batch(None, &c)?,
                v => return Err(err(ErrorKind::UnknownCommand, v)),
            }
        }
        Ok(())
    }

    fn new_window(&mut self, c: &Command) -> Result<(), Error> {
        let [name] = &c.args[..] else {
            return Err(err(
                ErrorKind::BadSyntax,
                "window name [title=text] [size=w,h] ...",
            ));
        };
        if !valid_name(name) {
            return Err(err(ErrorKind::BadValue, format!("window name: {name}")));
        }
        if self.st.windows.contains_key(name) {
            return Err(err(ErrorKind::InUse, format!("windows/{name}")));
        }
        for (k, v) in &c.props {
            let ok = match k.as_str() {
                "title" => true,
                "size" | "min" => pair(v),
                "pos" => v == "center" || pair(v),
                "kind" => ["normal", "dialog", "popup"].contains(&v.as_str()),
                "titlebar" => ["system", "custom", "none"].contains(&v.as_str()),
                "resizable" => is_on(v).is_some(),
                _ => return Err(err(ErrorKind::NotFound, format!("window option: {k}"))),
            };
            if !ok {
                return Err(err(ErrorKind::BadValue, format!("{k}={v}")));
            }
        }
        let g = self.generation();
        let mut win = Win {
            name: name.clone(),
            props: c.props.clone(),
            version: g,
            ..Default::default()
        };
        if let Some((_, t)) = c.props.iter().find(|(k, _)| k == "title") {
            win.files.insert(
                "title".into(),
                FileVal {
                    data: Bytes::copy_from_slice(t.as_bytes()),
                    version: g,
                },
            );
        }
        self.st.windows.insert(name.clone(), Arc::new(win));
        let root = format!("windows/{name}/root");
        let root_node = self.st.new_node("div", "root");
        self.st.nodes.insert(root, Arc::new(root_node));
        let mut ov = self.st.new_node("overlays", "overlays");
        ov.fixed = true;
        self.st
            .nodes
            .insert(format!("windows/{name}/overlays"), Arc::new(ov));
        self.host.push(HostCmd::Window(WindowSpec {
            name: name.clone(),
            props: c.props.clone(),
        }));
        Ok(())
    }

    fn begin(&mut self, scope: Option<String>, c: &Command) -> Result<(), Error> {
        no_args(c)?;
        let open = self
            .tree
            .batches
            .iter()
            .any(|b| b.session == self.session && b.scope == scope)
            || self.batch_open_in_tx(&scope);
        if open {
            return Err(err(ErrorKind::InUse, "batch already open"));
        }
        self.batch_ops.push(BatchOp::Begin(scope));
        Ok(())
    }

    /// Net effect of this write's own begin/commit lines on `scope`.
    fn batch_open_in_tx(&self, scope: &Option<String>) -> bool {
        let mut open = false;
        for b in &self.batch_ops {
            match b {
                BatchOp::Begin(s) if s == scope => open = true,
                BatchOp::End(s) if s == scope => open = false,
                _ => {}
            }
        }
        open
    }

    fn end_batch(&mut self, scope: Option<String>, c: &Command) -> Result<(), Error> {
        no_args(c)?;
        let in_tree = self
            .tree
            .batches
            .iter()
            .find(|b| b.session == self.session && b.scope == scope);
        let began_here = self.batch_open_in_tx(&scope);
        if in_tree.is_none() && !began_here {
            return Err(err(ErrorKind::NoBatch, ""));
        }
        if c.verb == "abort" {
            let frozen = match in_tree {
                Some(b) if !began_here => b.frozen.clone(),
                _ => self.tree.state.clone(),
            };
            restore(&mut self.st, &frozen, scope.as_deref());
        }
        if began_here {
            // begin and commit in one write: they cancel out.
            if let Some(i) = self
                .batch_ops
                .iter()
                .rposition(|b| matches!(b, BatchOp::Begin(s) if *s == scope))
            {
                self.batch_ops.remove(i);
            }
        } else {
            self.batch_ops.push(BatchOp::End(scope));
        }
        Ok(())
    }

    fn write_window_file(&mut self, w: &str, file: &str, data: &[u8]) -> Result<(), Error> {
        match file {
            "ctl" => self.ctl_window(w, data),
            "events" | "bounds" => Err(read_only(&format!("windows/{w}/{file}"))),
            "title" => {
                let t = String::from_utf8_lossy(chomp(data)).into_owned();
                self.log(write_line(&format!("windows/{w}/title"), data, false));
                let c = Command {
                    verb: "title".into(),
                    args: vec![t],
                    props: vec![],
                };
                self.window_verb(w, &c)
            }
            "state" => {
                let s = utf8(data)?.trim().to_string();
                self.log(write_line(&format!("windows/{w}/state"), data, false));
                let c = Command {
                    verb: "state".into(),
                    args: vec![s],
                    props: vec![],
                };
                self.window_verb(w, &c)
            }
            "focus" => {
                let p = utf8(data)?.trim().to_string();
                if !p.is_empty() && !self.st.nodes.contains_key(&format!("windows/{w}/{p}")) {
                    return Err(err(ErrorKind::NotFound, p));
                }
                self.log(write_line(&format!("windows/{w}/focus"), data, false));
                self.set_win_file(w, "focus", p.as_bytes());
                if !p.is_empty() {
                    self.echo(
                        EventMsg::new(catalog::EventKind::State, "focus")
                            .win(w)
                            .node(&p),
                    );
                }
                self.host.push(HostCmd::Focus {
                    win: w.to_string(),
                    node: p,
                });
                Ok(())
            }
            _ => Err(err(ErrorKind::NotFound, format!("windows/{w}/{file}"))),
        }
    }

    fn set_win_file(&mut self, w: &str, file: &str, v: &[u8]) {
        let g = self.generation();
        if let Some(win) = self.st.windows.get_mut(w) {
            let win = Arc::make_mut(win);
            win.files.insert(
                file.to_string(),
                FileVal {
                    data: Bytes::copy_from_slice(v),
                    version: g,
                },
            );
            win.version = g;
        }
    }

    fn ctl_window(&mut self, w: &str, data: &[u8]) -> Result<(), Error> {
        for c in self.parse_ctl(data)? {
            self.log(ctl_line(&format!("windows/{w}/ctl"), &c, false));
            if c.props.iter().any(|(k, _)| k == "seq") {
                self.answer(&format!("windows/{w}"), &c)?;
                continue;
            }
            match c.verb.as_str() {
                "begin" => self.begin(Some(w.to_string()), &c)?,
                "commit" | "abort" => self.end_batch(Some(w.to_string()), &c)?,
                _ => self.window_verb(w, &c)?,
            }
        }
        Ok(())
    }

    fn window_verb(&mut self, w: &str, c: &Command) -> Result<(), Error> {
        let syntax = |u: &str| err(ErrorKind::BadSyntax, u.to_string());
        match c.verb.as_str() {
            "title" => {
                let [t] = &c.args[..] else {
                    return Err(syntax("title text"));
                };
                let t = t.clone();
                self.set_win_file(w, "title", t.as_bytes());
            }
            "size" | "move" => {
                let [v] = &c.args[..] else {
                    return Err(syntax(&format!("{} x,y", c.verb)));
                };
                if !pair(v) {
                    return Err(err(ErrorKind::BadValue, v.clone()));
                }
            }
            "center" | "activate" | "close" | "destroy" => no_args(c)?,
            "state" => {
                let [s] = &c.args[..] else {
                    return Err(syntax("state normal|minimized|maximized|fullscreen"));
                };
                if !["normal", "minimized", "maximized", "fullscreen"].contains(&s.as_str()) {
                    return Err(err(ErrorKind::BadValue, s.clone()));
                }
                let s = s.clone();
                self.set_win_file(w, "state", s.as_bytes());
                self.echo(
                    EventMsg::new(catalog::EventKind::State, "state")
                        .win(w)
                        .attr("value", &s),
                );
            }
            "notify" => {
                if c.args.len() != 1 {
                    return Err(syntax("notify text [type=info|success|warning|error]"));
                }
                if let Some((_, t)) = c.props.iter().find(|(k, _)| k == "type")
                    && !["info", "success", "warning", "error"].contains(&t.as_str())
                {
                    return Err(err(ErrorKind::BadValue, format!("type={t}")));
                }
            }
            v => return Err(err(ErrorKind::UnknownCommand, v.to_string())),
        }
        if c.verb == "close" {
            // Asking to close is a request to the client, as the close button is.
            let ev = EventMsg::new(catalog::EventKind::Request, "close")
                .win(w)
                .via(Via::Ctl);
            self.events.push((ev, Some(Answer::verb("close"))));
            return Ok(());
        }
        if c.verb == "destroy" {
            remove_window(&mut self.st, w);
        }
        self.host.push(HostCmd::WindowCtl {
            win: w.to_string(),
            cmd: c.clone(),
        });
        Ok(())
    }

    /// `verb seq=N` on `target`'s ctl answers request N.
    fn answer(&mut self, target: &str, c: &Command) -> Result<(), Error> {
        let seq_s = &c.props.iter().find(|(k, _)| k == "seq").unwrap().1;
        let seq: u64 = seq_s
            .parse()
            .map_err(|_| err(ErrorKind::BadValue, format!("seq={seq_s}")))?;
        let req = self
            .tree
            .requests
            .get(&seq)
            .filter(|r| r.target == target && !self.answered.contains(&seq))
            .ok_or_else(|| err(ErrorKind::NotFound, format!("request {seq}")))?;
        if let Some(d) = req.drag {
            self.st.drags.remove(&d);
        }
        if let Some(w) = req.closes_window.clone().filter(|_| c.verb == "close") {
            remove_window(&mut self.st, &w);
        }
        self.answered.insert(seq);
        self.host.push(HostCmd::Answer {
            seq,
            answer: Answer(c.clone()),
        });
        Ok(())
    }

    fn ctl_node(&mut self, node: &str, data: &[u8]) -> Result<(), Error> {
        let cmds = self.parse_ctl(data)?;
        for c in cmds {
            let secret = c.verb == "new"
                && c.props
                    .iter()
                    .any(|(k, v)| k == "flags" && v.split_whitespace().any(|w| w == "secret"));
            let secret = secret || self.st.is_secret(self.reg, node);
            self.log(ctl_line(&format!("{node}/ctl"), &c, secret));
            self.node_cmd(node, &c)?;
        }
        Ok(())
    }

    fn node_cmd(&mut self, node: &str, c: &Command) -> Result<(), Error> {
        if c.props.iter().any(|(k, _)| k == "seq") {
            return self.answer(node, c);
        }
        let spec = self.spec(node)?;
        match c.verb.as_str() {
            "new" => {
                let [ty, name] = &c.args[..] else {
                    return Err(err(ErrorKind::BadSyntax, "new type name [prop=value ...]"));
                };
                let (ty, name) = (ty.clone(), name.clone());
                self.create_child(node, &ty, &name, &c.props, false)
            }
            "delete" => {
                let [name] = &c.args[..] else {
                    return Err(err(ErrorKind::BadSyntax, "delete name"));
                };
                let p = format!("{node}/{name}");
                if !self.st.nodes.contains_key(&p) {
                    return Err(err(ErrorKind::NotFound, p));
                }
                self.st.remove_subtree(&p);
                Ok(())
            }
            _ if spec.verbs.iter().any(|v| v.name == c.verb) => {
                self.host.push(HostCmd::ComponentVerb {
                    node: node.to_string(),
                    cmd: c.clone(),
                });
                Ok(())
            }
            "open" | "close" if spec.tier == Tier::Overlay => {
                no_args(c)?;
                let win = window_of(node).unwrap_or("").to_string();
                let name = win_relative(node)
                    .and_then(|r| r.strip_prefix("overlays/"))
                    .unwrap_or_else(|| base_of(node))
                    .to_string();
                self.host.push(HostCmd::Overlay {
                    win,
                    name,
                    open: c.verb == "open",
                });
                Ok(())
            }
            v => Err(err(ErrorKind::UnknownCommand, v.to_string())),
        }
    }

    // ---- nodes ----------------------------------------------------------

    /// Whether a child of type `child` named `name` may go under `parent`.
    fn check_slot(
        &self,
        parent: &str,
        name: &str,
        child: &'static TypeSpec,
        at_mkdir: bool,
    ) -> Result<(), Error> {
        let pspec = self.spec(parent)?;
        let in_overlays = pspec.name == "overlays";
        if in_overlays && child.tier != Tier::Overlay && !at_mkdir {
            return Err(err(
                ErrorKind::UnknownType,
                format!("{}: not an overlay", child.name),
            ));
        }
        if in_overlays && at_mkdir {
            return Err(err(ErrorKind::BadValue, "overlays: use new <type> <name>"));
        }
        if !in_overlays && child.tier == Tier::Overlay {
            return Err(err(
                ErrorKind::UnknownType,
                format!("{}: belongs in overlays/", child.name),
            ));
        }
        match pspec.slots {
            Slots::Any => Ok(()),
            Slots::None => Err(err(
                ErrorKind::UnknownType,
                format!("{}: takes no children", pspec.name),
            )),
            Slots::Named(names) => {
                if names.contains(&name) {
                    Ok(())
                } else {
                    Err(err(
                        ErrorKind::BadValue,
                        format!("{}: slots are {}", pspec.name, names.join(" ")),
                    ))
                }
            }
            Slots::NamedAnd(names, _) if names.contains(&name) => Ok(()),
            Slots::ChildTypes(types) | Slots::NamedAnd(_, types) => {
                if types.contains(&child.name) || (at_mkdir && child.name == "div") {
                    Ok(())
                } else {
                    Err(err(
                        ErrorKind::UnknownType,
                        format!("{}: children are {}", pspec.name, types.join(" ")),
                    ))
                }
            }
        }
    }

    fn creatable(&self, ty: &str) -> Result<&'static TypeSpec, Error> {
        if ty == "overlays" {
            return Err(err(ErrorKind::UnknownType, ty));
        }
        self.reg
            .spec_of(ty)
            .ok_or_else(|| err(ErrorKind::UnknownType, ty))
    }

    pub(crate) fn create_child(
        &mut self,
        parent: &str,
        ty: &str,
        name: &str,
        props: &[(String, String)],
        at_mkdir: bool,
    ) -> Result<(), Error> {
        let pspec = self.spec(parent)?;
        if !valid_name(name) {
            return Err(err(ErrorKind::BadValue, format!("name: {name}")));
        }
        if is_reserved(pspec, name) {
            return Err(err(
                ErrorKind::BadValue,
                format!("name: {name} is a file of {}", pspec.name),
            ));
        }
        let path = format!("{parent}/{name}");
        if self.st.nodes.contains_key(&path) {
            return Err(err(ErrorKind::InUse, path));
        }
        if depth_of(&path) > MAX_DEPTH {
            return Err(err(ErrorKind::TooLarge, format!("depth: {path}")));
        }
        let spec = self.creatable(ty)?;
        self.check_slot(parent, name, spec, at_mkdir)?;
        let g = self.generation();
        let node = self.st.new_node(spec.name, name);
        self.st.nodes.insert(path.clone(), Arc::new(node));
        let p = self.st.node_mut(parent).unwrap();
        p.children.push(name.to_string());
        p.order.push(name.to_string());
        p.version = g;
        self.quietly(|tx| {
            for (k, v) in props {
                if k == "type" {
                    return Err(err(
                        ErrorKind::BadSyntax,
                        "type is the first argument of new",
                    ));
                }
                tx.set_file(&path, k, Bytes::copy_from_slice(v.as_bytes()), false)?;
            }
            Ok(())
        })
    }

    fn set_type(&mut self, path: &str, ty: &str) -> Result<(), Error> {
        let n = self
            .st
            .node(path)
            .ok_or_else(|| err(ErrorKind::NotFound, path))?;
        if n.ty == ty {
            return Ok(());
        }
        if n.fixed {
            return Err(err(ErrorKind::TypeIsFixed, path));
        }
        let spec = self.creatable(ty)?;
        if let Some(parent) = parent_of(path).filter(|p| self.st.nodes.contains_key(*p)) {
            self.check_slot(parent, base_of(path), spec, false)?;
        }
        if is_reserved_by_children(&self.st, path, spec) {
            return Err(err(
                ErrorKind::BadValue,
                format!("{ty}: a child's name is one of its files"),
            ));
        }
        let g = self.generation();
        let n = self.st.node_mut(path).unwrap();
        n.ty = spec.name.to_string();
        n.version = g;
        n.files.retain(|f, _| {
            COMMON_WRITABLE.contains(&f.as_str()) || spec.props.iter().any(|p| p.name == f)
        });
        n.mirrored
            .retain(|f| spec.props.iter().any(|p| p.name == f));
        let children: Vec<String> = n.children.clone();
        for c in children {
            let cp = format!("{path}/{c}");
            let cty = self.st.node(&cp).unwrap().ty.clone();
            let cspec = self.reg.spec_of(&cty).unwrap_or(&DIV_FALLBACK);
            self.check_slot(path, &c, cspec, cty == "div")?;
        }
        Ok(())
    }

    /// Writes one node file, after checking it.
    pub(crate) fn set_file(
        &mut self,
        node: &str,
        file: &str,
        data: Bytes,
        append: bool,
    ) -> Result<(), Error> {
        let spec = self.spec(node)?;
        match file {
            "ctl" => return self.ctl_node(node, &data),
            "tree" => {
                if data.len() > MAX_DATA {
                    return Err(err(ErrorKind::TooLarge, "tree"));
                }
                self.log(write_line(&format!("{node}/tree"), &data, false));
                return self.quietly(|tx| tx.write_doc(node, &data));
            }
            "id" | "bounds" | "events" => return Err(read_only(&format!("{node}/{file}"))),
            "type" => {
                let ty = utf8(&data)?.trim().to_string();
                self.set_type(node, &ty)?;
                self.log(write_line(&format!("{node}/type"), &data, false));
                return Ok(());
            }
            "order" => {
                let s = utf8(&data)?;
                let names: Vec<String> = s.split_whitespace().map(str::to_string).collect();
                let n = self.st.node(node).unwrap();
                let mut seen = HashSet::new();
                for c in &names {
                    if !n.children.contains(c) {
                        return Err(err(ErrorKind::NotFound, format!("{node}/{c}")));
                    }
                    if !seen.insert(c) {
                        return Err(err(ErrorKind::BadValue, format!("order: {c} twice")));
                    }
                }
                self.log(write_line(&format!("{node}/order"), &data, false));
                let g = self.generation();
                let n = self.st.node_mut(node).unwrap();
                n.order = names;
                n.version = g;
                return Ok(());
            }
            _ => {}
        }
        let value = if file == "style" {
            let s = utf8(chomp(&data))?;
            self.check_style(spec, s)?;
            Bytes::copy_from_slice(s.as_bytes())
        } else if file == "on" {
            let s = utf8(chomp(&data))?;
            for w in s.split_whitespace() {
                if !ON_WORDS.contains(&w) && !spec.events.iter().any(|e| e.name == w) {
                    return Err(err(ErrorKind::BadValue, format!("on: {w}")));
                }
            }
            Bytes::copy_from_slice(s.as_bytes())
        } else if file == "context" || file == "drag-type" {
            check_prop(PropKind::Word, file, &data)?
        } else if COMMON_WRITABLE.contains(&file) {
            // tag, tooltip, drop
            check_prop(PropKind::Text, file, &data)?
        } else if is_append_file(spec, file) {
            let rows = prop_spec(spec, "rows").unwrap();
            if let PropKind::Data(fmt) = rows.kind {
                check_lines(fmt, &data)?;
            }
            let mut cur = self
                .st
                .node_file(self.reg, node, "rows")
                .unwrap_or_default()
                .to_vec();
            if !cur.is_empty() && !cur.ends_with(b"\n") {
                cur.push(b'\n');
            }
            cur.extend_from_slice(&data);
            if cur.len() > MAX_DATA {
                return Err(err(ErrorKind::TooLarge, "rows"));
            }
            self.log(write_line(&format!("{node}/append"), &data, false));
            let g = self.generation();
            self.st
                .node_mut(node)
                .unwrap()
                .put_file("rows", Bytes::from(cur), g);
            return Ok(());
        } else if let Some(p) = prop_spec(spec, file) {
            let v = check_prop(p.kind, file, &data)?;
            if file == "value" {
                let items = self
                    .st
                    .node_file(self.reg, node, "items")
                    .unwrap_or_default();
                check_item_ids(spec, items, &v)?;
            }
            self.check_ref(node, p.kind, &v)?;
            v
        } else {
            return Err(err(ErrorKind::NotFound, format!("{node}/{file}")));
        };
        let _ = append;
        let kind = prop_spec(spec, file).map(|p| p.kind);
        let secret = file == "value" && self.st.is_secret(self.reg, node);
        self.log(write_line(&format!("{node}/{file}"), &data, secret));
        let g = self.generation();
        let n = self.st.node_mut(node).unwrap();
        n.put_file(file, value.clone(), g);
        n.mirrored.remove(file);
        // A write to a file a state event reports is echoed with via=ctl.
        if file == "value"
            && spec
                .events
                .iter()
                .any(|e| e.name == "change" && e.kind == catalog::EventKind::State)
        {
            let mut ev = EventMsg::new(catalog::EventKind::State, "change").node(node);
            let short = !matches!(
                kind,
                Some(PropKind::Text | PropKind::Bytes | PropKind::Data(_))
            );
            if short && !secret {
                ev = ev.attr("value", &String::from_utf8_lossy(&value));
            }
            self.echo(ev);
        }
        Ok(())
    }

    /// `Child` and `NodePath` props must name a node that exists.
    fn check_ref(&self, node: &str, kind: PropKind, v: &[u8]) -> Result<(), Error> {
        let v = String::from_utf8_lossy(v);
        if v.is_empty() {
            return Ok(());
        }
        match kind {
            PropKind::Child => {
                let n = self.st.node(node).unwrap();
                if !n.children.is_empty() && !n.children.iter().any(|c| *c == v) {
                    return Err(err(ErrorKind::NotFound, format!("{node}/{v}")));
                }
            }
            PropKind::NodePath => {
                let full = if v.starts_with("windows/") {
                    v.to_string()
                } else {
                    format!("windows/{}/{v}", window_of(node).unwrap_or(""))
                };
                if !self.st.nodes.contains_key(&full) {
                    return Err(err(ErrorKind::NotFound, v.to_string()));
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn check_style(&self, spec: &'static TypeSpec, s: &str) -> Result<(), Error> {
        let words = proto::parse_style(s)?;
        let theme_tokens = style::THEME_TOKENS;
        let tokens_ok = |t: &str| {
            theme_tokens.is_empty() || style::is_theme_token(t) || self.st.tokens.contains_key(t)
        };
        for w in &words {
            let name = w.name.as_str();
            let unknown = || err(ErrorKind::UnknownStyleWord, name.to_string());
            if name == "group" && w.group.is_some() && w.args.is_empty() {
                continue;
            }
            if style::is_size_word(name) || SIZE_WORDS.contains(&name) {
                if !spec.sizable || !w.args.is_empty() {
                    return Err(unknown());
                }
                continue;
            }
            if spec.variants.contains(&name) {
                if !w.args.is_empty() {
                    return Err(err(ErrorKind::BadValue, name.to_string()));
                }
                continue;
            }
            if !style::variant_owners(name).is_empty() || self.reg.is_variant_word(name) {
                return Err(unknown());
            }
            let e = style::lookup(name).ok_or_else(unknown)?;
            if !style_args_ok(e.arg, &w.args, &tokens_ok) {
                return Err(err(ErrorKind::BadValue, format!("style: {name}")));
            }
        }
        Ok(())
    }
}

/// On a type whose `items` file holds item or radio-item lines (`select`,
/// `combobox`, `radio-group`), each word of `value` must be an item id, once
/// `items` has any. An empty value clears the selection.
fn check_item_ids(spec: &'static TypeSpec, items: &[u8], value: &[u8]) -> Result<(), Error> {
    use proto::lines::*;
    let Some(fmt) = prop_spec(spec, "items").and_then(|p| match p.kind {
        PropKind::Data(f @ (LineFormat::Items | LineFormat::RadioItems)) => Some(f),
        _ => None,
    }) else {
        return Ok(());
    };
    let items = String::from_utf8_lossy(items);
    let ids: Vec<String> = match fmt {
        LineFormat::Items => parse_lines::<Item>(&items)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|i| match i {
                Item::Entry(e) => Some(e.id),
                _ => None,
            })
            .collect(),
        _ => parse_lines::<RadioItem>(&items)
            .unwrap_or_default()
            .into_iter()
            .map(|r| r.id)
            .collect(),
    };
    if ids.is_empty() {
        return Ok(());
    }
    for w in String::from_utf8_lossy(value).split_whitespace() {
        if !ids.iter().any(|id| id == w) {
            return Err(err(ErrorKind::NotFound, format!("item {w}")));
        }
    }
    Ok(())
}

fn is_reserved_by_children(st: &State, path: &str, spec: &'static TypeSpec) -> bool {
    st.node(path)
        .is_some_and(|n| n.children.iter().any(|c| is_reserved(spec, c)))
}

fn no_args(c: &Command) -> Result<(), Error> {
    if c.args.is_empty() {
        Ok(())
    } else {
        Err(err(
            ErrorKind::BadSyntax,
            format!("{} takes no arguments", c.verb),
        ))
    }
}
