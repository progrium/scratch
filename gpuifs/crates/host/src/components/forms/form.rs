//! `form` and `field`.
//!
//! A `form` lays out its `field` children with GPUI Kit's `Form`; each field
//! draws its label, description, error and required mark around its control
//! child. `submit` on a form comes from enter in any input inside it
//! (see `inputs`).

use gpui::{AnyElement, Axis, IntoElement as _, ParentElement as _, Styled as _, px};
use gpui_component::form::{Field, Form};
use gpui_component::{ActiveTheme as _, Sizable as _};

use super::{common, nonempty, num, size};
use crate::{Component, ComponentRegistry, NodeView, RenderCx};

pub(super) fn register(reg: &mut ComponentRegistry) {
    reg.add(FormC);
    reg.add(FieldC);
}

/// A field node as a GPUI Kit `Field`. Its controls render inside the
/// field node's own element box, which reports the field's `bounds`.
fn field(rcx: &mut RenderCx, node: &NodeView) -> Field {
    let mut f = Field::new().required(node.flag("required"));
    if let Some(l) = nonempty(node, "label") {
        f = f.label(l);
    }
    if let Some(d) = nonempty(node, "description") {
        f = f.description(d);
    }
    let kids = rcx.children(node);
    let mut body = rcx.element(node).children(kids);
    if let Some(e) = nonempty(node, "error") {
        let danger = rcx.cx_ref().theme().danger;
        body = body.child(gpui::div().pt_1().text_sm().text_color(danger).child(e));
    }
    f.child(body)
}

fn form_for(rcx: &mut RenderCx, node: &NodeView, fields: Vec<Field>) -> Form {
    let st = rcx.style_of(node);
    let axis = if node.text("layout").as_deref() == Some("h") {
        Axis::Horizontal
    } else {
        Axis::Vertical
    };
    let mut f = Form::new().layout(axis).children(fields);
    if let Some(w) = num(node, "label_width") {
        f = f.label_width(px(w as f32));
    }
    if let Some(s) = size(&st) {
        f = f.with_size(s);
    }
    f
}

struct FormC;
impl Component for FormC {
    common!("form");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let fields: Vec<Field> = node
            .children()
            .iter()
            .filter(|c| c.ty() == "field")
            .map(|c| field(rcx, c))
            .collect();
        let f = form_for(rcx, node, fields);
        rcx.element(node).child(f).into_any_element()
    }
}

/// A field outside a form draws as a one-field vertical form.
struct FieldC;
impl Component for FieldC {
    common!("field");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let f = field(rcx, node);
        Form::new().layout(Axis::Vertical).child(f).into_any_element()
    }
}
