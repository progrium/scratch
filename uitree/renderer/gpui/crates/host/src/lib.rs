//! The GPUI host, cut down for the spike to `div`, `text` and `button`.
//!
//! It holds no tree of its own. Each frame it walks the core's committed
//! tree through `uitcore` (children, type, style, props), builds GPUI
//! elements, and posts input back with `emit` and `key`. It never parses
//! `ctl` and never produces a protocol error: the core validated every
//! word and value before the pump that made it visible.
//!
//! The core's 9P threads call the waker, which sends on a channel; a task
//! on GPUI's main thread drains it and calls `pump`. W6 grows this into
//! the full host (uitreefs/crates/host's components on this same path).

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{Duration, Instant};

use futures::StreamExt as _;
use futures::channel::mpsc;
use gpui::{
    AnyElement, AnyWindowHandle, App, AppContext as _, AsyncApp, Bounds, Context, ElementId, Entity, FocusHandle,
    InteractiveElement as _, IntoElement, KeyDownEvent, ParentElement as _, Refineable as _, Render,
    StatefulInteractiveElement as _, StyleRefinement, Styled as _, TitlebarOptions, Window, WindowBounds,
    WindowOptions, div, px, size,
};
use uitcore::{Core, HostCmd, Node, State};

pub mod bench;
pub mod styling;

#[derive(Debug, Clone, Default)]
pub struct Options {
    pub title: Option<String>,
    pub root: Option<String>,
    pub argv: Vec<String>,
    /// Build an N-node tree and measure, instead of running an app.
    pub bench: Option<usize>,
}

static EXIT: AtomicI32 = AtomicI32::new(0);

pub struct Host {
    pub core: RefCell<Core>,
    opts: Options,
    window: RefCell<Option<(AnyWindowHandle, Entity<WindowView>)>>,
    quitting: Cell<bool>,
    /// Per-frame timings for --bench: (tree walk through the ABI, whole render).
    pub frames: RefCell<Vec<(Duration, Duration)>>,
}

/// The theme tokens the core resolves style colors with, from GPUI Kit's
/// default light and dark themes: `name light dark`.
fn theme_tokens() -> String {
    use gpui_component::ThemeColor;
    let (l, d) = (ThemeColor::light(), ThemeColor::dark());
    let hex = |c: gpui::Hsla| {
        let r = gpui::Rgba::from(c);
        format!("#{:02x}{:02x}{:02x}{:02x}", (r.r * 255.).round() as u8, (r.g * 255.).round() as u8, (r.b * 255.).round() as u8, (r.a * 255.).round() as u8)
    };
    let mut out = String::new();
    macro_rules! tok {
        ($($name:literal $field:ident),*) => {$(
            out.push_str(&format!("{} {} {}\n", $name, hex(l.$field), hex(d.$field)));
        )*};
    }
    tok!("background" background, "foreground" foreground, "muted" muted, "muted-foreground" muted_foreground,
        "primary" primary, "primary-foreground" primary_foreground, "accent" accent, "accent-foreground" accent_foreground,
        "border" border, "ring" ring, "danger" danger, "success" success, "warning" warning);
    out
}

/// The types this renderer draws, as descriptors (I6). W1 owns the real
/// ones in core/types/; the spike registers just the names.
const TYPES: &str = "type div\ntype text\ntype button\n";

/// Starts GPUI and the core on this (main) thread; returns the exit code.
pub fn run(opts: Options) -> i32 {
    gpui_kit::application().with_assets(gpui_kit::assets::AllAssets).run(move |cx: &mut App| {
        gpui_component::init(cx);
        cx.set_quit_mode(gpui::QuitMode::Explicit);
        let (tx, rx) = mpsc::unbounded::<()>();
        let words = styling::words();
        let tokens = theme_tokens();
        let core = match Core::new(
            &uitcore::Config { types: TYPES, style_words: &words, theme_tokens: &tokens, system_dark: false },
            Box::new(move || {
                let _ = tx.unbounded_send(());
            }),
        ) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("uitree: {e}");
                EXIT.store(1, Ordering::SeqCst);
                cx.quit();
                return;
            }
        };
        let host = Rc::new(Host {
            core: RefCell::new(core),
            opts: opts.clone(),
            window: RefCell::new(None),
            quitting: Cell::new(false),
            frames: RefCell::new(Vec::new()),
        });
        // The pump loop: every wake is one pump, however many came.
        let h = host.clone();
        cx.spawn(async move |cx: &mut AsyncApp| {
            let mut rx = rx;
            while rx.next().await.is_some() {
                while rx.try_recv().is_ok() {}
                cx.update(|cx| pump(&h, cx));
                if h.quitting.get() {
                    break;
                }
            }
        })
        .detach();
        if let Some(n) = opts.bench {
            bench::start(&host, n, cx);
            return;
        }
        let argv: Vec<&str> = opts.argv.iter().map(String::as_str).collect();
        let r = host.core.borrow_mut().run_machine(&uitcore::MachineArgs {
            prog: argv[0],
            argv: &argv,
            root: opts.root.as_deref().unwrap_or(""),
            cwd: "",
            env: &[],
        });
        if let Err(e) = r {
            eprintln!("uitree: {}: {e}", argv[0]);
            EXIT.store(1, Ordering::SeqCst);
            cx.quit();
        }
    });
    EXIT.load(Ordering::SeqCst)
}

fn pump(host: &Rc<Host>, cx: &mut App) {
    let ch = match host.core.borrow_mut().pump() {
        Ok(ch) => ch,
        Err(e) => {
            eprintln!("uitree: pump: {e}");
            return;
        }
    };
    for c in &ch.cmds {
        match c {
            HostCmd::Window { win } if win == "main" => open_window(host, cx),
            HostCmd::Quit => quit(host, 0, cx),
            _ => {}
        }
    }
    if !ch.dirty.is_empty() || !ch.props.is_empty() {
        if let Some((_, view)) = host.window.borrow().as_ref() {
            view.update(cx, |_, cx| cx.notify());
        }
    }
    if let Some(status) = ch.exited {
        // The client finished: exit as uitreefs does, 0 for an empty
        // exits string and 1 otherwise.
        if !status.is_empty() {
            eprintln!("uitree: {status}");
        }
        quit(host, if status.is_empty() { 0 } else { 1 }, cx);
    }
}

fn quit(host: &Rc<Host>, code: i32, cx: &mut App) {
    if host.quitting.replace(true) {
        return;
    }
    EXIT.store(code, Ordering::SeqCst);
    host.core.borrow().shutdown();
    cx.quit();
}

fn pair(s: Option<&str>) -> Option<(f32, f32)> {
    let (a, b) = s?.split_once(',')?;
    Some((a.trim().parse().ok()?, b.trim().parse().ok()?))
}

/// The main window, sized and titled from its root's props.
pub fn open_window(host: &Rc<Host>, cx: &mut App) {
    if host.window.borrow().is_some() {
        return;
    }
    let (title, (w, h)) = {
        let core = host.core.borrow();
        let root = core.window_root("main");
        let title = core.prop(root, "title").map(str::to_string).or_else(|| host.opts.title.clone()).unwrap_or_else(|| "uitree".into());
        (title, pair(core.prop(root, "size")).unwrap_or((800., 600.)))
    };
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::centered(None, size(px(w), px(h)), cx))),
        titlebar: Some(TitlebarOptions { title: Some(title.clone().into()), ..Default::default() }),
        app_id: Some("uitree".into()),
        ..Default::default()
    };
    let h2 = host.clone();
    match gpui_kit::open_window(options, cx, move |window, cx| {
        window.set_window_title(&title);
        let h3 = h2.clone();
        window.on_window_should_close(cx, move |_, cx| {
            h3.core.borrow().window_closed("main");
            quit(&h3, 0, cx);
            true
        });
        cx.new(|cx| {
            let focus = cx.focus_handle();
            focus.focus(window, cx);
            WindowView { host: h2, focus }
        })
    }) {
        Ok((handle, view)) => *host.window.borrow_mut() = Some((handle, view)),
        Err(e) => eprintln!("uitree: window main: {e}"),
    }
}

pub struct WindowView {
    host: Rc<Host>,
    focus: FocusHandle,
}

/// A GPUI keystroke in the protocol's spelling: modifiers joined by `-`,
/// then the key. The core maps `cmd` to the platform's command key.
fn keystroke(k: &gpui::Keystroke) -> String {
    let mut s = String::new();
    let m = &k.modifiers;
    for (on, name) in [(m.control, "ctrl"), (m.alt, "alt"), (m.shift, "shift"), (m.platform, "super")] {
        if on {
            s.push_str(name);
            s.push('-');
        }
    }
    s.push_str(&k.key);
    s
}

impl Render for WindowView {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        let t0 = Instant::now();
        let core = self.host.core.borrow();
        let root = core.window_root("main");
        let mut walk = Duration::ZERO;
        let body = build(&self.host, &core, root, &mut walk);
        drop(core);
        let host = self.host.clone();
        let el = div()
            .size_full()
            .track_focus(&self.focus)
            .on_key_down(move |ev: &KeyDownEvent, _, _| {
                let ks = keystroke(&ev.keystroke);
                host.core.borrow().key("main", &ks, 0);
            })
            .child(body);
        self.host.frames.borrow_mut().push((walk, t0.elapsed()));
        el
    }
}

/// The style split by state, as GPUI wants it.
#[derive(Default)]
struct Styles {
    base: StyleRefinement,
    hover: Option<StyleRefinement>,
    active: Option<StyleRefinement>,
}

/// A node's style words as read through the ABI, copied out.
type RawStyle = Vec<(String, State, Vec<uitcore::Arg<'static>>)>;

fn read_style(core: &Core, n: Node) -> RawStyle {
    core.style(n)
        .map(|w| {
            // Text arguments are only used during this frame; keep them as
            // owned strings leaked into 'static would be wrong, so drop them.
            let args = w
                .args()
                .map(|a| match a {
                    uitcore::Arg::Rgba(v, _) => uitcore::Arg::Rgba(v, ""),
                    uitcore::Arg::Text(_) => uitcore::Arg::None,
                    uitcore::Arg::Px(x) => uitcore::Arg::Px(x),
                    uitcore::Arg::Percent(x) => uitcore::Arg::Percent(x),
                    uitcore::Arg::Rem(x) => uitcore::Arg::Rem(x),
                    uitcore::Arg::Number(x) => uitcore::Arg::Number(x),
                    uitcore::Arg::None => uitcore::Arg::None,
                })
                .collect();
            (w.name.to_string(), w.state, args)
        })
        .collect()
}

fn styles(raw: &RawStyle) -> Styles {
    let mut st = Styles::default();
    for (name, state, args) in raw {
        let slot = match state {
            State::Base => &mut st.base,
            State::Hover => st.hover.get_or_insert_default(),
            State::Active => st.active.get_or_insert_default(),
            _ => continue,
        };
        if let Some(r) = styling::apply(std::mem::take(slot), name, args) {
            *slot = r;
        }
    }
    st
}

/// One node and its subtree. `walk` collects the time spent in ABI reads.
fn build(host: &Rc<Host>, core: &Core, n: Node, walk: &mut Duration) -> AnyElement {
    let t = Instant::now();
    let ty = core.type_of(n).to_string();
    let path = core.path(n).to_string();
    let raw = read_style(core, n);
    let text = core.prop(n, "text").map(str::to_string);
    let label = core.prop(n, "label").map(str::to_string);
    let click = core.prop(n, "on").is_some_and(|on| on.split_whitespace().any(|w| w == "click"));
    let kids: Vec<Node> = core.children(n).to_vec();
    *walk += t.elapsed();
    let st = styles(&raw);

    let mut el = div();
    el.style().refine(&st.base);
    if let Some(h) = st.hover {
        el = el.hover(move |mut s| {
            s.refine(&h);
            s
        });
    }
    let mut el = el.id(ElementId::Name(format!("n{n}:{path}").into()));
    if let Some(a) = st.active {
        el = el.active(move |mut s| {
            s.refine(&a);
            s
        });
    }
    match ty.as_str() {
        "text" => el = el.child(text.unwrap_or_default()),
        "button" => el = el.child(label.or(text).unwrap_or_default()),
        _ => {}
    }
    if click || ty == "button" {
        let h = host.clone();
        el = el.on_click(move |ev, _, _| {
            let p = ev.position();
            let (x, y) = (format!("{}", f32::from(p.x).round()), format!("{}", f32::from(p.y).round()));
            let _ = h.core.borrow().emit(n, "click", &[("x", &x), ("y", &y), ("button", "left")]);
        });
    }
    for k in kids {
        el = el.child(build(host, core, k, walk));
    }
    el.into_any_element()
}
