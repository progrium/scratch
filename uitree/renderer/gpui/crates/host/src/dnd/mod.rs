//! Drag and drop (transfer layer), on `uit_drag`.
//!
//! **Receiving.** A node with a non-empty `drop` file accepts drags offering
//! a type it lists (`file`, `text`, `uri`, or a client type such as
//! `x.notes.card`); an empty `drop` with `drop` in `on` accepts any type.
//! While an accepted drag hovers, the node's `hover:` and `drop-over:`
//! style words apply in GPUI with no round trip. A drop goes to the core
//! as `UIT_DRAG_DROP`. Files from the platform go as `file=` attributes,
//! one host path each: the core turns each into a read-only file handle
//! (`$ui/file/ID`) and an item of the offer's `file` list, so the client
//! gets the bytes and never the path (transfer.md: bytes cross, paths
//! don't). The core sends the `drop` request; its answer comes back as
//! `UIT_CMD_ANSWER`.
//!
//! **Starting a drag.** A node with `drag` in `on` and a `drag-types` file
//! starts a GPUI drag when pressed and moved: `UIT_DRAG_START` makes the
//! offer and sends `dragstart`, and `UIT_DRAG_END` (with
//! `result=dropped|cancelled`) sends `dragend` and ends it.
//!
//! Drags out of the window to the platform are not offered in v1.

use std::cell::Cell;
use std::rc::Rc;

use gpui::{
    AppContext as _, Context, ExternalPaths, InteractiveElement, IntoElement, ParentElement, Pixels, Point,
    Refineable as _, Render, SharedString, StatefulInteractiveElement, Styled, Window, div, px,
};
use uitcore::{DragKind, Node};

use crate::runtime::Inner;
use crate::{NodeView, ParsedStyle};

/// The value GPUI carries during an in-app drag.
pub struct DragValue {
    /// The core's number for the drag, set when it starts.
    n: Cell<u64>,
    /// The source's `drag-types`, richest first.
    types: Vec<String>,
    source: Node,
    /// Whether a target took it.
    dropped: Rc<Cell<bool>>,
}

/// The words of a node's `drop` file.
fn accepts(node: &NodeView) -> Vec<String> {
    node.text("drop").unwrap_or_default().split_whitespace().map(str::to_string).collect()
}

fn accepted(list: &[String], any: bool, offered: &[&str]) -> bool {
    any || offered.iter().any(|ty| list.iter().any(|w| w == ty))
}

/// The words of a node's `drag-types` file.
fn drag_types(node: &NodeView) -> Vec<String> {
    node.text("drag-types").unwrap_or_default().split_whitespace().map(str::to_string).collect()
}

/// `UIT_DRAG_DROP` attributes for files dropped from the platform: one
/// `file=PATH` each. The core keeps the paths to itself.
pub(crate) fn file_attrs(paths: &[std::path::PathBuf]) -> Vec<(String, String)> {
    paths.iter().map(|p| ("file".to_string(), p.to_string_lossy().into_owned())).collect()
}



fn drop_at(host: &Inner, target: Node, n: u64, pos: Point<Pixels>, attrs: &[(&str, &str)]) {
    let (x, y) = (f32::from(pos.x), f32::from(pos.y));
    if let Ok(core) = host.core.try_borrow() {
        let _ = core.drag(DragKind::Drop, n, target, x, y, attrs);
    }
}

/// Adds drop-target and drag-source behaviour to a node's element.
pub(crate) fn attach(node: &NodeView, st: &ParsedStyle, on: &[String], mut el: gpui::Stateful<gpui::Div>) -> gpui::Stateful<gpui::Div> {
    let list = accepts(node);
    let any = list.is_empty() && on.iter().any(|w| w == "drop");
    if !list.is_empty() || any {
        let list = Rc::new(list);
        // Style while an accepted drag hovers: hover:, then drop-over:.
        let mut over = st.hover.clone().unwrap_or_default();
        if let Some(d) = &st.drop_over {
            over.refine(d);
        }
        let over = Rc::new(over);
        {
            let list = list.clone();
            el = el.can_drop(move |v, _, _| {
                if let Some(d) = v.downcast_ref::<DragValue>() {
                    let offered: Vec<&str> = d.types.iter().map(String::as_str).collect();
                    accepted(&list, any, &offered)
                } else if v.downcast_ref::<ExternalPaths>().is_some() {
                    accepted(&list, any, &["file"])
                } else {
                    false
                }
            });
        }
        let o = over.clone();
        el = el.drag_over::<DragValue>(move |mut s, _, _, _| {
            s.refine(&o);
            s
        });
        let o = over.clone();
        el = el.drag_over::<ExternalPaths>(move |mut s, _, _, _| {
            s.refine(&o);
            s
        });
        let target = node.node();
        {
            let host = node.host.clone();
            el = el.on_drop::<DragValue>(move |d, window, _| {
                d.dropped.set(true);
                drop_at(&host, target, d.n.get(), window.mouse_position(), &[]);
            });
        }
        {
            let host = node.host.clone();
            el = el.on_drop::<ExternalPaths>(move |p, window, _| {
                let owned = file_attrs(p.paths());
                let attrs: Vec<(&str, &str)> = owned.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
                drop_at(&host, target, 0, window.mouse_position(), &attrs);
            });
        }
    }

    let types = drag_types(node);
    if on.iter().any(|w| w == "drag") && !types.is_empty() {
        let label: SharedString = node.text("label").or_else(|| node.text("text")).filter(|s| !s.is_empty()).unwrap_or_else(|| types[0].clone()).into();
        let value = DragValue { n: Cell::new(0), types, source: node.node(), dropped: Rc::new(Cell::new(false)) };
        let host = node.host.clone();
        el = el.on_drag(value, move |v, _offset, window, cx| {
            let pos = window.mouse_position();
            let n = host
                .core
                .try_borrow()
                .ok()
                .and_then(|c| c.drag(DragKind::Start, 0, v.source, f32::from(pos.x), f32::from(pos.y), &[]).ok())
                .unwrap_or(0);
            v.n.set(n);
            let label = label.clone();
            let view = cx.new(|_| DragPreview { label });
            let (h, src, dropped) = (host.clone(), v.source, v.dropped.clone());
            cx.observe_release(&view, move |_, _| {
                let result = if dropped.get() { "dropped" } else { "cancelled" };
                if let Ok(core) = h.core.try_borrow() {
                    let _ = core.drag(DragKind::End, n, src, 0., 0., &[("result", result)]);
                }
            })
            .detach();
            view
        });
    }
    el
}
/// What follows the pointer during an in-app drag.
struct DragPreview {
    label: SharedString,
}

impl Render for DragPreview {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let bg = crate::theme::token(cx, "secondary").unwrap_or_default();
        let fg = crate::theme::token(cx, "secondary-foreground").unwrap_or_default();
        let border = crate::theme::token(cx, "border").unwrap_or_default();
        div().px(px(8.)).py(px(4.)).rounded(px(6.)).border_1().border_color(border).bg(bg).text_color(fg).text_sm().opacity(0.9).child(self.label.clone())
    }
}


