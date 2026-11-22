//! `accordion`, `accordion-item`, `collapsible`, `group-box`, `separator`, `grid`.

use gpui::{
    AnyElement, AnyEntity, App, InteractiveElement as _, IntoElement, ParentElement as _,
    StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use gpui_component::accordion::Accordion;
use gpui_component::collapsible::Collapsible;
use gpui_component::group_box::{GroupBox, GroupBoxVariant, GroupBoxVariants as _};
use gpui_component::separator::Separator;
use gpui_component::{Icon, Sizable as _, Size};

use super::{no_verb, number, spec};
use crate::{Component, NodeView, RenderCx};

macro_rules! no_verbs {
    () => {
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
    };
}

fn size_of(word: Option<&str>) -> Size {
    match word {
        Some("xs") => Size::XSmall,
        Some("sm") => Size::Small,
        Some("lg") => Size::Large,
        _ => Size::Medium,
    }
}

// ---------------------------------------------------------------------------
// accordion

pub struct AccordionComponent;
impl Component for AccordionComponent {
    fn spec(&self) -> &'static catalog::TypeSpec {
        spec("accordion")
    }
    no_verbs!();

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let st = rcx.style_of(node);
        let open: Vec<String> = node
            .text("value")
            .unwrap_or_default()
            .split_whitespace()
            .map(str::to_string)
            .collect();
        let multiple = node.flag("multiple");
        let items: Vec<NodeView> = node
            .children()
            .into_iter()
            .filter(|c| c.ty() == "accordion-item")
            .collect();
        let names: Vec<String> = items.iter().map(|c| c.name().to_string()).collect();
        let mut acc = Accordion::new(gpui::ElementId::Name(format!("{}#acc", node.path()).into()))
            .multiple(multiple)
            .with_size(size_of(st.size.as_deref()));
        for item in &items {
            let kids = rcx.children(item);
            let title = item.text("title").unwrap_or_default();
            let icon = item.text("icon").filter(|i| !i.trim().is_empty());
            let is_open = open.iter().any(|o| o == item.name());
            let disabled = item.flag("disabled");
            acc = acc.item(move |it| {
                let mut it = it
                    .title(title)
                    .open(is_open)
                    .disabled(disabled)
                    .children(kids);
                if let Some(i) = icon {
                    it = it.icon(Icon::default().path(format!("icons/{}.svg", i.trim())));
                }
                it
            });
        }
        let em = node.emitter();
        let before = open.join(" ");
        acc = acc.on_toggle_click(move |ixs, _, _| {
            let mut ixs = ixs.to_vec();
            ixs.sort_unstable();
            let value = ixs
                .iter()
                .filter_map(|i| names.get(*i).cloned())
                .collect::<Vec<_>>()
                .join(" ");
            if value != before {
                em.mirror("value", value.clone().into_bytes());
                em.event("change", &[("value", &value)]);
            }
        });
        rcx.element_from(node, div().flex().flex_col())
            .child(acc)
            .into_any_element()
    }
}

/// Drawn by its `accordion`; on its own it is a box of its children.
pub struct AccordionItemComponent;
impl Component for AccordionItemComponent {
    fn spec(&self) -> &'static catalog::TypeSpec {
        spec("accordion-item")
    }
    no_verbs!();
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let kids = rcx.children(node);
        rcx.element(node).children(kids).into_any_element()
    }
}

// ---------------------------------------------------------------------------
// collapsible

pub struct CollapsibleComponent;
impl Component for CollapsibleComponent {
    fn spec(&self) -> &'static catalog::TypeSpec {
        spec("collapsible")
    }
    no_verbs!();

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let open = node.flag("open");
        let trigger = rcx.slot(node, "trigger");
        let content = rcx.slot(node, "content");
        let others = rcx.children(node);
        let em = node.emitter();
        let trigger = div()
            .id(gpui::ElementId::Name(
                format!("{}#trigger", node.path()).into(),
            ))
            .cursor_pointer()
            .children(trigger)
            .on_click(move |_, _, _| {
                let v = if open { "off" } else { "on" };
                em.mirror("open", v.as_bytes().to_vec());
                em.event("change", &[("value", v)]);
            });
        let mut c = Collapsible::new()
            .open(open)
            .motion_id(gpui::ElementId::Name(
                format!("{}#reveal", node.path()).into(),
            ))
            .child(trigger)
            .children(others);
        if let Some(content) = content {
            c = c.content(content);
        }
        rcx.element_from(node, div().flex().flex_col())
            .child(c)
            .into_any_element()
    }
}

// ---------------------------------------------------------------------------
// group-box, separator, grid

pub struct GroupBoxComponent;
impl Component for GroupBoxComponent {
    fn spec(&self) -> &'static catalog::TypeSpec {
        spec("group-box")
    }
    no_verbs!();

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let st = rcx.style_of(node);
        let variant = st
            .variants
            .iter()
            .find(|v| catalog::layout::GROUP_BOX_VARIANTS.contains(&v.as_str()))
            .map(|v| GroupBoxVariant::from_str(v))
            .unwrap_or_default();
        let kids = rcx.children(node);
        let mut gb = GroupBox::new()
            .id(gpui::ElementId::Name(format!("{}#box", node.path()).into()))
            .with_variant(variant)
            .w_full()
            .children(kids);
        if let Some(t) = node.text("title").filter(|t| !t.is_empty()) {
            gb = gb.title(t);
        }
        rcx.element_from(node, div().flex().flex_col())
            .child(gb)
            .into_any_element()
    }
}

pub struct SeparatorComponent;
impl Component for SeparatorComponent {
    fn spec(&self) -> &'static catalog::TypeSpec {
        spec("separator")
    }
    no_verbs!();

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let vertical = node.text("dir").as_deref().map(str::trim) == Some("v");
        let mut sep = if vertical {
            Separator::vertical()
        } else {
            Separator::horizontal()
        };
        if let Some(l) = node.text("label").filter(|l| !l.is_empty()) {
            sep = sep.label(l);
        }
        let base = if vertical {
            div().flex().flex_col().self_stretch().flex_none()
        } else {
            div().flex().w_full().flex_none()
        };
        rcx.element_from(node, base).child(sep).into_any_element()
    }
}

pub struct GridComponent;
impl Component for GridComponent {
    fn spec(&self) -> &'static catalog::TypeSpec {
        spec("grid")
    }
    no_verbs!();

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let mut base = div().grid();
        if let Some(c) = number(node, "cols").filter(|c| *c >= 1.) {
            base = base.grid_cols(c as u16);
        }
        if let Some(r) = number(node, "rows").filter(|r| *r >= 1.) {
            base = base.grid_rows(r as u16);
        }
        if let Some(g) = number(node, "gap").filter(|g| *g >= 0.) {
            base = base.gap(px(g));
        }
        let kids = rcx.children(node);
        rcx.element_from(node, base)
            .children(kids)
            .into_any_element()
    }
}
