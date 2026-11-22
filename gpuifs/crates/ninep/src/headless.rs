//! A `Tree` on its own thread behind `FsBackend`, with a fake clock and
//! frame control, and `/debug` for driving and observing the host side.
//!
//! The thread owns the tree. Ops arrive on a channel, are applied in order,
//! and the new snapshot is published before the op is acknowledged, so a read
//! after a write sees it. Subscriptions come straight from a clone of the
//! tree's event bus, with no round trip.
//!
//! **Frames.** By default headless draws no frames on its own, so `type`
//! stays writable until a script says a frame happened (`frame` below); this
//! keeps conformance runs deterministic. [`Options::auto_frames`] draws one
//! every 16 ms, like a real host.
//!
//! **Clock.** The tree is ticked every 16 ms with a fake clock: real time plus
//! whatever `tick SECONDS` has added, so batch and request timeouts run in
//! real time and a script can skip ahead without sleeping.
//!
//! **Host commands** are what the GPUI host would act on. Headless acts on
//! those that change the tree or the app's life (`quit`, a window `close`
//! request and its answer, a drop's answer) and logs every one to `/debug/log`.
//!
//! ## `/debug` (headless only)
//!
//! `/debug/inject` takes lines in `ctl` syntax, applied in order as if the
//! user did it in the UI (tests/conformance/README.md § `/debug/inject`).
//! Nothing written here appears in `trace`.
//!
//! ```text
//! event NAME [win=W] [node=PATH] [attr=value ...] [default=VERB]
//!         Tree::emit, or open_request when the node's TypeSpec says NAME is a
//!         request (or, with no node, NAME is close or quit). node= is
//!         window-relative. default= picks a request's default answer
//!         (otherwise drop->refuse, NAME->NAME).
//! mirror [win=W] [node=PATH] file=NAME value=TEXT
//!         Tree::mirror(..., Via::User). No event. With no node=, a window
//!         file; with no win= either, a root file.
//! bounds win=W [node=PATH] value='x y w h'
//! frame [win=W]          Tree::frame_drawn for one window, or every window
//! tick SECONDS           advance the fake clock, then Tree::tick
//! drag n=N [type=TYPE] data=TEXT
//!         make /drags/N/data hold TEXT, as a platform drag would
//! ```
//!
//! `/debug/log` reads back one line per host command and injected event:
//! `window main title=Hi`, `ctl main notify Saved`, `answer seq=7 close`,
//! `event click seq=12`, `quit`, ...

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use proto::{Command, Error, ErrorKind};
use tree::{Answer, EventBus, EventKind, EventMsg, FsPath, HostCmd, Op, SessionId, Snapshot, Stat, StatKind, Tree, Via};

use crate::FsBackend;

/// The frame and tick interval.
pub const FRAME: Duration = Duration::from_millis(16);
/// How long a request waits for an answer.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
/// Lines kept in `/debug/log`.
const LOG_LINES: usize = 10_000;

const DEBUG: &str = "debug";
const INJECT: &str = "debug/inject";
const LOG: &str = "debug/log";

#[derive(Debug, Clone, Default)]
pub struct Options {
    /// Draw a frame every 16 ms for every window, as a real host does.
    /// Off by default, so `type` stays writable until `frame` is injected.
    pub auto_frames: bool,
}

enum Msg {
    Apply { s: SessionId, op: Op, reply: futures::channel::oneshot::Sender<Result<(), Error>> },
}

struct Shared {
    snap: Mutex<Arc<Snapshot>>,
    gone: AtomicBool,
    log: Mutex<VecDeque<String>>,
    quit_waiters: Mutex<Vec<futures::channel::oneshot::Sender<()>>>,
}

impl Shared {
    fn log(&self, line: String) {
        let mut l = self.log.lock().unwrap();
        if l.len() >= LOG_LINES {
            l.pop_front();
        }
        l.push_back(line);
    }
    fn set_gone(&self) {
        let mut w = self.quit_waiters.lock().unwrap();
        if !self.gone.swap(true, Ordering::SeqCst) {
            for w in w.drain(..) {
                let _ = w.send(());
            }
        }
    }
}

pub struct HeadlessBackend {
    tx: mpsc::Sender<Msg>,
    bus: EventBus,
    shared: Arc<Shared>,
    next_session: AtomicU32,
}

impl HeadlessBackend {
    pub fn new(reg: tree::Registry) -> Arc<Self> {
        Self::with_options(reg, Options::default())
    }

    pub fn with_options(reg: tree::Registry, opts: Options) -> Arc<Self> {
        let (tx, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("gpuifs-tree".into())
            .spawn(move || {
                let tree = Tree::new(reg);
                let shared = Arc::new(Shared {
                    snap: Mutex::new(tree.snapshot()),
                    gone: AtomicBool::new(false),
                    log: Mutex::new(VecDeque::new()),
                    quit_waiters: Mutex::new(Vec::new()),
                });
                let _ = ready_tx.send((shared.clone(), tree.bus().clone()));
                TreeThread { tree, shared, opts, requests: HashMap::new(), skew: Duration::ZERO, dirty: BTreeSet::new() }
                    .run(rx);
            })
            .expect("spawn tree thread");
        let (shared, bus) = ready_rx.recv().expect("tree thread started");
        Arc::new(HeadlessBackend { tx, bus, shared, next_session: AtomicU32::new(1) })
    }

    /// Resolves when the app quits (`quit` on the root `ctl`, or an answered
    /// or defaulted `quit` request).
    pub async fn wait_gone(&self) {
        let rx = {
            let mut w = self.shared.quit_waiters.lock().unwrap();
            if self.shared.gone.load(Ordering::SeqCst) {
                return;
            }
            let (tx, rx) = futures::channel::oneshot::channel();
            w.push(tx);
            rx
        };
        let _ = rx.await;
    }

    /// The `/debug/log` lines so far.
    pub fn log(&self) -> Vec<String> {
        self.shared.log.lock().unwrap().iter().cloned().collect()
    }
}

fn debug_stat(p: &FsPath) -> Option<Stat> {
    let (name, kind) = match p.as_str() {
        DEBUG => ("debug", StatKind::Dir),
        INJECT => ("inject", StatKind::Ctl),
        LOG => ("log", StatKind::ReadOnly),
        _ => return None,
    };
    Some(Stat { name: name.into(), kind, len: 0, version: 0 })
}

const INJECT_USAGE: &str = "event NAME [win=W] [node=PATH] [attr=value ...] [default=VERB]
mirror [win=W] [node=PATH] file=NAME value=TEXT
bounds win=W [node=PATH] value='x y w h'
frame [win=W]
tick SECONDS
drag n=N [type=TYPE] data=TEXT
";

#[async_trait::async_trait]
impl FsBackend for HeadlessBackend {
    fn snapshot(&self) -> Arc<Snapshot> {
        self.shared.snap.lock().unwrap().clone()
    }

    async fn apply(&self, s: SessionId, op: Op) -> Result<(), Error> {
        let (reply, rx) = futures::channel::oneshot::channel();
        if self.tx.send(Msg::Apply { s, op, reply }).is_err() {
            return Err(gone_err());
        }
        rx.await.unwrap_or_else(|_| Err(gone_err()))
    }

    fn subscribe(&self, events_file: &FsPath) -> Result<tree::Subscription, Error> {
        if self.is_gone() {
            return Err(gone_err());
        }
        self.bus.subscribe(events_file)
    }

    fn new_session(&self) -> SessionId {
        SessionId(self.next_session.fetch_add(1, Ordering::Relaxed))
    }

    fn extra_stat(&self, p: &FsPath) -> Option<Stat> {
        let mut st = debug_stat(p)?;
        if st.kind != StatKind::Dir {
            st.len = self.extra_read(p).map(|b| b.len() as u64).unwrap_or(0);
        }
        Some(st)
    }

    fn extra_readdir(&self, p: &FsPath) -> Vec<Stat> {
        match p.as_str() {
            "" => debug_stat(&FsPath::new(DEBUG)).into_iter().collect(),
            DEBUG => [INJECT, LOG].iter().filter_map(|f| self.extra_stat(&FsPath::new(*f))).collect(),
            _ => Vec::new(),
        }
    }

    fn extra_read(&self, p: &FsPath) -> Option<Bytes> {
        match p.as_str() {
            INJECT => Some(Bytes::from_static(INJECT_USAGE.as_bytes())),
            LOG => {
                let l = self.shared.log.lock().unwrap();
                let mut s = String::new();
                for line in l.iter() {
                    s.push_str(line);
                    s.push('\n');
                }
                Some(Bytes::from(s))
            }
            _ => None,
        }
    }

    fn is_gone(&self) -> bool {
        self.shared.gone.load(Ordering::SeqCst)
    }
}

/// A request whose answer headless acts on.
struct PendingRequest {
    win: Option<String>,
    name: String,
    drag: Option<u64>,
}

struct TreeThread {
    tree: Tree,
    shared: Arc<Shared>,
    opts: Options,
    requests: HashMap<u64, PendingRequest>,
    /// Added to real time by `tick SECONDS`. The tree stamps deadlines with
    /// real time, so a request opened now gets its timeout plus the skew.
    skew: Duration,
    dirty: BTreeSet<String>,
}

fn gone_err() -> Error {
    Error::new(ErrorKind::AppGone, "")
}

fn fmt_cmd(c: &Command) -> String {
    let mut s = c.verb.clone();
    for a in &c.args {
        s.push(' ');
        s.push_str(&proto::quote(a));
    }
    for (k, v) in &c.props {
        s.push(' ');
        s.push_str(k);
        s.push('=');
        s.push_str(&proto::quote(v));
    }
    s
}

fn fmt_host(h: &HostCmd) -> String {
    match h {
        HostCmd::Window(w) => {
            let mut s = format!("window {}", w.name);
            for (k, v) in &w.props {
                s.push_str(&format!(" {k}={}", proto::quote(v)));
            }
            s
        }
        HostCmd::WindowCtl { win, cmd } => format!("ctl {win} {}", fmt_cmd(cmd)),
        HostCmd::Quit => "quit".into(),
        HostCmd::Menus => "menus".into(),
        HostCmd::Keymap => "keymap".into(),
        HostCmd::Theme => "theme".into(),
        HostCmd::SetAction { id, enabled, check } => {
            let mut s = format!("set {id}");
            if let Some(e) = enabled {
                s.push_str(if *e { " enabled=on" } else { " enabled=off" });
            }
            if let Some(c) = check {
                s.push_str(if *c { " check=on" } else { " check=off" });
            }
            s
        }
        HostCmd::Overlay { win, name, open } => {
            format!("overlay {win} {name} {}", if *open { "open" } else { "closed" })
        }
        HostCmd::Focus { win, node } => format!("focus {win} {node}"),
        HostCmd::Clipboard => "clipboard".into(),
        HostCmd::ComponentVerb { node, cmd } => format!("verb {node} {}", fmt_cmd(cmd)),
        HostCmd::Answer { seq, answer } => format!("answer seq={seq} {}", fmt_cmd(&answer.0)),
        HostCmd::Redraw { win } => format!("redraw {win}"),
        HostCmd::ThemeLoad { path } => format!("theme load {}", proto::quote(path)),
    }
}

fn default_answer_verb(name: &str) -> String {
    match name {
        "drop" => "refuse".into(),
        n => n.into(),
    }
}

fn prop<'a>(c: &'a Command, k: &str) -> Option<&'a str> {
    c.props.iter().find(|(pk, _)| pk == k).map(|(_, v)| v.as_str())
}

fn need<'a>(c: &'a Command, k: &str) -> Result<&'a str, Error> {
    prop(c, k).ok_or_else(|| Error::new(ErrorKind::BadSyntax, format!("{}: needs {k}=", c.verb)))
}

/// The full path for `win=` and `node=`: a node, a window dir, or `""`.
fn target(c: &Command) -> Result<String, Error> {
    match (prop(c, "win"), prop(c, "node")) {
        (_, Some(n)) if n.starts_with("windows/") => Ok(n.trim_matches('/').to_string()),
        (Some(w), Some(n)) => Ok(format!("windows/{w}/{}", n.trim_matches('/'))),
        (Some(w), None) => Ok(format!("windows/{w}")),
        (None, Some(n)) => Err(Error::new(ErrorKind::BadSyntax, format!("node={n} needs win="))),
        (None, None) => Ok(String::new()),
    }
}

/// `windows/W/...` with something after the window: a node.
fn is_node_path(p: &str) -> bool {
    p.starts_with("windows/") && p.matches('/').count() >= 2
}

impl TreeThread {
    fn run(mut self, rx: mpsc::Receiver<Msg>) {
        let mut last = Instant::now();
        loop {
            let wait = FRAME.saturating_sub(last.elapsed());
            match rx.recv_timeout(wait) {
                Ok(Msg::Apply { s, op, reply }) => {
                    let r = self.apply(s, op);
                    self.publish();
                    let _ = reply.send(r);
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
            if last.elapsed() >= FRAME {
                if self.opts.auto_frames {
                    for w in std::mem::take(&mut self.dirty) {
                        self.tree.frame_drawn(&w);
                    }
                }
                self.tick();
                self.publish();
                last = Instant::now();
            }
        }
    }

    fn gone(&self) -> bool {
        self.shared.gone.load(Ordering::SeqCst)
    }

    fn publish(&self) {
        *self.shared.snap.lock().unwrap() = self.tree.snapshot();
    }

    fn now(&self) -> Instant {
        Instant::now() + self.skew
    }

    fn apply(&mut self, s: SessionId, op: Op) -> Result<(), Error> {
        if self.gone() {
            return Err(gone_err());
        }
        match &op {
            Op::Write { path, data } | Op::Append { path, data } if path.as_str() == INJECT => {
                return self.inject(data);
            }
            Op::Write { path, .. } | Op::Append { path, .. } | Op::Mkdir { path } | Op::Remove { path }
                if path.as_str() == DEBUG || path.as_str().starts_with("debug/") =>
            {
                return Err(Error::new(ErrorKind::BadValue, format!("{path} is fixed")));
            }
            _ => {}
        }
        let changes = self.tree.apply(s, op)?;
        self.dirty.extend(changes.dirty_windows.iter().cloned());
        self.host(changes.host);
        // Request defaults with no reader are handed out by tick; act now.
        let cmds = self.tree.tick(self.now());
        self.host(cmds);
        Ok(())
    }

    fn tick(&mut self) {
        if self.gone() {
            return;
        }
        let cmds = self.tree.tick(self.now());
        self.host(cmds);
    }

    /// Acts on host commands the way the GPUI host would, where that changes
    /// the tree or the app's life; logs all of them.
    fn host(&mut self, cmds: Vec<HostCmd>) {
        let mut queue: VecDeque<HostCmd> = cmds.into();
        while let Some(h) = queue.pop_front() {
            if self.gone() {
                return;
            }
            self.shared.log(fmt_host(&h));
            match h {
                HostCmd::Quit => self.quit(),
                HostCmd::Window(w) => {
                    self.dirty.insert(w.name);
                }
                HostCmd::Redraw { win } => {
                    self.dirty.insert(win);
                }
                HostCmd::WindowCtl { win, cmd } if cmd.verb == "close" => {
                    // Asking to close, as the close button does: a request.
                    let ev = EventMsg::new(EventKind::Request, "close").win(&win).attr("via", "ctl");
                    let seq = self.tree.open_request(ev, Answer::verb("close"), REQUEST_TIMEOUT + self.skew);
                    self.requests.insert(seq, PendingRequest { win: Some(win), name: "close".into(), drag: None });
                    queue.extend(self.tree.tick(self.now()));
                }
                HostCmd::Answer { seq, answer } => {
                    let Some(req) = self.requests.remove(&seq) else { continue };
                    if let Some(d) = req.drag {
                        self.tree.drag_done(d);
                    }
                    match (req.name.as_str(), answer.0.verb.as_str(), req.win) {
                        ("close", "close", Some(w)) => {
                            let c = self.tree.window_closed(&w);
                            self.dirty.remove(&w);
                            queue.extend(c.host);
                        }
                        ("quit", "quit", None) => self.quit(),
                        _ => {}
                    }
                }
                _ => {}
            }
        }
    }

    fn quit(&mut self) {
        self.tree.app_gone();
        self.requests.clear();
        self.publish();
        self.shared.set_gone();
    }

    fn spec_kind(&self, path: &str, name: &str) -> Option<EventKind> {
        let spec = self.tree.node(path)?.spec()?;
        spec.events.iter().find(|e| e.name == name).map(|e| e.kind)
    }

    fn inject(&mut self, data: &[u8]) -> Result<(), Error> {
        let cmds = proto::parse_ctl(data)?;
        // Check every line before applying any, as a ctl write does.
        for c in &cmds {
            target(c)?;
            let ok = match c.verb.as_str() {
                "event" => c.args.len() == 1,
                "mirror" => c.args.is_empty() && prop(c, "file").is_some() && prop(c, "value").is_some(),
                "bounds" => {
                    let v = need(c, "value")?;
                    let ok = v.split_whitespace().filter(|x| x.parse::<f32>().is_ok()).count() == 4
                        && v.split_whitespace().count() == 4;
                    if !ok {
                        return Err(Error::new(ErrorKind::BadValue, format!("value={v}")));
                    }
                    c.args.is_empty() && prop(c, "win").is_some()
                }
                "frame" => c.args.is_empty(),
                "tick" => match &c.args[..] {
                    [s] => match s.parse::<f64>() {
                        Ok(v) if v >= 0.0 && v.is_finite() => true,
                        _ => return Err(Error::new(ErrorKind::BadValue, s.clone())),
                    },
                    _ => false,
                },
                "drag" => {
                    let n = need(c, "n")?;
                    n.parse::<u64>().map_err(|_| Error::new(ErrorKind::BadValue, format!("n={n}")))?;
                    need(c, "data")?;
                    c.args.is_empty()
                }
                v => return Err(Error::new(ErrorKind::UnknownCommand, v.to_string())),
            };
            if !ok {
                let usage = INJECT_USAGE.lines().find(|l| l.starts_with(c.verb.as_str())).unwrap_or("");
                return Err(Error::new(ErrorKind::BadSyntax, usage.to_string()));
            }
        }
        for c in cmds {
            if self.gone() {
                return Err(gone_err());
            }
            self.inject_one(c);
        }
        Ok(())
    }

    fn inject_one(&mut self, c: Command) {
        match c.verb.as_str() {
            "event" => {
                let name = c.args[0].clone();
                let path = target(&c).unwrap();
                let node = is_node_path(&path);
                let mut ev = EventMsg::new(EventKind::Action, &name);
                if let Some(w) = prop(&c, "win") {
                    ev = ev.win(w);
                }
                if node {
                    ev = ev.node(&path);
                }
                let mut default = None;
                for (k, v) in &c.props {
                    match k.as_str() {
                        "win" | "node" => {}
                        "default" => default = Some(v.clone()),
                        _ => ev.attrs.push((k.clone(), v.clone())),
                    }
                }
                let kind = if node {
                    self.spec_kind(&path, &name).unwrap_or(EventKind::Action)
                } else if matches!(name.as_str(), "close" | "quit") {
                    EventKind::Request
                } else if matches!(name.as_str(), "state" | "resize" | "move") {
                    EventKind::State
                } else {
                    EventKind::Action
                };
                let seq = if kind == EventKind::Request {
                    let drag = ev.attrs.iter().find(|(k, _)| k == "drag").and_then(|(_, v)| v.parse().ok());
                    let verb = default.unwrap_or_else(|| default_answer_verb(&name));
                    let win = prop(&c, "win").map(str::to_string);
                    let seq = self.tree.open_request(ev, Answer::verb(&verb), REQUEST_TIMEOUT + self.skew);
                    if !node || drag.is_some() {
                        self.requests.insert(seq, PendingRequest { win, name: name.clone(), drag });
                    }
                    seq
                } else {
                    ev.kind = kind;
                    self.tree.emit(ev)
                };
                self.shared.log(format!("event {name} seq={seq}"));
                let cmds = self.tree.tick(self.now());
                self.host(cmds);
            }
            "mirror" => {
                let path = target(&c).unwrap();
                let value = Bytes::from(prop(&c, "value").unwrap().to_string());
                self.tree.mirror(&path, prop(&c, "file").unwrap(), value, Via::User);
            }
            "bounds" => {
                let path = target(&c).unwrap();
                let v: Vec<f32> = prop(&c, "value").unwrap().split_whitespace().map(|x| x.parse().unwrap()).collect();
                self.tree.report_bounds(&path, [v[0], v[1], v[2], v[3]]);
            }
            "frame" => match prop(&c, "win") {
                Some(w) => {
                    self.dirty.remove(w);
                    self.tree.frame_drawn(w);
                }
                None => {
                    self.dirty.clear();
                    for w in self.tree.windows() {
                        self.tree.frame_drawn(&w);
                    }
                }
            },
            "tick" => {
                let s: f64 = c.args[0].parse().unwrap();
                self.skew += Duration::from_secs_f64(s);
                self.tick();
            }
            "drag" => {
                let n = prop(&c, "n").unwrap();
                let data = Bytes::from(prop(&c, "data").unwrap().to_string());
                self.tree.mirror(&format!("drags/{n}"), "data", data, Via::User);
            }
            _ => unreachable!("checked above"),
        }
    }
}
