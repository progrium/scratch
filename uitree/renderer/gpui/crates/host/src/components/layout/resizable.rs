//! `resizable` and `panel`: GPUI Kit's resizable panel group.
//!
//! A finished drag mirrors every panel's `size` (via=user) and sends one
//! `resize sizes='a b ...'` on the group. A client write to a panel's `size`
//! resizes it in place, with no event.

use std::cell::Cell;
use std::rc::Rc;

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, Entity, IntoElement, ParentElement as _, Pixels,
    Styled as _, Window, div, px,
};
use gpui_component::resizable::{ResizableState, h_resizable, resizable_panel, v_resizable};

use super::{entity, no_verb, number, spec};
use crate::{Component, NodeView, RenderCx};

pub struct ResizableComponent;
pub struct PanelComponent;

/// The host-side state of one `resizable`.
pub struct ResizableNode {
    state: Entity<ResizableState>,
    /// Resizes the client asked for whose `Resized` hasn't arrived yet.
    quiet: Rc<Cell<u32>>,
}

fn panels(node: &NodeView) -> Vec<NodeView> {
    node.children()
        .into_iter()
        .filter(|c| c.ty() == "panel")
        .collect()
}

fn fmt_px(p: Pixels) -> String {
    let v = f32::from(p);
    if v.fract().abs() < 0.05 {
        format!("{}", v.round() as i64)
    } else {
        format!("{v:.1}")
    }
}

impl Component for ResizableComponent {
    fn spec(&self) -> &'static crate::Spec {
        spec("resizable")
    }

    fn create(&self, _: &NodeView, _: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let state = cx.new(|_| ResizableState::default());
        Some(
            cx.new(|_| ResizableNode {
                state,
                quiet: Rc::new(Cell::new(0)),
            })
            .into_any(),
        )
    }

    fn verb(
        &self,
        _: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &crate::Ctl,
        _: &mut Window,
        _: &mut App,
    ) -> crate::VerbResult {
        no_verb(cmd)
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(e) = rcx.state::<ResizableNode>(node) else {
            return rcx.element(node).into_any_element();
        };
        let (state, quiet) = {
            let me = e.read(rcx.cx_ref());
            (me.state.clone(), me.quiet.clone())
        };
        let vertical = node.text("dir").as_deref().map(str::trim) == Some("col");
        let id = gpui::ElementId::Name(format!("{}#group", node.path()).into());
        let mut group = if vertical {
            v_resizable(id)
        } else {
            h_resizable(id)
        }
        .with_state(&state);
        let kids = panels(node);
        for p in &kids {
            let mut rp = resizable_panel();
            if let Some(s) = number(p, "size").filter(|s| *s > 0.) {
                rp = rp.size(px(s));
            }
            let min = number(p, "min").filter(|m| *m >= 0.);
            let max = number(p, "max").filter(|m| *m > 0.);
            if min.is_some() || max.is_some() {
                rp = rp.size_range(px(min.unwrap_or(0.))..max.map(px).unwrap_or(Pixels::MAX));
            }
            group = group.child(rp.child(rcx.render(p)));
        }
        let names: Vec<NodeView> = kids;
        let em = node.emitter();
        group = group.on_resize(move |state, _, cx| {
            let sizes: Vec<String> = state.read(cx).sizes().iter().map(|s| fmt_px(*s)).collect();
            for (p, s) in names.iter().zip(&sizes) {
                p.emitter().mirror("size", s.clone().into_bytes());
            }
            if quiet.get() > 0 {
                quiet.set(quiet.get() - 1);
                return;
            }
            em.event("resize", &[("sizes", &sizes.join(" "))]);
        });
        rcx.element_from(node, div().flex())
            .child(group)
            .into_any_element()
    }
}

impl Component for PanelComponent {
    fn spec(&self) -> &'static crate::Spec {
        spec("panel")
    }

    /// A client write to `size` resizes the panel in its group.
    fn prop_changed(
        &self,
        node: &NodeView,
        _: Option<&AnyEntity>,
        prop: &str,
        window: &mut Window,
        cx: &mut App,
    ) {
        if prop != "size" {
            return;
        }
        let Some(size) = number(node, "size").filter(|s| *s > 0.) else {
            return;
        };
        let Some(group) = node.parent() else {
            return;
        };
        let Some(ix) = panels(&group).iter().position(|p| p.path() == node.path()) else {
            return;
        };
        let st = node
            .host
            .states
            .borrow()
            .get(&group.node())
            .and_then(|s| s.entity.clone());
        let Some(g) = entity::<ResizableNode>(st.as_ref()) else {
            return;
        };
        let (state, quiet) = {
            let me = g.read(cx);
            (me.state.clone(), me.quiet.clone())
        };
        quiet.set(quiet.get() + 1);
        state.update(cx, |s, cx| s.resize_panel(ix, px(size), window, cx));
    }

    fn verb(
        &self,
        _: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &crate::Ctl,
        _: &mut Window,
        _: &mut App,
    ) -> crate::VerbResult {
        no_verb(cmd)
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let kids = rcx.children(node);
        rcx.element_from(node, div().size_full().flex().flex_col())
            .children(kids)
            .into_any_element()
    }
}
