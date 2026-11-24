//! The browser surface: an `<iframe>` fixed over gpui_web's canvas at the
//! node's box, moved each frame from the element's prepaint.
//!
//! A page on another origin can't be scripted from here, so on one `eval`
//! answers with `ok` absent ("cross-origin page"), `back` and `forward`
//! do nothing, `script` and the `uitree` bridge aren't injected, and there
//! is no `title` or `navigate`. Such a page can still send messages with
//! `parent.postMessage({uitree: text}, '*')`. `script` runs after the page
//! loads, not before its own scripts as on the desktop.

use std::cell::Cell;
use std::rc::Rc;

use gpui::{AnyElement, App, Bounds, IntoElement, Pixels, Styled, Window, canvas};
use wasm_bindgen::{JsCast, JsValue, closure::Closure};
use web_sys::{HtmlIFrameElement, MessageEvent};

use super::{Sink, Source};
use crate::NodeView;

/// How the bridge reaches the host: a message to the parent page.
const SEND: &str = "(s=>parent.postMessage({uitreeIpc:s},'*'))";

pub(crate) struct Surface {
    frame: HtmlIFrameElement,
    shown: Rc<Cell<bool>>,
    on_message: Closure<dyn FnMut(MessageEvent)>,
    _on_load: Closure<dyn FnMut()>,
}

impl Drop for Surface {
    fn drop(&mut self) {
        if let Some(w) = web_sys::window() {
            let _ = w.remove_event_listener_with_callback("message", self.on_message.as_ref().unchecked_ref());
        }
        self.frame.remove();
    }
}

fn doc() -> Result<web_sys::Document, String> {
    web_sys::window().and_then(|w| w.document()).ok_or_else(|| "no document".to_string())
}

/// The frame's window, as a plain object for `Reflect`.
fn content(frame: &HtmlIFrameElement) -> Option<JsValue> {
    frame.content_window().map(JsValue::from)
}

/// Calls `win.eval(src)` in the frame; Err when the page is on another origin.
fn run(frame: &HtmlIFrameElement, src: &str) -> Result<JsValue, String> {
    let w = content(frame).ok_or("no page")?;
    let f = js_sys::Reflect::get(&w, &"eval".into()).map_err(|_| "cross-origin page".to_string())?;
    let f: js_sys::Function = f.dyn_into().map_err(|_| "cross-origin page".to_string())?;
    f.call1(&w, &src.into()).map_err(|e| e.as_string().unwrap_or_else(|| format!("{e:?}")))
}

impl Surface {
    pub(crate) fn new(node: &NodeView, sink: Sink, _: &mut Window, _: &mut App) -> Result<Surface, String> {
        let d = doc()?;
        let frame: HtmlIFrameElement = d
            .create_element("iframe")
            .map_err(|e| format!("{e:?}"))?
            .dyn_into()
            .map_err(|_| "not an iframe".to_string())?;
        let st = frame.style();
        for (k, v) in [("position", "fixed"), ("border", "0"), ("display", "none"), ("left", "0"), ("top", "0")] {
            let _ = st.set_property(k, v);
        }
        if !super::transparent(node) {
            let _ = st.set_property("background", "white");
        }
        let _ = frame.set_attribute("allow", "autoplay; fullscreen; clipboard-read; clipboard-write");

        // Messages from the page: the bridge's JSON, or {uitree: text}.
        let (s1, f1) = (sink.clone(), frame.clone());
        let on_message = Closure::<dyn FnMut(MessageEvent)>::new(move |ev: MessageEvent| {
            let from_frame = match (ev.source(), f1.content_window()) {
                (Some(src), Some(w)) => JsValue::from(src) == JsValue::from(w),
                _ => false,
            };
            if !from_frame {
                return;
            }
            let data = ev.data();
            if let Some(s) = js_sys::Reflect::get(&data, &"uitreeIpc".into()).ok().and_then(|v| v.as_string()) {
                s1.ipc(&s);
            } else if let Ok(v) = js_sys::Reflect::get(&data, &"uitree".into())
                && !v.is_undefined()
            {
                let text = v.as_string().unwrap_or_else(|| js_sys::JSON::stringify(&v).ok().and_then(|s| s.as_string()).unwrap_or_default());
                let body = serde_json::json!({ "k": "message", "body": text }).to_string();
                s1.ipc(&body);
            }
        });
        web_sys::window()
            .ok_or("no window")?
            .add_event_listener_with_callback("message", on_message.as_ref().unchecked_ref())
            .map_err(|e| format!("{e:?}"))?;

        // Each load: the bridge and `script` where the page lets us, its title, `load`.
        let (s2, f2) = (sink, frame.clone());
        let script = super::user_script(node);
        let on_load = Closure::<dyn FnMut()>::new(move || {
            if run(&f2, &super::bridge(SEND)).is_ok() {
                if let Some(s) = &script {
                    let _ = run(&f2, s);
                }
                if let Some(t) = f2.content_document().map(|d| d.title()) {
                    s2.title(&t);
                }
            }
            s2.loaded();
        });
        frame.set_onload(Some(on_load.as_ref().unchecked_ref()));

        d.body().ok_or("no body")?.append_child(&frame).map_err(|e| format!("{e:?}"))?;
        let s = Surface { frame, shown: Rc::new(Cell::new(false)), on_message, _on_load: on_load };
        s.load_src(&super::source(node));
        Ok(s)
    }

    fn load_src(&self, src: &Source) {
        match src {
            Source::Html(h) => {
                self.frame.remove_attribute("src").ok();
                self.frame.set_srcdoc(h);
            }
            Source::Url(u) => {
                self.frame.remove_attribute("srcdoc").ok();
                self.frame.set_src(u);
            }
            Source::Blank => {
                self.frame.remove_attribute("srcdoc").ok();
                self.frame.set_src("about:blank");
            }
        }
    }

    pub(crate) fn load(&self, src: &Source, _: &App) {
        self.load_src(src);
    }

    pub(crate) fn reload(&self, _: &App) {
        if run(&self.frame, "location.reload()").is_err() {
            // Another origin: setting src again reloads it.
            let src = self.frame.src();
            self.frame.set_src(&src);
        }
    }

    pub(crate) fn history(&self, delta: i32, _: &App) {
        let _ = run(&self.frame, &format!("history.go({delta})"));
    }

    pub(crate) fn eval(&self, n: Option<&str>, script: &str, sink: &Sink, _: &App) {
        if let Err(e) = run(&self.frame, &super::eval_wrapper(SEND, n, script))
            && let Some(n) = n
        {
            sink.result(n, false, &e);
        }
    }

    pub(crate) fn set_shown(&self, shown: bool, _: &App) {
        if self.shown.replace(shown) != shown && !shown {
            let _ = self.frame.style().set_property("display", "none");
        }
    }

    pub(crate) fn element(&self, _: &NodeView) -> AnyElement {
        let frame = self.frame.clone();
        let shown = self.shown.clone();
        canvas(
            move |bounds: Bounds<Pixels>, window: &mut Window, _: &mut App| {
                if !shown.get() {
                    return;
                }
                // Clip to the content mask the way the native view can't:
                // the visible part only.
                let clip = window.content_mask().bounds;
                let vis = bounds.intersect(&clip);
                let st = frame.style();
                if vis.is_empty() {
                    let _ = st.set_property("display", "none");
                    return;
                }
                let origin = doc()
                    .ok()
                    .and_then(|d| d.query_selector("canvas").ok().flatten())
                    .map(|c| c.get_bounding_client_rect())
                    .map(|r| (r.left(), r.top()))
                    .unwrap_or((0., 0.));
                let px = |v: Pixels| format!("{}px", f32::from(v));
                let _ = st.set_property("left", &format!("{}px", origin.0 + f64::from(f32::from(bounds.origin.x))));
                let _ = st.set_property("top", &format!("{}px", origin.1 + f64::from(f32::from(bounds.origin.y))));
                let _ = st.set_property("width", &px(bounds.size.width));
                let _ = st.set_property("height", &px(bounds.size.height));
                let (dx, dy) = (vis.origin.x - bounds.origin.x, vis.origin.y - bounds.origin.y);
                let _ = st.set_property(
                    "clip-path",
                    &format!(
                        "inset({} {} {} {})",
                        px(dy),
                        px(bounds.size.width - vis.size.width - dx),
                        px(bounds.size.height - vis.size.height - dy),
                        px(dx)
                    ),
                );
                let _ = st.set_property("display", "block");
            },
            |_, _, _, _| {},
        )
        .size_full()
        .into_any_element()
    }
}
