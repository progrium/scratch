//! Windows: opening one for `UIT_CMD_WINDOW`, window `ctl` verbs, and each
//! window's root view.

use std::rc::Rc;

use gpui::{
    AnyElement, App, AppContext, Bounds, Context, InteractiveElement, IntoElement, ParentElement, Render, Styled,
    TitlebarOptions, Window, WindowBackgroundAppearance, WindowBounds, WindowDecorations, WindowKind, WindowOptions, div, point, px, size,
};
use gpui_component::{ActiveTheme as _, WindowExt as _, notification::Notification};
use uitcore::{Ctl, Node};

use crate::RenderCx;
use crate::runtime::{Inner, Pending, WindowEntry, notify_window};

/// One window's root view: renders the window's root and its overlays.
pub struct WindowView {
    win: String,
    host: Rc<Inner>,
    /// What the `state` file last said, so only changes are reported.
    last_state: String,
    last_bounds: [f32; 4],
    /// The focused node, as the `focus` file says.
    last_focus: Option<Node>,
    /// The window's own focus, so keys reach it when no node has focus.
    focus: gpui::FocusHandle,
    /// `transparent` is on or `blur`: the window paints no background of
    /// its own, so whatever the tree leaves unpainted shows the desktop.
    clear: bool,
}

impl WindowView {
    fn new(win: String, host: Rc<Inner>, clear: bool, window: &mut Window, cx: &mut Context<Self>) -> Self {
        cx.observe_window_bounds(window, |this: &mut Self, window, _cx| this.window_moved(window)).detach();
        // The OS appearance, for `theme/mode` when `pref` is `system`.
        cx.observe_window_appearance(window, |this: &mut Self, window, _cx| {
            if let Ok(core) = this.host.core.try_borrow() {
                core.system_dark(crate::runtime::is_dark(window.appearance()));
            }
        })
        .detach();
        let w = win.clone();
        let h = host.clone();
        window.on_window_should_close(cx, move |_window, _cx| {
            // Closing asks the client (§ Requests). If nobody answers, the
            // default closes the window.
            let root = h.core.borrow().window_root(&w);
            h.request(root, Pending::WindowClose(w.clone()), "close", &[("via", "titlebar")], "close");
            false
        });
        let mut v = WindowView { win, host, last_state: String::new(), last_bounds: [0.; 4], last_focus: None, focus: cx.focus_handle(), clear };
        v.focus.focus(window, cx);
        v.window_moved(window);
        v
    }

    fn window_moved(&mut self, window: &mut Window) {
        let b = window.bounds();
        let nb = [f32::from(b.origin.x), f32::from(b.origin.y), f32::from(b.size.width), f32::from(b.size.height)];
        if nb != self.last_bounds {
            self.last_bounds = nb;
            let v = format!("{} {} {} {}", nb[0], nb[1], nb[2], nb[3]);
            self.host.window_file(&self.win, "bounds", &v);
        }
        let st = window_state(window);
        if st != self.last_state {
            self.last_state = st.to_string();
            self.host.window_file(&self.win, "state", st);
        }
    }

    /// A focus move the client asked for, which needs no event.
    pub(crate) fn set_known_focus(&mut self, n: Option<Node>) {
        self.last_focus = n;
    }

    /// Focus moves are noticed after each frame: mirror `focus`, send
    /// `focus`/`blur` to nodes that listed them in `on`.
    fn track_focus(&mut self, window: &Window) {
        let now = self.host.focused(&self.win, window);
        let now_n = now.as_ref().map(|v| v.node());
        if now_n == self.last_focus {
            return;
        }
        let old = std::mem::replace(&mut self.last_focus, now_n);
        let rel = now.as_ref().map(|v| v.rel_path().to_string()).unwrap_or_default();
        self.host.window_file(&self.win, "focus", &rel);
        if let Some(o) = old.and_then(|o| self.host.view(o))
            && o.on_words().iter().any(|w| w == "blur")
        {
            o.emitter().event("blur", &[]);
        }
        if let Some(n) = now
            && n.on_words().iter().any(|w| w == "focus")
        {
            n.emitter().event("focus", &[]);
        }
    }
}

fn window_state(window: &Window) -> &'static str {
    if window.is_fullscreen() {
        "full"
    } else if window.is_maximized() {
        "max"
    } else {
        "normal"
    }
}

/// A GPUI keystroke in the protocol's spelling: modifiers joined by `-`,
/// then the key. The core maps `cmd` to the platform's command key.
pub(crate) fn keystroke(k: &gpui::Keystroke) -> String {
    let m = &k.modifiers;
    let mut s = String::new();
    for (on, name) in [(m.control, "ctrl"), (m.alt, "alt"), (m.shift, "shift"), (m.platform, if cfg!(target_os = "macos") { "cmd" } else { "super" }), (m.function, "fn")] {
        if on {
            s.push_str(name);
            s.push('-');
        }
    }
    s.push_str(&k.key);
    s
}

impl Render for WindowView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t0 = crate::time::Instant::now();
        let host = self.host.clone();
        crate::latency::on_render(&host, window);
        // `spacing` scales every rem-based length: the Tailwind scale words
        // (`p-4` is 1rem) and the rem text sizes, as in Tailwind.
        window.set_rem_size(gpui::px(host.rem.get()));
        let root = host.window_root(&self.win);
        let overlays = host.overlay_views(&self.win);
        let bg = cx.theme().background;
        let fg = cx.theme().foreground;
        let font = cx.theme().font_family.clone();
        let font_size = cx.theme().font_size;
        let app: &mut App = cx;
        let mut rcx = RenderCx::new(window, app, host.clone());
        host.frame_tips.borrow_mut().remove(&self.win);
        let body: Option<AnyElement> = root.map(|n| rcx.render(&n));
        let mut over: Vec<AnyElement> = overlays.iter().map(|n| rcx.render(n)).collect();
        // `tooltip` files of the nodes just drawn, above every overlay.
        over.extend(crate::components::overlays::tooltip::node_tips(&mut rcx, &self.win, &overlays));
        drop(rcx);

        if let Ok(core) = host.core.try_borrow() {
            core.frame_drawn(&self.win);
        }
        self.track_focus(window);

        // Keys no widget took go to the core, which matches `keys`.
        let h = self.host.clone();
        let w = self.win.clone();
        let el = div()
            .id("uitree-window")
            .size_full()
            .track_focus(&self.focus)
            .on_key_down(move |ev: &gpui::KeyDownEvent, window, cx| {
                let ks = keystroke(&ev.keystroke);
                let focused = h.focused(&w, window).map(|v| v.node()).unwrap_or(0);
                let matched = h.core.try_borrow().map(|core| core.key(&w, &ks, focused)).unwrap_or(false);
                // A key a binding took is done. In the browser this also
                // keeps the keystroke's default from going on: gpui_web
                // turns an Enter it didn't cancel into a second Enter.
                if matched {
                    cx.stop_propagation();
                }
            })
            .text_color(fg)
            .font_family(font)
            .text_size(font_size);
        // A transparent window leaves its background to the tree: a root
        // styled `bg=...` still paints, and a node with no `bg` is a hole.
        let el = if self.clear { el } else { el.bg(bg) };
        // The menu bar, in the browser (actions.rs): above the root, which
        // takes the rest of the window.
        #[cfg(target_family = "wasm")]
        let el = match self.host.menu_bar.borrow().clone() {
            Some(bar) if !gpui_component::GlobalState::global(cx).app_menus().is_empty() => el
                .flex()
                .flex_col()
                .child(div().flex_none().border_b_1().border_color(cx.theme().border).child(bar))
                .child(div().flex_1().min_h_0().relative().children(body)),
            _ => el.children(body),
        };
        #[cfg(not(target_family = "wasm"))]
        let el = el.children(body);
        let el = if over.is_empty() { el } else { el.child(div().absolute().top_0().left_0().size_full().children(over)) };
        self.host.frames.borrow_mut().push((std::time::Duration::ZERO, t0.elapsed()));
        el
    }
}

/// A transparent window's surface: GPUI Kit's `Root` paints the theme
/// background under everything (its window plugin's default style), so a
/// transparent window overrides that with a clear one, and an opaque one
/// drops the override.
fn clear_root(root: &gpui::AnyView, clear: bool, cx: &mut App) {
    if let Ok(root) = root.clone().downcast::<gpui_component::Root>() {
        root.update(cx, |r, cx| {
            Styled::style(r).background = clear.then(|| gpui::transparent_black().into());
            cx.notify();
        });
    }
}

/// `transparent=on|off|blur` (shell.md § Window props) as GPUI's window
/// background. `blur` falls back to plain transparency where the platform
/// can't blur (GPUI's call).
fn background(v: Option<&str>) -> WindowBackgroundAppearance {
    match v {
        Some("on") => WindowBackgroundAppearance::Transparent,
        Some("blur") => WindowBackgroundAppearance::Blurred,
        _ => WindowBackgroundAppearance::Opaque,
    }
}

fn parse_pair(s: &str) -> Option<(f32, f32)> {
    let (a, b) = s.split_once(',')?;
    Some((a.trim().parse().ok()?, b.trim().parse().ok()?))
}

/// Opens a window the core made, with its props read from its root.
pub(crate) fn open(inner: &Rc<Inner>, win: &str, cx: &mut App) {
    if inner.windows.borrow().contains_key(win) {
        return;
    }
    let Some(root) = inner.window_root(win) else { return };
    let prop = |k: &str| root.text(k).filter(|v| !v.is_empty());
    let title = prop("title").or_else(|| inner.opts.title.clone()).unwrap_or_else(|| win.to_string());
    let (w, h) = prop("size").as_deref().and_then(parse_pair).unwrap_or((800., 600.));
    let sz = size(px(w), px(h));
    let bounds = match prop("pos") {
        Some(p) if p != "center" => match parse_pair(&p) {
            Some((x, y)) => Bounds::new(point(px(x), px(y)), sz),
            None => Bounds::centered(None, sz, cx),
        },
        _ => Bounds::centered(None, sz, cx),
    };
    let titlebar = prop("titlebar").unwrap_or_else(|| "system".into());
    let dialog = prop("kind").as_deref() == Some("dialog");
    let window_background = background(prop("transparent").as_deref());
    let clear = window_background != WindowBackgroundAppearance::Opaque;
    let click_through = prop("click-through").as_deref() == Some("on");
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: if titlebar == "none" {
            None
        } else {
            Some(TitlebarOptions { title: Some(title.clone().into()), appears_transparent: titlebar == "custom", traffic_light_position: None })
        },
        window_decorations: (titlebar != "system").then_some(WindowDecorations::Client),
        kind: if dialog { WindowKind::Floating } else { WindowKind::Normal },
        is_resizable: prop("resizable").as_deref() != Some("off"),
        is_minimizable: !dialog,
        window_min_size: prop("min").as_deref().and_then(parse_pair).map(|(w, h)| size(px(w), px(h))),
        window_background,
        app_id: Some(inner.opts.title.clone().unwrap_or_else(|| "uitree".into())),
        ..Default::default()
    };
    let name = win.to_string();
    let host = inner.clone();
    let r = gpui_kit::open_window(options, cx, move |window, cx| {
        window.set_window_title(&title);
        // Again after opening: GPUI's X11 window starts opaque whatever
        // `window_background` said.
        window.set_background_appearance(window_background);
        if click_through {
            crate::passthrough::set(window, true);
        }
        cx.new(|cx| WindowView::new(name, host, clear, window, cx))
    });
    match r {
        Ok((handle, view)) => {
            if clear {
                let _ = handle.update(cx, |root, _, cx| clear_root(&root, true, cx));
            }
            inner.windows.borrow_mut().insert(win.to_string(), WindowEntry { handle, view });
        }
        Err(e) => eprintln!("uitree: window {win}: {e}"),
    }
}

/// A window `ctl` verb the core passed on.
pub(crate) fn ctl(inner: &Rc<Inner>, win: &str, cmd: &Ctl, cx: &mut App) {
    if !inner.windows.borrow().contains_key(win) && matches!(cmd.verb.as_str(), "show" | "activate") {
        open(inner, win, cx);
    }
    let Some((handle, view)) = inner.windows.borrow().get(win).map(|e| (e.handle, e.view.clone())) else {
        return;
    };
    let cmd = cmd.clone();
    let w2 = win.to_string();
    let host = inner.clone();
    let _ = handle.update(cx, |root, window, cx| match cmd.verb.as_str() {
        "title" => window.set_window_title(&cmd.args.join(" ")),
        // `set . prop=value` on a shown window: the props that change in
        // place. The rest are read when the window opens.
        "set" => {
            for (k, v) in &cmd.attrs {
                match k.as_str() {
                    "transparent" => {
                        let b = background(Some(v));
                        let clear = b != WindowBackgroundAppearance::Opaque;
                        window.set_background_appearance(b);
                        clear_root(&root, clear, cx);
                        view.update(cx, |v, cx| {
                            v.clear = clear;
                            cx.notify();
                        });
                    }
                    "click-through" => crate::passthrough::set(window, v == "on"),
                    _ => {}
                }
            }
        }
        "size" => {
            if let Some((w, h)) = cmd.arg(0).and_then(parse_pair) {
                window.resize(size(px(w), px(h)));
            }
        }
        "state" => {
            let want = cmd.arg(0).unwrap_or("normal");
            let cur = window_state(window);
            view.update(cx, |v, _| v.last_state = want.to_string());
            match want {
                "min" => window.minimize_window(),
                "max" if cur != "max" => window.zoom_window(),
                "full" if cur != "full" => window.toggle_fullscreen(),
                "normal" if cur == "full" => window.toggle_fullscreen(),
                "normal" if cur == "max" => window.zoom_window(),
                _ => {}
            }
        }
        "show" | "activate" => {
            window.activate_window();
            cx.activate(true);
        }
        "close" => {
            let root = host.core.borrow().window_root(&w2);
            host.request(root, Pending::WindowClose(w2.clone()), "close", &[("via", "ctl")], "close");
        }
        "destroy" => window.remove_window(),
        "notify" => {
            let text = cmd.args.join(" ");
            let mut n = match cmd.attr("type") {
                Some("success") => Notification::success(text),
                Some("warning") => Notification::warning(text),
                Some("error") => Notification::error(text),
                Some("info") => Notification::info(text),
                _ => Notification::new().message(text),
            };
            if cmd.attr("sticky") == Some("on") {
                n = n.autohide(false);
            }
            if let Some(title) = cmd.attr("title") {
                n = n.title(title.to_string());
            }
            if let Some(action) = cmd.attr("action") {
                // `action=id:'Label'`: clicking the toast sends `action id`.
                let id = action.split(':').next().unwrap_or(action).to_string();
                let h = host.clone();
                n = n.on_click(move |_, _window, _cx| {
                    if let Ok(core) = h.core.try_borrow() {
                        core.menu_action(&id);
                    }
                });
            }
            window.push_notification(n, cx);
        }
        _ => {}
    });
    notify_window(inner, win, cx);
}
