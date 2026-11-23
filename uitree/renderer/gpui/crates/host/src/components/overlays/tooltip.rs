//! Tooltips: the `tooltip` overlay (components.md § Tooltips) and the
//! `tooltip` file every node has (core.md § Overlays), drawn by one code
//! path. A node's file is a tooltip overlay anchored to the node with the
//! descriptor's defaults, and no `over/` node to mirror `open` into.
//!
//! The host opens a tip `open-delay` ms after the pointer enters its anchor
//! and closes it when the pointer leaves or presses the anchor, all from
//! window-level mouse listeners painted every frame, so the client sees no
//! round trip and no events.

use std::collections::HashSet;
use std::rc::Rc;
use std::time::Duration;

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, AsyncApp, Bounds, DispatchPhase, Entity,
    IntoElement, MouseDownEvent, MouseMoveEvent, ParentElement, Pixels, Styled, Window, anchored,
    canvas, div, point, px,
};
use gpui_component::ThemeStyled as _;

use super::placement;
use crate::components::nav::{no_verb, number, spec, text_or_default};
use crate::runtime::Inner;
use crate::{Component, ComponentRegistry, Node, NodeView, RenderCx};

/// The `tooltip` descriptor's defaults, which a node's `tooltip` file uses.
pub(crate) const DEFAULT_PLACEMENT: &str = "top";
pub(crate) const DEFAULT_DELAY_MS: u64 = 500;

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(TooltipOverlay);
}

/// Per-tip host state: one per `tooltip` overlay (in the host's node
/// states) and one per node with a `tooltip` file (in `Inner::tips`).
#[derive(Default)]
pub struct TipState {
    pub open: bool,
    /// The pointer was in the anchor at the last move.
    inside: bool,
    /// A press in the anchor hides the tip until the pointer leaves.
    suppressed: bool,
    /// Bumped on every enter, leave and verb, so a stale delayed open drops.
    generation: u64,
}

/// One tip to draw this frame.
struct Tip {
    host: Rc<Inner>,
    win: String,
    anchor: Option<Node>,
    text: String,
    placement: String,
    delay: u64,
    state: Entity<TipState>,
    /// The `tooltip` overlay node, for its `open` file and its style; `None`
    /// for a node's `tooltip` file.
    overlay: Option<NodeView>,
}

impl Tip {
    fn anchor_bounds(&self) -> Option<Bounds<Pixels>> {
        anchor_bounds(&self.host, self.anchor?)
    }
}

fn anchor_bounds(host: &Inner, n: Node) -> Option<Bounds<Pixels>> {
    match host.bounds.borrow().get(&n).copied()? {
        [x, y, w, h] if w > 0. || h > 0. => Some(Bounds::new(point(px(x), px(y)), gpui::size(px(w), px(h)))),
        _ => None,
    }
}

/// Shows or hides a tip, mirroring an overlay's `open` file.
fn set_open(
    host: &Rc<Inner>,
    win: &str,
    state: &Entity<TipState>,
    overlay: Option<&NodeView>,
    open: bool,
    window: &mut Window,
    cx: &mut App,
) {
    let changed = state.update(cx, |s, _| {
        let ch = s.open != open;
        s.open = open;
        ch
    });
    if !changed {
        return;
    }
    if let Some(o) = overlay {
        o.emitter().mirror("open", if open { &b"on"[..] } else { &b"off"[..] });
    }
    crate::runtime::notify_window(host, win, cx);
    window.refresh();
}

/// Opens after the tip's delay unless the pointer leaves (or presses) first.
fn open_later(tip: &Tip, window: &mut Window, cx: &mut App) {
    let generation = tip.state.update(cx, |s, _| {
        s.generation += 1;
        s.generation
    });
    if tip.delay == 0 {
        set_open(&tip.host, &tip.win, &tip.state, tip.overlay.as_ref(), true, window, cx);
        return;
    }
    let (host, win, st, overlay, d) =
        (tip.host.clone(), tip.win.clone(), tip.state.clone(), tip.overlay.clone(), tip.delay);
    cx.spawn(async move |cx: &mut AsyncApp| {
        cx.background_executor().timer(Duration::from_millis(d)).await;
        cx.update(|cx| {
            let s = st.read(cx);
            if s.generation != generation || !s.inside || s.suppressed {
                return;
            }
            crate::runtime::with_window(&host, &win, cx, |window, cx| {
                set_open(&host, &win, &st, overlay.as_ref(), true, window, cx)
            });
        });
    })
    .detach();
}

/// The tip's layer: a zero-size element that paints its listeners, and the
/// panel when it is open.
fn render_tip(rcx: &mut RenderCx, tip: Tip) -> AnyElement {
    let open = tip.state.read(rcx.cx_ref()).open;
    let panel = open.then(|| {
        let base = div()
            .popover_style(rcx.cx_ref())
            .py_0p5()
            .px_2()
            .text_sm()
            .max_w(px(360.))
            .child(tip.text.clone());
        let el: AnyElement = match &tip.overlay {
            Some(o) => rcx.element_from(o, base).into_any_element(),
            None => base.into_any_element(),
        };
        let (corner, at, offset) = placement(&tip.placement);
        let mut a = anchored().anchor(corner).snap_to_window_with_margin(px(8.));
        a = match tip.anchor_bounds() {
            Some(b) => a.attach(b, at).offset(offset),
            None => a.position(point(rcx.window().viewport_size().width / 2., px(80.))),
        };
        a.child(el).into_any_element()
    });
    let tip = Rc::new(tip);
    let listener = canvas(
        |_, _, _| {},
        move |_, _, window, _| {
            let t = tip.clone();
            window.on_mouse_event(move |ev: &MouseMoveEvent, phase, window, cx| {
                if phase != DispatchPhase::Capture {
                    return;
                }
                let inside = t.anchor_bounds().is_some_and(|b| b.contains(&ev.position));
                let (was, open, suppressed) = {
                    let s = t.state.read(cx);
                    (s.inside, s.open, s.suppressed)
                };
                if inside == was {
                    return;
                }
                t.state.update(cx, |s, _| {
                    s.inside = inside;
                    if !inside {
                        s.suppressed = false;
                        s.generation += 1;
                    }
                });
                if inside && !open && !suppressed {
                    open_later(&t, window, cx);
                } else if !inside && open {
                    set_open(&t.host, &t.win, &t.state, t.overlay.as_ref(), false, window, cx);
                }
            });
            let t = tip.clone();
            window.on_mouse_event(move |ev: &MouseDownEvent, phase, window, cx| {
                if phase != DispatchPhase::Capture {
                    return;
                }
                if !t.anchor_bounds().is_some_and(|b| b.contains(&ev.position)) {
                    return;
                }
                t.state.update(cx, |s, _| {
                    s.suppressed = true;
                    s.generation += 1;
                });
                set_open(&t.host, &t.win, &t.state, t.overlay.as_ref(), false, window, cx);
            });
        },
    )
    .absolute()
    .size_0();
    div()
        .absolute()
        .top_0()
        .left_0()
        .size_full()
        .child(listener)
        .children(panel)
        .into_any_element()
}

// ---- the `tooltip` overlay -------------------------------------------------

struct TooltipOverlay;

/// The overlay's state entity, made now if it hasn't drawn yet (an `open`
/// can come in the same write as the `new`).
fn overlay_state(node: &NodeView, cx: &mut App) -> Entity<TipState> {
    let have = node
        .host
        .states
        .borrow()
        .get(&node.node())
        .filter(|s| s.ty == node.ty())
        .and_then(|s| s.entity.clone())
        .and_then(|e| e.downcast::<TipState>().ok());
    if let Some(e) = have {
        return e;
    }
    let e = cx.new(|_| TipState::default());
    node.host.states.borrow_mut().insert(
        node.node(),
        crate::NodeState { ty: node.ty().to_string(), entity: Some(e.clone().into_any()) },
    );
    e
}

/// The node an overlay's `anchor` names, if it exists.
fn anchor_of(node: &NodeView) -> Option<Node> {
    let a = node.text("anchor")?;
    let a = a.trim();
    if a.is_empty() {
        return None;
    }
    Some(node.host.node_at(&format!("{}/{}", node.win(), a))?.node())
}

impl Component for TooltipOverlay {
    fn spec(&self) -> &'static crate::Spec {
        spec("tooltip")
    }

    fn create(&self, _: &NodeView, _: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        Some(cx.new(|_| TipState::default()).into_any())
    }

    fn verb(
        &self,
        node: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &crate::Ctl,
        window: &mut Window,
        cx: &mut App,
    ) -> crate::VerbResult {
        let open = match cmd.verb.as_str() {
            "open" if cmd.attr("seq").is_none() => true,
            "close" => false,
            _ => return no_verb(cmd),
        };
        let st = overlay_state(node, cx);
        // A verb wins over a pending hover open.
        st.update(cx, |s, _| s.generation += 1);
        set_open(&node.host, node.win(), &st, Some(node), open, window, cx);
        Ok(())
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let state = overlay_state(node, rcx.cx);
        let tip = Tip {
            host: node.host.clone(),
            win: node.win().to_string(),
            anchor: anchor_of(node),
            text: node.text("text").unwrap_or_default(),
            placement: text_or_default(node, "placement"),
            delay: number(node, "open-delay", DEFAULT_DELAY_MS as f64).max(0.) as u64,
            state,
            overlay: Some(node.clone()),
        };
        render_tip(rcx, tip)
    }
}

// ---- the `tooltip` node file -----------------------------------------------

/// The window's tips from `tooltip` files, for the nodes drawn this frame
/// (`Inner::frame_tips`), above the window's overlays. A node that a
/// `tooltip` overlay anchors to shows the overlay instead.
pub(crate) fn node_tips(rcx: &mut RenderCx, win: &str, overlays: &[NodeView]) -> Vec<AnyElement> {
    let host = rcx.host.clone();
    let nodes = host.frame_tips.borrow_mut().remove(win).unwrap_or_default();
    if nodes.is_empty() {
        return Vec::new();
    }
    let covered: HashSet<Node> = overlays
        .iter()
        .filter(|o| o.ty() == "tooltip")
        .filter_map(anchor_of)
        .collect();
    let mut out = Vec::new();
    for n in nodes {
        if covered.contains(&n) {
            continue;
        }
        let Some(view) = host.view(n) else { continue };
        let Some(text) = view.text("tooltip").filter(|t| !t.trim().is_empty()) else { continue };
        let state = host.tips.borrow().get(&n).cloned();
        let state = match state {
            Some(s) => s,
            None => {
                let s = rcx.cx.new(|_| TipState::default());
                host.tips.borrow_mut().insert(n, s.clone());
                s
            }
        };
        let tip = Tip {
            host: host.clone(),
            win: win.to_string(),
            anchor: Some(n),
            text,
            placement: DEFAULT_PLACEMENT.to_string(),
            delay: DEFAULT_DELAY_MS,
            state,
            overlay: None,
        };
        out.push(render_tip(rcx, tip));
    }
    out
}

/// Whether the node file's tip for `n` is showing, for tests.
#[cfg(test)]
pub(crate) fn node_tip_open(host: &Inner, n: Node, cx: &App) -> bool {
    host.tips.borrow().get(&n).is_some_and(|s| s.read(cx).open)
}
