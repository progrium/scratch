//! W6b: the `nav` group. See `catalog::nav` for the specs.
//!
//! Each component is GPUI Kit's own (`TabBar`, `Sidebar`, `Breadcrumb`,
//! `Pagination`, `Stepper`, `TitleBar`, `Toolbar`, `StatusBar`, `Link`)
//! inside the node's box from [`RenderCx::element`], so style words, `on`,
//! `tooltip` and `bounds` work as on any node. State the user changes
//! (the selected tab, the page, the step, a collapsed sidebar) is kept in a
//! small entity so the next frame shows it at once, and mirrored to the
//! node's file with an event, as DESIGN's uncontrolled rule says.

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, ElementId, Entity,
    IntoElement, ParentElement, StatefulInteractiveElement as _,
    Styled, Window,
};
use gpui_component::{
    Icon, IconName, Side, Sizable as _, Size,
    breadcrumb::{Breadcrumb, BreadcrumbItem},
    button::{Button, ButtonVariants as _},
    link::Link,
    pagination::Pagination,
    sidebar::{
        Sidebar, SidebarCollapsible, SidebarGroup, SidebarMenu, SidebarMenuItem,
        SidebarToggleButton,
    },
    status_bar::StatusBar,
    stepper::{Stepper, StepperItem},
    tab::{Tab, TabBar, TabVariant},
    toolbar::Toolbar,
    Disableable as _, ElementExt as _, TitleBar,
};
use crate::data_lines::Item;

use crate::{Component, ComponentRegistry, NodeView, RenderCx};

#[cfg(test)]
pub(crate) mod tests;

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(Tabs);
    reg.add(TabNode);
    reg.add(SidebarNode);
    reg.add(SidebarGroupNode);
    reg.add(SidebarItemNode);
    reg.add(BreadcrumbNode);
    reg.add(PaginationNode);
    reg.add(StepperNode);
    reg.add(TitleBarNode);
    reg.add(ToolbarNode);
    reg.add(StatusBarNode);
    reg.add(LinkNode);
}

// ---- helpers shared with `overlays` ---------------------------------------

pub(crate) fn spec(name: &str) -> &'static crate::Spec {
    crate::spec::must(name)
}

pub(crate) fn no_verb(cmd: &crate::Ctl) -> crate::VerbResult {
    Err(crate::Unhandled)
}

/// A GPUI element id below a node: `path#part`.
pub(crate) fn part_id(node: &NodeView, part: &str) -> ElementId {
    ElementId::Name(format!("{}#{part}", node.path()).into())
}

/// A GPUI Kit icon by name (`settings`, `chevron-down`).
pub(crate) fn icon(name: &str) -> Icon {
    Icon::default().path(format!("icons/{}.svg", name.trim()))
}

pub(crate) fn icon_of(node: &NodeView, file: &str) -> Option<Icon> {
    node.text(file)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .map(|s| icon(&s))
}

/// The node's GPUI Kit size word.
pub(crate) fn size_of(rcx: &RenderCx, node: &NodeView) -> Size {
    match rcx.style_of(node).size.as_deref() {
        Some("xs") => Size::XSmall,
        Some("sm") => Size::Small,
        Some("lg") => Size::Large,
        _ => Size::Medium,
    }
}

/// Entries of an `items` file (groups and separators dropped).
pub(crate) fn entries(node: &NodeView, file: &str) -> Vec<crate::data_lines::Entry> {
    node.typed_lines::<Item>(file)
        .into_iter()
        .filter_map(|i| match i {
            Item::Entry(e) => Some(e),
            _ => None,
        })
        .collect()
}

pub(crate) fn number(node: &NodeView, file: &str, default: f64) -> f64 {
    node.text(file)
        .and_then(|s| s.trim().parse().ok())
        .or_else(|| {
            node.spec()
                .and_then(|s| s.default(file))
                .and_then(|d| d.parse().ok())
        })
        .unwrap_or(default)
}

/// A prop's text, or the spec's default.
pub(crate) fn text_or_default(node: &NodeView, file: &str) -> String {
    node.text(file)
        .filter(|s| !s.trim().is_empty())
        .or_else(|| {
            node.spec()
                .and_then(|s| s.default(file))
                .map(str::to_string)
        })
        .unwrap_or_default()
}

/// State a component changes itself, read before the node's file so a
/// frame never lags the click that changed it. A client write clears it.
#[derive(Default)]
pub(crate) struct Local {
    pub value: Option<String>,
}

pub(crate) fn local(cx: &mut App) -> Option<AnyEntity> {
    Some(cx.new(|_| Local::default()).into_any())
}

fn local_value(rcx: &RenderCx, node: &NodeView, file: &str) -> Option<String> {
    rcx.state::<Local>(node)
        .and_then(|e| e.read(rcx.cx_ref()).value.clone())
        .or_else(|| node.text(file))
        .filter(|s| !s.is_empty())
}

fn clear_local(state: Option<&AnyEntity>, cx: &mut App) {
    if let Some(e) = state.and_then(|s| s.clone().downcast::<Local>().ok()) {
        e.update(cx, |l, _| l.value = None);
    }
}

fn set_local(e: &Option<Entity<Local>>, v: &str, window: &mut Window, cx: &mut App) {
    if let Some(e) = e {
        e.update(cx, |l, _| l.value = Some(v.to_string()));
    }
    window.refresh();
}

macro_rules! stateless {
    ($name:literal) => {
        fn spec(&self) -> &'static crate::Spec {
            spec($name)
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
    };
}

/// A component with a [`Local`] value that a client write to `$file` resets.
macro_rules! with_local {
    ($name:literal, $file:literal) => {
        fn spec(&self) -> &'static crate::Spec {
            spec($name)
        }
        fn create(&self, _: &NodeView, _: &mut Window, cx: &mut App) -> Option<AnyEntity> {
            local(cx)
        }
        fn prop_changed(
            &self,
            _: &NodeView,
            state: Option<&AnyEntity>,
            prop: &str,
            _: &mut Window,
            cx: &mut App,
        ) {
            if prop == $file {
                clear_local(state, cx);
            }
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
    };
}

// ---- tabs, tab -------------------------------------------------------------

struct Tabs;
impl Component for Tabs {
    with_local!("tabs", "value");

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let tabs: Vec<NodeView> = node.children().into_iter().filter(|c| c.ty() == "tab").collect();
        let value = local_value(rcx, node, "value");
        let sel = value
            .as_deref()
            .and_then(|v| tabs.iter().position(|t| t.name() == v))
            .unwrap_or(0);
        let st = rcx.style_of(node);
        let variant = if st.has_variant("underline") {
            TabVariant::Underline
        } else if st.has_variant("pill") {
            TabVariant::Pill
        } else if st.has_variant("segmented") {
            TabVariant::Segmented
        } else if st.has_variant("outline") {
            TabVariant::Outline
        } else if st.has_variant("folder") {
            TabVariant::Folder
        } else {
            TabVariant::Tab
        };
        let size = size_of(rcx, node);
        let names: Vec<String> = tabs.iter().map(|t| t.name().to_string()).collect();
        let current = names.get(sel).cloned();
        let em = node.emitter();
        let state = rcx.state::<Local>(node);
        let mut bar = TabBar::new(part_id(node, "bar"))
            .with_variant(variant)
            .with_size(size)
            .selected_index(sel)
            .on_click(move |ix, window, cx| {
                let Some(name) = names.get(*ix) else { return };
                if current.as_deref() == Some(name.as_str()) {
                    return;
                }
                set_local(&state, name, window, cx);
                em.mirror("value", name.clone().into_bytes());
                em.event("change", &[("value", name)]);
            });
        for (i, t) in tabs.iter().enumerate() {
            let mut tab = Tab::new()
                .label(t.text("label").unwrap_or_else(|| t.name().to_string()))
                .disabled(t.flag("disabled"));
            if let Some(ic) = icon_of(t, "icon") {
                tab = tab.icon(ic);
            }
            if t.flag("closable") {
                let tem = t.emitter();
                tab = tab.suffix(part(
                    t,
                    "close",
                    Button::new(part_id(t, "close"))
                        .ghost()
                        .xsmall()
                        .icon(IconName::Close)
                        .on_click(move |_, _, cx| {
                            cx.stop_propagation();
                            tem.request("close", &[], "close");
                        }),
                ));
            }
            // The header's bounds, for hit tests (`path#header`).
            let key = format!("{}#header", t.path());
            tab = tab.on_prepaint(move |b, _, _| record_part(key, b));
            let _ = i;
            bar = bar.child(tab);
        }
        let panel = tabs.get(sel).map(|t| rcx.render(t));
        let mut el = rcx.element_from(node, gpui::div().flex().flex_col());
        // `underline` is a gpui word too; on tabs it is only the variant.
        el.style().text.underline = None;
        el.child(bar).children(panel).into_any_element()
    }
}

struct TabNode;
impl Component for TabNode {
    fn spec(&self) -> &'static crate::Spec {
        spec("tab")
    }
    fn verb(
        &self,
        node: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &crate::Ctl,
        _: &mut Window,
        _: &mut App,
    ) -> crate::VerbResult {
        match cmd.verb.as_str() {
            // The answer to a `close` request: the tab goes away.
            "close" if cmd.attr("seq").is_some() => {
                remove_node(node);
                Ok(())
            }
            "keep" if cmd.attr("seq").is_some() => Ok(()),
            _ => no_verb(cmd),
        }
    }
    /// The panel: drawn by `tabs` only while the tab is selected.
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let kids = rcx.children(node);
        rcx.element_from(node, gpui::div().flex().flex_col().flex_1())
            .children(kids)
            .into_any_element()
    }
}

/// A `close` answer for a tab. The core removes the node when it applies
/// the answer (a renderer never changes the tree); nothing to do here.
pub(crate) fn remove_node(_node: &NodeView) {}

thread_local! {
    /// Bounds of parts of components that aren't nodes (a tab's header), by
    /// `path#part`, from the last frame. Tests click them.
    static PARTS: std::cell::RefCell<std::collections::HashMap<String, gpui::Bounds<gpui::Pixels>>> =
        Default::default();
}

pub(crate) fn record_part(key: String, b: gpui::Bounds<gpui::Pixels>) {
    PARTS.with(|p| p.borrow_mut().insert(key, b));
}

/// `el` in a box whose bounds are recorded as `path#name`.
pub(crate) fn part(node: &NodeView, name: &str, el: impl IntoElement) -> AnyElement {
    let key = format!("{}#{name}", node.path());
    gpui::div()
        .child(el)
        .on_prepaint(move |b, _, _| record_part(key, b))
        .into_any_element()
}

#[allow(dead_code)]
pub(crate) fn part_bounds(key: &str) -> Option<gpui::Bounds<gpui::Pixels>> {
    PARTS.with(|p| p.borrow().get(key).copied())
}

// ---- sidebar ---------------------------------------------------------------

struct SidebarNode;
impl Component for SidebarNode {
    with_local!("sidebar", "collapsed");

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let collapsed = local_value(rcx, node, "collapsed")
            .is_some_and(|v| matches!(v.trim(), "on" | "true" | "1" | "yes"));
        let side = if text_or_default(node, "side") == "right" {
            Side::Right
        } else {
            Side::Left
        };
        let collapsible = text_or_default(node, "collapsible") != "off";
        let header = rcx.slot(node, "header");
        let footer = rcx.slot(node, "footer");
        let groups: Vec<SidebarGroup<SidebarMenu>> = node
            .children()
            .into_iter()
            .filter(|c| c.ty() == "sidebar-group")
            .map(|g| {
                let items = g
                    .children()
                    .into_iter()
                    .filter(|c| c.ty() == "sidebar-item")
                    .map(|i| menu_item(&i));
                SidebarGroup::new(g.text("label").unwrap_or_default())
                    .child(SidebarMenu::new().children(items))
            })
            .collect();

        let em = node.emitter();
        let state = rcx.state::<Local>(node);
        let toggle = collapsible.then(|| {
            SidebarToggleButton::new()
                .side(side)
                .collapsed(collapsed)
                .on_click(move |_, window, cx| {
                    let v = if collapsed { "off" } else { "on" };
                    set_local(&state, v, window, cx);
                    em.mirror("collapsed", v.as_bytes().to_vec());
                    em.event("collapse", &[("value", v)]);
                })
        });
        let head = gpui_component::h_flex()
            .w_full()
            .gap_2()
            .justify_between()
            .children(header.filter(|_| !collapsed))
            .children(toggle);
        let mut sb = Sidebar::new(part_id(node, "sidebar"))
            .side(side)
            .collapsible(if collapsible {
                SidebarCollapsible::Icon
            } else {
                SidebarCollapsible::None
            })
            .collapsed(collapsed)
            .header(head)
            .children(groups);
        if let Some(f) = footer {
            sb = sb.footer(f);
        }
        // The Sidebar draws at its own width (255px unless told), so a
        // `w=` on the node has to reach it, not only the box around it.
        if let Some(w) = rcx.style_of(node).base.size.width {
            sb.style().size.width = Some(w);
        }
        rcx.element_from(node, gpui::div().flex().h_full())
            .child(sb)
            .into_any_element()
    }
}

fn menu_item(node: &NodeView) -> SidebarMenuItem {
    let em = node.emitter();
    let mut item = SidebarMenuItem::new(node.text("label").unwrap_or_else(|| node.name().to_string()))
        .active(node.flag("active"))
        .disable(node.flag("disabled"))
        .on_click(move |_, _, _| em.event("click", &[]));
    if let Some(ic) = icon_of(node, "icon") {
        item = item.icon(ic);
    }
    if let Some(b) = node.text("badge").filter(|b| !b.trim().is_empty()) {
        item = item.suffix(move |_, cx| {
            use gpui_component::ActiveTheme as _;
            gpui::div()
                .px_1p5()
                .rounded_full()
                .text_xs()
                .bg(cx.theme().secondary)
                .text_color(cx.theme().secondary_foreground)
                .child(b.clone())
                .into_any_element()
        });
    }
    let subs: Vec<SidebarMenuItem> = node
        .children()
        .into_iter()
        .filter(|c| c.ty() == "sidebar-item")
        .map(|c| menu_item(&c))
        .collect();
    if !subs.is_empty() {
        item = item.default_open(true).children(subs);
    }
    item
}

/// Drawn by its `sidebar`; alone, a labelled column of its items.
struct SidebarGroupNode;
impl Component for SidebarGroupNode {
    stateless!("sidebar-group");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let kids = rcx.children(node);
        rcx.element_from(node, gpui::div().flex().flex_col().gap_1())
            .child(node.text("label").unwrap_or_default())
            .children(kids)
            .into_any_element()
    }
}

/// Drawn by its `sidebar`; alone, a clickable row.
struct SidebarItemNode;
impl Component for SidebarItemNode {
    stateless!("sidebar-item");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let em = node.emitter();
        rcx.element_from(node, gpui_component::h_flex().gap_2())
            .children(icon_of(node, "icon"))
            .child(node.text("label").unwrap_or_default())
            .on_click(move |_, _, _| em.event("click", &[]))
            .into_any_element()
    }
}

// ---- breadcrumb, pagination, stepper ---------------------------------------

struct BreadcrumbNode;
impl Component for BreadcrumbNode {
    stateless!("breadcrumb");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let items = entries(node, "items").into_iter().map(|e| {
            let em = node.emitter();
            let id = e.id.clone();
            let label = if e.label.is_empty() { e.id.clone() } else { e.label.clone() };
            BreadcrumbItem::new(label)
                .disabled(e.disabled)
                .on_click(move |_, _, _| em.event("click", &[("id", &id)]))
        });
        let bc = Breadcrumb::new().children(items);
        rcx.element(node).child(bc).into_any_element()
    }
}

struct PaginationNode;
impl Component for PaginationNode {
    with_local!("pagination", "page");

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let page = local_value(rcx, node, "page")
            .and_then(|p| p.trim().parse::<f64>().ok())
            .unwrap_or_else(|| number(node, "page", 1.))
            .max(1.) as usize;
        let total = number(node, "total", 0.).max(0.);
        let per = number(node, "per-page", 10.).max(1.);
        let pages = ((total / per).ceil() as usize).max(1);
        let em = node.emitter();
        let state = rcx.state::<Local>(node);
        let size = size_of(rcx, node);
        let pg = Pagination::new(part_id(node, "pages"))
            .current_page(page.min(pages))
            .total_pages(pages)
            .with_size(size)
            .disabled(node.flag("disabled"))
            .on_click(move |p, window, cx| {
                if *p == page {
                    return;
                }
                let v = p.to_string();
                set_local(&state, &v, window, cx);
                em.mirror("page", v.clone().into_bytes());
                em.event("change", &[("page", &v)]);
            });
        rcx.element(node).child(pg).into_any_element()
    }
}

struct StepperNode;
impl Component for StepperNode {
    with_local!("stepper", "value");

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let items = entries(node, "items");
        let value = local_value(rcx, node, "value");
        let sel = value
            .as_deref()
            .and_then(|v| items.iter().position(|e| e.id == v))
            .unwrap_or(0);
        let ids: Vec<String> = items.iter().map(|e| e.id.clone()).collect();
        let em = node.emitter();
        let state = rcx.state::<Local>(node);
        let size = size_of(rcx, node);
        let mut sp = Stepper::new(part_id(node, "steps"))
            .with_size(size)
            .selected_index(sel)
            .disabled(node.flag("disabled"))
            .items(items.iter().map(|e| {
                let label = if e.label.is_empty() { e.id.clone() } else { e.label.clone() };
                let mut it = StepperItem::new().disabled(e.disabled).child(label);
                if let Some(i) = &e.icon {
                    it = it.icon(icon(i));
                }
                it
            }))
            .on_click(move |ix, window, cx| {
                let Some(id) = ids.get(*ix) else { return };
                if *ix == sel {
                    return;
                }
                set_local(&state, id, window, cx);
                em.mirror("value", id.clone().into_bytes());
                em.event("change", &[("value", id)]);
            });
        if text_or_default(node, "dir") == "col" {
            sp = sp.vertical();
        }
        rcx.element(node).child(sp).into_any_element()
    }
}

// ---- title-bar, toolbar, status-bar, link ----------------------------------

struct TitleBarNode;
impl Component for TitleBarNode {
    stateless!("title-bar");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let title = node.text("title").filter(|t| !t.is_empty());
        let kids = rcx.children(node);
        let em = node.emitter();
        let win = node.win().to_string();
        let host = node.host.clone();
        let bar = TitleBar::new()
            .children(title)
            .children(kids)
            .on_close_window(move |_, _, _| {
                // The close control asks, as the system title bar does.
                em.event("action", &[("id", "close")]);
                request_window_close(&host, &win);
            });
        rcx.element(node).child(bar).into_any_element()
    }
}

/// A window `close` request, as the system title bar's close button sends.
fn request_window_close(host: &std::rc::Rc<crate::runtime::Inner>, win: &str) {
    let root = host.core.borrow().window_root(win);
    host.request(root, crate::runtime::Pending::WindowClose(win.to_string()), "close", &[("via", "titlebar")], "close");
}

struct ToolbarNode;
impl Component for ToolbarNode {
    stateless!("toolbar");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let kids = rcx.children(node);
        let tb = Toolbar::new(part_id(node, "toolbar"))
            .disabled(node.flag("disabled"))
            .contents(kids);
        rcx.element(node).child(tb).into_any_element()
    }
}

struct StatusBarNode;
impl Component for StatusBarNode {
    stateless!("status-bar");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let mut sb = StatusBar::new();
        if let Some(l) = rcx.slot(node, "left") {
            sb = sb.left(l);
        }
        if let Some(c) = rcx.slot(node, "center") {
            sb = sb.child(c);
        }
        if let Some(r) = rcx.slot(node, "right") {
            sb = sb.right(r);
        }
        rcx.element(node).child(sb.w_full()).into_any_element()
    }
}

struct LinkNode;
impl Component for LinkNode {
    stateless!("link");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let href = node.text("href").unwrap_or_default();
        let label = node
            .text("label")
            .filter(|l| !l.is_empty())
            .unwrap_or_else(|| href.clone());
        // The host opens https links itself unless `on` lists `click`.
        let opens = !node.on_words().iter().any(|w| w == "click")
            && (href.starts_with("https://") || href.starts_with("http://"));
        let em = node.emitter();
        let mut link = Link::new(part_id(node, "link"))
            .disabled(node.flag("disabled"))
            .child(label)
            .on_click(move |_, _, _| em.event("click", &[]));
        if opens {
            link = link.href(href);
        }
        rcx.element(node).child(link).into_any_element()
    }
}
