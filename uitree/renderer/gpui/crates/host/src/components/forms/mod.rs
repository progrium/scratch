//! W6a: the `forms` group. See `catalog::forms` for the specs.
//!
//! Every component here renders inside the node's own element box
//! ([`RenderCx::element`]), which carries the node's style words, `on`
//! listeners, tooltip and `bounds`; the GPUI Kit control sits in it and fills
//! it when the style sizes the box.
//!
//! Values follow DESIGN's rules: a user change mirrors the new `value` into
//! the tree (unless `controlled=on`) and sends `change`, with `value=` on
//! every type but the text inputs. Client writes reach stateful controls
//! through `prop_changed`; stateless ones read their files on every frame.
//! A prop that GPUI Kit only takes at construction (a slider's range, a
//! select's `searchable`) drops the node's state, so the next frame builds it
//! again from the files.

use gpui::{AnyElement, App, IntoElement, ParentElement, Styled, Window};
use gpui_component::Size;

use crate::{ComponentRegistry, Emitter, NodeView, ParsedStyle, RenderCx};

mod buttons;
mod form;
mod inputs;
mod pickers;
mod toggles;

// uitreefs-spelled render tests: not built until they are ported to 0.2
// as the core serves what they need (README § Tests).
#[cfg(any())]
mod tests;

pub fn register(reg: &mut ComponentRegistry) {
    buttons::register(reg);
    toggles::register(reg);
    inputs::register(reg);
    pickers::register(reg);
    form::register(reg);
}

pub(crate) fn spec(name: &str) -> &'static crate::Spec {
    crate::spec::must(name)
}

/// No component verbs in this group.
pub(crate) fn no_verb(cmd: &crate::Ctl) -> crate::VerbResult {
    Err(crate::Unhandled)
}

macro_rules! common {
    ($name:literal) => {
        fn spec(&self) -> &'static crate::Spec {
            super::spec($name)
        }
        fn verb(
            &self,
            _: &crate::NodeView,
            _: Option<&gpui::AnyEntity>,
            cmd: &crate::Ctl,
            _: &mut gpui::Window,
            _: &mut gpui::App,
        ) -> crate::VerbResult {
            super::no_verb(cmd)
        }
    };
}
pub(crate) use common;

/// The GPUI Kit size for the node's size word, if any.
pub(crate) fn size(st: &ParsedStyle) -> Option<Size> {
    st.size.as_deref().map(|s| match s {
        "xs" => Size::XSmall,
        "sm" => Size::Small,
        "lg" => Size::Large,
        _ => Size::Medium,
    })
}

/// A flag prop (0.2 splits the old `flags` file into one prop per flag).
pub(crate) fn has_flag(node: &NodeView, f: &str) -> bool {
    node.flag(f)
}

pub(crate) fn num(node: &NodeView, file: &str) -> Option<f64> {
    node.text(file)?.trim().parse().ok()
}

/// A number as files and events print it: `3`, `2.5`.
pub(crate) fn fmt_num(v: f64) -> String {
    if v.fract() == 0.0 && v.abs() < 1e15 {
        format!("{}", v as i64)
    } else {
        let s = format!("{v:.4}");
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

/// The user changed a control's value: mirror it unless the client controls
/// the value, then send `change` (with `value=` when `with_value`).
pub(crate) fn user_change(node: &NodeView, em: &Emitter, value: &str, with_value: bool) {
    if !node.flag("controlled") {
        em.mirror("value", value.to_string());
    }
    if with_value {
        em.event("change", &[("value", value)]);
    } else {
        em.event("change", &[]);
    }
}

/// Drops the node's GPUI state, so the next frame makes it again from the
/// node's files. For props GPUI Kit takes only at construction.
pub(crate) fn rebuild(node: &NodeView, window: &mut Window, cx: &mut App) {
    node.host.states.borrow_mut().remove(&node.node());
    window.refresh();
    let _ = cx;
}

/// The nearest `form` above a node, for `submit`.
pub(crate) fn enclosing_form(node: &NodeView) -> Option<NodeView> {
    let mut p = node.parent();
    while let Some(v) = p {
        if v.ty() == "form" {
            return Some(v);
        }
        p = v.parent();
    }
    None
}

/// The node's element box with the control in it. The control fills the
/// box on an axis the node's style sizes (`w_full`, `w=240`, `flex_1`).
pub(crate) fn boxed<E: IntoElement + Styled>(rcx: &mut RenderCx, node: &NodeView, el: E) -> AnyElement {
    let st = rcx.style_of(node);
    let b = &st.base;
    let fill_w = b.size.width.is_some() || b.flex_grow.is_some_and(|g| g > 0.) || b.flex_basis.is_some();
    let fill_h = b.size.height.is_some();
    let el = if fill_w { el.w_full() } else { el };
    let el = if fill_h { el.h_full() } else { el };
    rcx.element(node).child(el).into_any_element()
}

/// The node's `icon` file as a GPUI Kit icon.
pub(crate) fn icon(node: &NodeView) -> Option<gpui_component::Icon> {
    let name = node.text("icon")?;
    let name = name.trim();
    (!name.is_empty()).then(|| gpui_component::Icon::default().path(format!("icons/{name}.svg")))
}

/// A text prop that is set and not empty.
pub(crate) fn nonempty(node: &NodeView, file: &str) -> Option<String> {
    node.text(file).filter(|s| !s.is_empty())
}
