//! A `Tree` on its own thread behind `FsBackend`, with a fake frame clock and
//! `/debug` for driving and observing the host side.
//!
//! The thread owns the tree. Ops arrive on a channel, are applied in order,
//! and the new snapshot is published before the op is acknowledged, so a read
//! after a write sees it. Every 16 ms the thread "draws a frame": it calls
//! `frame_drawn` for each window dirtied since the last one (which fixes
//! `type` and closes batch timeouts) and `tick`s the tree.
//!
//! Host commands are what the GPUI host would act on. Headless acts on the few
//! that change the tree or the app's life (`quit`, a window `close` request and
//! its answer) and logs every one to `/debug/log`.
//!
//! ## `/debug` (headless only)
//!
//! `/debug/inject` takes one command per line, in `ctl` quoting, applied as if
//! the user did it in the UI:
//!
//! ```text
//! event NAME TARGET [k=v ...] [default=VERB]   emit an event; TARGET is `-` (app),
//!                                             windows/WIN, or windows/WIN/root/...
//!                                             Requests (by the node type's spec, or
//!                                             close/quit/drop/complete) open with
//!                                             the 5 s default; default= picks its verb
//! mirror FILE VALUE                           component state -> file, via=user
//! bounds NODE X Y W H                         as reported after layout
//! frame [WIN]                                 draw a frame now (all dirty windows)
//! tick                                        run batch and request timeouts now
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
use tree::{Answer, EventKind, EventMsg, FsPath, HostCmd, Op, SessionId, Snapshot, Stat, StatKind, Tree, Via};

use crate::FsBackend;

/// The fake frame interval.
pub const FRAME: Duration = Duration::from_millis(16);
/// How long a request waits for an answer.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
/// Lines kept in `/debug/log`.
const LOG_LINES: usize = 10_000;

const DEBUG: &str = "debug";
const INJECT: &str = "debug/inject";
const LOG: &str = "debug/log";

/// The session headless uses for its own follow-up ops (destroying a window
/// after its `close` request is answered).
const HOST_SESSION: SessionId = SessionId(0);

enum Msg {
    Apply { s: SessionId, op: Op, reply: futures::channel::oneshot::Sender<Result<(), Error>> },
    Subscribe { path: FsPath, reply: mpsc::Sender<Result<tree::Subscription, Error>> },
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
        if !self.gone.swap(true, Ordering::SeqCst) {
            for w in self.quit_waiters.lock().unwrap().drain(..) {
                let _ = w.send(());
            }
        }
    }
}

pub struct HeadlessBackend {
    tx: mpsc::Sender<Msg>,
    shared: Arc<Shared>,
    next_session: AtomicU32,
}

impl HeadlessBackend {
    pub fn new(reg: tree::Registry) -> Arc<Self> {
        let (tx, rx) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::channel();
        let shared_slot: Arc<Mutex<Option<Arc<Shared>>>> = Arc::new(Mutex::new(None));
        let slot = shared_slot.clone();
        std::thread::Builder::new()
            .name("gpuifs-tree".into())
            .spawn(move || {
                let tree = Tree::new(reg.clone());
                let shared = Arc::new(Shared {
                    snap: Mutex::new(tree.snapshot()),
                    gone: AtomicBool::new(false),
                    log: Mutex::new(VecDeque::new()),
                    quit_waiters: Mutex::new(Vec::new()),
                });
                *slot.lock().unwrap() = Some(shared.clone());
                let _ = ready_tx.send(());
                TreeThread { tree: Some(tree), reg, shared, dirty: BTreeSet::new(), requests: HashMap::new() }.run(rx);
            })
            .expect("spawn tree thread");
        ready_rx.recv().expect("tree thread started");
        let shared = shared_slot.lock().unwrap().take().unwrap();
        Arc::new(HeadlessBackend { tx, shared, next_session: AtomicU32::new(1) })
    }

    /// Resolves when the app quits (`quit` on the root `ctl`, or an answered
    /// or defaulted `quit` request).
    pub async fn wait_gone(&self) {
        if self.shared.gone.load(Ordering::SeqCst) {
            return;
        }
        let (tx, rx) = futures::channel::oneshot::channel();
        self.shared.quit_waiters.lock().unwrap().push(tx);
        if self.shared.gone.load(Ordering::SeqCst) {
            return;
        }
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

#[async_trait::async_trait]
impl FsBackend for HeadlessBackend {
    fn snapshot(&self) -> Arc<Snapshot> {
        self.shared.snap.lock().unwrap().clone()
    }

    async fn apply(&self, s: SessionId, op: Op) -> Result<(), Error> {
        let (reply, rx) = futures::channel::oneshot::channel();
        if self.tx.send(Msg::Apply { s, op, reply }).is_err() {
            return Err(Error::new(ErrorKind::AppGone, ""));
        }
        rx.await.unwrap_or_else(|_| Err(Error::new(ErrorKind::AppGone, "")))
    }

    fn subscribe(&self, events_file: &FsPath) -> Result<tree::Subscription, Error> {
        let (reply, rx) = mpsc::channel();
        self.tx
            .send(Msg::Subscribe { path: events_file.clone(), reply })
            .map_err(|_| Error::new(ErrorKind::AppGone, ""))?;
        rx.recv().unwrap_or_else(|_| Err(Error::new(ErrorKind::AppGone, "")))
    }

    fn new_session(&self) -> SessionId {
        SessionId(self.next_session.fetch_add(1, Ordering::Relaxed))
    }

    fn extra_stat(&self, p: &FsPath) -> Option<Stat> {
        let mut st = debug_stat(p)?;
        if p.as_str() == LOG {
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
            INJECT => Some(Bytes::from_static(
                b"event NAME TARGET [k=v ...] [default=VERB]\nmirror FILE VALUE\nbounds NODE X Y W H\nframe [WIN]\ntick\n",
            )),
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

struct PendingRequest {
    win: Option<String>,
    name: String,
}

struct TreeThread {
    /// `None` once the app has quit: dropping the tree ends every subscription.
    tree: Option<Tree>,
    reg: tree::Registry,
    shared: Arc<Shared>,
    dirty: BTreeSet<String>,
    requests: HashMap<u64, PendingRequest>,
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
    }
}

/// Splits `windows/WIN[/rest]` into the window and the window-relative node.
fn split_target(t: &str) -> Result<(Option<String>, Option<String>), Error> {
    if t == "-" || t.is_empty() {
        return Ok((None, None));
    }
    let t = t.trim_matches('/');
    let mut it = t.splitn(3, '/');
    match (it.next(), it.next(), it.next()) {
        (Some("windows"), Some(w), rest) if !w.is_empty() => Ok((Some(w.to_string()), rest.map(str::to_string))),
        _ => Err(Error::new(ErrorKind::NotFound, format!("{t}: want - or windows/WIN[/node]"))),
    }
}

fn default_answer_verb(name: &str) -> &'static str {
    match name {
        "close" => "close",
        "quit" => "quit",
        "drop" => "refuse",
        _ => "keep",
    }
}

impl TreeThread {
    fn run(mut self, rx: mpsc::Receiver<Msg>) {
        let mut last_frame = Instant::now();
        loop {
            let wait = FRAME.saturating_sub(last_frame.elapsed());
            match rx.recv_timeout(wait) {
                Ok(Msg::Apply { s, op, reply }) => {
                    let r = self.apply(s, op);
                    self.publish();
                    let _ = reply.send(r);
                }
                Ok(Msg::Subscribe { path, reply }) => {
                    let r = match self.tree.as_ref() {
                        Some(t) => t.bus().subscribe(&path),
                        None => Err(gone_err()),
                    };
                    let _ = reply.send(r);
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
            if last_frame.elapsed() >= FRAME {
                self.frame(None);
                self.tick();
                self.publish();
                last_frame = Instant::now();
            }
        }
    }

    fn publish(&self) {
        if let Some(t) = self.tree.as_ref() {
            *self.shared.snap.lock().unwrap() = t.snapshot();
        }
    }

    fn apply(&mut self, s: SessionId, op: Op) -> Result<(), Error> {
        if self.tree.is_none() {
            return Err(gone_err());
        }
        if let Op::Write { path, data } | Op::Append { path, data } = &op {
            if path.as_str() == INJECT {
                return self.inject(data);
            }
            if path.as_str().starts_with("debug/") || path.as_str() == DEBUG {
                return Err(Error::new(ErrorKind::BadValue, format!("{path} is read-only")));
            }
        }
        if matches!(&op, Op::Mkdir { path } | Op::Remove { path } if path.as_str().starts_with("debug")) {
            return Err(Error::new(ErrorKind::BadValue, "debug is fixed"));
        }
        let changes = self.tree.as_mut().unwrap().apply(s, op)?;
        self.dirty.extend(changes.dirty_windows.iter().cloned());
        self.host(changes.host);
        Ok(())
    }

    fn frame(&mut self, win: Option<&str>) {
        let Some(t) = self.tree.as_mut() else { return };
        match win {
            Some(w) => {
                self.dirty.remove(w);
                t.frame_drawn(w);
            }
            None => {
                for w in std::mem::take(&mut self.dirty) {
                    t.frame_drawn(&w);
                }
            }
        }
    }

    fn tick(&mut self) {
        let Some(t) = self.tree.as_mut() else { return };
        let cmds = t.tick(Instant::now());
        self.host(cmds);
    }

    /// Acts on host commands the way the GPUI host would, where that changes
    /// the tree or the app's life; logs all of them.
    fn host(&mut self, cmds: Vec<HostCmd>) {
        let mut queue: VecDeque<HostCmd> = cmds.into();
        while let Some(h) = queue.pop_front() {
            self.shared.log(fmt_host(&h));
            let Some(t) = self.tree.as_mut() else { return };
            match h {
                HostCmd::Quit => {
                    self.quit();
                    return;
                }
                HostCmd::Window(w) => {
                    self.dirty.insert(w.name);
                }
                HostCmd::WindowCtl { win, cmd } if cmd.verb == "close" && cmd.props.iter().all(|(k, _)| k != "seq") => {
                    let ev = EventMsg {
                        kind: EventKind::Request,
                        name: "close".into(),
                        win: Some(win.clone()),
                        node: None,
                        attrs: Vec::new(),
                        via: Via::Ctl,
                    };
                    let default = Answer(Command { verb: "close".into(), ..Default::default() });
                    let seq = t.open_request(ev, default, REQUEST_TIMEOUT);
                    self.requests.insert(seq, PendingRequest { win: Some(win), name: "close".into() });
                }
                HostCmd::Answer { seq, answer } => {
                    let Some(req) = self.requests.remove(&seq) else { continue };
                    match (req.name.as_str(), answer.0.verb.as_str()) {
                        ("close", "close") => {
                            if let Some(w) = req.win {
                                let op = Op::Write {
                                    path: FsPath::new(format!("windows/{w}/ctl")),
                                    data: Bytes::from_static(b"destroy"),
                                };
                                match t.apply(HOST_SESSION, op) {
                                    Ok(c) => {
                                        self.dirty.extend(c.dirty_windows);
                                        queue.extend(c.host);
                                    }
                                    Err(e) => self.shared.log(format!("error destroy {w}: {e}")),
                                }
                            }
                        }
                        ("quit", "quit") => {
                            self.quit();
                            return;
                        }
                        _ => {}
                    }
                }
                _ => {}
            }
        }
    }

    fn quit(&mut self) {
        // Publish the last snapshot, then drop the tree: its event bus goes
        // with it, so every blocked `events` read sees end of file.
        self.publish();
        self.tree = None;
        self.requests.clear();
        self.shared.set_gone();
    }

    fn node_type(&self, path: &str) -> Option<String> {
        let snap = self.shared.snap.lock().unwrap().clone();
        let b = snap.read(&FsPath::new(format!("{path}/type")))?;
        Some(String::from_utf8_lossy(&b).trim().to_string())
    }

    fn event_kind(&self, target: &str, name: &str) -> EventKind {
        if target.starts_with("windows/") {
            if let Some(ty) = self.node_type(target) {
                if let Some(spec) = self.reg.get(&ty) {
                    if let Some(e) = spec.events.iter().find(|e| e.name == name) {
                        return e.kind;
                    }
                }
            }
        }
        match name {
            "close" | "quit" | "drop" | "complete" => EventKind::Request,
            "change" | "select" | "cursor" | "resize" | "layout" | "move" | "scroll" | "hover" | "state"
            | "drag" => EventKind::State,
            _ => EventKind::Action,
        }
    }

    fn inject(&mut self, data: &[u8]) -> Result<(), Error> {
        let cmds = proto::parse_ctl(data)?;
        // Check every line before applying any, as a ctl write does.
        for c in &cmds {
            match c.verb.as_str() {
                "event" if c.args.len() == 2 => {
                    split_target(&c.args[1])?;
                }
                "mirror" if c.args.len() == 2 => {}
                "bounds" if c.args.len() == 5 => {
                    for a in &c.args[1..] {
                        a.parse::<f32>().map_err(|_| Error::new(ErrorKind::BadValue, a.clone()))?;
                    }
                }
                "frame" if c.args.len() <= 1 => {}
                "tick" if c.args.is_empty() => {}
                "event" | "mirror" | "bounds" | "frame" | "tick" => {
                    return Err(Error::new(ErrorKind::BadSyntax, format!("usage: {}", c.verb)));
                }
                v => return Err(Error::new(ErrorKind::UnknownCommand, v.to_string())),
            }
        }
        for c in cmds {
            self.inject_one(c)?;
            if self.tree.is_none() {
                break;
            }
        }
        Ok(())
    }

    fn inject_one(&mut self, c: Command) -> Result<(), Error> {
        match c.verb.as_str() {
            "event" => {
                let name = c.args[0].clone();
                let target = c.args[1].clone();
                let (win, node) = split_target(&target)?;
                let kind = self.event_kind(&target, &name);
                let mut default = None;
                let attrs: Vec<(String, String)> = c
                    .props
                    .into_iter()
                    .filter(|(k, v)| {
                        if k == "default" {
                            default = Some(v.clone());
                            false
                        } else {
                            true
                        }
                    })
                    .collect();
                let ev = EventMsg { kind, name: name.clone(), win: win.clone(), node, attrs, via: Via::User };
                let t = self.tree.as_mut().unwrap();
                let seq = if kind == EventKind::Request {
                    let verb = default.unwrap_or_else(|| default_answer_verb(&name).to_string());
                    let seq = t.open_request(ev, Answer(Command { verb, ..Default::default() }), REQUEST_TIMEOUT);
                    self.requests.insert(seq, PendingRequest { win, name: name.clone() });
                    seq
                } else {
                    t.emit(ev)
                };
                self.shared.log(format!("event {name} seq={seq}"));
            }
            "mirror" => {
                let file = FsPath::new(c.args[0].clone());
                let s = file.as_str();
                let Some(i) = s.rfind('/') else {
                    return Err(Error::new(ErrorKind::NotFound, s.to_string()));
                };
                let (node, f) = (&s[..i], &s[i + 1..]);
                let value = Bytes::from(c.args[1].clone().into_bytes());
                self.tree.as_mut().unwrap().mirror(node, f, value, Via::User);
            }
            "bounds" => {
                let v: Vec<f32> = c.args[1..].iter().map(|a| a.parse().unwrap_or(0.0)).collect();
                self.tree.as_mut().unwrap().report_bounds(&c.args[0], [v[0], v[1], v[2], v[3]]);
            }
            "frame" => {
                let w = c.args.first().cloned();
                self.frame(w.as_deref());
            }
            "tick" => self.tick(),
            _ => unreachable!("checked above"),
        }
        Ok(())
    }
}
