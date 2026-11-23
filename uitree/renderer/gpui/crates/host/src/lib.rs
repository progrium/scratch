//! The GPUI host: app, windows, root view, materialize, style dispatch,
//! theme, actions, menus, and every component, drawing the core's committed
//! tree through `uitcore.h`.
//!
//! # How it fits together
//!
//! - [`run`] starts GPUI and makes the core ([`uitcore::Core`]) on GPUI's
//!   main thread, which is the ABI's owner thread. The core's 9P threads
//!   call the waker; a task on the main thread then calls `uit_pump` and
//!   acts on the returned changes (`runtime::pump`).
//! - Each window has one root view (`window::WindowView`). Its `render`
//!   walks the window's committed tree through the ABI and builds elements
//!   with [`RenderCx`]; the element tier lives in [`elements`], every other
//!   type is a [`Component`].
//! - The renderer holds no tree. It keeps, per node handle, only what
//!   drawing needs to be fast: the node's type and path (fixed for its
//!   life), prop text it already copied, and the parsed style, each dropped
//!   when a pump reports the node's prop changed or the theme changed.
//! - GPUI listeners send input with an [`Emitter`] (`uit_emit`,
//!   `uit_request`, `uit_mirror`); the core queues it and applies it at the
//!   next pump, in order with the client's ops.
//! - The renderer never parses `ctl`, never validates, and never produces a
//!   protocol error. If a component needs one, the core is missing
//!   something.
//!
//! # For component code
//!
//! Implement [`Component`] and `reg.add(...)` it in your group's
//! `register`. In `render`, start from [`RenderCx::element`] when your
//! component is a box (it applies style words, `on`, `context`, `tooltip`,
//! `bounds`), or build a GPUI Kit element and pass it through
//! [`RenderCx::styled`]. Read props with [`NodeView::text`] /
//! [`NodeView::prop`]; data files with [`NodeView::lines`]; size and
//! variant words with [`RenderCx::style_of`]. Send events with
//! [`RenderCx::emitter`].
//!
//! A request opened with [`Emitter::request`] is answered (by the client,
//! or by its default) by calling your [`Component::verb`] with the answer,
//! for example `close seq=12` or `keep seq=12`.
#![allow(clippy::too_many_arguments, unused_variables)]

use std::collections::HashMap;
use std::rc::Rc;

use gpui::{AnyElement, AnyEntity, App, Entity, FocusHandle, Refineable as _, ScrollHandle, Stateful, Styled, Window, div};

pub use uitcore::{Ctl, Node};

pub mod bench;
pub mod canvas;
pub mod clipboard;
pub mod components;
pub mod data_lines;
pub mod dnd;
pub mod elements;
pub mod spec;

mod actions;
mod materialize;
pub(crate) mod runtime;
pub mod styling;
mod theme;
pub(crate) mod window;

#[cfg(any(test, feature = "test-support"))]
pub mod testing;

#[cfg(test)]
mod tests;

pub use runtime::run;
pub use spec::Spec;
pub use styling::ParsedStyle;

/// What the `uitree` binary passes in.
#[derive(Debug, Clone, Default)]
pub struct Options {
    /// `-t title`: the app name and default window title.
    pub title: Option<String>,
    /// `-k`: keep running after the client exits.
    pub keep: bool,
    /// h9's `--root` (default the built-in root).
    pub root: Option<String>,
    /// The program and its arguments.
    pub argv: Vec<String>,
    /// Build an N-node tree and measure, instead of running an app.
    pub bench: Option<usize>,
}

/// Every component the host knows: the element tier, each group, and canvas.
pub fn register_all(reg: &mut ComponentRegistry) {
    elements::register(reg);
    components::register(reg);
    canvas::register(reg);
}

/// Components by type name.
#[derive(Default)]
pub struct ComponentRegistry {
    components: HashMap<&'static str, Box<dyn Component>>,
}

impl ComponentRegistry {
    pub fn add(&mut self, c: impl Component) {
        self.components.insert(c.spec().name, Box::new(c));
    }
    pub fn get(&self, ty: &str) -> Option<&dyn Component> {
        self.components.get(ty).map(|c| c.as_ref())
    }
    /// Type names that have a renderer, sorted.
    pub fn names(&self) -> Vec<&'static str> {
        let mut v: Vec<_> = self.components.keys().copied().collect();
        v.sort();
        v
    }
}

/// What the renderer keeps about a node for its whole life.
pub(crate) struct NodeInfo {
    pub node: Node,
    /// `win` for a window's root, else `win/rel`: unique, and the node's
    /// `ElementId`.
    pub path: String,
    pub win: String,
    pub ty: String,
}

/// One committed node as the renderer sees it. Cheap to clone; props are
/// read from the core on demand and cached until a pump changes them.
#[derive(Clone)]
pub struct NodeView {
    pub(crate) info: Rc<NodeInfo>,
    pub(crate) host: Rc<runtime::Inner>,
}

impl NodeView {
    /// The core's handle.
    pub fn node(&self) -> Node {
        self.info.node
    }
    /// `win/rel` (`win` for a root): unique, used as the element id.
    pub fn path(&self) -> &str {
        &self.info.path
    }
    pub fn win(&self) -> &str {
        &self.info.win
    }
    pub fn ty(&self) -> &str {
        &self.info.ty
    }
    /// The node's own name (the last path element).
    pub fn name(&self) -> &str {
        self.rel_path().rsplit('/').next().unwrap_or("")
    }
    /// The window-relative path (`.` for the root, `f/ok`), as events use.
    pub fn rel_path(&self) -> &str {
        self.info.path.strip_prefix(&self.info.win).and_then(|r| r.strip_prefix('/')).unwrap_or(".")
    }
    /// A prop file's bytes as committed, `None` when unset.
    pub fn prop(&self, file: &str) -> Option<Rc<[u8]>> {
        self.host.prop(self.info.node, file)
    }
    /// A prop file as text, one trailing newline dropped.
    pub fn text(&self, file: &str) -> Option<String> {
        let b = self.prop(file)?;
        let s = String::from_utf8_lossy(&b);
        Some(s.strip_suffix('\n').unwrap_or(&s).to_string())
    }
    /// A prop as a boolean: `on`, `true`, `1` and `yes` are true.
    pub fn flag(&self, file: &str) -> bool {
        self.prop(file).is_some_and(|b| matches!(std::str::from_utf8(&b).map(str::trim), Ok("on" | "true" | "1" | "yes")))
    }
    /// Whether the prop has a value (written, or a default).
    pub fn is_set(&self, file: &str) -> bool {
        self.prop(file).is_some_and(|b| !b.is_empty())
    }
    /// A data file, split into lines and fields by the core.
    pub fn lines(&self, file: &str) -> Rc<Vec<uitcore::Line>> {
        self.host.lines(self.info.node, file)
    }
    /// A data file as typed lines; lines that don't read are skipped.
    pub fn typed_lines<T: data_lines::Line>(&self, file: &str) -> Vec<T> {
        data_lines::from_core(&self.lines(file))
    }
    /// How many times a pump changed this prop; 0 if never. For
    /// components that rebuild GPUI state only when a file changes.
    pub fn revision(&self, file: &str) -> u64 {
        self.host.revision(self.info.node, file)
    }
    /// The type's descriptor.
    pub fn spec(&self) -> Option<&'static Spec> {
        spec::get(&self.info.ty)
    }
    /// Children in `order`.
    pub fn children(&self) -> Vec<NodeView> {
        self.host.children_of(self.info.node)
    }
    /// One child by name, drawn or not (slots).
    pub fn child(&self, name: &str) -> Option<NodeView> {
        self.host.node_at(&format!("{}/{name}", self.info.path))
    }
    /// The parent node, if this isn't a window's root.
    pub fn parent(&self) -> Option<NodeView> {
        let (p, _) = self.info.path.rsplit_once('/')?;
        self.host.node_at(p)
    }
    /// The words in the node's `on` file.
    pub fn on_words(&self) -> Vec<String> {
        self.text("on").unwrap_or_default().split_whitespace().map(str::to_string).collect()
    }
    /// The node's last laid-out bounds, window space.
    pub fn bounds(&self) -> Option<[f32; 4]> {
        self.host.bounds.borrow().get(&self.info.node).copied()
    }
    /// An app asset (`$ui/asset/NAME`), for `src=@NAME`.
    pub fn asset(&self, name: &str) -> Option<Rc<[u8]>> {
        if let Some(a) = self.host.assets.borrow().get(name) {
            return Some(a.clone());
        }
        let a: Rc<[u8]> = self.host.core.borrow().asset(name)?.into();
        self.host.assets.borrow_mut().insert(name.to_string(), a.clone());
        Some(a)
    }
    /// An `Emitter` for this node, usable outside render.
    pub fn emitter(&self) -> Emitter {
        Emitter { node: self.info.node, win: self.info.win.clone(), tx: self.host.input.clone() }
    }
}

impl PartialEq for NodeView {
    fn eq(&self, o: &Self) -> bool {
        self.info.node == o.info.node
    }
}

impl std::fmt::Debug for NodeView {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NodeView").field("node", &self.info.node).field("path", &self.info.path).field("ty", &self.info.ty).finish()
    }
}

/// A verb or answer the component doesn't act on. Not a protocol error:
/// the core already accepted the verb; the renderer just has nothing to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Unhandled;

impl std::fmt::Display for Unhandled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("not handled by this renderer")
    }
}

pub type VerbResult = Result<(), Unhandled>;

pub trait Component: 'static {
    /// The type's descriptor (from `uitree/core/types`).
    fn spec(&self) -> &'static Spec;
    /// Make the GPUI state entity for a new node (InputState, SelectState, ...). None if stateless.
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        None
    }
    /// A prop file changed from the client side: push it into the entity.
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {}
    /// Move keyboard focus into the node's own widget (an input's text
    /// field). False if the component has none, and the node's generic
    /// focus handle is used.
    fn focus(&self, state: Option<&AnyEntity>, window: &mut Window, cx: &mut App) -> bool {
        false
    }
    /// A component verb on the node's ctl, already parsed and validated by
    /// the core against the descriptor. Also receives answers to requests
    /// the component opened (`close seq=N`, `keep seq=N`, ...), and
    /// `open`/`close` for overlays. `Err(Unhandled)` means the
    /// renderer has nothing to do for it; nothing is reported.
    fn verb(&self, node: &NodeView, state: Option<&AnyEntity>, cmd: &Ctl, window: &mut Window, cx: &mut App) -> VerbResult {
        Err(Unhandled)
    }
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement;
}

pub struct RenderCx<'a> {
    pub(crate) window: &'a mut Window,
    pub(crate) cx: &'a mut App,
    pub(crate) host: Rc<runtime::Inner>,
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
        let slots: &[&str] = node.spec().map(|s| s.slots.as_slice()).unwrap_or(&[]);
        node.children().into_iter().filter(|c| !slots.contains(&c.name())).map(|c| self.render(&c)).collect()
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

    /// The node's style, parsed (cached per node until it changes): base and
    /// state refinements, group, size and variant words.
    pub fn style_of(&self, node: &NodeView) -> Rc<ParsedStyle> {
        self.host.style_of(node)
    }

    /// A stateful `div` with the node's id, style words and state styles,
    /// `group`, `on` listeners, `context`, `tooltip` and `bounds`
    /// reporting. Add children and return it.
    pub fn element(&mut self, node: &NodeView) -> Stateful<gpui::Div> {
        materialize::element(self, node, div())
    }

    /// As [`RenderCx::element_from`], without the listeners for the `on`
    /// words in `skip`, for a component that sends those events itself.
    pub fn element_except(&mut self, node: &NodeView, base: gpui::Div, skip: &[&str]) -> Stateful<gpui::Div> {
        materialize::element_except(self, node, base, skip)
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
        self.host.states.borrow().get(&node.node()).and_then(|s| s.entity.clone()).and_then(|e| e.downcast::<T>().ok())
    }

    /// The node's focus handle (made on first use, kept while the node lives).
    pub fn focus_handle(&mut self, node: &NodeView) -> FocusHandle {
        self.host.focus_handle(node.node(), self.cx)
    }

    /// The node's scroll handle (made on first use, kept while the node lives).
    pub fn scroll_handle(&mut self, node: &NodeView) -> ScrollHandle {
        self.host.scroll_handle(node.node())
    }

    /// A theme token's current color (`primary`, `muted-foreground`, ...).
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

/// Sends input about one node to the core from GPUI listeners. It is
/// `Send` (some GPUI Kit callbacks require it), so it queues on a channel
/// that the main thread drains into `uit_emit`, `uit_request` and
/// `uit_mirror`, in order. The core then applies it at the next pump, in
/// order with the client's ops; it adds `win=`, the path, `via=user` and
/// `seq=`, and picks the queue from the descriptor.
#[derive(Clone)]
pub struct Emitter {
    node: Node,
    win: String,
    tx: runtime::InputTx,
}

impl Emitter {
    /// An element or component event (`click`, `change value=x`).
    pub fn event(&self, name: &str, attrs: &[(&str, &str)]) {
        self.send(runtime::Input::Event { node: self.node, name: name.into(), attrs: own(attrs) });
    }
    /// Opens a request; its answer (or the default, `default_answer`, a
    /// verb such as `close`) comes back through `Component::verb`.
    pub fn request(&self, name: &str, attrs: &[(&str, &str)], default_answer: &str) {
        self.send(runtime::Input::Request { node: self.node, name: name.into(), attrs: own(attrs), default: default_answer.into() });
    }
    /// Component state -> the node's file, as `via=user`.
    pub fn mirror(&self, file: &str, value: impl AsRef<[u8]>) {
        self.send(runtime::Input::Mirror { node: self.node, file: file.into(), value: value.as_ref().to_vec() });
    }
    /// A menu item was chosen (a context menu's or a menu button's): the
    /// core sends `action ID - via=menu`, as for the menu bar.
    pub fn menu_action(&self, id: &str) {
        self.send(runtime::Input::MenuAction { id: id.into() });
    }
    fn send(&self, m: runtime::Input) {
        let _ = self.tx.unbounded_send(m);
    }
    pub fn node(&self) -> Node {
        self.node
    }
    pub fn win(&self) -> &str {
        &self.win
    }
}

fn own(attrs: &[(&str, &str)]) -> Vec<(String, String)> {
    attrs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

/// Per-node GPUI state the host keeps while the node lives.
pub(crate) struct NodeState {
    pub ty: String,
    pub entity: Option<AnyEntity>,
}

/// std::time, or on wasm the browser's clock (std's panics there).
pub(crate) mod time {
    #[cfg(not(target_family = "wasm"))]
    pub use std::time::{Instant, SystemTime, UNIX_EPOCH};
    #[cfg(target_family = "wasm")]
    pub use web_time::{Instant, SystemTime, UNIX_EPOCH};
}
