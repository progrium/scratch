//! The model the whole system shares: nodes, the type registry, ops,
//! snapshots, batches, the event bus and requests. Pure, no GPUI. Owned by W2.
#![allow(unused_variables, dead_code)]

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub use bytes::Bytes;
pub use catalog::EventKind;

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
    Write { path: FsPath, data: Bytes },
    Append { path: FsPath, data: Bytes },
    Mkdir { path: FsPath },
    Remove { path: FsPath },
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

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WindowSpec {
    pub name: String,
    /// The `window` verb's options (`title=`, `size=`, ...).
    pub props: Vec<(String, String)>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Changes {
    pub dirty_windows: Vec<String>,
    pub created: Vec<String>,
    pub removed: Vec<String>,
    /// `(node path, prop file)` pairs whose value changed.
    pub props: Vec<(String, String)>,
    pub host: Vec<HostCmd>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostCmd {
    Window(WindowSpec),
    WindowCtl { win: String, cmd: proto::Command },
    Quit,
    Menus,
    Keymap,
    Theme,
    SetAction { id: String, enabled: Option<bool>, check: Option<bool> },
    Overlay { win: String, name: String, open: bool },
    Focus { win: String, node: String },
    Clipboard,
    ComponentVerb { node: String, cmd: proto::Command },
    Answer { seq: u64, answer: Answer },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventMsg {
    pub kind: EventKind,
    pub name: String,
    pub win: Option<String>,
    /// Window-relative (`root/prefs/ok/save`); `None` for app-level events.
    pub node: Option<String>,
    pub attrs: Vec<(String, String)>,
    pub via: Via,
}

/// A borrowed view of one committed node, for the renderer.
#[derive(Debug, Clone, Copy)]
pub struct NodeRef<'a> {
    tree: &'a Tree,
    path: &'a str,
}

impl<'a> NodeRef<'a> {
    pub fn path(&self) -> &'a str {
        self.path
    }
    pub fn ty(&self) -> &'a str {
        todo!("W2")
    }
    pub fn name(&self) -> &'a str {
        todo!("W2")
    }
    /// A prop file's stored bytes.
    pub fn prop(&self, file: &str) -> Option<&'a [u8]> {
        todo!("W2")
    }
    /// Children in `order`.
    pub fn children(&self) -> Vec<NodeRef<'a>> {
        todo!("W2")
    }
}

/// The tree. Main-thread only.
#[derive(Debug)]
pub struct Tree {
    reg: Registry,
}

impl Tree {
    pub fn new(reg: Registry) -> Self {
        todo!("W2")
    }
    /// Applies one op whole or not at all.
    pub fn apply(&mut self, s: SessionId, op: Op) -> Result<Changes, proto::Error> {
        todo!("W2")
    }
    pub fn snapshot(&self) -> Arc<Snapshot> {
        todo!("W2")
    }
    /// What to render for a window (frozen while a batch is open).
    pub fn committed(&self, win: &str) -> Option<NodeRef<'_>> {
        todo!("W2")
    }
    /// Fixes types and closes timeouts for that window.
    pub fn frame_drawn(&mut self, win: &str) {
        todo!("W2")
    }
    /// Component state -> files.
    pub fn mirror(&mut self, node: &str, file: &str, value: Bytes, via: Via) {
        todo!("W2")
    }
    pub fn report_bounds(&mut self, node: &str, b: [f32; 4]) {
        todo!("W2")
    }
    /// Returns the event's seq; fills `tag` and `win`.
    pub fn emit(&mut self, ev: EventMsg) -> u64 {
        todo!("W2")
    }
    pub fn open_request(&mut self, ev: EventMsg, default: Answer, timeout: Duration) -> u64 {
        todo!("W2")
    }
    /// Batch and request timeouts.
    pub fn tick(&mut self, now: Instant) -> Vec<HostCmd> {
        todo!("W2")
    }
    pub fn bus(&self) -> &EventBus {
        todo!("W2")
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

/// An immutable view of the tree after a batch of ops. `Send + Sync`.
#[derive(Debug, Default)]
pub struct Snapshot {}

impl Snapshot {
    pub fn stat(&self, p: &FsPath) -> Option<Stat> {
        todo!("W2")
    }
    pub fn readdir(&self, p: &FsPath) -> Option<Vec<Stat>> {
        todo!("W2")
    }
    pub fn read(&self, p: &FsPath) -> Option<Bytes> {
        todo!("W2")
    }
}

/// Subscriptions per app, window and node. Thread-safe.
#[derive(Debug, Default)]
pub struct EventBus {}

impl EventBus {
    /// One subscription per open of an `events` file.
    pub fn subscribe(&self, events_file: &FsPath) -> Result<Subscription, proto::Error> {
        todo!("W2")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubEnd {
    /// After `gone`, or when the app quits.
    Eof,
    /// `max` is smaller than the next line.
    ShortRead,
}

/// One open `events` file. `Send`.
#[derive(Debug)]
pub struct Subscription {}

impl Subscription {
    /// Whole lines only, at most `max` bytes. Blocks until a line is ready.
    pub async fn read(&mut self, max: usize) -> Result<Bytes, SubEnd> {
        todo!("W2")
    }
}
