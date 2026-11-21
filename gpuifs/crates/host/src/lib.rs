//! The GPUI host: app, windows, root view, materialize, style application,
//! theme, actions, menus. Owned by W5b, except `components/` (W6a-d) and
//! `canvas/`, `dnd/`, `clipboard.rs` (W7).
//!
//! # How it fits together
//!
//! - [`run`] starts GPUI and hands the `gpuifs` binary an [`ninep::FsBackend`]
//!   (`runtime::HostBackend`). The 9P thread sends each op over a channel to
//!   the main thread, which applies it to the [`tree::Tree`] inside an
//!   `update`, publishes a fresh snapshot, then acks the op.
//! - Each window has one root view (`window::WindowView`). Its `render`
//!   walks the window's committed tree and builds elements with
//!   [`RenderCx`]; the element tier lives in [`elements`], every other type
//!   is a [`Component`] that a W6/W7 group registered.
//! - GPUI listeners never touch the tree directly. They send through an
//!   [`Emitter`], which queues on the same channel, so events, mirrors and
//!   ops are applied in order on the main thread.
//!
//! # For component threads (W6, W7)
//!
//! Implement [`Component`] and `reg.add(...)` it in your group's
//! `register`. In `render`, start from [`RenderCx::element`] when your
//! component is a box (it applies style words, `on`, `context`, `tooltip`,
//! `bounds`), or build a GPUI Kit element and pass it through
//! [`RenderCx::styled`]. Read props with [`NodeView::text`] /
//! [`NodeView::prop`]; size and variant words with [`RenderCx::style_of`].
//! Send events with [`RenderCx::emitter`]. State entities made in
//! [`Component::create`] come back from [`RenderCx::state`].
//!
//! A request opened with [`Emitter::request`] is answered (by the client's
//! `ctl` write with `seq=`, or by the default after a timeout) by calling
//! your [`Component::verb`] with the answer command, for example
//! `close seq=12` or `keep seq=12`.
//!
//! Overlays (`windows/<w>/overlays/<name>`) are rendered after the root, in
//! order, through the same path; `open`/`close` on an overlay's `ctl` come
//! to the overlay's component as `verb`s.
//!
//! Tests: `testing::Harness` (behind `cfg(test)` or the `test-support`
//! feature) builds a tree with ops, renders it in a `TestAppContext` window,
//! simulates input and reads events back.
#![allow(clippy::too_many_arguments, unused_variables)]

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;

use gpui::{
    AnyElement, AnyEntity, App, Entity, FocusHandle, Refineable as _, ScrollHandle, Stateful,
    Styled, Window, div,
};

pub use tree::{Answer, Bytes};

pub mod canvas;
pub mod clipboard;
pub mod components;
pub mod dnd;
pub mod elements;

mod actions;
mod materialize;
mod runtime;
pub mod styling;
mod theme;
mod window;

#[cfg(any(test, feature = "test-support"))]
pub mod testing;

#[cfg(test)]
mod tests;

pub use actions::ClientAction;
pub use runtime::HostBackend;
pub use styling::ParsedStyle;

/// What the `gpuifs` binary passes in.
#[derive(Debug, Clone, Default)]
pub struct HostOptions {
    /// `-t title`: the app name and default window title.
    pub title: Option<String>,
    /// `-k`: keep running after the client exits.
    pub keep: bool,
}

/// Starts GPUI on the calling (main) thread and never returns until the app
/// quits. `start` runs once on the main thread with the backend the 9P
/// server should serve; the caller spawns the server and the h9 machine there.
pub fn run(opts: HostOptions, start: impl FnOnce(Arc<dyn ninep::FsBackend>) + 'static) {
    runtime::run(opts, start)
}

/// Every component the host knows: the element tier, each W6 group, and canvas.
pub fn register_all(reg: &mut ComponentRegistry) {
    elements::register(reg);
    components::register(reg);
    canvas::register(reg);
}

/// Components by type name.
#[derive(Default)]
pub struct ComponentRegistry {
    components: Vec<Box<dyn Component>>,
}

impl ComponentRegistry {
    pub fn add(&mut self, c: impl Component) {
        self.components.push(Box::new(c));
    }
    pub fn get(&self, ty: &str) -> Option<&dyn Component> {
        self.components
            .iter()
            .find(|c| c.spec().name == ty)
            .map(|c| c.as_ref())
    }
    /// Type names that have a renderer.
    pub fn names(&self) -> Vec<&'static str> {
        self.components.iter().map(|c| c.spec().name).collect()
    }
}

/// One committed node as the renderer sees it. Cheap to clone; props are
/// read from the tree on demand.
#[derive(Clone)]
pub struct NodeView {
    path: String,
    win: String,
    ty: String,
    host: Rc<runtime::Inner>,
}

impl NodeView {
    /// Full tree path, also the node's `ElementId`.
    pub fn path(&self) -> &str {
        &self.path
    }
    pub fn win(&self) -> &str {
        &self.win
    }
    pub fn ty(&self) -> &str {
        &self.ty
    }
    /// The node's own name (the last path element).
    pub fn name(&self) -> &str {
        self.path.rsplit('/').next().unwrap_or("")
    }
    /// The path below the window directory (`root/prefs/ok`), as events use.
    pub fn rel_path(&self) -> &str {
        self.path
            .strip_prefix("windows/")
            .and_then(|p| p.split_once('/'))
            .map(|(_, r)| r)
            .unwrap_or(&self.path)
    }
    /// A prop file's stored bytes (or its default), as committed.
    pub fn prop(&self, file: &str) -> Option<Bytes> {
        let t = self.host.tree.borrow();
        t.committed_node(&self.path)
            .and_then(|n| n.prop(file))
            .map(Bytes::copy_from_slice)
    }
    /// A prop file as text, one trailing newline dropped.
    pub fn text(&self, file: &str) -> Option<String> {
        let b = self.prop(file)?;
        let s = String::from_utf8_lossy(&b);
        Some(s.strip_suffix('\n').unwrap_or(&s).to_string())
    }
    /// A prop as a boolean: `on`, `true`, `1` and `yes` are true.
    pub fn flag(&self, file: &str) -> bool {
        matches!(
            self.text(file).as_deref().map(str::trim),
            Some("on" | "true" | "1" | "yes")
        )
    }
    /// Whether the client (or a mirror) wrote the file.
    pub fn is_set(&self, file: &str) -> bool {
        let t = self.host.tree.borrow();
        t.committed_node(&self.path).is_some_and(|n| n.is_set(file))
    }
    /// The type's spec.
    pub fn spec(&self) -> Option<&'static catalog::TypeSpec> {
        catalog::get(&self.ty)
    }
    /// Children in `order`.
    pub fn children(&self) -> Vec<NodeView> {
        self.host.children_of(&self.path)
    }
    /// One child by name, drawn or not (slots).
    pub fn child(&self, name: &str) -> Option<NodeView> {
        self.host.node_view(&format!("{}/{name}", self.path))
    }
    /// The words in the node's `on` file.
    pub fn on_words(&self) -> Vec<String> {
        self.text("on")
            .unwrap_or_default()
            .split_whitespace()
            .map(str::to_string)
            .collect()
    }
    /// An app-level file (`assets/<name>`, `clipboard`, `theme/mode`, ...).
    pub fn host_root_file(&self, path: &str) -> Option<Bytes> {
        self.host.tree.borrow().root_file(path)
    }
    /// An `Emitter` for this node, usable outside render.
    pub fn emitter(&self) -> Emitter {
        Emitter {
            win: self.win.clone(),
            node: self.path.clone(),
            tx: self.host.tx.clone(),
        }
    }
}

impl std::fmt::Debug for NodeView {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NodeView")
            .field("path", &self.path)
            .field("ty", &self.ty)
            .finish()
    }
}

pub trait Component: 'static {
    fn spec(&self) -> &'static catalog::TypeSpec;
    /// Make the GPUI state entity for a new node (InputState, SelectState, ...). None if stateless.
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        None
    }
    /// A prop file changed from the client side: push it into the entity.
    fn prop_changed(
        &self,
        node: &NodeView,
        state: Option<&AnyEntity>,
        prop: &str,
        window: &mut Window,
        cx: &mut App,
    ) {
    }
    /// A component verb on the node's ctl, already parsed and validated
    /// against the spec. Also receives answers to requests the component
    /// opened (`close seq=N`, `keep seq=N`, ...), and `open`/`close` for overlays.
    fn verb(
        &self,
        node: &NodeView,
        state: Option<&AnyEntity>,
        cmd: &proto::Command,
        window: &mut Window,
        cx: &mut App,
    ) -> Result<(), proto::Error>;
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement;
}

pub struct RenderCx<'a> {
    window: &'a mut Window,
    cx: &'a mut App,
    host: Rc<runtime::Inner>,
}

impl<'a> RenderCx<'a> {
    pub(crate) fn new(window: &'a mut Window, cx: &'a mut App, host: Rc<runtime::Inner>) -> Self {
        RenderCx { window, cx, host }
    }

    /// Renders any node: its component (creating its state on first use).
    pub fn render(&mut self, node: &NodeView) -> AnyElement {
        materialize::render_node(self, node)
    }

    /// Non-slot children, in order, rendered.
    pub fn children(&mut self, node: &NodeView) -> Vec<AnyElement> {
        let slots: &[&str] = match node.spec().map(|s| s.slots) {
            Some(catalog::Slots::Named(n)) => n,
            _ => &[],
        };
        node.children()
            .into_iter()
            .filter(|c| !slots.contains(&c.name()))
            .map(|c| self.render(&c))
            .collect()
    }

    /// A named slot child, rendered, whether or not `order` lists it.
    pub fn slot(&mut self, node: &NodeView, name: &str) -> Option<AnyElement> {
        let c = node.child(name)?;
        Some(self.render(&c))
    }

    /// Style words (base words only; state styles need an interactive
    /// element, see [`RenderCx::element`]).
    pub fn styled<E: Styled>(&self, mut el: E, node: &NodeView) -> E {
        let st = self.style_of(node);
        el.style().refine(&st.base);
        el
    }

    /// The node's parsed `style` file (cached per node until it changes):
    /// base and state refinements, group, size and variant words.
    pub fn style_of(&self, node: &NodeView) -> Rc<ParsedStyle> {
        self.host.style_of(node, self.cx)
    }

    /// A stateful `div` with the node's id, style words and state styles,
    /// `group`, `on` listeners, `context`, `tooltip` and `bounds`
    /// reporting. Add children and return it.
    pub fn element(&mut self, node: &NodeView) -> Stateful<gpui::Div> {
        materialize::element(self, node, div())
    }

    /// As [`RenderCx::element`], starting from a `div` you made.
    pub fn element_from(&mut self, node: &NodeView, base: gpui::Div) -> Stateful<gpui::Div> {
        materialize::element(self, node, base)
    }

    /// `'static + Clone`, for listeners.
    pub fn emitter(&self, node: &NodeView) -> Emitter {
        node.emitter()
    }

    pub fn state<T: 'static>(&self, node: &NodeView) -> Option<Entity<T>> {
        self.host
            .states
            .borrow()
            .get(node.path())
            .and_then(|s| s.entity.clone())
            .and_then(|e| e.downcast::<T>().ok())
    }

    /// The node's focus handle (made on first use, kept while the node lives).
    pub fn focus_handle(&mut self, node: &NodeView) -> FocusHandle {
        self.host.focus_handle(node.path(), self.cx)
    }

    /// The node's scroll handle (made on first use, kept while the node lives).
    pub fn scroll_handle(&mut self, node: &NodeView) -> ScrollHandle {
        self.host.scroll_handle(node.path())
    }

    /// A theme token's current color (`primary`, `muted_foreground`, ...).
    pub fn token(&self, name: &str) -> Option<gpui::Hsla> {
        theme::token(self.cx, name)
    }

    pub fn window(&mut self) -> &mut Window {
        self.window
    }
    pub fn cx(&mut self) -> &mut App {
        self.cx
    }
    pub fn cx_ref(&self) -> &App {
        self.cx
    }
}

/// Sends events for one node back to the tree from GPUI listeners.
#[derive(Clone)]
pub struct Emitter {
    win: String,
    /// Full path of the node.
    node: String,
    tx: runtime::Tx,
}

impl Emitter {
    /// Kind comes from the node's spec (or, for `on` words, the design's
    /// table: `click`, `mouse_down`, `mouse_up`, `key` are actions; `hover`,
    /// `scroll`, `move`, `focus`, `blur` are coalesced state events).
    pub fn event(&self, name: &str, attrs: &[(&str, &str)]) {
        self.send(runtime::Msg::Event {
            node: self.node.clone(),
            name: name.to_string(),
            attrs: own(attrs),
        });
    }
    /// Opens a request; its answer comes back through `Component::verb`.
    pub fn request(&self, name: &str, attrs: &[(&str, &str)], default: Answer) {
        self.send(runtime::Msg::Request {
            node: self.node.clone(),
            name: name.to_string(),
            attrs: own(attrs),
            default,
        });
    }
    /// Component state -> the node's file, as `via=user`.
    pub fn mirror(&self, file: &str, value: impl Into<Bytes>) {
        self.send(runtime::Msg::Mirror {
            path: self.node.clone(),
            file: file.to_string(),
            value: value.into(),
        });
    }
    pub fn node(&self) -> &str {
        &self.node
    }
    pub fn win(&self) -> &str {
        &self.win
    }
    fn send(&self, m: runtime::Msg) {
        let _ = self.tx.unbounded_send(m);
    }
}

fn own(attrs: &[(&str, &str)]) -> Vec<(String, String)> {
    attrs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

/// Per-node GPUI state the host keeps while the node lives.
pub(crate) struct NodeState {
    pub ty: String,
    pub entity: Option<AnyEntity>,
}

pub(crate) type StyleCache = RefCell<HashMap<String, (String, u64, Rc<ParsedStyle>)>>;
