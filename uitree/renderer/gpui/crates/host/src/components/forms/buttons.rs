//! `button`, `button-group`, `dropdown-button`.

use gpui::{AnyElement, ElementId, ParentElement as _};
use gpui_component::button::{Button, ButtonGroup, ButtonVariant, ButtonVariants as _, DropdownButton};
use gpui_component::menu::{PopupMenu, PopupMenuItem};
use gpui_component::{Disableable as _, Selectable as _, Sizable as _};
use crate::data_lines::{MenuKind, MenuLine};

use super::{boxed, common, icon, nonempty, size, user_change};
use crate::{Component, ComponentRegistry, NodeView, ParsedStyle, RenderCx};

pub(super) fn register(reg: &mut ComponentRegistry) {
    reg.add(ButtonC);
    reg.add(ButtonGroupC);
    reg.add(DropdownButtonC);
}

fn variant(st: &ParsedStyle) -> Option<ButtonVariant> {
    st.variants.iter().rev().find_map(|v| {
        Some(match v.as_str() {
            "primary" => ButtonVariant::Primary,
            "secondary" => ButtonVariant::Secondary,
            "danger" => ButtonVariant::Danger,
            "info" => ButtonVariant::Info,
            "success" => ButtonVariant::Success,
            "warning" => ButtonVariant::Warning,
            "ghost" => ButtonVariant::Ghost,
            "link" => ButtonVariant::Link,
            _ => return None,
        })
    })
}

/// A GPUI Kit button from a `button` node's files, without a click handler.
fn kit_button(node: &NodeView, st: &ParsedStyle) -> Button {
    let mut b = Button::new(ElementId::Name(format!("{}#button", node.path()).into()));
    if let Some(l) = nonempty(node, "label") {
        b = b.label(l);
    }
    if let Some(i) = icon(node) {
        b = b.icon(i);
    }
    if let Some(v) = variant(st) {
        b = b.with_variant(v);
    }
    if st.has_variant("outline") {
        b = b.outline();
    }
    if let Some(s) = size(st) {
        b = b.with_size(s);
    }
    b.loading(node.flag("loading"))
        .disabled(node.flag("disabled"))
        .selected(node.flag("selected"))
}

struct ButtonC;
impl Component for ButtonC {
    common!("button");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let st = rcx.style_of(node);
        let kids = rcx.children(node);
        let em = node.emitter();
        let b = kit_button(node, &st)
            .children(kids)
            .on_click(move |_, _, _| em.event("click", &[]));
        boxed(rcx, node, b)
    }
}

/// The selected child names, from `value`.
fn selected(node: &NodeView) -> Vec<String> {
    node.text("value")
        .unwrap_or_default()
        .split_whitespace()
        .map(str::to_string)
        .collect()
}

struct ButtonGroupC;
impl Component for ButtonGroupC {
    common!("button-group");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let st = rcx.style_of(node);
        let sel = selected(node);
        let kids: Vec<NodeView> = node.children().into_iter().filter(|c| c.ty() == "button").collect();
        let names: Vec<String> = kids.iter().map(|c| c.name().to_string()).collect();
        let buttons: Vec<Button> = kids
            .iter()
            .map(|c| {
                let cst = rcx.style_of(c);
                kit_button(c, &cst).selected(sel.iter().any(|s| s == c.name()))
            })
            .collect();
        let mut g = ButtonGroup::new(ElementId::Name(format!("{}#group", node.path()).into()))
            .children(buttons)
            .multiple(node.flag("multiple"))
            .disabled(node.flag("disabled"));
        if node.text("dir").as_deref() == Some("col") {
            g = g.layout(gpui::Axis::Vertical);
        }
        if let Some(v) = variant(&st) {
            g = g.with_variant(v);
        }
        if st.has_variant("outline") {
            g = g.outline();
        }
        if let Some(s) = size(&st) {
            g = g.with_size(s);
        }
        let em = node.emitter();
        let n = node.clone();
        let g = g.on_click(move |ixs: &Vec<usize>, _, _| {
            let v: Vec<&str> = ixs.iter().filter_map(|i| names.get(*i).map(String::as_str)).collect();
            user_change(&n, &em, &v.join(" "), true);
        });
        boxed(rcx, node, g)
    }
}

/// `menu` lines to PopupMenu items; choosing one sends `action id=`.
/// Submenus are flattened into the one menu.
fn build_menu(mut menu: PopupMenu, lines: &[MenuLine], node: &NodeView) -> PopupMenu {
    for l in lines {
        let prop = |k: &str| l.props.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        match l.kind {
            MenuKind::Sep => menu = menu.separator(),
            MenuKind::Sub => {
                if let Some(label) = prop("label") {
                    menu = menu.label(label);
                }
            }
            MenuKind::Item => {
                let label = prop("label").unwrap_or_else(|| l.id.clone());
                let em = node.emitter();
                let id = l.id.clone();
                let mut item = PopupMenuItem::new(label)
                    .disabled(prop("enabled").as_deref() == Some("off"))
                    .checked(prop("check").as_deref() == Some("on"))
                    .on_click(move |_, _, _| em.menu_action(&id));
                if let Some(i) = prop("icon") {
                    item = item.icon(gpui_component::Icon::default().path(format!("icons/{i}.svg")));
                }
                menu = menu.item(item);
            }
        }
    }
    menu
}

struct DropdownButtonC;
impl Component for DropdownButtonC {
    common!("dropdown-button");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let st = rcx.style_of(node);
        let em = node.emitter();
        let mut b = Button::new(ElementId::Name(format!("{}#button", node.path()).into()))
            .on_click(move |_, _, _| em.event("click", &[]));
        if let Some(l) = nonempty(node, "label") {
            b = b.label(l);
        }
        if let Some(i) = icon(node) {
            b = b.icon(i);
        }
        let lines: Vec<MenuLine> = node.typed_lines("menu");
        let n = node.clone();
        let mut d = DropdownButton::new(ElementId::Name(format!("{}#dropdown", node.path()).into()))
            .button(b)
            .dropdown_menu(move |menu, _, _| build_menu(menu, &lines, &n))
            .disabled(node.flag("disabled"));
        if let Some(v) = variant(&st) {
            d = d.with_variant(v);
        }
        if st.has_variant("outline") {
            d = d.outline();
        }
        if let Some(s) = size(&st) {
            d = d.with_size(s);
        }
        boxed(rcx, node, d)
    }
}

