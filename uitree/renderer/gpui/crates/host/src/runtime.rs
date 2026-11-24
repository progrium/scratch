//! The host's main-thread state, the pump loop, the per-node caches, and
//! `HostCmd` handling.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicI32, Ordering};

use futures::StreamExt;
use futures::channel::mpsc;
use gpui::{AnyWindowHandle, App, AsyncApp, Entity, FocusHandle, ScrollHandle, Window};
use uitcore::{Changes, Core, Ctl, HostCmd, Node};

use crate::window::WindowView;
use crate::{ComponentRegistry, NodeInfo, NodeState, NodeView, Options, ParsedStyle};

pub(crate) type InputTx = mpsc::UnboundedSender<Input>;

/// Input from GPUI listeners, drained on the main thread into the core.
pub(crate) enum Input {
    Event { node: Node, name: String, attrs: Vec<(String, String)> },
    Request { node: Node, name: String, attrs: Vec<(String, String)>, default: String },
    Mirror { node: Node, file: String, value: Vec<u8> },
    MenuAction { id: String },
}

fn refs(a: &[(String, String)]) -> Vec<(&str, &str)> {
    a.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect()
}

/// Hands the queued input to the core, in order.
pub(crate) fn drain_input(inner: &Rc<Inner>, batch: Vec<Input>) {
    for m in batch {
        match m {
            Input::Event { node, name, attrs } => {
                if let Ok(core) = inner.core.try_borrow() {
                    let _ = core.emit(node, &name, &refs(&attrs));
                }
            }
            Input::Request { node, name, attrs, default } => inner.request(node, Pending::Component(node), &name, &refs(&attrs), &default),
            Input::MenuAction { id } => {
                if let Ok(core) = inner.core.try_borrow() {
                    core.menu_action(&id);
                }
            }
            Input::Mirror { node, file, value } => {
                if let Ok(core) = inner.core.try_borrow() {
                    let _ = core.mirror(node, &file, &value);
                }
                inner.forget_prop(node, &file);
            }
        }
    }
    if let Ok(core) = inner.core.try_borrow() {
        core.wake();
    }
}

/// What a request the host opened is for.
#[derive(Debug, Clone)]
pub(crate) enum Pending {
    /// A component request: the answer goes to its `verb`.
    Component(Node),
    /// The titlebar's close button: `close` closes the window.
    WindowClose(String),
}

pub(crate) struct WindowEntry {
    pub handle: AnyWindowHandle,
    pub view: Entity<WindowView>,
}

/// Prop bytes and data lines copied out of the core, per node, until a
/// pump says the file changed.
#[derive(Default)]
pub(crate) struct NodeCache {
    pub props: HashMap<String, Option<Rc<[u8]>>>,
    pub lines: HashMap<String, Rc<Vec<uitcore::Line>>>,
    pub revs: HashMap<String, u64>,
    pub style: Option<Rc<ParsedStyle>>,
}

/// The host's main-thread state.
pub(crate) struct Inner {
    pub core: RefCell<Core>,
    pub input: InputTx,
    pub components: ComponentRegistry,
    pub opts: Options,
    pub nodes: RefCell<HashMap<Node, Rc<NodeInfo>>>,
    /// `NodeInfo::path` to handle, for slots, parents and tests.
    pub index: RefCell<HashMap<String, Node>>,
    pub cache: RefCell<HashMap<Node, NodeCache>>,
    pub bounds: RefCell<HashMap<Node, [f32; 4]>>,
    pub states: RefCell<HashMap<Node, NodeState>>,
    pub focus: RefCell<HashMap<Node, FocusHandle>>,
    pub scroll: RefCell<HashMap<Node, ScrollHandle>>,
    pub windows: RefCell<HashMap<String, WindowEntry>>,
    pub pending: RefCell<HashMap<u64, Pending>>,
    /// Answers to apply at the next pump: requests the core answered with
    /// their default at once.
    pub deferred: RefCell<Vec<(Pending, Ctl)>>,
    /// `enabled`, `check` per action id, from `UIT_CMD_SET_ACTION`.
    pub action_state: RefCell<HashMap<String, (bool, i32)>>,
    pub quitting: Cell<bool>,
    /// The platform clipboard as last published.
    pub clipboard: crate::clipboard::State,
    /// The browser has no menu bar: menus are drawn in the window
    /// (actions.rs), by GPUI Kit's AppMenuBar.
    #[cfg(target_family = "wasm")]
    pub menu_bar: RefCell<Option<gpui::Entity<gpui_component::menu::AppMenuBar>>>,
    /// Per-frame timings for --bench: (ABI reads, whole render).
    pub frames: RefCell<Vec<(std::time::Duration, std::time::Duration)>>,
    /// UITREE_CLICK_BENCH's probe and results (latency.rs).
    pub clicks: RefCell<crate::latency::Clicks>,
    /// App assets read so far, dropped on `UIT_CMD_ASSETS`.
    pub assets: RefCell<HashMap<String, Rc<[u8]>>>,
    /// Per window, the nodes drawn this frame that have a `tooltip` file.
    pub frame_tips: RefCell<HashMap<String, Vec<Node>>>,
    /// The tip state of each node with a `tooltip` file.
    pub tips: RefCell<HashMap<Node, Entity<crate::components::overlays::tooltip::TipState>>>,
    /// The windows' rem size, from the `spacing` token (theme.rs).
    pub rem: Cell<f32>,
}

pub(crate) fn is_dark(a: gpui::WindowAppearance) -> bool {
    matches!(a, gpui::WindowAppearance::Dark | gpui::WindowAppearance::VibrantDark)
}

pub(crate) static EXIT: AtomicI32 = AtomicI32::new(0);

impl Inner {
    /// What the renderer keeps about a node, read through the ABI once.
    pub fn info(self: &Rc<Self>, n: Node) -> Option<Rc<NodeInfo>> {
        if n == 0 {
            return None;
        }
        if let Some(i) = self.nodes.borrow().get(&n) {
            return Some(i.clone());
        }
        let core = self.core.borrow();
        let ty = core.type_of(n);
        if ty.is_empty() {
            return None;
        }
        let win = core.window_of(n).to_string();
        let rel = core.path(n);
        let path = if rel == "." || rel.is_empty() { win.clone() } else { format!("{win}/{rel}") };
        let info = Rc::new(NodeInfo { node: n, path: path.clone(), win, ty: ty.to_string() });
        drop(core);
        self.nodes.borrow_mut().insert(n, info.clone());
        self.index.borrow_mut().insert(path, n);
        Some(info)
    }

    pub fn view(self: &Rc<Self>, n: Node) -> Option<NodeView> {
        Some(NodeView { info: self.info(n)?, host: self.clone() })
    }

    /// A node by `NodeInfo::path` (`main`, `main/f/ok`).
    pub fn node_at(self: &Rc<Self>, path: &str) -> Option<NodeView> {
        let n = self.index.borrow().get(path).copied();
        if let Some(n) = n {
            return self.view(n);
        }
        // Not seen yet: a window root, or a node under one we haven't drawn.
        let (win, rest) = path.split_once('/').unwrap_or((path, ""));
        let root = self.core.borrow().window_root(win);
        let mut v = self.view(root)?;
        for name in rest.split('/').filter(|s| !s.is_empty()) {
            v = v.children().into_iter().find(|c| c.name() == name)?;
        }
        Some(v)
    }

    pub fn children_of(self: &Rc<Self>, n: Node) -> Vec<NodeView> {
        let kids: Vec<Node> = self.core.borrow().children(n).to_vec();
        kids.into_iter().filter_map(|k| self.view(k)).collect()
    }

    pub fn window_root(self: &Rc<Self>, win: &str) -> Option<NodeView> {
        let r = self.core.borrow().window_root(win);
        self.view(r)
    }

    /// The window's overlays to draw, bottom first: the closed anchored
    /// ones (popover, hover-card, context-menu, tooltip), which draw only the
    /// listeners that open them on their anchor, then the open ones in the
    /// core's order (`uit_overlays` lists only open overlays).
    pub fn overlay_views(self: &Rc<Self>, win: &str) -> Vec<NodeView> {
        let open: Vec<Node> = self.core.borrow().overlays(win).to_vec();
        let prefix = format!("{win}/over/");
        let mut closed: Vec<(String, Node)> = self
            .index
            .borrow()
            .iter()
            .filter(|(p, n)| p.strip_prefix(&prefix).is_some_and(|r| !r.contains('/')) && !open.contains(n))
            .map(|(p, n)| (p.clone(), *n))
            .collect();
        closed.sort();
        closed
            .into_iter()
            .map(|(_, n)| n)
            .filter_map(|k| self.view(k))
            .filter(|v| matches!(v.ty(), "popover" | "hover-card" | "context-menu" | "tooltip"))
            .chain(open.into_iter().filter_map(|k| self.view(k)))
            .collect()
    }

    pub fn prop(&self, n: Node, file: &str) -> Option<Rc<[u8]>> {
        if let Some(c) = self.cache.borrow().get(&n)
            && let Some(v) = c.props.get(file)
        {
            return v.clone();
        }
        let v: Option<Rc<[u8]>> = self.core.borrow().prop_bytes(n, file).map(Rc::from);
        self.cache.borrow_mut().entry(n).or_default().props.insert(file.to_string(), v.clone());
        v
    }

    pub fn lines(&self, n: Node, file: &str) -> Rc<Vec<uitcore::Line>> {
        if let Some(c) = self.cache.borrow().get(&n)
            && let Some(v) = c.lines.get(file)
        {
            return v.clone();
        }
        let v = Rc::new(self.core.borrow().lines(n, file));
        self.cache.borrow_mut().entry(n).or_default().lines.insert(file.to_string(), v.clone());
        v
    }

    pub fn revision(&self, n: Node, file: &str) -> u64 {
        self.cache.borrow().get(&n).and_then(|c| c.revs.get(file).copied()).unwrap_or(0)
    }

    /// Drops what the renderer copied of one prop (after a mirror, the
    /// core's value is the one to read).
    pub fn forget_prop(&self, n: Node, file: &str) {
        if let Some(c) = self.cache.borrow_mut().get_mut(&n) {
            c.props.remove(file);
            c.lines.remove(file);
            *c.revs.entry(file.to_string()).or_default() += 1;
            c.style = None;
        }
    }

    pub fn style_of(&self, node: &NodeView) -> Rc<ParsedStyle> {
        let n = node.node();
        if let Some(s) = self.cache.borrow().get(&n).and_then(|c| c.style.clone()) {
            return s;
        }
        // A node's variant and size words come first, as bare base words.
        let p = {
            let core = self.core.borrow();
            Rc::new(crate::styling::parse(core.style(n)))
        };
        self.cache.borrow_mut().entry(n).or_default().style = Some(p.clone());
        p
    }

    pub fn focus_handle(&self, n: Node, cx: &mut App) -> FocusHandle {
        self.focus.borrow_mut().entry(n).or_insert_with(|| cx.focus_handle()).clone()
    }

    pub fn scroll_handle(&self, n: Node) -> ScrollHandle {
        self.scroll.borrow_mut().entry(n).or_default().clone()
    }

    /// The node whose focus handle has focus in `window`.
    pub fn focused(self: &Rc<Self>, win: &str, window: &Window) -> Option<NodeView> {
        let n = self.focus.borrow().iter().find(|(_, h)| h.is_focused(window)).map(|(n, _)| *n)?;
        self.view(n).filter(|v| v.win() == win)
    }

    /// Opens a request on the core. A core that answers at once (the
    /// default) gets the answer applied at the next pump.
    pub fn request(&self, n: Node, p: Pending, name: &str, attrs: &[(&str, &str)], default_answer: &str) {
        let seq = match self.core.try_borrow() {
            Ok(core) => core.request(n, name, attrs, default_answer),
            Err(_) => 0,
        };
        if seq == 0 {
            self.deferred.borrow_mut().push((p, uitcore::answer_ctl(default_answer)));
            if let Ok(core) = self.core.try_borrow() {
                core.wake();
            }
        } else {
            self.pending.borrow_mut().insert(seq, p);
        }
    }

    /// Records a node's laid-out bounds and reports them to the core.
    pub fn report_bounds(&self, n: Node, b: [f32; 4]) {
        let old = self.bounds.borrow_mut().insert(n, b);
        if old != Some(b)
            && let Ok(core) = self.core.try_borrow()
        {
            core.bounds(n, b);
        }
    }

    /// Writes one of a window's own files (`state`, `focus`) as the user.
    /// The ABI reaches them through the window's root node.
    pub fn window_file(self: &Rc<Self>, win: &str, file: &str, value: &str) {
        if let Ok(core) = self.core.try_borrow() {
            let root = core.window_root(win);
            if root != 0 {
                let _ = core.mirror(root, file, value.as_bytes());
            }
        }
    }

    fn drop_node(&self, n: Node) {
        if let Some(i) = self.nodes.borrow_mut().remove(&n) {
            self.index.borrow_mut().remove(&i.path);
        }
        self.cache.borrow_mut().remove(&n);
        self.bounds.borrow_mut().remove(&n);
        self.states.borrow_mut().remove(&n);
        self.tips.borrow_mut().remove(&n);
        self.focus.borrow_mut().remove(&n);
        self.scroll.borrow_mut().remove(&n);
    }
}

/// Builds the host inside a running GPUI app: the core, the pump loop and
/// the main-thread state. Used by `run`, `--bench` and the test harness.
pub(crate) fn install(opts: Options, cx: &mut App) -> Result<Rc<Inner>, uitcore::Error> {
    install_with(opts, None, cx)
}

/// As [`install`]; a `waker` replaces the pump loop (the test harness
/// pumps itself, since GPUI's test scheduler refuses wakes from other
/// threads).
pub(crate) fn install_with(opts: Options, waker: Option<uitcore::Waker>, cx: &mut App) -> Result<Rc<Inner>, uitcore::Error> {
    let (tx, rx) = mpsc::unbounded::<()>();
    let waker = waker.unwrap_or_else(|| {
        Box::new(move || {
            let _ = tx.unbounded_send(());
        })
    });
    let (input, input_rx) = mpsc::unbounded::<Input>();
    let mut components = ComponentRegistry::default();
    crate::register_all(&mut components);
    let types = crate::spec::registration(&components.names());
    let mut core = Core::new(
        &uitcore::Config {
            types: &types,
            style_words: crate::spec::STYLE_WORDS,
            theme_tokens: crate::spec::THEME_TOKENS,
            system_dark: is_dark(cx.window_appearance()),
        },
        waker,
    )?;
    // GPUI Kit's theme set, as the core's renderer-neutral palettes: the
    // core resolves tokens through the one `theme/name` picks, and
    // theme::apply copies them into GPUI Kit's ThemeColor.
    core.themes(crate::spec::THEMES)?;
    let inner = Rc::new(Inner {
        core: RefCell::new(core),
        input,
        components,
        opts,
        nodes: Default::default(),
        index: Default::default(),
        cache: Default::default(),
        bounds: Default::default(),
        states: Default::default(),
        focus: Default::default(),
        scroll: Default::default(),
        windows: Default::default(),
        pending: Default::default(),
        deferred: Default::default(),
        action_state: Default::default(),
        quitting: Cell::new(false),
        clipboard: Default::default(),
        #[cfg(target_family = "wasm")]
        menu_bar: RefCell::new(None),
        frames: Default::default(),
        clicks: Default::default(),
        assets: Default::default(),
        frame_tips: Default::default(),
        rem: Cell::new(16.),
        tips: Default::default(),
    });
    crate::theme::init(&inner, cx);
    crate::actions::init(&inner, cx);

    // The pump loop: every wake is one pump, however many came.
    let i = inner.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let mut rx = rx;
        while rx.next().await.is_some() {
            while rx.try_recv().is_ok() {}
            if i.quitting.get() {
                break;
            }
            cx.update(|cx| pump(&i, cx));
        }
    })
    .detach();

    // Input from listeners, in order.
    let i = inner.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        let mut rx = input_rx;
        while let Some(first) = rx.next().await {
            let mut batch = vec![first];
            while let Ok(m) = rx.try_recv() {
                batch.push(m);
            }
            if i.quitting.get() {
                break;
            }
            cx.update(|_| drain_input(&i, batch));
        }
    })
    .detach();

    // The clipboard, polled.
    let i = inner.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        loop {
            cx.background_executor().timer(std::time::Duration::from_millis(250)).await;
            if i.quitting.get() {
                break;
            }
            cx.update(|cx| crate::clipboard::poll(&i, cx));
        }
    })
    .detach();

    #[cfg(target_family = "wasm")]
    web_drops(cx);

    Ok(inner)
}

/// A file drop from the page (uitree/web/gpui.js): the files' paths in
/// the core's file system, and where they were dropped, in window points.
#[cfg(target_family = "wasm")]
type WebDrop = (Vec<std::path::PathBuf>, f32, f32);

#[cfg(target_family = "wasm")]
thread_local! {
    static WEB_DROPS: RefCell<Option<futures::channel::mpsc::UnboundedSender<WebDrop>>> = const { RefCell::new(None) };
}

/// In the browser: drops `paths` at `x`, `y` on the window, as the
/// platform's file drop would. gpui_web makes none: the browser gives
/// `File`s, not paths, so the page puts each file in the core's own file
/// system first (uit-web.js putFile), where `uit_drag`'s `file=` finds it.
#[cfg(target_family = "wasm")]
pub fn web_drop(paths: Vec<std::path::PathBuf>, x: f32, y: f32) {
    WEB_DROPS.with(|d| {
        if let Some(tx) = &*d.borrow() {
            let _ = tx.unbounded_send((paths, x, y));
        }
    });
}

/// Delivers web_drop's drops to the window, from the app's own task.
#[cfg(target_family = "wasm")]
fn web_drops(cx: &mut App) {
    use gpui::{point, px, ExternalPaths, FileDropEvent, Modifiers, MouseMoveEvent, PlatformInput};
    let (tx, mut rx) = futures::channel::mpsc::unbounded::<WebDrop>();
    WEB_DROPS.with(|d| *d.borrow_mut() = Some(tx));
    cx.spawn(async move |cx: &mut AsyncApp| {
        while let Some((paths, x, y)) = rx.next().await {
            let position = point(px(x), px(y));
            // As a platform delivers them: entered, moved, dropped, each
            // after a frame, since the drop target is hit-tested against
            // the frame drawn while the drag was over it. First the pointer
            // itself: the browser sends no mouse moves during a drag, and
            // GPUI counts nothing as hovered while the last input was a
            // key (a drop right after a key press would find no target).
            let events = [
                PlatformInput::MouseMove(MouseMoveEvent { position, pressed_button: None, modifiers: Modifiers::default() }),
                PlatformInput::FileDrop(FileDropEvent::Entered { position, paths: ExternalPaths(paths.into()) }),
                PlatformInput::FileDrop(FileDropEvent::Pending { position }),
                PlatformInput::FileDrop(FileDropEvent::Submit { position }),
            ];
            for ev in events {
                let (tx, rx) = futures::channel::oneshot::channel::<()>();
                cx.update(|cx| {
                    // gpui_web has one window: the canvas.
                    let Some(w) = cx.active_window().or_else(|| cx.windows().first().copied()) else { return };
                    let _ = w.update(cx, |_, window, cx| {
                        window.dispatch_event(ev, cx);
                        window.refresh();
                        // On after the frame this event draws: next-frame
                        // callbacks run as a frame starts, so wait for two.
                        window.on_next_frame(move |window, _| {
                            window.on_next_frame(move |_, _| {
                                let _ = tx.send(());
                            });
                        });
                    });
                });
                let _ = rx.await;
            }
        }
    })
    .detach();
}

/// In the browser: where GPUI Kit's icons are fetched from, as
/// `{WEB_ASSETS}/assets/icons/NAME.svg` (uitree/web/build.zig copies them).
/// An absolute URL: the fetch has no page to resolve a relative one against.
#[cfg(target_family = "wasm")]
pub static WEB_ASSETS: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// Starts GPUI and the core on this (main) thread and runs the app in h9;
/// returns the exit code when the app quits.
pub fn run(opts: Options) -> i32 {
    // In the browser (uitree/web): gpui_web on one canvas, single-threaded,
    // icons fetched on demand. run returns at once there; the page's event
    // loop runs the app, and uit_run_machine starts it in h9's Worker.
    #[cfg(target_family = "wasm")]
    let app = gpui_kit::platform::single_threaded_web()
        .with_assets(gpui_kit::assets::AllAssets::new(WEB_ASSETS.get().cloned().unwrap_or_default()));
    // WebKitGTK embeds only in an X11 window (natively or XWayland), so
    // with the webview feature GPUI doesn't pick Wayland on Linux.
    #[cfg(all(feature = "webview", target_os = "linux"))]
    let app = gpui_kit::platform::linux(gpui::WindowingModes::X11 | gpui::WindowingModes::HEADLESS)
        .with_assets(gpui_kit::assets::AllAssets);
    #[cfg(all(not(target_family = "wasm"), not(all(feature = "webview", target_os = "linux"))))]
    let app = gpui_kit::application().with_assets(gpui_kit::assets::AllAssets);
    let launch = move |cx: &mut App| {
        gpui_component::init(cx);
        #[cfg(target_family = "wasm")]
        web_fonts(cx);
        cx.set_quit_mode(gpui::QuitMode::Explicit);
        let inner = match install(opts.clone(), cx) {
            Ok(i) => i,
            Err(e) => {
                eprintln!("uitree: {e}");
                EXIT.store(1, Ordering::SeqCst);
                cx.quit();
                return;
            }
        };
        if let Some(n) = opts.bench {
            crate::bench::start(&inner, n, cx);
            return;
        }
        if let Some(n) = std::env::var("UITREE_CLICK_BENCH").ok().and_then(|v| v.parse().ok()) {
            crate::latency::start(&inner, n, cx);
        }
        // UITREE_RENDER_LISTEN=ADDR: other renderers (protocols/render.md)
        // can dial ADDR and mirror this window.
        if let Ok(addr) = std::env::var("UITREE_RENDER_LISTEN") {
            match inner.core.borrow_mut().render_listen(&addr) {
                Ok(d) => eprintln!("uitree: renderers dial {d}"),
                Err(e) => eprintln!("uitree: UITREE_RENDER_LISTEN: {e}"),
            }
        }
        // UITREE_HOST_APP: a client on the host that dials the core.
        if let Ok(app) = std::env::var("UITREE_HOST_APP") {
            let dial = inner.core.borrow_mut().listen();
            let r = dial.map_err(|e| e.to_string()).and_then(|d| {
                std::process::Command::new("sh").arg("-c").arg(&app).env("UI_DIAL", d).spawn().map_err(|e| e.to_string())
            });
            if let Err(e) = r {
                eprintln!("uitree: UITREE_HOST_APP: {e}");
                EXIT.store(1, Ordering::SeqCst);
                cx.quit();
            }
            return;
        }
        let argv: Vec<&str> = opts.argv.iter().map(String::as_str).collect();
        let dirs: Vec<&str> = opts.dirs.iter().map(String::as_str).collect();
        let env: Vec<&str> = opts.env.iter().map(String::as_str).collect();
        let r = inner.core.borrow_mut().run_machine(&uitcore::MachineArgs {
            prog: argv[0],
            argv: &argv,
            root: opts.root.as_deref().unwrap_or(""),
            cwd: "",
            dirs: &dirs,
            env: &env,
        });
        if let Err(e) = r {
            eprintln!("uitree: {}: {e}", argv[0]);
            EXIT.store(1, Ordering::SeqCst);
            cx.quit();
        }
    };
    // The page's event loop owns the app in the browser: keep it alive.
    #[cfg(target_family = "wasm")]
    std::mem::forget(app.run_embedded(launch));
    #[cfg(not(target_family = "wasm"))]
    app.run(launch);
    EXIT.load(Ordering::SeqCst)
}

/// The browser has no system fonts: IBM Plex Sans, which gpui_web resolves
/// `.SystemUIFont` to and which must exist before the first frame, as the
/// UI font, and JetBrains Mono. From GPUI Kit's story-web (OFL, web/fonts).
#[cfg(target_family = "wasm")]
fn web_fonts(cx: &mut App) {
    use std::borrow::Cow;
    cx.text_system()
        .add_fonts(vec![
            Cow::Borrowed(include_bytes!("../../web/fonts/JetBrainsMono-Regular.ttf").as_slice()),
            Cow::Borrowed(include_bytes!("../../web/fonts/IBMPlexSans-Regular.ttf").as_slice()),
        ])
        .expect("web fonts");
    gpui_component::Theme::global_mut(cx).font_family = "IBM Plex Sans".into();
    gpui_component::Theme::global_mut(cx).mono_font_family = "JetBrains Mono".into();
}

/// One pump: apply what the core queued, then act on what changed.
pub(crate) fn pump(inner: &Rc<Inner>, cx: &mut App) {
    let ch = match inner.core.borrow_mut().pump() {
        Ok(ch) => ch,
        Err(e) => {
            eprintln!("uitree: pump: {e}");
            return;
        }
    };
    apply_changes(inner, ch, cx);
    let deferred = std::mem::take(&mut *inner.deferred.borrow_mut());
    for (p, answer) in deferred {
        answered(inner, p, answer, cx);
    }
}

pub(crate) fn apply_changes(inner: &Rc<Inner>, ch: Changes, cx: &mut App) {
    for n in &ch.removed {
        inner.drop_node(*n);
    }
    for n in &ch.created {
        inner.info(*n);
    }
    crate::latency::on_props(inner, &ch.props);
    // Client-side prop writes: drop the copies, tell components.
    for (n, file) in &ch.props {
        {
            let mut cache = inner.cache.borrow_mut();
            let c = cache.entry(*n).or_default();
            c.props.remove(file);
            c.lines.remove(file);
            *c.revs.entry(file.clone()).or_default() += 1;
            c.style = None;
        }
        if file == "origin" {
            set_scroll_origin(inner, *n);
        }
        let Some(node) = inner.view(*n) else { continue };
        if node.spec().is_some_and(|s| s.has_prop(file))
            && let Some(comp) = inner.components.get(node.ty())
        {
            let state = inner.states.borrow().get(n).and_then(|s| s.entity.clone());
            with_window(inner, node.win(), cx, |window, cx| comp.prop_changed(&node, state.as_ref(), file, window, cx));
        }
    }
    for c in ch.cmds {
        host_cmd(inner, c, cx);
    }
    for w in &ch.dirty {
        notify_window(inner, w, cx);
    }
    reconcile_windows(inner, cx);
    // Once we're quitting, the client's status is its answer to our
    // hangup, not a failure of its own: keep the exit status as it is.
    if let Some(status) = ch.exited.filter(|_| !inner.quitting.get()) {
        // The client finished: exit 0 for an empty exits string, else 1.
        if !status.is_empty() {
            eprintln!("uitree: {status}");
        }
        EXIT.store(if status.is_empty() { 0 } else { 1 }, Ordering::SeqCst);
        if !inner.opts.keep {
            quit(inner, cx);
        }
    }
}

fn set_scroll_origin(inner: &Rc<Inner>, n: Node) {
    let Some(node) = inner.view(n) else { return };
    let v: Vec<f32> = node.text("origin").unwrap_or_default().split([' ', ',']).filter_map(|x| x.trim().parse().ok()).collect();
    if let [x, y] = v[..] {
        // GPUI offsets are negative as content scrolls up.
        inner.scroll_handle(n).set_offset(gpui::point(gpui::px(-x), gpui::px(-y)));
    }
}

pub(crate) fn notify_window(inner: &Rc<Inner>, win: &str, cx: &mut App) {
    let view = inner.windows.borrow().get(win).map(|w| w.view.clone());
    if let Some(v) = view {
        v.update(cx, |_, cx| cx.notify());
    }
}

pub(crate) fn notify_all(inner: &Rc<Inner>, cx: &mut App) {
    let views: Vec<_> = inner.windows.borrow().values().map(|w| w.view.clone()).collect();
    for v in views {
        v.update(cx, |_, cx| cx.notify());
    }
}

/// Runs `f` with a window's `Window`, if that window is open.
pub(crate) fn with_window<R>(inner: &Inner, win: &str, cx: &mut App, f: impl FnOnce(&mut Window, &mut App) -> R) -> Option<R> {
    let h = inner.windows.borrow().get(win).map(|w| w.handle)?;
    h.update(cx, |_, window, cx| f(window, cx)).ok()
}

/// Closes GPUI windows the core no longer has.
fn reconcile_windows(inner: &Rc<Inner>, cx: &mut App) {
    let live: Vec<String> = inner.core.borrow().windows().into_iter().map(str::to_string).collect();
    let dead: Vec<String> = inner.windows.borrow().keys().filter(|w| !live.contains(w)).cloned().collect();
    if dead.is_empty() {
        return;
    }
    for w in &dead {
        let e = inner.windows.borrow_mut().remove(w);
        if let Some(e) = e {
            let _ = e.handle.update(cx, |_, window, _| window.remove_window());
        }
    }
    // Closing the last window quits.
    if inner.windows.borrow().is_empty() && !inner.opts.keep {
        quit(inner, cx);
    }
}

pub(crate) fn quit(inner: &Rc<Inner>, cx: &mut App) {
    if inner.quitting.replace(true) {
        return;
    }
    inner.core.borrow().shutdown();
    cx.quit();
}

pub(crate) fn host_cmd(inner: &Rc<Inner>, c: HostCmd, cx: &mut App) {
    match c {
        HostCmd::Window { win } => crate::window::open(inner, &win, cx),
        HostCmd::WindowCtl { win, ctl } => crate::window::ctl(inner, &win, &ctl, cx),
        HostCmd::Quit => quit(inner, cx),
        HostCmd::Menus | HostCmd::Keymap => crate::actions::set_menus(inner, cx),
        HostCmd::Theme => {
            crate::theme::apply(inner, cx);
            for c in inner.cache.borrow_mut().values_mut() {
                c.style = None;
            }
            cx.refresh_windows();
        }
        HostCmd::ThemeLoad { path } => crate::theme::load(inner, &path, cx),
        HostCmd::SetAction { id, enabled, check } => {
            {
                let mut st = inner.action_state.borrow_mut();
                let e = st.entry(id).or_insert((true, -1));
                if let Some(v) = enabled {
                    e.0 = v;
                }
                if let Some(v) = check {
                    e.1 = v;
                }
            }
            crate::actions::set_menus(inner, cx);
            notify_all(inner, cx);
        }
        HostCmd::Overlay { win, node, open, .. } => {
            component_verb(inner, node, &Ctl::new(if open { "open" } else { "close" }), cx);
            notify_window(inner, &win, cx);
        }
        HostCmd::Focus { win, node } => {
            // A text component focuses its own field; anything else, the
            // node's handle.
            let comp = inner.view(node).and_then(|n| inner.components.get(n.ty()));
            let state = inner.states.borrow().get(&node).and_then(|s| s.entity.clone());
            let done = comp.is_some_and(|c| with_window(inner, &win, cx, |window, cx| c.focus(state.as_ref(), window, cx)).unwrap_or(false));
            if !done && node != 0 {
                let h = inner.focus_handle(node, cx);
                with_window(inner, &win, cx, |window, cx| h.focus(window, cx));
            }
            // The core already echoed this move (via=ctl); don't report it as the user's.
            let view = inner.windows.borrow().get(&win).map(|w| w.view.clone());
            if let Some(v) = view {
                v.update(cx, |v, _| v.set_known_focus((node != 0).then_some(node)));
            }
        }
        HostCmd::Clipboard { text } => crate::clipboard::write(inner, &text, cx),
        HostCmd::ComponentVerb { node, ctl } => {
            component_verb(inner, node, &ctl, cx);
            if let Some(v) = inner.view(node) {
                notify_window(inner, v.win(), cx);
            }
        }
        HostCmd::Answer { seq, answer } => {
            let p = inner.pending.borrow_mut().remove(&seq);
            if let Some(p) = p {
                let mut answer = answer;
                if answer.attr("seq").is_none() {
                    answer.attrs.push(("seq".into(), seq.to_string()));
                }
                answered(inner, p, answer, cx);
            }
        }
        HostCmd::Redraw { win } => notify_window(inner, &win, cx),
        HostCmd::Assets { name } => {
            inner.assets.borrow_mut().remove(&name);
            notify_all(inner, cx);
        }
        HostCmd::Other(_) => {}
    }
}

/// A request's answer reached the renderer.
fn answered(inner: &Rc<Inner>, p: Pending, answer: Ctl, cx: &mut App) {
    match p {
        Pending::Component(n) => component_verb(inner, n, &answer, cx),
        Pending::WindowClose(win) => {
            if answer.verb == "close" {
                inner.core.borrow().window_closed(&win);
                let e = inner.windows.borrow_mut().remove(&win);
                if let Some(e) = e {
                    let _ = e.handle.update(cx, |_, window, _| window.remove_window());
                }
                if inner.windows.borrow().is_empty() && !inner.opts.keep {
                    quit(inner, cx);
                }
            }
        }
    }
}

pub(crate) fn component_verb(inner: &Rc<Inner>, n: Node, cmd: &Ctl, cx: &mut App) {
    let Some(node) = inner.view(n) else { return };
    let Some(comp) = inner.components.get(node.ty()) else { return };
    let state = inner.states.borrow().get(&n).and_then(|s| s.entity.clone());
    with_window(inner, node.win(), cx, |window, cx| comp.verb(&node, state.as_ref(), cmd, window, cx));
}
