//! No page engine in this build (the `webview` feature is off): every
//! `web` node draws as a placeholder with its URL.

use gpui::{AnyElement, App, Window};

use super::{Sink, Source};
use crate::NodeView;

pub(crate) struct Surface;

impl Surface {
    pub(crate) fn new(_: &NodeView, _: Sink, _: &mut Window, _: &mut App) -> Result<Surface, String> {
        Err("built without the webview feature".into())
    }
    pub(crate) fn load(&self, _: &Source, _: &App) {}
    pub(crate) fn reload(&self, _: &App) {}
    pub(crate) fn history(&self, _: i32, _: &App) {}
    pub(crate) fn eval(&self, _: Option<&str>, _: &str, _: &Sink, _: &App) {}
    pub(crate) fn set_shown(&self, _: bool, _: &App) {}
    pub(crate) fn element(&self, node: &NodeView) -> AnyElement {
        super::placeholder_element(node)
    }
}
