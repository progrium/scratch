//! `form` and `field`.
//!
//! A `form` lays out its `field` children with GPUI Kit's `Form`; each field
//! draws its label, description, error and required mark around its control
//! child. `submit` on a form comes from enter in any input inside it
//! (see `inputs`).

use gpui::{AnyElement, Axis, IntoElement as _, ParentElement as _, Styled as _, px};
#[allow(unused_imports)]
use gpui::InteractiveElement as _;
use gpui_component::form::{Field, Form};
use gpui_component::{ActiveTheme as _, Sizable as _};

use super::{common, nonempty, num, size};
use crate::{Component, ComponentRegistry, NodeView, RenderCx};

pub(super) fn register(reg: &mut ComponentRegistry) {
    reg.add(FormC);
    reg.add(FieldC);
}

/// A field node as a GPUI Kit `Field`: its label, description and error
/// around its control child. The field's own style goes on the box around
/// it (`field_box`), so `w=110` sizes what the user sees.
fn field(rcx: &mut RenderCx, node: &NodeView) -> Field {
    let mut f = Field::new().required(node.flag("required"));
    if let Some(l) = nonempty(node, "label") {
        f = f.label(l);
    }
    if let Some(d) = nonempty(node, "description") {
        f = f.description(d);
    }
    let kids = rcx.children(node);
    let mut body = gpui::div().w_full().children(kids);
    if let Some(e) = nonempty(node, "error") {
        let danger = rcx.cx_ref().theme().danger;
        body = body.child(gpui::div().pt_1().text_sm().text_color(danger).child(e));
    }
    f.child(body)
}

/// Where a form's labels go: `labels=side` beside each control, else above.
fn label_axis(form: Option<&NodeView>) -> Axis {
    match form.and_then(|f| f.text("labels")).as_deref().map(str::trim) {
        Some("side") => Axis::Horizontal,
        _ => Axis::Vertical,
    }
}

/// One field, drawn as a one-field GPUI Kit `Form` inside the field
/// node's own element (its style, its bounds).
fn field_box(rcx: &mut RenderCx, form: Option<&NodeView>, node: &NodeView) -> AnyElement {
    let f = field(rcx, node);
    let mut kit = Form::new().layout(label_axis(form)).child(f);
    if let Some(w) = form.and_then(|n| num(n, "label-width")) {
        kit = kit.label_width(px(w as f32));
    }
    if let Some(fm) = form {
        let st = rcx.style_of(fm);
        if let Some(s) = size(&st) {
            kit = kit.with_size(s);
        }
    }
    rcx.element_from(node, gpui::div().flex().flex_col())
        .child(kit)
        .into_any_element()
}

struct FormC;
impl Component for FormC {
    common!("form");
    /// `dir=row` puts the fields side by side, `dir=col` (the default)
    /// stacks them. The form's style sets the gap and everything else.
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let row = node.text("dir").as_deref().map(str::trim) == Some("row");
        let fields: Vec<AnyElement> = node
            .children()
            .iter()
            .filter(|c| c.ty() == "field")
            .map(|c| field_box(rcx, Some(node), c))
            .collect();
        let base = if row {
            gpui::div().flex().flex_row().items_start().gap_3()
        } else {
            gpui::div().flex().flex_col().gap_3()
        };
        rcx.element_from(node, base).children(fields).into_any_element()
    }
}

/// A field outside a form draws as a one-field form, labels on top.
struct FieldC;
impl Component for FieldC {
    common!("field");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        field_box(rcx, None, node)
    }
}
