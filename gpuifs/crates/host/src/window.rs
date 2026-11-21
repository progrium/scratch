//! Windows: the `window` verb, window `ctl` verbs, and each window's root view.

use std::rc::Rc;

use gpui::{
    AnyElement, App, AppContext, Bounds, InteractiveElement, Context, IntoElement, ParentElement, Render, Styled,
    TitlebarOptions, Window, WindowBounds, WindowDecorations, WindowKind, WindowOptions, div, point,
    px, size,
};
use gpui_component::{ActiveTheme as _, WindowExt as _, notification::Notification};

use tree::{Answer, EventKind, EventMsg, Via};

use crate::RenderCx;
use crate::runtime::{Inner, WindowEntry, notify_window};

/// One window's root view: renders `windows/<win>/root` and its overlays.
pub struct WindowView {
    win: String,
    host: Rc<Inner>,
    /// What the `state` file last said, so only changes send events.
    last_state: String,
    last_bounds: [f32; 4],
    /// The focused node's window-relative path, as the `focus` file says.
    last_focus: Option<String>,
    /// The window's own focus, so actions dispatch here when no node has focus.
    focus: gpui::FocusHandle,
}

impl WindowView {
    fn new(win: String, host: Rc<Inner>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        cx.observe_window_bounds(window, |this: &mut Self, window, _cx| {
            this.window_moved(window);
        })
        .detach();
        let w = win.clone();
        let h = host.clone();
        window.on_window_should_close(cx, move |_window, _cx| {
            // Closing asks the client (§ Requests). If nobody answers, the
            // default closes the window, and the host follows the tree.
            let ev = EventMsg::new(EventKind::Request, "close")
                .win(&w)
                .attr("via", "titlebar");
            h.tree
                .borrow_mut()
                .open_request(ev, Answer::verb("close"), tree::REQUEST_TIMEOUT);
            // Wake the op loop, which ticks right away.
            let _ = h.tx.unbounded_send(crate::runtime::Msg::Wake);
            false
        });
        let mut v = WindowView {
            win,
            host,
            last_state: String::new(),
            last_bounds: [0.; 4],
            last_focus: None,
            focus: cx.focus_handle(),
        };
        v.focus.focus(window, cx);
        v.window_moved(window);
        v
    }

    fn window_moved(&mut self, window: &mut Window) {
        let b = window.bounds();
        let nb = [
            f32::from(b.origin.x),
            f32::from(b.origin.y),
            f32::from(b.size.width),
            f32::from(b.size.height),
        ];
        let dir = format!("windows/{}", self.win);
        if nb != self.last_bounds {
            self.last_bounds = nb;
            self.host.tree.borrow_mut().report_bounds(&dir, nb);
        }
        let st = window_state(window);
        if st != self.last_state {
            let first = self.last_state.is_empty();
            self.last_state = st.to_string();
            let mut t = self.host.tree.borrow_mut();
            t.mirror(&dir, "state", st.as_bytes().to_vec().into(), Via::User);
            if !first {
                t.emit(
                    EventMsg::new(EventKind::State, "state")
                        .win(&self.win)
                        .attr("value", st)
                        .via(Via::User),
                );
            }
        }
    }

    /// Focus moves are noticed after each frame: mirror `focus`, send
    /// `focus`/`blur` to nodes that listed them in `on`.
    fn track_focus(&mut self, window: &Window) {
        let now = self.host.focused_path(&self.win, window);
        let rel = |p: &str| {
            p.strip_prefix(&format!("windows/{}/", self.win))
                .unwrap_or(p)
                .to_string()
        };
        let now_rel = now.as_deref().map(rel);
        if now_rel == self.last_focus {
            return;
        }
        let old = std::mem::replace(&mut self.last_focus, now_rel.clone());
        let dir = format!("windows/{}", self.win);
        let mut t = self.host.tree.borrow_mut();
        t.mirror(
            &dir,
            "focus",
            now_rel.clone().unwrap_or_default().into_bytes().into(),
            Via::User,
        );
        drop(t);
        let wants = |rel: &str, ev: &str| -> bool {
            let full = format!("windows/{}/{rel}", self.win);
            self.host
                .tree
                .borrow()
                .node(&full)
                .and_then(|n| n.text("on"))
                .is_some_and(|on| on.split_whitespace().any(|w| w == ev))
        };
        if let Some(o) = old
            && wants(&o, "blur")
        {
            let full = format!("windows/{}/{o}", self.win);
            self.host.emit_node_event(&full, "blur", Vec::new());
        }
        if let Some(n) = now_rel
            && wants(&n, "focus")
        {
            let full = format!("windows/{}/{n}", self.win);
            self.host.emit_node_event(&full, "focus", Vec::new());
        }
    }
}

fn window_state(window: &Window) -> &'static str {
    if window.is_fullscreen() {
        "fullscreen"
    } else if window.is_maximized() {
        "maximized"
    } else {
        "normal"
    }
}

impl Render for WindowView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let host = self.host.clone();
        let root = host.node_view(&format!("windows/{}/root", self.win));
        let overlays = host.overlay_views(&self.win);
        let bg = cx.theme().background;
        let fg = cx.theme().foreground;
        let font = cx.theme().font_family.clone();
        let font_size = cx.theme().font_size;
        let app: &mut App = cx;
        let mut rcx = RenderCx::new(window, app, host.clone());
        let body: Option<AnyElement> = root.map(|n| rcx.render(&n));
        let over: Vec<AnyElement> = overlays.iter().map(|n| rcx.render(n)).collect();
        drop(rcx);

        host.tree.borrow_mut().frame_drawn(&self.win);
        self.track_focus(window);

        let h = self.host.clone();
        let w = self.win.clone();
        div()
            .id("gpuifs-window")
            .size_full()
            .track_focus(&self.focus)
            .on_action(move |a: &crate::ClientAction, window, cx| {
                let focus = h.focused_path(&w, window);
                crate::actions::dispatch_in(&h, &a.id, Some(w.clone()), focus, cx)
            })
            .bg(bg)
            .text_color(fg)
            .font_family(font)
            .text_size(font_size)
            .children(body)
            .when_some_any(over)
    }
}

trait WhenOverlays: ParentElement + Sized {
    fn when_some_any(self, over: Vec<AnyElement>) -> Self {
        if over.is_empty() {
            self
        } else {
            self.child(div().absolute().top_0().left_0().size_full().children(over))
        }
    }
}
impl<T: ParentElement> WhenOverlays for T {}

fn parse_pair(s: &str) -> Option<(f32, f32)> {
    let (a, b) = s.split_once(',')?;
    Some((a.trim().parse().ok()?, b.trim().parse().ok()?))
}

/// `window name [title=] [size=w,h] [min=w,h] [pos=x,y|center] [kind=] [titlebar=] [resizable=]`.
pub(crate) fn open(inner: &Rc<Inner>, spec: tree::WindowSpec, cx: &mut App) {
    if inner.windows.borrow().contains_key(&spec.name) {
        return;
    }
    let prop = |k: &str| {
        spec.props
            .iter()
            .find(|(n, _)| n == k)
            .map(|(_, v)| v.as_str())
    };
    let title = prop("title")
        .map(str::to_string)
        .or_else(|| inner.opts.title.clone())
        .unwrap_or_else(|| spec.name.clone());
    let (w, h) = prop("size").and_then(parse_pair).unwrap_or((800., 600.));
    let sz = size(px(w), px(h));
    let bounds = match prop("pos") {
        Some(p) if p != "center" => match parse_pair(p) {
            Some((x, y)) => Bounds::new(point(px(x), px(y)), sz),
            None => Bounds::centered(None, sz, cx),
        },
        _ => Bounds::centered(None, sz, cx),
    };
    let titlebar = prop("titlebar").unwrap_or("system");
    let kind = match prop("kind") {
        Some("popup") => WindowKind::PopUp,
        Some("dialog") => WindowKind::Floating,
        _ => WindowKind::Normal,
    };
    let dialog = prop("kind") == Some("dialog");
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: if titlebar == "none" {
            None
        } else {
            Some(TitlebarOptions {
                title: Some(title.clone().into()),
                appears_transparent: titlebar == "custom",
                traffic_light_position: None,
            })
        },
        window_decorations: (titlebar != "system").then_some(WindowDecorations::Client),
        kind,
        is_resizable: prop("resizable") != Some("off"),
        is_minimizable: !dialog,
        window_min_size: prop("min").and_then(parse_pair).map(|(w, h)| size(px(w), px(h))),
        app_id: inner.opts.title.clone(),
        ..Default::default()
    };
    let name = spec.name.clone();
    let host = inner.clone();
    let r = gpui_kit::open_window(options, cx, move |window, cx| {
        window.set_window_title(&title);
        cx.new(|cx| WindowView::new(name, host, window, cx))
    });
    match r {
        Ok((handle, view)) => {
            inner
                .windows
                .borrow_mut()
                .insert(spec.name.clone(), WindowEntry { handle, view });
        }
        Err(e) => eprintln!("gpuifs: window {}: {e}", spec.name),
    }
}

/// A window `ctl` verb the tree passed on.
pub(crate) fn ctl(inner: &Rc<Inner>, win: &str, cmd: &proto::Command, cx: &mut App) {
    let Some(e) = inner.windows.borrow().get(win).map(|e| (e.handle, e.view.clone())) else {
        return;
    };
    let (handle, view) = e;
    let host = inner.clone();
    let cmd = cmd.clone();
    let win = win.to_string();
    let w2 = win.clone();
    let _ = handle.update(cx, |_, window, cx| match cmd.verb.as_str() {
        "title" => {
            let t = cmd.args.join(" ");
            window.set_window_title(&t);
        }
        "size" => {
            if let Some((w, h)) = cmd.arg(0).and_then(parse_pair) {
                window.resize(size(px(w), px(h)));
            }
        }
        "move" | "center" => {
            // GPUI has no portable window move; the bounds file keeps the truth.
            eprintln!("gpuifs: window {w2}: {} is not supported on this platform", cmd.verb);
        }
        "state" => {
            let want = cmd.arg(0).unwrap_or("normal");
            let cur = window_state(window);
            view.update(cx, |v, _| v.last_state = want.to_string());
            match want {
                "minimized" => window.minimize_window(),
                "maximized" if cur != "maximized" => window.zoom_window(),
                "fullscreen" if cur != "fullscreen" => window.toggle_fullscreen(),
                "normal" if cur == "fullscreen" => window.toggle_fullscreen(),
                "normal" if cur == "maximized" => window.zoom_window(),
                _ => {}
            }
        }
        "activate" => {
            window.activate_window();
            cx.activate(true);
        }
        "destroy" => window.remove_window(),
        "notify" => {
            let text = cmd.args.join(" ");
            let mut n = match cmd.prop("type") {
                Some("success") => Notification::success(text),
                Some("warning") => Notification::warning(text),
                Some("error") => Notification::error(text),
                Some("info") => Notification::info(text),
                _ => Notification::new().message(text),
            };
            if cmd.prop("sticky") == Some("on") {
                n = n.autohide(false);
            }
            if let Some(title) = cmd.prop("title") {
                n = n.title(title.to_string());
            }
            if let Some(action) = cmd.prop("action") {
                // `action=id:'Label'`: clicking the toast sends `action id=`.
                let id = action.split(':').next().unwrap_or(action).to_string();
                let h = host.clone();
                let w = w2.clone();
                n = n.on_click(move |_, _window, _cx| {
                    h.tree.borrow_mut().emit(
                        EventMsg::new(EventKind::Action, "action")
                            .win(&w)
                            .attr("id", &id),
                    );
                });
            }
            window.push_notification(n, cx);
        }
        _ => {}
    });
    notify_window(inner, &win, cx);
}
