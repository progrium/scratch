//! W6c: the `data` group (DESIGN § Data display). See `catalog::data` for
//! the specs and the choices made where DESIGN.md is silent.
//!
//! GPUI Kit's `List`, `Table` and `Tree` take a Rust delegate that answers
//! how many rows there are and renders row n. The delegates here read the
//! node's data files (`items`, `columns`, `rows`, `fields`, `expanded`) and
//! re-parse a file only when its committed bytes change, which they check
//! on every render ([`Fingerprint`]), so batches, `tree` documents and
//! `append` all reach the component the same way.
//!
//! Each stateful component keeps a small holder entity in the node's state
//! slot; the holder owns the GPUI Kit state entity and the subscriptions
//! that turn Kit events into uitreefs events.

use std::collections::HashMap;

use gpui::{AnyElement, IntoElement, ParentElement, Styled};
use gpui_component::{Icon, Size};

use crate::{ComponentRegistry, NodeView, ParsedStyle, RenderCx};

mod chart;
mod display;
mod list;
mod table;
mod tree;

// uitreefs-spelled render tests: not built until they are ported to 0.2
// as the core serves what they need (README § Tests).
#[cfg(any())]
mod tests;

pub fn register(reg: &mut ComponentRegistry) {
    list::register(reg);
    table::register(reg);
    tree::register(reg);
    display::register(reg);
    chart::register(reg);
}

pub(crate) fn spec(name: &str) -> &'static crate::Spec {
    crate::spec::must(name)
}

pub(crate) fn no_verbs(cmd: &crate::Ctl) -> crate::VerbResult {
    Err(crate::Unhandled)
}

/// Identifies a committed file's value: the node and how many times a
/// pump changed the file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct Fingerprint(crate::Node, u64);

/// The committed file's fingerprint.
pub(crate) fn fingerprint(node: &NodeView, file: &str) -> Fingerprint {
    Fingerprint(node.node(), node.revision(file))
}

/// Runs `f` on the committed text of a file.
pub(crate) fn with_file<R>(node: &NodeView, file: &str, f: impl FnOnce(&str) -> R) -> R {
    let b = node.prop(file);
    f(&String::from_utf8_lossy(b.as_deref().unwrap_or(&[])))
}

/// A whole data file of one line format, as the core split it; lines that
/// don't read are skipped.
pub(crate) fn lines<T: crate::data_lines::Line>(node: &NodeView, file: &str) -> Vec<T> {
    node.typed_lines(file)
}

/// Tracks one file's fingerprint; `changed` is true once per new value.
#[derive(Default)]
pub(crate) struct Watch(Option<Fingerprint>);

impl Watch {
    pub fn changed(&mut self, node: &NodeView, file: &str) -> bool {
        let f = fingerprint(node, file);
        let ch = self.0 != Some(f);
        self.0 = Some(f);
        ch
    }
}

/// A number prop, or `default`.
pub(crate) fn number(node: &NodeView, file: &str, default: f32) -> f32 {
    node.text(file)
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(default)
}

/// The GPUI Kit size for a node's size word.
pub(crate) fn kit_size(st: &ParsedStyle) -> Option<Size> {
    st.size.as_deref().map(|s| match s {
        "xs" => Size::XSmall,
        "sm" => Size::Small,
        "lg" => Size::Large,
        _ => Size::Medium,
    })
}

/// A GPUI Kit icon by name, as the `icon` element draws it.
pub(crate) fn icon(name: &str) -> Icon {
    Icon::default().path(format!("icons/{}.svg", name.trim()))
}

/// `{field}` placeholders filled from `vals`; unknown names stay as written.
pub(crate) fn substitute(s: &str, vals: &HashMap<&str, &str>) -> String {
    if !s.contains('{') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('{') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        match after.find('}') {
            Some(j) if vals.contains_key(&after[..j]) => {
                out.push_str(vals[&after[..j]]);
                rest = &after[j + 1..];
            }
            _ => {
                out.push('{');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// The values a `row` template sees for one item: `id`, then the names in
/// `fields` for the label and the further TSV columns, in order.
pub(crate) fn item_values<'a>(
    fields: &'a [String],
    e: &'a crate::data_lines::Entry,
) -> HashMap<&'a str, &'a str> {
    let mut m = HashMap::new();
    m.insert("id", e.id.as_str());
    m.insert("label", e.label.as_str());
    let cols = std::iter::once(e.label.as_str()).chain(e.fields.iter().map(|s| s.as_str()));
    for (k, v) in fields.iter().zip(cols) {
        m.insert(k.as_str(), v);
    }
    if let Some(i) = &e.icon {
        m.insert("icon", i.as_str());
    }
    m
}

/// Stamps a template subtree once for one item. Text-valued files of the
/// element tier (and of `avatar`, `tag`, `kbd`) get their placeholders
/// filled; any other type renders as written. Stamped nodes share the
/// template's element ids, which is fine because each stamp sits inside its
/// own row element.
pub(crate) fn stamp(rcx: &mut RenderCx, t: &NodeView, vals: &HashMap<&str, &str>) -> AnyElement {
    let sub = |f: &str| substitute(&t.text(f).unwrap_or_default(), vals);
    match t.ty() {
        "div" => {
            let kids: Vec<AnyElement> = t
                .children()
                .iter()
                .map(|c| stamp(rcx, c, vals))
                .collect();
            rcx.element(t).children(kids).into_any_element()
        }
        "text" => {
            let truncate = t
                .text("flags")
                .unwrap_or_default()
                .split_whitespace()
                .any(|f| f == "truncate");
            let mut el = rcx.element(t);
            if truncate {
                el = el.overflow_hidden().text_ellipsis().whitespace_nowrap();
            }
            el.child(sub("text")).into_any_element()
        }
        "icon" => {
            let st = rcx.style_of(t);
            let mut i = icon(&sub("name"));
            if let Some(c) = st.base.text.color {
                i = i.text_color(c);
            }
            rcx.element(t)
                .flex()
                .items_center()
                .justify_center()
                .child(i)
                .into_any_element()
        }
        "avatar" => display::avatar(rcx, t, &sub("name"), &sub("src")),
        "tag" => display::tag(rcx, t, &sub("label")),
        "kbd" => display::kbd(rcx, t, &sub("key")),
        _ => rcx.render(t),
    }
}

/// The node's `x y w h` from the last layout.
pub(crate) fn bounds(node: &NodeView) -> Option<[f32; 4]> {
    node.bounds()
}

/// Space-separated IDs.
pub(crate) fn id_set(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_string).collect()
}
