//! The host's main-thread state, the op channel from the 9P thread, and
//! `HostCmd` handling.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures::StreamExt;
use futures::channel::{mpsc, oneshot};
use gpui::{AnyWindowHandle, App, AsyncApp, ClipboardItem, Entity, FocusHandle, ScrollHandle, Window};

use tree::{Answer, Bytes, EventKind, EventMsg, FsPath, HostCmd, Op, SessionId, Tree, Via};

use crate::window::WindowView;
use crate::{ComponentRegistry, HostOptions, NodeState, NodeView, ParsedStyle, StyleCache};

pub(crate) type Tx = mpsc::UnboundedSender<Msg>;

/// Everything that reaches the main thread: ops from 9P, and events from
/// GPUI listeners.
pub(crate) enum Msg {
    Op {
        s: SessionId,
        op: Op,
        ack: Option<oneshot::Sender<Result<(), proto::Error>>>,
    },
    Event {
        node: String,
        name: String,
        attrs: Vec<(String, String)>,
    },
    Request {
        node: String,
        name: String,
        attrs: Vec<(String, String)>,
        default: Answer,
    },
    Mirror {
        path: String,
        file: String,
        value: Bytes,
    },
    /// Nothing to apply; the loop runs `tick`.
    Wake,
}

/// What a request the host opened is for.
pub(crate) enum Pending {
    /// A component request: the answer goes to its `verb`.
    Component(String),
}

pub(crate) struct WindowEntry {
    pub handle: AnyWindowHandle,
    pub view: Entity<WindowView>,
}

/// The host's main-thread state.
pub(crate) struct Inner {
    pub tree: RefCell<Tree>,
    pub components: ComponentRegistry,
    pub tx: Tx,
    pub snapshot: Arc<Mutex<Arc<tree::Snapshot>>>,
    pub opts: HostOptions,
    pub states: RefCell<HashMap<String, NodeState>>,
    pub focus: RefCell<HashMap<String, FocusHandle>>,
    pub scroll: RefCell<HashMap<String, ScrollHandle>>,
    pub styles: StyleCache,
    /// Bumped when theme tokens change, so cached styles re-resolve.
    pub theme_gen: Cell<u64>,
    pub windows: RefCell<HashMap<String, WindowEntry>>,
    pub pending: RefCell<HashMap<u64, Pending>>,
    /// `set id enabled= check=` per action id.
    pub action_state: RefCell<HashMap<String, (bool, bool)>>,
    /// Key bindings that came with GPUI Kit, kept when the keymap is rewritten.
    pub base_bindings: RefCell<Option<Vec<gpui::KeyBinding>>>,
    pub quitting: Cell<bool>,
}

impl Inner {
    pub fn node_view(self: &Rc<Self>, path: &str) -> Option<NodeView> {
        let t = self.tree.borrow();
        let n = t.committed_node(path)?;
        Some(NodeView {
            path: n.path().to_string(),
            win: n.win().to_string(),
            ty: n.ty().to_string(),
            host: self.clone(),
        })
    }

    pub fn children_of(self: &Rc<Self>, path: &str) -> Vec<NodeView> {
        let t = self.tree.borrow();
        let Some(n) = t.committed_node(path) else {
            return Vec::new();
        };
        n.children()
            .into_iter()
            .map(|c| NodeView {
                path: c.path().to_string(),
                win: c.win().to_string(),
                ty: c.ty().to_string(),
                host: self.clone(),
            })
            .collect()
    }

    pub fn overlay_views(self: &Rc<Self>, win: &str) -> Vec<NodeView> {
        let t = self.tree.borrow();
        t.committed_overlays(win)
            .into_iter()
            .map(|c| NodeView {
                path: c.path().to_string(),
                win: c.win().to_string(),
                ty: c.ty().to_string(),
                host: self.clone(),
            })
            .collect()
    }

    pub fn style_of(&self, node: &NodeView, cx: &App) -> Rc<ParsedStyle> {
        let src = node.text("style").unwrap_or_default();
        let gen_ = self.theme_gen.get();
        if let Some((s, g, p)) = self.styles.borrow().get(node.path())
            && *s == src
            && *g == gen_
        {
            return p.clone();
        }
        let toks = crate::theme::TokenView(cx);
        let p = Rc::new(crate::styling::parse(&src, &toks));
        self.styles
            .borrow_mut()
            .insert(node.path().to_string(), (src, gen_, p.clone()));
        p
    }

    pub fn focus_handle(&self, path: &str, cx: &mut App) -> FocusHandle {
        self.focus
            .borrow_mut()
            .entry(path.to_string())
            .or_insert_with(|| cx.focus_handle())
            .clone()
    }

    pub fn scroll_handle(&self, path: &str) -> ScrollHandle {
        self.scroll
            .borrow_mut()
            .entry(path.to_string())
            .or_default()
            .clone()
    }

    fn publish(&self) {
        let snap = self.tree.borrow().snapshot();
        *self.snapshot.lock().unwrap() = snap;
    }

    /// The node path whose focus handle has focus in `window`.
    pub fn focused_path(&self, win: &str, window: &Window) -> Option<String> {
        let prefix = format!("windows/{win}/");
        self.focus
            .borrow()
            .iter()
            .filter(|(p, _)| p.starts_with(&prefix))
            .find(|(_, h)| h.is_focused(window))
            .map(|(p, _)| p.clone())
    }

    /// Emits a user event about a node (full path), with the kind from its spec.
    pub fn emit_node_event(&self, node: &str, name: &str, attrs: Vec<(String, String)>) -> u64 {
        let kind = self.event_kind(node, name);
        let mut t = self.tree.borrow_mut();
        t.emit(EventMsg {
            kind,
            name: name.to_string(),
            win: None,
            node: Some(node.to_string()),
            attrs,
            via: Via::User,
        })
    }

    fn event_kind(&self, node: &str, name: &str) -> EventKind {
        let t = self.tree.borrow();
        if let Some(spec) = t.node(node).and_then(|n| n.spec())
            && let Some(e) = spec.events.iter().find(|e| e.name == name)
        {
            return e.kind;
        }
        match name {
            "hover" | "scroll" | "move" | "focus" | "blur" | "change" | "select" | "cursor"
            | "resize" | "layout" | "state" | "query" | "drag" => EventKind::State,
            _ => EventKind::Action,
        }
    }
}

/// The `FsBackend` the 9P server serves in GUI mode.
pub struct HostBackend {
    tx: Tx,
    snapshot: Arc<Mutex<Arc<tree::Snapshot>>>,
    bus: tree::EventBus,
    next_session: AtomicU32,
}

#[async_trait::async_trait]
impl ninep::FsBackend for HostBackend {
    fn snapshot(&self) -> Arc<tree::Snapshot> {
        self.snapshot.lock().unwrap().clone()
    }
    async fn apply(&self, s: SessionId, op: Op) -> Result<(), proto::Error> {
        let (ack, rx) = oneshot::channel();
        self.tx
            .unbounded_send(Msg::Op { s, op, ack: Some(ack) })
            .map_err(|_| gone())?;
        rx.await.map_err(|_| gone())?
    }
    fn subscribe(&self, events_file: &FsPath) -> Result<tree::Subscription, proto::Error> {
        self.bus.subscribe(events_file)
    }
    fn new_session(&self) -> SessionId {
        SessionId(self.next_session.fetch_add(1, Ordering::Relaxed))
    }
}

fn gone() -> proto::Error {
    proto::Error::new(proto::ErrorKind::AppGone, "")
}

/// Builds the host inside a running GPUI app: the tree, the op channel and
/// the main-thread loop. Used by `run` and by the test harness.
pub(crate) fn install(opts: HostOptions, cx: &mut App) -> (Rc<Inner>, Arc<HostBackend>) {
    let tree = Tree::new(tree::Registry::from_catalog());
    let bus = tree.bus().clone();
    let snapshot = Arc::new(Mutex::new(tree.snapshot()));
    let (tx, rx) = mpsc::unbounded();
    let mut components = ComponentRegistry::default();
    crate::register_all(&mut components);
    let inner = Rc::new(Inner {
        tree: RefCell::new(tree),
        components,
        tx: tx.clone(),
        snapshot: snapshot.clone(),
        opts,
        states: Default::default(),
        focus: Default::default(),
        scroll: Default::default(),
        styles: Default::default(),
        theme_gen: Cell::new(0),
        windows: Default::default(),
        pending: Default::default(),
        action_state: Default::default(),
        base_bindings: RefCell::new(None),
        quitting: Cell::new(false),
    });
    let backend = Arc::new(HostBackend {
        tx,
        snapshot,
        bus,
        next_session: AtomicU32::new(1),
    });
    crate::actions::init(&inner, cx);
    crate::theme::init(&inner, cx);

    // The op loop: drain everything that's ready, apply it in one update.
    let i = inner.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let mut rx = rx;
        while let Some(first) = rx.next().await {
            let mut batch = vec![first];
            while let Ok(m) = rx.try_recv() {
                batch.push(m);
            }
            cx.update(|cx| process(&i, batch, cx));
        }
    })
    .detach();

    // Batch and request timeouts.
    let i = inner.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        loop {
            cx.background_executor()
                .timer(Duration::from_millis(100))
                .await;
            if i.quitting.get() {
                break;
            }
            cx.update(|cx| tick(&i, cx));
        }
    })
    .detach();

    (inner, backend)
}

pub(crate) fn run(opts: HostOptions, start: impl FnOnce(Arc<dyn ninep::FsBackend>) + 'static) {
    gpui_kit::application()
        .with_assets(gpui_kit::assets::Assets)
        .run(move |cx| {
            gpui_component::init(cx);
            cx.set_quit_mode(gpui::QuitMode::Explicit);
            let (_inner, backend) = install(opts, cx);
            start(backend);
        });
}

/// Applies a batch of messages, publishes the snapshot, acks the ops, then
/// acts on what changed.
pub(crate) fn process(inner: &Rc<Inner>, batch: Vec<Msg>, cx: &mut App) {
    let mut acks = Vec::new();
    let mut changes = Vec::new();
    for m in batch {
        match m {
            Msg::Op { s, op, ack } => {
                let r = inner.tree.borrow_mut().apply(s, op);
                match r {
                    Ok(ch) => {
                        changes.push(ch);
                        if let Some(a) = ack {
                            acks.push((a, Ok(())));
                        }
                    }
                    Err(e) => {
                        if let Some(a) = ack {
                            acks.push((a, Err(e)));
                        }
                    }
                }
            }
            Msg::Event { node, name, attrs } => {
                inner.emit_node_event(&node, &name, attrs);
            }
            Msg::Request {
                node,
                name,
                attrs,
                default,
            } => {
                let ev = EventMsg {
                    kind: EventKind::Request,
                    name,
                    win: None,
                    node: Some(node.clone()),
                    attrs,
                    via: Via::User,
                };
                let seq =
                    inner
                        .tree
                        .borrow_mut()
                        .open_request(ev, default, tree::REQUEST_TIMEOUT);
                inner
                    .pending
                    .borrow_mut()
                    .insert(seq, Pending::Component(node));
            }
            Msg::Mirror { path, file, value } => {
                inner
                    .tree
                    .borrow_mut()
                    .mirror(&path, &file, value, Via::User);
            }
            Msg::Wake => {}
        }
    }
    inner.publish();
    for (a, r) in acks {
        let _ = a.send(r);
    }
    for ch in changes {
        apply_changes(inner, ch, cx);
    }
    tick(inner, cx);
}

/// Requests' defaults and batch timeouts.
pub(crate) fn tick(inner: &Rc<Inner>, cx: &mut App) {
    let cmds = inner.tree.borrow_mut().tick(Instant::now());
    if cmds.is_empty() {
        return;
    }
    inner.publish();
    for c in cmds {
        host_cmd(inner, c, cx);
    }
    reconcile_windows(inner, cx);
}

fn apply_changes(inner: &Rc<Inner>, ch: tree::Changes, cx: &mut App) {
    // Drop GPUI state for removed nodes.
    for p in &ch.removed {
        let pre = format!("{p}/");
        let gone = |k: &String| k == p || k.starts_with(&pre);
        inner.states.borrow_mut().retain(|k, _| !gone(k));
        inner.focus.borrow_mut().retain(|k, _| !gone(k));
        inner.scroll.borrow_mut().retain(|k, _| !gone(k));
        inner.styles.borrow_mut().retain(|k, _| !gone(k));
    }
    // Client-side prop writes go to components.
    for (path, file) in &ch.props {
        if file == "type" {
            inner.states.borrow_mut().remove(path);
            continue;
        }
        if path.starts_with("windows/") && path.matches('/').count() == 1 {
            continue; // a window file
        }
        if file == "origin" {
            set_scroll_origin(inner, path);
        }
        let Some(node) = inner.node_view(path) else {
            continue;
        };
        if node.spec().is_some_and(|s| s.props.iter().any(|p| p.name == file))
            && let Some(comp) = inner.components.get(node.ty())
        {
            let state = inner
                .states
                .borrow()
                .get(path)
                .and_then(|s| s.entity.clone());
            with_window(inner, node.win(), cx, |window, cx| {
                comp.prop_changed(&node, state.as_ref(), file, window, cx)
            });
        }
    }
    for c in ch.host {
        host_cmd(inner, c, cx);
    }
    for w in &ch.dirty_windows {
        notify_window(inner, w, cx);
    }
    reconcile_windows(inner, cx);
}

fn set_scroll_origin(inner: &Rc<Inner>, path: &str) {
    let Some(node) = inner.node_view(path) else {
        return;
    };
    let v: Vec<f32> = node
        .text("origin")
        .unwrap_or_default()
        .split_whitespace()
        .filter_map(|x| x.parse().ok())
        .collect();
    if let [x, y] = v[..] {
        // GPUI offsets are negative as content scrolls up.
        inner
            .scroll_handle(path)
            .set_offset(gpui::point(gpui::px(-x), gpui::px(-y)));
    }
}

pub(crate) fn notify_window(inner: &Rc<Inner>, win: &str, cx: &mut App) {
    let view = inner.windows.borrow().get(win).map(|w| w.view.clone());
    if let Some(v) = view {
        v.update(cx, |_, cx| cx.notify());
    }
}

/// Runs `f` with a window's `Window`, if that window is open.
pub(crate) fn with_window<R>(
    inner: &Inner,
    win: &str,
    cx: &mut App,
    f: impl FnOnce(&mut Window, &mut App) -> R,
) -> Option<R> {
    let h = inner.windows.borrow().get(win).map(|w| w.handle)?;
    h.update(cx, |_, window, cx| f(window, cx)).ok()
}

/// Closes GPUI windows the tree no longer has.
fn reconcile_windows(inner: &Rc<Inner>, cx: &mut App) {
    let live = inner.tree.borrow().windows();
    let dead: Vec<String> = inner
        .windows
        .borrow()
        .keys()
        .filter(|w| !live.contains(w))
        .cloned()
        .collect();
    if dead.is_empty() {
        return;
    }
    for w in &dead {
        let e = inner.windows.borrow_mut().remove(w);
        if let Some(e) = e {
            let _ = e.handle.update(cx, |_, window, _| window.remove_window());
        }
    }
    // With no events file open, closing the last window quits.
    if inner.windows.borrow().is_empty()
        && !inner.opts.keep
        && !inner.tree.borrow().bus().has_reader(None, "")
    {
        quit(inner, cx);
    }
}

pub(crate) fn quit(inner: &Rc<Inner>, cx: &mut App) {
    if inner.quitting.replace(true) {
        return;
    }
    inner.tree.borrow_mut().app_gone();
    inner.publish();
    cx.quit();
}

pub(crate) fn host_cmd(inner: &Rc<Inner>, c: HostCmd, cx: &mut App) {
    match c {
        HostCmd::Window(spec) => crate::window::open(inner, spec, cx),
        HostCmd::WindowCtl { win, cmd } => crate::window::ctl(inner, &win, &cmd, cx),
        HostCmd::Quit => quit(inner, cx),
        HostCmd::Menus => crate::actions::set_menus(inner, cx),
        HostCmd::Keymap => crate::actions::set_keymap(inner, cx),
        HostCmd::Theme => crate::theme::apply(inner, cx),
        HostCmd::ThemeLoad { path } => crate::theme::load(inner, &path, cx),
        HostCmd::SetAction { id, enabled, check } => {
            {
                let mut st = inner.action_state.borrow_mut();
                let e = st.entry(id).or_insert((true, false));
                if let Some(v) = enabled {
                    e.0 = v;
                }
                if let Some(v) = check {
                    e.1 = v;
                }
            }
            crate::actions::set_menus(inner, cx);
            let wins: Vec<String> = inner.windows.borrow().keys().cloned().collect();
            for w in wins {
                notify_window(inner, &w, cx);
            }
        }
        HostCmd::Overlay { win, name, open } => {
            let path = format!("windows/{win}/overlays/{name}");
            let verb = if open { "open" } else { "close" };
            component_verb(inner, &path, &proto::Command::new(verb), cx);
            notify_window(inner, &win, cx);
        }
        HostCmd::Focus { win, node } => {
            let path = if node.starts_with("windows/") {
                node
            } else {
                format!("windows/{win}/{node}")
            };
            let h = inner.focus_handle(&path, cx);
            with_window(inner, &win, cx, |window, cx| h.focus(window, cx));
            // The tree already echoed this move (via=ctl); don't report it as the user's.
            let view = inner.windows.borrow().get(&win).map(|w| w.view.clone());
            if let Some(v) = view {
                let rel = path
                    .strip_prefix(&format!("windows/{win}/"))
                    .unwrap_or(&path)
                    .to_string();
                v.update(cx, |v, _| v.set_known_focus(Some(rel)));
            }
        }
        HostCmd::Clipboard => {
            let text = inner.tree.borrow().root_file("clipboard");
            if let Some(t) = text {
                cx.write_to_clipboard(ClipboardItem::new_string(
                    String::from_utf8_lossy(&t).into_owned(),
                ));
            }
        }
        HostCmd::ComponentVerb { node, cmd } => {
            component_verb(inner, &node, &cmd, cx);
            if let Some(w) = node.strip_prefix("windows/").and_then(|p| p.split('/').next()) {
                notify_window(inner, w, cx);
            }
        }
        HostCmd::Answer { seq, answer } => {
            let p = inner.pending.borrow_mut().remove(&seq);
            if let Some(Pending::Component(node)) = p {
                let mut cmd = answer.0.clone();
                if !cmd.props.iter().any(|(k, _)| k == "seq") {
                    cmd.props.push(("seq".to_string(), seq.to_string()));
                }
                component_verb(inner, &node, &cmd, cx);
            }
            // Window close requests: the tree removed the window; reconcile closes it.
        }
        HostCmd::Redraw { win } => notify_window(inner, &win, cx),
    }
}

fn component_verb(inner: &Rc<Inner>, path: &str, cmd: &proto::Command, cx: &mut App) {
    let Some(node) = inner.node_view(path) else {
        return;
    };
    let Some(comp) = inner.components.get(node.ty()) else {
        return;
    };
    let state = inner
        .states
        .borrow()
        .get(path)
        .and_then(|s| s.entity.clone());
    let r = with_window(inner, node.win(), cx, |window, cx| {
        comp.verb(&node, state.as_ref(), cmd, window, cx)
    });
    if let Some(Err(e)) = r {
        eprintln!("gpuifs: {path}: {} : {e}", cmd.verb);
    }
}

/// Helper for tests and in-process callers: apply one op now.
#[allow(dead_code)]
pub(crate) fn apply_now(inner: &Rc<Inner>, s: SessionId, op: Op, cx: &mut App) -> Result<(), proto::Error> {
    let (ack, mut rx) = oneshot::channel();
    process(inner, vec![Msg::Op { s, op, ack: Some(ack) }], cx);
    rx.try_recv().ok().flatten().unwrap_or(Ok(()))
}

#[allow(dead_code)]
pub(crate) fn drain_now(inner: &Rc<Inner>, rx: Vec<Msg>, cx: &mut App) {
    process(inner, rx, cx)
}
