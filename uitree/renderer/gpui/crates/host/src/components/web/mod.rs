//! `web` (profile `web`, components.md § New in this spec): a page as a
//! node, so a window can mix native nodes and a page.
//!
//! Three surfaces, picked at build time:
//!
//! - **Desktop** ([`native`], the `webview` feature, on by default): GPUI
//!   Kit's `gpui-webview`, a wry view (WKWebView, WebView2, WebKitGTK) that
//!   is a child view of the window, kept on the node's layout box every
//!   frame. It sits above GPUI's drawing, so a menu or tooltip can't cover
//!   it. On Linux the window must be X11 (natively or XWayland), which
//!   `runtime::run` asks for when this feature is on.
//! - **Browser** ([`iframe`], wasm): an `<iframe>` fixed over gpui_web's
//!   canvas at the node's box. `eval`, `back` and `forward` only reach a
//!   same-origin page (`html`, or a `url` on the page's own origin); a
//!   cross-origin page talks back with `parent.postMessage({uitree: text})`.
//! - **Anywhere else** (no feature, or a window with no native handle, as
//!   on GPUI's test platform): a placeholder box with the URL.
//!
//! Protocol, as the descriptor says, with two choices the core forces for
//! now: event attributes are always `key=value`, so a flag reads `ok=on`
//! and `allowed=on` (absent when false); and `message` and `result` are
//! one bytes file each (the latest body), not the `message/N`, `result/N`
//! directories components.md describes, which the core doesn't serve yet.
//!
//! - `url` loads a page, `html` a document (it wins when both are set),
//!   `script` runs before the page's own scripts on every load (changing it
//!   rebuilds the view).
//! - `reload`, `back`, `forward`; `eval n=N script=TEXT` answers
//!   `result - PATH n=N ok=on` with the value as text in `result` (a
//!   string as is, anything else as JSON; `ok` absent and the error in
//!   `result` when it threw or its promise rejected). Without `n=` nothing
//!   answers.
//! - In the page, `uitree.post(text)` sends `message - PATH n=N` with the
//!   body in `message`.
//! - `load - PATH ok=on` when a page finishes loading; `title - PATH
//!   value=T` when its title changes; `navigate - PATH url=U allowed=on`
//!   for each navigation (every one is allowed for now).

// The placeholder build uses none of the page plumbing.
#![cfg_attr(not(any(feature = "webview", target_family = "wasm")), allow(dead_code))]

#[allow(unused_imports)]
use crate::*;

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, IntoElement, ParentElement, Styled, WeakEntity, Window, div,
};

#[cfg(all(feature = "webview", not(target_family = "wasm")))]
mod native;
#[cfg(all(feature = "webview", not(target_family = "wasm")))]
use native::Surface;

#[cfg(target_family = "wasm")]
mod iframe;
#[cfg(target_family = "wasm")]
use iframe::Surface;

#[cfg(not(any(feature = "webview", target_family = "wasm")))]
mod placeholder;
#[cfg(not(any(feature = "webview", target_family = "wasm")))]
use placeholder::Surface;

#[cfg(test)]
mod tests;

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(Web);
}

/// What the node shows: `html` wins over `url`.
pub(crate) enum Source {
    Html(String),
    Url(String),
    Blank,
}

pub(crate) fn source(node: &NodeView) -> Source {
    if let Some(h) = node.prop("html").filter(|b| !b.is_empty()) {
        return Source::Html(String::from_utf8_lossy(&h).into_owned());
    }
    match node.text("url").map(|u| u.trim().to_string()).filter(|u| !u.is_empty()) {
        Some(u) => Source::Url(u),
        None => Source::Blank,
    }
}

/// The node's `script`, if any.
pub(crate) fn user_script(node: &NodeView) -> Option<String> {
    node.prop("script").filter(|b| !b.is_empty()).map(|b| String::from_utf8_lossy(&b).into_owned())
}

/// Whether the node's own background is transparent (`bg=transparent`):
/// then the page draws no background of its own and what is under the node
/// shows through where the page leaves it bare.
pub(crate) fn transparent(node: &NodeView) -> bool {
    node.host
        .style_of(node)
        .base
        .background
        .as_ref()
        .and_then(|f| f.color())
        .is_some_and(|b| b.is_transparent())
}

/// The page side of the bridge, run before every page's own scripts:
/// `uitree.post(text)`. `send` is how the surface hands a JSON string to
/// the host (wry's `window.ipc.postMessage`, or the iframe's parent).
pub(crate) fn bridge(send: &str) -> String {
    format!(
        "(function(){{if(window.uitree)return;const send={send};\
         window.uitree={{post(t){{send(JSON.stringify({{k:'message',body:String(t)}}))}}}};}})();"
    )
}

/// `eval`'s script, wrapped so its value (or what it threw) comes back
/// through `send` as a `result` message. Run as global code with indirect
/// eval, so `var` and function declarations land on the page as a
/// console's would; a promise is awaited.
pub(crate) fn eval_wrapper(send: &str, n: Option<&str>, script: &str) -> String {
    let src = serde_json::to_string(script).unwrap_or_else(|_| "\"\"".into());
    let Some(n) = n else {
        return format!("(0,eval)({src});");
    };
    let n = serde_json::to_string(n).unwrap_or_else(|_| "\"\"".into());
    format!(
        "(function(){{const send={send};const n={n};\
         const text=v=>v===undefined?'':typeof v==='string'?v:(()=>{{try{{const j=JSON.stringify(v);return j===undefined?String(v):j}}catch(e){{return String(v)}}}})();\
         const done=(ok,v)=>send(JSON.stringify({{k:'result',n,ok,body:ok?text(v):String(v&&v.stack||v)}}));\
         let r;try{{r=(0,eval)({src})}}catch(e){{done(false,e);return}}\
         Promise.resolve(r).then(v=>done(true,v),e=>done(false,e));}})();"
    )
}

/// Turns what a surface's page and engine report into events, mirrored
/// files first so a client that reads `message` or `result` on the event
/// sees the new body.
#[derive(Clone)]
pub(crate) struct Sink {
    em: Emitter,
    messages: Rc<Cell<u64>>,
}

impl Sink {
    fn new(node: &NodeView) -> Sink {
        Sink { em: node.emitter(), messages: Rc::new(Cell::new(0)) }
    }

    /// A JSON message from the bridge.
    pub(crate) fn ipc(&self, body: &str) {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(body) else { return };
        let text = v.get("body").and_then(|b| b.as_str()).unwrap_or("");
        match v.get("k").and_then(|k| k.as_str()) {
            Some("message") => {
                let n = self.messages.get() + 1;
                self.messages.set(n);
                self.em.mirror("message", text);
                self.em.event("message", &[("n", &n.to_string())]);
            }
            Some("result") => {
                let n = match v.get("n") {
                    Some(serde_json::Value::String(s)) => s.clone(),
                    Some(other) => other.to_string(),
                    None => return,
                };
                self.result(&n, v.get("ok").and_then(|o| o.as_bool()).unwrap_or(false), text);
            }
            _ => {}
        }
    }

    pub(crate) fn result(&self, n: &str, ok: bool, text: &str) {
        self.em.mirror("result", text);
        if ok {
            self.em.event("result", &[("n", n), ("ok", "on")]);
        } else {
            self.em.event("result", &[("n", n)]);
        }
    }

    pub(crate) fn loaded(&self) {
        self.em.event("load", &[("ok", "on")]);
    }

    pub(crate) fn title(&self, t: &str) {
        self.em.event("title", &[("value", t)]);
    }

    #[cfg_attr(target_family = "wasm", allow(dead_code))]
    pub(crate) fn navigate(&self, url: &str) {
        self.em.event("navigate", &[("url", url), ("allowed", "on")]);
    }
}

/// A `web` node's state: its surface, or why it has none.
pub struct WebNode {
    surface: Result<Surface, String>,
    sink: Sink,
}

impl WebNode {
    fn build(node: &NodeView, sink: &Sink, window: &mut Window, cx: &mut App) -> Result<Surface, String> {
        Surface::new(node, sink.clone(), window, cx)
    }
}

// Which surfaces were drawn this frame, per window, so one that wasn't
// (its node is in a closed tab, or its window shows another tree now) can
// be hidden: a native view or an iframe stays where it was last put
// otherwise, over whatever GPUI draws there next.
thread_local! {
    static LIVE: RefCell<HashMap<Node, Live>> = RefCell::new(HashMap::new());
}

struct Live {
    win: String,
    entity: WeakEntity<WebNode>,
    drawn: bool,
}

/// Called by the window after it draws its tree: hides the surfaces of
/// `win` that weren't drawn, and forgets the ones whose node is gone.
pub(crate) fn end_frame(win: &str, cx: &mut App) {
    let mut hide = Vec::new();
    LIVE.with(|l| {
        l.borrow_mut().retain(|_, e| {
            let Some(ent) = e.entity.upgrade() else { return false };
            if e.win == win {
                if !e.drawn {
                    hide.push(ent);
                }
                e.drawn = false;
            }
            true
        })
    });
    for ent in hide {
        if let Ok(s) = &ent.read(cx).surface {
            s.set_shown(false, cx);
        }
    }
}

struct Web;

impl Component for Web {
    fn spec(&self) -> &'static Spec {
        spec::must("web")
    }

    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let sink = Sink::new(node);
        let surface = WebNode::build(node, &sink, window, cx);
        if let Err(e) = &surface {
            eprintln!("uitree: web {}: {e}", node.path());
        }
        let ent = cx.new(|_| WebNode { surface, sink });
        LIVE.with(|l| {
            l.borrow_mut().insert(node.node(), Live { win: node.win().to_string(), entity: ent.downgrade(), drawn: false })
        });
        Some(ent.into_any())
    }

    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {
        let Some(ent) = state.and_then(|s| s.clone().downcast::<WebNode>().ok()) else { return };
        match prop {
            "url" | "html" => {
                if let Ok(s) = &ent.read(cx).surface {
                    s.load(&source(node), cx);
                }
            }
            // An init script is fixed when the view is made.
            "script" => {
                let sink = ent.read(cx).sink.clone();
                let surface = WebNode::build(node, &sink, window, cx);
                ent.update(cx, |w, cx| {
                    w.surface = surface;
                    cx.notify();
                });
            }
            _ => {}
        }
    }

    fn verb(&self, node: &NodeView, state: Option<&AnyEntity>, cmd: &Ctl, window: &mut Window, cx: &mut App) -> VerbResult {
        let Some(ent) = state.and_then(|s| s.clone().downcast::<WebNode>().ok()) else { return Err(Unhandled) };
        let w = ent.read(cx);
        let s = match &w.surface {
            Ok(s) => s,
            Err(e) => {
                // No page to run it in: answer so a client waiting on n= isn't left hanging.
                if cmd.verb == "eval"
                    && let Some(n) = cmd.attr("n")
                {
                    w.sink.result(n, false, e);
                }
                return Ok(());
            }
        };
        match cmd.verb.as_str() {
            "reload" => s.reload(cx),
            "back" => s.history(-1, cx),
            "forward" => s.history(1, cx),
            "eval" => {
                let script = cmd.attr("script").or(cmd.arg(0)).unwrap_or("");
                s.eval(cmd.attr("n"), script, &w.sink, cx);
            }
            _ => return Err(Unhandled),
        }
        Ok(())
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        // Fills what it's given by default; style words override.
        let base = div().flex().flex_col().flex_1().w_full().min_h(gpui::px(0.)).overflow_hidden();
        let el = rcx.element_except(node, base, &[]);
        let Some(ent) = rcx.state::<WebNode>(node) else { return el.into_any_element() };
        LIVE.with(|l| {
            if let Some(e) = l.borrow_mut().get_mut(&node.node()) {
                e.drawn = true;
            }
        });
        let inner = match &ent.read(rcx.cx_ref()).surface {
            Ok(s) => {
                s.set_shown(true, rcx.cx_ref());
                s.element(node)
            }
            Err(_) => placeholder_element(node),
        };
        el.child(inner).into_any_element()
    }
}

/// The page's address in a muted box, where no page can be shown.
pub(crate) fn placeholder_element(node: &NodeView) -> AnyElement {
    let what = match source(node) {
        Source::Html(_) => "web: inline html".to_string(),
        Source::Url(u) => format!("web: {u}"),
        Source::Blank => "web".to_string(),
    };
    div()
        .flex_1()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .border_1()
        .border_dashed()
        .text_sm()
        .opacity(0.6)
        .child(what)
        .into_any_element()
}
