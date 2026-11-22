//! `dock` and `dock-panel`: GPUI Kit's `DockArea`.
//!
//! Each `dock-panel` child is one dock panel entity ([`DockPanelView`])
//! whose content is the node's children, rendered through the host like any
//! other subtree. The user drags, splits, resizes and zooms inside GPUI Kit;
//! the host mirrors the area's serialized `DockAreaState` to `layout` and
//! sends a coalesced `layout` event. Writing `layout` loads one (panels it
//! names that no longer exist are dropped, panels it doesn't name stay
//! closed until `activate`d); writing it empty puts every panel back in its
//! `zone`.
//!
//! Closing a tab sends `panel-close id=<name>` on the dock, a request whose
//! default is `close`. Answering `keep seq=N` brings the panel back.
//! `activate` on a dock-panel's ctl shows it, reopening it if it was closed.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, Context, Entity, EntityId, EventEmitter,
    FocusHandle, Focusable, IntoElement, ParentElement as _, Render, SharedString, Styled as _,
    WeakEntity, Window, div, px,
};
use gpui_component::dock::{
    BasePanel, DockArea, DockAreaState, DockEvent, DockPlacement, DockSkin, Panel, PanelEvent,
    PanelInfo, PanelState, panel_handle, register_panel,
};
use gpui_component::{Icon, h_flex};

use super::{entity, spec};
use crate::{Component, NodeView, RenderCx};
use tree::Answer;

/// The panel name every dock-panel persists under.
const PANEL_NAME: &str = "gpuifs.dock-panel";

pub struct DockComponent;
pub struct DockPanelComponent;

/// What the dock node and its panels share. Kept outside the `DockNode`
/// entity so the panel builder can reach it while a `load` holds the area.
pub struct Shared {
    node: NodeView,
    /// Panel entities by child name, open or closed.
    panels: RefCell<HashMap<String, Entity<DockPanelView>>>,
    /// Panels the user closed (or a loaded layout left out).
    closed: RefCell<HashSet<String>>,
    /// Set while the host edits the area itself: removals then are not the
    /// user's, and activations are not reported.
    busy: Cell<bool>,
    /// Open `panel-close` requests: seq -> panel name.
    requests: RefCell<HashMap<u64, String>>,
    /// The `layout` the tree holds.
    last_layout: RefCell<String>,
}

thread_local! {
    /// Each dock area's shared state, for the panel builder.
    static AREAS: RefCell<HashMap<EntityId, Rc<Shared>>> = RefCell::new(HashMap::new());
}

/// The host-side state of one `dock` node.
pub struct DockNode {
    pub area: Entity<DockArea>,
    shared: Rc<Shared>,
    _subs: Vec<gpui::Subscription>,
}

/// One dock panel: a `dock-panel` node's children.
pub struct DockPanelView {
    node: NodeView,
    shared: std::rc::Weak<Shared>,
    focus: FocusHandle,
    active: bool,
}

impl EventEmitter<PanelEvent> for DockPanelView {}

impl Focusable for DockPanelView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl DockPanelView {
    fn exists(&self) -> bool {
        self.node.host.node_view(self.node.path()).is_some()
    }

    fn busy(&self) -> bool {
        self.shared.upgrade().is_none_or(|s| s.busy.get())
    }
}

impl BasePanel for DockPanelView {
    fn panel_name(&self) -> &'static str {
        PANEL_NAME
    }

    fn closable(&self, _: &App) -> bool {
        self.node.flag("closable")
    }

    fn zoomable(&self, _: &App) -> bool {
        self.node.flag("zoomable")
    }

    fn set_active(&mut self, active: bool, _: &mut Window, _: &mut Context<Self>) {
        if active && !self.active && !self.busy() && self.exists() {
            self.node.emitter().event("activate", &[]);
        }
        self.active = active;
    }

    /// The user closed the tab: ask the client (default: it stays closed).
    fn on_removed(&mut self, _: &mut Window, _: &mut Context<Self>) {
        self.active = false;
        let Some(sh) = self.shared.upgrade() else {
            return;
        };
        let name = self.node.name().to_string();
        sh.closed.borrow_mut().insert(name.clone());
        if sh.busy.get() || !self.exists() {
            return;
        }
        let ev = tree::EventMsg::new(catalog::EventKind::Request, "panel-close")
            .node(sh.node.path())
            .attr("id", &name);
        let seq = {
            let mut t = sh.node.host.tree.borrow_mut();
            t.open_request(ev, Answer::verb("close"), tree::REQUEST_TIMEOUT)
        };
        sh.requests.borrow_mut().insert(seq, name);
        sh.node.host.pending.borrow_mut().insert(
            seq,
            crate::runtime::Pending::Component(sh.node.path().to_string()),
        );
    }

    fn dump(&self, _: &App) -> PanelState {
        let mut s = PanelState::new(PANEL_NAME);
        s.info = PanelInfo::panel(serde_json::json!({ "id": self.node.name() }));
        s
    }
}

impl Panel for DockPanelView {
    fn tab_name(&self, _: &App) -> Option<SharedString> {
        self.node.text("title").map(Into::into)
    }

    fn title(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let title = self
            .node
            .text("title")
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| self.node.name().to_string());
        let icon = self.node.text("icon").filter(|i| !i.trim().is_empty());
        h_flex()
            .gap_1()
            .items_center()
            .children(icon.map(|i| Icon::default().path(format!("icons/{}.svg", i.trim()))))
            .child(title)
    }
}

impl Render for DockPanelView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let host = self.node.host.clone();
        let Some(node) = host.node_view(self.node.path()) else {
            return div().into_any_element();
        };
        let mut rcx = RenderCx::new(window, cx, host);
        rcx.render(&node)
    }
}

fn placement(node: &NodeView) -> DockPlacement {
    match node.text("zone").as_deref().map(str::trim) {
        Some("left") => DockPlacement::Left,
        Some("right") => DockPlacement::Right,
        Some("bottom") => DockPlacement::Bottom,
        _ => DockPlacement::Center,
    }
}

fn dock_size(p: DockPlacement) -> Option<gpui::Pixels> {
    match p {
        DockPlacement::Left | DockPlacement::Right => Some(px(240.)),
        DockPlacement::Bottom => Some(px(200.)),
        DockPlacement::Center => None,
    }
}

fn panel_children(node: &NodeView) -> Vec<NodeView> {
    node.children()
        .into_iter()
        .filter(|c| c.ty() == "dock-panel")
        .collect()
}

impl Shared {
    fn panel(&self, child: &NodeView, cx: &mut App) -> Entity<DockPanelView> {
        if let Some(p) = self.panels.borrow().get(child.name()) {
            return p.clone();
        }
        let shared = AREAS.with(|a| {
            a.borrow()
                .values()
                .find(|s| s.node.path() == self.node.path())
                .map(Rc::downgrade)
        });
        let p = cx.new(|cx| DockPanelView {
            node: child.clone(),
            shared: shared.unwrap_or_default(),
            focus: cx.focus_handle(),
            active: false,
        });
        self.panels
            .borrow_mut()
            .insert(child.name().to_string(), p.clone());
        p
    }
}

impl DockNode {
    fn new(node: &NodeView, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (area, skin) = DockSkin::dock_area(node.path().to_string(), Some(1), window, cx);
        skin.set_close_button_visible(true, cx);
        let shared = Rc::new(Shared {
            node: node.clone(),
            panels: RefCell::new(HashMap::new()),
            closed: RefCell::new(HashSet::new()),
            busy: Cell::new(false),
            requests: RefCell::new(HashMap::new()),
            last_layout: RefCell::new(String::new()),
        });
        AREAS.with(|a| a.borrow_mut().insert(area.entity_id(), shared.clone()));
        let subs = vec![
            cx.subscribe_in(&area, window, |this, _, ev: &DockEvent, _, cx| {
                if let DockEvent::LayoutChanged = ev {
                    this.report_layout(true, cx);
                }
            }),
        ];
        let mut me = DockNode {
            area,
            shared,
            _subs: subs,
        };
        let layout = me.shared.node.text("layout").unwrap_or_default();
        if no_layout(&layout) {
            me.reconcile(window, cx);
        } else {
            me.load(&layout, window, cx);
        }
        me.report_layout(false, cx);
        me
    }

    /// Mirrors the area's layout; with `event`, a change also sends `layout`.
    fn report_layout(&mut self, event: bool, cx: &mut Context<Self>) {
        let state = self.area.read(cx).dump(cx);
        let Ok(json) = serde_json::to_string(&state) else {
            return;
        };
        if *self.shared.last_layout.borrow() == json {
            return;
        }
        let em = self.shared.node.emitter();
        em.mirror("layout", json.clone().into_bytes());
        if event && !self.shared.busy.get() {
            em.event("layout", &[]);
        }
        *self.shared.last_layout.borrow_mut() = json;
    }

    /// Adds a panel to the area at its zone.
    fn add(&mut self, child: &NodeView, window: &mut Window, cx: &mut Context<Self>) {
        let p = self.shared.panel(child, cx);
        let at = placement(child);
        self.area.update(cx, |a, cx| {
            a.add_panel_view(panel_handle(p), at, dock_size(at), window, cx);
            if at == DockPlacement::Bottom {
                a.set_dock_collapsible(at, true, window, cx);
            }
        });
    }

    /// Brings the area in line with the tree's dock-panel children.
    fn reconcile(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let kids = panel_children(&self.shared.node);
        let names: HashSet<String> = kids.iter().map(|k| k.name().to_string()).collect();
        self.shared.busy.set(true);
        let gone: Vec<(String, Entity<DockPanelView>)> = self
            .shared
            .panels
            .borrow()
            .iter()
            .filter(|(n, _)| !names.contains(*n))
            .map(|(n, p)| (n.clone(), p.clone()))
            .collect();
        for (n, p) in gone {
            self.area.update(cx, |a, cx| a.remove_panel(p, window, cx));
            self.shared.panels.borrow_mut().remove(&n);
            self.shared.closed.borrow_mut().remove(&n);
        }
        for k in &kids {
            let known = self.shared.panels.borrow().contains_key(k.name());
            if !known && !self.shared.closed.borrow().contains(k.name()) {
                self.add(k, window, cx);
            }
        }
        self.shared.busy.set(false);
    }

    /// Loads a serialized layout; an empty one resets every panel to its zone.
    fn load(&mut self, json: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.shared.busy.set(true);
        if no_layout(json) {
            let all: Vec<Entity<DockPanelView>> =
                self.shared.panels.borrow().values().cloned().collect();
            for p in all {
                self.area.update(cx, |a, cx| a.remove_panel(p, window, cx));
            }
            self.shared.panels.borrow_mut().clear();
            self.shared.closed.borrow_mut().clear();
            self.shared.busy.set(false);
            self.reconcile(window, cx);
            return;
        }
        let state: DockAreaState = match serde_json::from_str(json) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("gpuifs: {}/layout: {e}", self.shared.node.path());
                self.shared.busy.set(false);
                return;
            }
        };
        let named = layout_ids(&state);
        // Panels the layout doesn't name stay closed; the builder makes the
        // ones it does (see `build_panel`).
        {
            let mut closed = self.shared.closed.borrow_mut();
            closed.clear();
            for k in panel_children(&self.shared.node) {
                if !named.contains(k.name()) {
                    closed.insert(k.name().to_string());
                }
            }
        }
        let r = self.area.update(cx, |a, cx| a.load(state, window, cx));
        if let Err(e) = r {
            eprintln!("gpuifs: {}/layout: {e}", self.shared.node.path());
        }
        // Panels the layout named that the tree no longer has.
        let stale: Vec<Entity<DockPanelView>> = self
            .shared
            .panels
            .borrow()
            .values()
            .filter(|p| !p.read(cx).exists())
            .cloned()
            .collect();
        for p in stale {
            let n = p.read(cx).node.name().to_string();
            self.area.update(cx, |a, cx| a.remove_panel(p, window, cx));
            self.shared.panels.borrow_mut().remove(&n);
        }
        self.shared.busy.set(false);
    }

    /// `activate`: show a panel, reopening it if it was closed.
    fn activate(&mut self, child: &NodeView, window: &mut Window, cx: &mut Context<Self>) {
        let reopen = self.shared.closed.borrow_mut().remove(child.name())
            || !self.shared.panels.borrow().contains_key(child.name());
        self.shared.busy.set(true);
        if reopen {
            self.add(child, window, cx);
        }
        let p = self.shared.panel(child, cx);
        let id = gpui_component::dock::PanelId::from(p.entity_id());
        self.area.update(cx, |a, cx| a.select_panel(id, window, cx));
        let fh = p.read(cx).focus.clone();
        window.focus(&fh, cx);
        self.shared.busy.set(false);
    }

    /// A panel entity by child name (for tests and the verbs).
    pub fn shared_panel(&self, name: &str) -> Option<Entity<DockPanelView>> {
        self.shared.panels.borrow().get(name).cloned()
    }

    /// The answer to a `panel-close` request.
    fn answer(&mut self, cmd: &proto::Command, window: &mut Window, cx: &mut Context<Self>) {
        let seq = cmd
            .props
            .iter()
            .find(|(k, _)| k == "seq")
            .and_then(|(_, v)| v.parse::<u64>().ok());
        let Some(name) = seq.and_then(|s| self.shared.requests.borrow_mut().remove(&s)) else {
            return;
        };
        let Some(child) = self.shared.node.child(&name) else {
            return;
        };
        if cmd.verb == "keep" {
            self.activate(&child, window, cx);
        } else {
            child.emitter().event("close", &[]);
        }
    }
}

/// An empty `layout`, or the `{}` a new dock reads as, names no layout.
fn no_layout(json: &str) -> bool {
    matches!(json.trim(), "" | "{}")
}

/// The dock-panel names a layout holds.
fn layout_ids(state: &DockAreaState) -> HashSet<String> {
    fn walk(s: &PanelState, out: &mut HashSet<String>) {
        if s.panel_name == PANEL_NAME
            && let PanelInfo::Panel(v) = &s.info
            && let Some(id) = v.get("id").and_then(|i| i.as_str())
        {
            out.insert(id.to_string());
        }
        for c in &s.children {
            walk(c, out);
        }
    }
    let mut out = HashSet::new();
    walk(&state.center, &mut out);
    // Docks keep their panel state private; their panels reach the builder,
    // which is where the rest are counted (see `build_panel`).
    let json = serde_json::to_value(state).unwrap_or_default();
    collect_ids(&json, &mut out);
    out
}

fn collect_ids(v: &serde_json::Value, out: &mut HashSet<String>) {
    match v {
        serde_json::Value::Object(m) => {
            if m.get("panel_name").and_then(|n| n.as_str()) == Some(PANEL_NAME)
                && let Some(id) = m
                    .get("info")
                    .and_then(|i| i.get("panel"))
                    .and_then(|p| p.get("id"))
                    .and_then(|i| i.as_str())
            {
                out.insert(id.to_string());
            }
            for x in m.values() {
                collect_ids(x, out);
            }
        }
        serde_json::Value::Array(a) => {
            for x in a {
                collect_ids(x, out);
            }
        }
        _ => {}
    }
}

thread_local! {
    static REGISTERED: Cell<bool> = const { Cell::new(false) };
}

/// Registers the builder that turns a persisted dock-panel back into the
/// panel entity for that child (made on first use).
fn ensure_registered(cx: &mut App) {
    if REGISTERED.with(|r| r.replace(true)) {
        return;
    }
    register_panel(cx, PANEL_NAME, |ctx, _, cx| {
        let area = ctx.dock_area().entity_id();
        let id = match ctx.info() {
            PanelInfo::Panel(v) => v
                .get("id")
                .and_then(|i| i.as_str())
                .unwrap_or("")
                .to_string(),
            _ => String::new(),
        };
        let shared = AREAS.with(|a| a.borrow().get(&area).cloned());
        let panel = match shared {
            Some(sh) => {
                let child = sh.node.child(&id).filter(|c| c.ty() == "dock-panel");
                match child {
                    Some(c) => sh.panel(&c, cx),
                    // Gone from the tree: a placeholder the load then drops.
                    None => {
                        let n = NodeView {
                            path: format!("{}/{id}", sh.node.path()),
                            win: sh.node.win().to_string(),
                            ty: "dock-panel".into(),
                            host: sh.node.host.clone(),
                        };
                        let p = sh.panel(&n, cx);
                        p
                    }
                }
            }
            None => {
                let empty = cx.new(|cx| Placeholder {
                    focus: cx.focus_handle(),
                });
                return panel_handle(empty);
            }
        };
        panel_handle(panel)
    });
}

/// A persisted panel whose dock is gone.
struct Placeholder {
    focus: FocusHandle,
}
impl EventEmitter<PanelEvent> for Placeholder {}
impl Focusable for Placeholder {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}
impl BasePanel for Placeholder {
    fn panel_name(&self) -> &'static str {
        PANEL_NAME
    }
}
impl Panel for Placeholder {}
impl Render for Placeholder {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
    }
}

impl Component for DockComponent {
    fn spec(&self) -> &'static catalog::TypeSpec {
        spec("dock")
    }

    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        ensure_registered(cx);
        Some(cx.new(|cx| DockNode::new(node, window, cx)).into_any())
    }

    fn prop_changed(
        &self,
        _: &NodeView,
        state: Option<&AnyEntity>,
        prop: &str,
        window: &mut Window,
        cx: &mut App,
    ) {
        if prop != "layout" {
            return;
        }
        let Some(e) = entity::<DockNode>(state) else {
            return;
        };
        e.update(cx, |me, cx| {
            let json = me.shared.node.text("layout").unwrap_or_default();
            *me.shared.last_layout.borrow_mut() = String::new();
            me.load(&json, window, cx);
            me.report_layout(false, cx);
        });
    }

    fn verb(
        &self,
        _: &NodeView,
        state: Option<&AnyEntity>,
        cmd: &proto::Command,
        window: &mut Window,
        cx: &mut App,
    ) -> Result<(), proto::Error> {
        if let Some(e) = entity::<DockNode>(state)
            && cmd.props.iter().any(|(k, _)| k == "seq")
        {
            e.update(cx, |me, cx| {
                me.answer(cmd, window, cx);
                me.report_layout(false, cx);
            });
        }
        Ok(())
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(e) = rcx.state::<DockNode>(node) else {
            return rcx.element(node).into_any_element();
        };
        let (area, shared) = {
            let me = e.read(rcx.cx_ref());
            (me.area.clone(), me.shared.clone())
        };
        // A dock-panel was added or removed: reconcile after this frame.
        let kids: HashSet<String> = panel_children(node)
            .iter()
            .map(|k| k.name().to_string())
            .collect();
        let known: HashSet<String> = shared.panels.borrow().keys().cloned().collect();
        let closed = shared.closed.borrow().clone();
        let stale = kids
            .iter()
            .any(|k| !known.contains(k) && !closed.contains(k))
            || known.iter().any(|k| !kids.contains(k));
        if stale {
            let weak: WeakEntity<DockNode> = e.downgrade();
            rcx.window.defer(rcx.cx, move |window, cx| {
                if let Some(e) = weak.upgrade() {
                    e.update(cx, |me, cx| {
                        me.reconcile(window, cx);
                        me.report_layout(false, cx);
                    });
                }
            });
        }
        rcx.element_from(node, div().flex().flex_col().min_h_0().min_w_0())
            .child(div().flex_1().min_h_0().size_full().child(area))
            .into_any_element()
    }
}

impl Component for DockPanelComponent {
    fn spec(&self) -> &'static catalog::TypeSpec {
        spec("dock-panel")
    }

    fn verb(
        &self,
        node: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &proto::Command,
        window: &mut Window,
        cx: &mut App,
    ) -> Result<(), proto::Error> {
        if cmd.verb != "activate" {
            return super::no_verb(cmd);
        }
        let Some((parent, _)) = node.path().rsplit_once('/') else {
            return Ok(());
        };
        let st = node
            .host
            .states
            .borrow()
            .get(parent)
            .and_then(|s| s.entity.clone());
        if let Some(e) = entity::<DockNode>(st.as_ref()) {
            e.update(cx, |me, cx| {
                me.activate(node, window, cx);
                me.report_layout(false, cx);
            });
        }
        Ok(())
    }

    /// Drawn inside its dock's panel entity: its children, filling the tab.
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let kids = rcx.children(node);
        rcx.element_from(node, div().size_full().flex().flex_col())
            .children(kids)
            .into_any_element()
    }
}
