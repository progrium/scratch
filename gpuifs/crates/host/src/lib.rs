//! The GPUI host: app, windows, root view, materialize, style application,
//! theme, actions, menus. Owned by W5b, except `components/` (W6a-d) and
//! `canvas/`, `dnd/`, `clipboard.rs` (W7).
#![allow(unused_variables, dead_code)]

use std::sync::Arc;

use gpui::{AnyElement, AnyEntity, App, Entity, Styled, Window};

pub use tree::{Answer, Bytes};

pub mod canvas;
pub mod clipboard;
pub mod components;
pub mod dnd;
pub mod elements;

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
    todo!("W5b")
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
}

/// One committed node as the renderer sees it.
pub struct NodeView {
    path: String,
    win: String,
    ty: String,
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
    /// A prop file's stored bytes.
    pub fn prop(&self, file: &str) -> Option<Bytes> {
        todo!("W5b")
    }
    /// A prop file as text, one trailing newline dropped.
    pub fn text(&self, file: &str) -> Option<String> {
        todo!("W5b")
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
    /// A component verb on the node's ctl, already parsed and validated against the spec.
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
}

impl RenderCx<'_> {
    /// Non-slot children, in order.
    pub fn children(&mut self, node: &NodeView) -> Vec<AnyElement> {
        todo!("W5b")
    }
    pub fn slot(&mut self, node: &NodeView, name: &str) -> Option<AnyElement> {
        todo!("W5b")
    }
    /// Style words + state styles.
    pub fn styled<E: Styled>(&self, el: E, node: &NodeView) -> E {
        todo!("W5b")
    }
    /// `'static + Clone`, for listeners.
    pub fn emitter(&self, node: &NodeView) -> Emitter {
        todo!("W5b")
    }
    pub fn state<T: 'static>(&self, node: &NodeView) -> Option<Entity<T>> {
        todo!("W5b")
    }
    pub fn window(&mut self) -> &mut Window {
        self.window
    }
    pub fn cx(&mut self) -> &mut App {
        self.cx
    }
}

/// Sends events for one node back to the tree from GPUI listeners.
#[derive(Clone)]
pub struct Emitter {
    win: String,
    node: String,
}

impl Emitter {
    /// Kind comes from the node's spec.
    pub fn event(&self, name: &str, attrs: &[(&str, &str)]) {
        todo!("W5b")
    }
    pub fn request(&self, name: &str, attrs: &[(&str, &str)], default: Answer) {
        todo!("W5b")
    }
    pub fn mirror(&self, file: &str, value: impl Into<Bytes>) {
        todo!("W5b")
    }
}
