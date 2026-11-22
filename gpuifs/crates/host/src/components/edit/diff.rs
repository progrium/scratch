//! `diff`: GPUI Kit's `Diff` view.
//!
//! A `patch` (unified or Git format) is shown as written. Otherwise the host
//! diffs `old` against `new` itself. `path` names the file in the header and
//! picks the highlighting language; `layout=split` puts the sides next to
//! each other.

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, Context, Entity, IntoElement, ParentElement as _,
    Styled as _, Window, div,
};
use gpui_component::ActiveTheme as _;
use gpui_component::diff::{Diff, DiffFile, DiffMode, DiffState};

use super::{entity, no_verb, raw_text, spec};
use crate::{Component, NodeView, RenderCx};

pub struct DiffComponent;

/// The host-side state of one `diff` node.
pub struct DiffNode {
    state: Entity<DiffState>,
    /// Why the patch didn't parse, shown instead of the diff.
    error: Option<String>,
}

fn mode(node: &NodeView) -> DiffMode {
    match node.text("layout").as_deref().map(str::trim) {
        Some("split") => DiffMode::Split,
        _ => DiffMode::Unified,
    }
}

/// The files to show, or why there are none.
fn files(node: &NodeView) -> Result<Vec<DiffFile>, String> {
    let patch = raw_text(node, "patch");
    if !patch.trim().is_empty() {
        return DiffFile::parse(&patch).map_err(|e| format!("{e:?}"));
    }
    let path = node
        .text("path")
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| "file".to_string());
    let old = raw_text(node, "old");
    let new = raw_text(node, "new");
    if old == new {
        return Ok(vec![DiffFile::unchanged(path, &new)]);
    }
    DiffFile::parse(&unified(&path, &old, &new)).map_err(|e| format!("{e:?}"))
}

/// A unified patch from `old` to `new`.
pub(crate) fn unified(path: &str, old: &str, new: &str) -> String {
    let d = similar::TextDiff::from_lines(old, new);
    let mut out = format!("--- a/{path}\n+++ b/{path}\n");
    for hunk in d.unified_diff().context_radius(3).iter_hunks() {
        let s = hunk.to_string();
        out.push_str(&s);
        if !s.ends_with('\n') {
            out.push('\n');
        }
    }
    out
}

impl DiffNode {
    fn new(node: &NodeView, cx: &mut Context<Self>) -> Self {
        let (f, error) = match files(node) {
            Ok(f) => (f, None),
            Err(e) => (Vec::new(), Some(e)),
        };
        let m = mode(node);
        let state = cx.new(|cx| DiffState::new(f, cx).with_mode(m));
        DiffNode { state, error }
    }

    fn reload(&mut self, node: &NodeView, cx: &mut Context<Self>) {
        match files(node) {
            Ok(f) => {
                self.error = None;
                self.state.update(cx, |s, cx| s.set_files(f, cx));
            }
            Err(e) => self.error = Some(e),
        }
        cx.notify();
    }
}

impl Component for DiffComponent {
    fn spec(&self) -> &'static catalog::TypeSpec {
        spec("diff")
    }

    fn create(&self, node: &NodeView, _: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        Some(cx.new(|cx| DiffNode::new(node, cx)).into_any())
    }

    fn prop_changed(
        &self,
        node: &NodeView,
        state: Option<&AnyEntity>,
        prop: &str,
        _: &mut Window,
        cx: &mut App,
    ) {
        let Some(e) = entity::<DiffNode>(state) else {
            return;
        };
        match prop {
            "old" | "new" | "patch" | "path" => e.update(cx, |me, cx| me.reload(node, cx)),
            "layout" => {
                let m = mode(node);
                let s = e.read(cx).state.clone();
                s.update(cx, |s, cx| s.set_mode(m, cx));
            }
            _ => {}
        }
    }

    fn verb(
        &self,
        _: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &proto::Command,
        _: &mut Window,
        _: &mut App,
    ) -> Result<(), proto::Error> {
        no_verb(cmd)
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(e) = rcx.state::<DiffNode>(node) else {
            return rcx.element(node).into_any_element();
        };
        let (state, error) = {
            let me = e.read(rcx.cx_ref());
            (me.state.clone(), me.error.clone())
        };
        let el = rcx.element_from(node, div().flex().flex_col().min_h_0());
        if let Some(err) = error {
            let color = rcx.cx_ref().theme().danger;
            return el
                .child(
                    div()
                        .p_2()
                        .text_sm()
                        .text_color(color)
                        .child(format!("bad patch: {err}")),
                )
                .into_any_element();
        }
        el.child(
            Diff::new(&state)
                .line_number(node.flag("line_numbers"))
                .size_full()
                .flex_1(),
        )
        .into_any_element()
    }
}
