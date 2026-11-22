//! The model the whole system shares: nodes, the type registry, ops,
//! snapshots, batches, the event bus and requests. Pure, no GPUI. Owned by W2.
//!
//! The `Tree` lives on one thread (GPUI's main thread, or the headless
//! backend's). Every op is applied to a copy of the state and swapped in only
//! when it succeeds, so an op never half-applies. Readers on other threads
//! get an immutable [`Snapshot`], and `events` readers get a [`Subscription`]
//! from the shared [`EventBus`].
//!
//! Choices this crate makes where DESIGN.md is silent:
//!
//! - `PropKind::Text` and `Word` drop one trailing newline on write
//!   (PLAN § Design questions 11); `Bytes` and `Data` keep the bytes as written.
//! - `mkdir` appends the new node to its parent's `order`, as `new` does.
//! - Removing a node's file (as `rm -r` does before removing the directory)
//!   succeeds and changes nothing; removing the node's directory removes it.
//! - Writing a read-only file fails with `bad value: read-only`.
//! - `begin` on the root `ctl` freezes every window for that session;
//!   `abort` restores the window (or the app) to its state at `begin`.
//! - A `tree` write keeps files the host mirrored (component state, such as
//!   an input's `value`) unless the document names them; every other file the
//!   document leaves out goes back to its default.
//! - State events carry `via=ctl|user`; action events carry `via` only when
//!   the caller set one in `attrs`.
#![allow(clippy::new_without_default)]

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub use bytes::Bytes;
pub use catalog::EventKind;

mod apply;
mod bus;
mod doc;
mod snapshot;
mod state;
mod trace;

#[cfg(test)]
mod tests;

pub use bus::{ACTION_CAP, EventBus, Subscription};
pub use snapshot::Snapshot;

use state::{Node, State};

/// Event names that are always state events (DESIGN § Two kinds of event).
pub const STATE_EVENTS: &[&str] = &[
    "change", "select", "cursor", "resize", "layout", "move", "scroll", "hover", "focus", "blur",
    "state",
];

/// How long a batch may stay open before it is committed.
pub const BATCH_TIMEOUT: Duration = Duration::from_secs(2);
/// How long a request waits for an answer before its default applies.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SessionId(pub u32);

/// A path relative to the tree root, no leading slash:
/// `windows/main/root/prefs/ok/save/label`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
pub struct FsPath(String);

impl FsPath {
    pub fn new(p: impl Into<String>) -> Self {
        FsPath(p.into().trim_matches('/').to_string())
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for FsPath {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    /// `ctl`: one write. Text and data files: the whole value, at clunk.
    /// A write to a missing `menus/<name>` or `assets/<name>` creates it.
    Write {
        path: FsPath,
        data: Bytes,
    },
    /// Adds to the end of a file. On a table's `append` file, adds rows.
    Append {
        path: FsPath,
        data: Bytes,
    },
    Mkdir {
        path: FsPath,
    },
    Remove {
        path: FsPath,
    },
    /// Aborts that session's open batches.
    SessionClosed,
}

/// The `TypeSpec`s the tree validates every write against.
#[derive(Debug, Clone, Default)]
pub struct Registry {
    types: BTreeMap<&'static str, &'static catalog::TypeSpec>,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }
    /// Every spec in `catalog::all()`.
    pub fn from_catalog() -> Self {
        let mut r = Self::new();
        for t in catalog::all() {
            r.insert(t);
        }
        r
    }
    pub fn insert(&mut self, spec: &'static catalog::TypeSpec) {
        self.types.insert(spec.name, spec);
    }
    pub fn get(&self, name: &str) -> Option<&'static catalog::TypeSpec> {
        self.types.get(name).copied()
    }
    pub fn iter(&self) -> impl Iterator<Item = &'static catalog::TypeSpec> + '_ {
        self.types.values().copied()
    }
}

/// Whether a change came from a client write or from the user in the UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Via {
    Ctl,
    User,
}

/// How a request is answered: the answering `ctl` command (`seq=` already matched).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer(pub proto::Command);

impl Answer {
    /// An answer that is just a verb: `Answer::verb("close")`.
    pub fn verb(v: &str) -> Self {
        Answer(proto::Command {
            verb: v.to_string(),
            ..Default::default()
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WindowSpec {
    pub name: String,
    /// The `window` verb's options (`title=`, `size=`, ...).
    pub props: Vec<(String, String)>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Changes {
    /// Windows whose committed tree changed and should be redrawn.
    pub dirty_windows: Vec<String>,
    /// Paths of new nodes, and `windows/<w>` for new windows.
    pub created: Vec<String>,
    /// Paths of removed nodes, and `windows/<w>` for removed windows.
    pub removed: Vec<String>,
    /// `(node path, prop file)` pairs whose value changed, `type` and
    /// `order` included. Window files show as `(windows/<w>, file)`.
    pub props: Vec<(String, String)>,
    pub host: Vec<HostCmd>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostCmd {
    Window(WindowSpec),
    WindowCtl {
        win: String,
        cmd: proto::Command,
    },
    Quit,
    Menus,
    Keymap,
    Theme,
    SetAction {
        id: String,
        enabled: Option<bool>,
        check: Option<bool>,
    },
    Overlay {
        win: String,
        name: String,
        open: bool,
    },
    /// `node` is window-relative (`root/src`).
    Focus {
        win: String,
        node: String,
    },
    Clipboard,
    /// `node` is the full path.
    ComponentVerb {
        node: String,
        cmd: proto::Command,
    },
    Answer {
        seq: u64,
        answer: Answer,
    },
    /// A batch committed or timed out: the window's committed tree changed.
    Redraw {
        win: String,
    },
    /// `theme load path` on the root `ctl`.
    ThemeLoad {
        path: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventMsg {
    pub kind: EventKind,
    pub name: String,
    pub win: Option<String>,
    /// Window-relative (`root/prefs/ok/save`); `None` for app-level events.
    /// A full path (`windows/main/root/...`) is accepted too, and fills `win`.
    pub node: Option<String>,
    pub attrs: Vec<(String, String)>,
    pub via: Via,
}

impl EventMsg {
    pub fn new(kind: EventKind, name: &str) -> Self {
        EventMsg {
            kind,
            name: name.to_string(),
            win: None,
            node: None,
            attrs: Vec::new(),
            via: Via::User,
        }
    }
    pub fn win(mut self, w: &str) -> Self {
        self.win = Some(w.to_string());
        self
    }
    pub fn node(mut self, n: &str) -> Self {
        self.node = Some(n.to_string());
        self
    }
    pub fn attr(mut self, k: &str, v: &str) -> Self {
        self.attrs.push((k.to_string(), v.to_string()));
        self
    }
    pub fn via(mut self, v: Via) -> Self {
        self.via = v;
        self
    }
}

/// A borrowed view of one node, for the renderer.
#[derive(Debug, Clone, Copy)]
pub struct NodeRef<'a> {
    st: &'a State,
    reg: &'a Registry,
    path: &'a str,
    node: &'a Node,
}

impl<'a> NodeRef<'a> {
    fn new(st: &'a State, reg: &'a Registry, path: &str) -> Option<Self> {
        let (k, n) = st.nodes.get_key_value(path)?;
        Some(NodeRef {
            st,
            reg,
            path: k.as_str(),
            node: n,
        })
    }
    /// The full path, which is also the node's `ElementId`.
    pub fn path(&self) -> &'a str {
        self.path
    }
    /// The path below the window directory (`root/prefs/ok`), as events use.
    pub fn rel_path(&self) -> &'a str {
        state::win_relative(self.path).unwrap_or(self.path)
    }
    pub fn win(&self) -> &'a str {
        state::window_of(self.path).unwrap_or("")
    }
    pub fn ty(&self) -> &'a str {
        &self.node.ty
    }
    pub fn name(&self) -> &'a str {
        &self.node.name
    }
    pub fn spec(&self) -> Option<&'static catalog::TypeSpec> {
        self.reg.spec_of(&self.node.ty)
    }
    /// A prop file's stored bytes, or its default. Common files (`style`,
    /// `tag`, `on`, ...) read as empty until written.
    pub fn prop(&self, file: &str) -> Option<&'a [u8]> {
        self.st.node_file(self.reg, self.path, file)
    }
    /// A prop as text.
    pub fn text(&self, file: &str) -> Option<&'a str> {
        self.prop(file).and_then(|b| std::str::from_utf8(b).ok())
    }
    /// Whether the client (or a mirror) has written the file.
    pub fn is_set(&self, file: &str) -> bool {
        self.node.files.contains_key(file)
    }
    /// Children in `order`. Children not listed are not returned.
    pub fn children(&self) -> Vec<NodeRef<'a>> {
        self.node
            .order
            .iter()
            .filter_map(|c| NodeRef::new(self.st, self.reg, &format!("{}/{c}", self.path)))
            .collect()
    }
    /// One child by name, drawn or not (for slots).
    pub fn child(&self, name: &str) -> Option<NodeRef<'a>> {
        NodeRef::new(self.st, self.reg, &format!("{}/{name}", self.path))
    }
    /// Whether the type of this node can no longer change.
    pub fn type_fixed(&self) -> bool {
        self.node.fixed
    }
}

#[derive(Debug)]
struct Batch {
    session: SessionId,
    /// `None`: the app (`begin` on the root `ctl`).
    scope: Option<String>,
    frozen: Arc<State>,
    started: Instant,
}

#[derive(Debug)]
struct Request {
    /// The directory whose `ctl` answers it: `""`, `windows/<w>` or a node path.
    target: String,
    default: Answer,
    deadline: Instant,
    drag: Option<u64>,
    /// A window `close` request: answering `close` removes the window.
    closes_window: Option<String>,
}

/// State readers on other threads see live, outside the snapshot.
#[derive(Debug, Default)]
pub(crate) struct Shared {
    pub trace: Mutex<trace::TraceBuf>,
    pub bounds: Mutex<std::collections::HashMap<String, [f32; 4]>>,
}

/// The tree. Main-thread only.
#[derive(Debug)]
pub struct Tree {
    reg: Arc<Registry>,
    state: Arc<State>,
    batches: Vec<Batch>,
    requests: BTreeMap<u64, Request>,
    /// Host commands produced outside `apply` (defaults applied at once),
    /// handed out by the next `tick`.
    pending: Vec<HostCmd>,
    bus: EventBus,
    shared: Arc<Shared>,
    /// Added to the real clock wherever the tree stamps a time (batch
    /// starts, request deadlines), for a fake clock such as headless's.
    skew: Duration,
}

impl Tree {
    pub fn new(reg: Registry) -> Self {
        Tree {
            reg: Arc::new(reg),
            state: Arc::new(State::default()),
            batches: Vec::new(),
            requests: BTreeMap::new(),
            pending: Vec::new(),
            bus: EventBus::default(),
            shared: Arc::new(Shared::default()),
            skew: Duration::ZERO,
        }
    }

    /// Moves the tree's clock forward: later batch starts and request
    /// deadlines are stamped `Instant::now() + total skew`. Pass `tick` the
    /// real time; `tick` adds the skew too.
    pub fn advance_clock(&mut self, d: Duration) {
        self.skew += d;
    }

    /// The tree's clock: the real one plus every `advance_clock`.
    pub fn now(&self) -> Instant {
        Instant::now() + self.skew
    }

    pub fn registry(&self) -> &Registry {
        &self.reg
    }

    /// Applies one op whole or not at all.
    pub fn apply(&mut self, s: SessionId, op: Op) -> Result<Changes, proto::Error> {
        apply::apply(self, s, op)
    }

    pub fn snapshot(&self) -> Arc<Snapshot> {
        Arc::new(Snapshot::new(
            self.state.clone(),
            self.reg.clone(),
            self.shared.clone(),
        ))
    }

    fn committed_state(&self, win: &str) -> &State {
        self.batches
            .iter()
            .find(|b| b.scope.as_deref().is_none_or(|w| w == win))
            .map(|b| &*b.frozen)
            .unwrap_or(&self.state)
    }

    /// What to render for a window: its `root` node, frozen while a batch is open.
    pub fn committed(&self, win: &str) -> Option<NodeRef<'_>> {
        NodeRef::new(
            self.committed_state(win),
            &self.reg,
            &format!("windows/{win}/root"),
        )
    }

    /// Any committed node by full path (an overlay, a slot's subtree).
    pub fn committed_node(&self, path: &str) -> Option<NodeRef<'_>> {
        let win = state::window_of(path)?;
        NodeRef::new(self.committed_state(win), &self.reg, path)
    }

    /// The window's committed overlays, in order.
    pub fn committed_overlays(&self, win: &str) -> Vec<NodeRef<'_>> {
        self.committed_node(&format!("windows/{win}/overlays"))
            .map(|o| o.children())
            .unwrap_or_default()
    }

    /// A node as it is now, batch or not.
    pub fn node(&self, path: &str) -> Option<NodeRef<'_>> {
        NodeRef::new(&self.state, &self.reg, path)
    }

    /// Window names, sorted.
    pub fn windows(&self) -> Vec<String> {
        self.state.windows.keys().cloned().collect()
    }

    /// The options the window was made with.
    pub fn window_spec(&self, win: &str) -> Option<WindowSpec> {
        let w = self.state.windows.get(win)?;
        Some(WindowSpec {
            name: w.name.clone(),
            props: w.props.clone(),
        })
    }

    /// A window file (`title`, `state`, `focus`) as stored.
    pub fn window_file(&self, win: &str, file: &str) -> Option<&[u8]> {
        self.state.win_file(win, file)
    }

    /// An app-level file: `keymap`, `clipboard`, `clipboard-files`,
    /// `theme/mode`, `theme/name`, `menus/<name>`, `assets/<name>`,
    /// `drags/<n>/data`, `theme/tokens` (the full table).
    pub fn root_file(&self, path: &str) -> Option<Bytes> {
        let snap = Snapshot::new(self.state.clone(), self.reg.clone(), self.shared.clone());
        snap.read(&FsPath::new(path))
    }

    /// Menus in menu-bar order, as `(name, item lines)`.
    pub fn menus(&self) -> Vec<(String, Bytes)> {
        self.state
            .menus
            .iter()
            .map(|(n, v)| (n.clone(), v.data.clone()))
            .collect()
    }

    /// Theme tokens the client set, on top of the mode's defaults.
    pub fn theme_overrides(&self) -> &BTreeMap<String, String> {
        &self.state.tokens
    }

    /// Fixes types for that window's committed nodes.
    pub fn frame_drawn(&mut self, win: &str) {
        let prefix = format!("windows/{win}/");
        let committed = self.committed_state(win);
        let todo: Vec<String> = self
            .state
            .nodes
            .range(prefix.clone()..)
            .take_while(|(k, _)| k.starts_with(&prefix))
            .filter(|(k, n)| !n.fixed && committed.nodes.contains_key(*k))
            .map(|(k, _)| k.clone())
            .collect();
        if todo.is_empty() {
            return;
        }
        let st = Arc::make_mut(&mut self.state);
        for p in todo {
            if let Some(n) = st.node_mut(&p) {
                n.fixed = true;
            }
        }
    }

    /// Component state -> files. `path` is a node's full path, a window dir
    /// (`windows/main`: `title`, `state`, `focus`, `bounds`), `""` for root
    /// files (`clipboard`, `clipboard-files`, `theme/mode`, `theme/name`), or
    /// `drags/<n>` (file `data`), which also creates that drag.
    ///
    /// Mirroring updates files only. Events are the host's to `emit`.
    pub fn mirror(&mut self, path: &str, file: &str, value: Bytes, via: Via) {
        let _ = via;
        if file == "bounds" {
            let v: Vec<f32> = String::from_utf8_lossy(&value)
                .split_whitespace()
                .filter_map(|x| x.parse().ok())
                .collect();
            if let [x, y, w, h] = v[..] {
                self.report_bounds(path, [x, y, w, h]);
            }
            return;
        }
        let st = Arc::make_mut(&mut self.state);
        st.generation = st.generation.wrapping_add(1);
        let fv = state::FileVal {
            data: value,
            version: st.generation,
        };
        if path.is_empty() {
            st.root_files.insert(file.to_string(), fv);
        } else if let Some(n) = path
            .strip_prefix("drags/")
            .and_then(|n| n.parse::<u64>().ok())
        {
            st.drags.insert(n, fv);
        } else if st.nodes.contains_key(path) {
            let n = st.node_mut(path).unwrap();
            n.put_file(file, fv.data, fv.version);
            n.mirrored.insert(file.to_string());
        } else if let Some(w) = path.strip_prefix("windows/").filter(|w| !w.contains('/'))
            && let Some(win) = st.windows.get_mut(w)
        {
            Arc::make_mut(win).files.insert(file.to_string(), fv);
        }
    }

    /// `x y w h` from the last layout, for a node path or a window dir.
    pub fn report_bounds(&mut self, path: &str, b: [f32; 4]) {
        self.shared
            .bounds
            .lock()
            .unwrap()
            .insert(path.to_string(), b);
    }

    /// A drag's payload, written by the client or the host.
    pub fn drag_data(&self, n: u64) -> Option<Bytes> {
        self.state.drags.get(&n).map(|v| v.data.clone())
    }

    /// The drag is over: `drags/<n>` goes away.
    pub fn drag_done(&mut self, n: u64) {
        if self.state.drags.contains_key(&n) {
            Arc::make_mut(&mut self.state).drags.remove(&n);
        }
    }

    /// The host closed a window (the user, or an answered `close` request).
    pub fn window_closed(&mut self, win: &str) -> Changes {
        let old = self.state.clone();
        let st = Arc::make_mut(&mut self.state);
        apply::remove_window(st, win);
        self.finish(&old, Vec::new())
    }

    /// The app quit: every `events` reader gets EOF, and every later op
    /// fails with `app gone`.
    pub fn app_gone(&mut self) {
        Arc::make_mut(&mut self.state).gone = true;
        self.bus.shut_down();
    }

    /// Returns the event's seq; fills `tag` (and `win` from a full node path).
    pub fn emit(&mut self, mut ev: EventMsg) -> u64 {
        // DESIGN § Two kinds of event names the state events; they coalesce
        // whatever kind the caller (or an empty catalog spec) gave.
        if ev.kind == EventKind::Action && STATE_EVENTS.contains(&ev.name.as_str()) {
            ev.kind = EventKind::State;
        }
        let (win, key, rel) = self.locate(&ev);
        let seq = self.bus.next_seq();
        let mut attrs = Vec::with_capacity(ev.attrs.len() + 4);
        if let Some(w) = &win {
            attrs.push(("win".to_string(), w.clone()));
        }
        if let Some(r) = &rel {
            attrs.push(("node".to_string(), r.clone()));
            let tag = self
                .state
                .node_file(&self.reg, &key, "tag")
                .map(|t| String::from_utf8_lossy(t).into_owned())
                .unwrap_or_default();
            attrs.push(("tag".to_string(), tag));
        }
        attrs.extend(ev.attrs.iter().cloned());
        let wants_via = ev.kind == EventKind::State
            || (ev.kind == EventKind::Request && (ev.name == "close" || ev.name == "quit"));
        if wants_via && !ev.attrs.iter().any(|(k, _)| k == "via") {
            let v = match ev.via {
                Via::Ctl => "ctl",
                Via::User => "user",
            };
            attrs.push(("via".to_string(), v.to_string()));
        }
        let line = proto::Event {
            name: ev.name.clone(),
            attrs,
        }
        .to_line(seq);
        self.bus
            .deliver(win.as_deref(), &key, &ev.name, ev.kind, line);
        seq
    }

    /// `(win, subscription key, window-relative node)` for an event.
    fn locate(&self, ev: &EventMsg) -> (Option<String>, String, Option<String>) {
        let mut win = ev.win.clone();
        let mut rel = ev.node.clone();
        if let Some(n) = &ev.node
            && n.starts_with("windows/")
        {
            win = state::window_of(n).map(str::to_string);
            rel = state::win_relative(n).map(str::to_string);
        }
        let key = match (&win, &rel) {
            (Some(w), Some(r)) => format!("windows/{w}/{r}"),
            (Some(w), None) => format!("windows/{w}"),
            _ => String::new(),
        };
        (win, key, rel)
    }

    /// Sends a request event. With no `events` file open to read it, the
    /// default applies at once (handed out by the next `tick`); otherwise
    /// the client answers on the `ctl` of the node (or window, or root) with
    /// `seq=`, or the default applies after `timeout`.
    pub fn open_request(&mut self, mut ev: EventMsg, default: Answer, timeout: Duration) -> u64 {
        ev.kind = EventKind::Request;
        let (win, key, _) = self.locate(&ev);
        let drag = if ev.name == "drop" {
            ev.attrs
                .iter()
                .find(|(k, _)| k == "drag")
                .and_then(|(_, v)| v.parse().ok())
        } else {
            None
        };
        let closes_window = match (&win, &ev.node) {
            (Some(w), None) if ev.name == "close" => Some(w.clone()),
            _ => None,
        };
        let reader = self.bus.has_reader(win.as_deref(), &key);
        let seq = self.emit(ev);
        if reader {
            self.requests.insert(
                seq,
                Request {
                    target: key,
                    default,
                    deadline: self.now() + timeout,
                    drag,
                    closes_window,
                },
            );
        } else {
            self.resolve_default(drag, closes_window.as_deref(), &default);
            self.pending.push(HostCmd::Answer {
                seq,
                answer: default,
            });
        }
        seq
    }

    /// A request's default answer applies: clear its drag, close its window.
    fn resolve_default(&mut self, drag: Option<u64>, closes_window: Option<&str>, answer: &Answer) {
        if let Some(d) = drag {
            self.drag_done(d);
        }
        if let Some(w) = closes_window.filter(|_| answer.0.verb == "close") {
            self.window_closed(w);
        }
    }

    /// Requests still waiting for an answer.
    pub fn open_requests(&self) -> Vec<u64> {
        self.requests.keys().copied().collect()
    }

    /// Batch and request timeouts, plus defaults applied since the last tick.
    /// `now` is the real clock; the tree adds its `advance_clock` skew.
    pub fn tick(&mut self, now: Instant) -> Vec<HostCmd> {
        let now = now + self.skew;
        let mut out = std::mem::take(&mut self.pending);
        let expired: Vec<u64> = self
            .requests
            .iter()
            .filter(|(_, r)| r.deadline <= now)
            .map(|(s, _)| *s)
            .collect();
        for seq in expired {
            let r = self.requests.remove(&seq).unwrap();
            self.resolve_default(r.drag, r.closes_window.as_deref(), &r.default);
            out.push(HostCmd::Answer {
                seq,
                answer: r.default,
            });
        }
        let mut i = 0;
        while i < self.batches.len() {
            if self.batches[i].started + BATCH_TIMEOUT <= now {
                let b = self.batches.remove(i);
                let wins = match &b.scope {
                    Some(w) => vec![w.clone()],
                    None => self.windows(),
                };
                let who = b
                    .scope
                    .as_deref()
                    .map(|w| format!(" win={w}"))
                    .unwrap_or_default();
                self.shared
                    .trace
                    .lock()
                    .unwrap()
                    .push(format!("batch timeout{who}"));
                for w in wins {
                    if !self.is_frozen(&w) {
                        out.push(HostCmd::Redraw { win: w });
                    }
                }
            } else {
                i += 1;
            }
        }
        out
    }

    pub fn bus(&self) -> &EventBus {
        &self.bus
    }

    fn is_frozen(&self, win: &str) -> bool {
        self.batches
            .iter()
            .any(|b| b.scope.as_deref().is_none_or(|w| w == win))
    }

    /// Diffs `old` against the current state, updates the bus's live
    /// targets, and builds `Changes`.
    fn finish(&mut self, old: &State, host: Vec<HostCmd>) -> Changes {
        let mut ch = apply::diff(old, &self.state);
        for p in &ch.created {
            self.bus.add_live(p);
        }
        for p in &ch.removed {
            self.bus.remove_live(p);
            self.shared.bounds.lock().unwrap().remove(p);
        }
        let frozen: Vec<String> = ch
            .dirty_windows
            .iter()
            .filter(|w| self.is_frozen(w))
            .cloned()
            .collect();
        ch.dirty_windows.retain(|w| !frozen.contains(w));
        ch.host = host;
        ch
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StatKind {
    Dir,
    Ctl,
    Text,
    Data,
    Events,
    ReadOnly,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stat {
    pub name: String,
    pub kind: StatKind,
    pub len: u64,
    /// Bumped on every change, for the 9P qid version.
    pub version: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubEnd {
    /// After `gone`, or when the app quits.
    Eof,
    /// `max` is smaller than the next line.
    ShortRead,
}
