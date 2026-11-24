//! The desktop surface: GPUI Kit's `gpui-webview`, a wry child view of
//! the window that its element keeps on the node's layout box.

use gpui::{AnyElement, App, AppContext as _, Entity, IntoElement, Window};
use gpui_webview::WebView;

use super::{Sink, Source};
use crate::NodeView;

/// How the bridge reaches the host: wry's IPC channel.
const SEND: &str = "(s=>window.ipc.postMessage(s))";

pub(crate) struct Surface {
    view: Entity<WebView>,
}

impl Surface {
    pub(crate) fn new(node: &NodeView, sink: Sink, window: &mut Window, cx: &mut App) -> Result<Surface, String> {
        let (s1, s2, s3, s4) = (sink.clone(), sink.clone(), sink.clone(), sink);
        let mut b = wry::WebViewBuilder::new()
            .with_transparent(super::transparent(node))
            .with_autoplay(true)
            // The inspector is a right-click away, in release builds too
            // (wry's `devtools` feature, through gpui-webview's `inspector`).
            .with_devtools(true)
            .with_initialization_script(super::bridge(SEND))
            .with_ipc_handler(move |req| s1.ipc(req.body()))
            .with_on_page_load_handler(move |ev, _url| {
                if matches!(ev, wry::PageLoadEvent::Finished) {
                    s2.loaded();
                }
            })
            .with_document_title_changed_handler(move |t| s3.title(&t))
            .with_navigation_handler(move |url| {
                s4.navigate(&url);
                true
            });
        if let Some(script) = super::user_script(node) {
            b = b.with_initialization_script(script);
        }
        b = match super::source(node) {
            Source::Html(h) => b.with_html(h),
            Source::Url(u) => b.with_url(u),
            Source::Blank => b,
        };
        let wv = WebView::build(b, window, cx).map_err(|e| e.to_string())?;
        let dark = gpui_component::ActiveTheme::theme(cx).is_dark();
        let _ = wv.set_theme(if dark { wry::Theme::Dark } else { wry::Theme::Light });
        Ok(Surface { view: cx.new(|_| wv) })
    }

    pub(crate) fn load(&self, src: &Source, cx: &App) {
        let wv = self.view.read(cx);
        let _ = match src {
            Source::Html(h) => wv.raw().load_html(h),
            Source::Url(u) => wv.raw().load_url(u),
            Source::Blank => wv.raw().load_url("about:blank"),
        };
    }

    pub(crate) fn reload(&self, cx: &App) {
        let _ = self.view.read(cx).raw().reload();
    }

    pub(crate) fn history(&self, delta: i32, cx: &App) {
        let _ = self.view.read(cx).raw().evaluate_script(&format!("history.go({delta});"));
    }

    pub(crate) fn eval(&self, n: Option<&str>, script: &str, sink: &Sink, cx: &App) {
        if let Err(e) = self.view.read(cx).raw().evaluate_script(&super::eval_wrapper(SEND, n, script))
            && let Some(n) = n
        {
            sink.result(n, false, &e.to_string());
        }
    }

    /// Shows or hides the native view without unloading the page.
    pub(crate) fn set_shown(&self, shown: bool, cx: &App) {
        let wv = self.view.read(cx);
        if wv.visible() != shown {
            let _ = wv.set_visible(shown);
        }
    }

    pub(crate) fn element(&self, _: &NodeView) -> AnyElement {
        self.view.clone().into_any_element()
    }
}
