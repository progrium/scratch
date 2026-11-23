//! W6b: the `overlays` group: `dialog`, `alert-dialog`, `sheet`, `popover`,
//! `hover-card`, `context-menu`. See `catalog::overlays` for the specs.
//!
//! The window's root view draws `overlays/` in a full-window layer above
//! the root, in order. Each overlay keeps whether it is open in an
//! [`OverlayState`] entity (so the frame after an `open` shows it), and
//! mirrors that to its read-only `open` file. Panels are drawn with GPUI
//! Kit's theme (`popover_style`, `Button`) the way Kit's own `Dialog`,
//! `Sheet` and `Popover` draw.
//!
//! Anchored overlays (`popover`, `hover-card`, `context-menu`) bind to their
//! `anchor` node with a window-level mouse listener painted every frame, so
//! the anchor keeps its own clicks and hover and the trigger needs no round
//! trip to the client.

use std::time::Duration;

use gpui::{
    Anchor, AnyElement, AnyEntity, App, AppContext as _, AsyncApp, Bounds, DispatchPhase, Entity,
    InteractiveElement, IntoElement, MouseButton, MouseDownEvent, MouseMoveEvent, ParentElement,
    Pixels, Point, StatefulInteractiveElement, Styled, Window, anchored, canvas, div, point, px,
};
use gpui_component::{
    ActiveTheme as _, IconName, Sizable as _, StyledExt as _, ThemeStyled as _,
    button::{Button, ButtonVariants as _},
    h_flex, v_flex,
};
use crate::data_lines::{MenuKind, MenuLine};

use super::nav::{no_verb, part, part_id, spec, text_or_default};
use crate::{Component, ComponentRegistry, NodeState, NodeView, RenderCx};

#[cfg(test)]
mod tests;

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(Overlay(Kind::Dialog));
    reg.add(Overlay(Kind::AlertDialog));
    reg.add(Overlay(Kind::Sheet));
    reg.add(Overlay(Kind::Popover));
    reg.add(Overlay(Kind::HoverCard));
    reg.add(Overlay(Kind::ContextMenu));
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Dialog,
    AlertDialog,
    Sheet,
    Popover,
    HoverCard,
    ContextMenu,
}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::Dialog => "dialog",
            Kind::AlertDialog => "alert-dialog",
            Kind::Sheet => "sheet",
            Kind::Popover => "popover",
            Kind::HoverCard => "hover-card",
            Kind::ContextMenu => "context-menu",
        }
    }
    fn anchored(self) -> bool {
        matches!(self, Kind::Popover | Kind::HoverCard | Kind::ContextMenu)
    }
}

/// Per-overlay host state.
#[derive(Default)]
pub struct OverlayState {
    pub open: bool,
    /// Where a context menu opened (window coordinates).
    pos: Option<Point<Pixels>>,
    /// The panel's bounds from the last frame, for outside clicks and hover.
    panel: Option<Bounds<Pixels>>,
    /// Bumped on every hover change, so a stale delayed open or close drops.
    hover_gen: u64,
    /// What a pending hover timer will set.
    hover_want: Option<bool>,
}

struct Overlay(Kind);

/// The node's state entity, made now if the node hasn't drawn yet (an
/// `open` can come in the same write as the `new`).
fn ensure_state(node: &NodeView, cx: &mut App) -> Entity<OverlayState> {
    let have = node
        .host
        .states
        .borrow()
        .get(&node.node())
        .filter(|s| s.ty == node.ty())
        .and_then(|s| s.entity.clone())
        .and_then(|e| e.downcast::<OverlayState>().ok());
    if let Some(e) = have {
        return e;
    }
    let e = cx.new(|_| OverlayState::default());
    node.host.states.borrow_mut().insert(
        node.node(),
        NodeState {
            ty: node.ty().to_string(),
            entity: Some(e.clone().into_any()),
        },
    );
    e
}

fn is_open(rcx: &RenderCx, node: &NodeView) -> bool {
    rcx.state::<OverlayState>(node)
        .is_some_and(|s| s.read(rcx.cx_ref()).open)
}

/// Shows or hides an overlay, mirrors `open`, moves focus into a modal
/// panel and back out. Returns whether it changed.
fn set_open(node: &NodeView, open: bool, window: &mut Window, cx: &mut App) -> bool {
    let st = ensure_state(node, cx);
    let changed = st.update(cx, |s, _| {
        let ch = s.open != open;
        s.open = open;
        if !open {
            s.panel = None;
            s.pos = None;
        }
        ch
    });
    if changed {
        node.emitter()
            .mirror("open", if open { &b"on"[..] } else { &b"off"[..] });
        let fh = node.host.focus_handle(node.node(), cx);
        if open {
            fh.focus(window, cx);
        } else if fh.is_focused(window) {
            window.blur(cx);
        }
        crate::runtime::notify_window(&node.host, node.win(), cx);
        window.refresh();
    }
    changed
}

/// A user-made open or close of an anchored overlay: also an event.
fn user_toggle(node: &NodeView, open: bool, window: &mut Window, cx: &mut App) {
    if set_open(node, open, window, cx) && node.spec().is_some_and(|s| !s.events.is_empty()) {
        if node.ty() != "context-menu" {
            node.emitter().event(if open { "open" } else { "close" }, &[]);
        }
    }
}

impl Component for Overlay {
    fn spec(&self) -> &'static crate::Spec {
        spec(self.0.name())
    }

    fn create(&self, _: &NodeView, _: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        Some(cx.new(|_| OverlayState::default()).into_any())
    }

    fn verb(
        &self,
        node: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &crate::Ctl,
        window: &mut Window,
        cx: &mut App,
    ) -> crate::VerbResult {
        let answer = cmd.attr("seq").is_some();
        match (cmd.verb.as_str(), answer) {
            ("open", false) => {
                set_open(node, true, window, cx);
                Ok(())
            }
            // The client's `close`, or `close seq=N` answering a request.
            ("close", _) => {
                set_open(node, false, window, cx);
                Ok(())
            }
            ("keep", true) => Ok(()),
            _ => no_verb(cmd),
        }
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let open = is_open(rcx, node);
        let mut layer = div().absolute().top_0().left_0().size_full();
        if self.0.anchored() {
            layer = layer.child(trigger_listener(self.0, node));
        }
        if !open {
            return layer.into_any_element();
        }
        let el = match self.0 {
            Kind::Dialog | Kind::AlertDialog => dialog(rcx, node, self.0),
            Kind::Sheet => sheet(rcx, node),
            Kind::Popover | Kind::HoverCard => popover(rcx, node, self.0),
            Kind::ContextMenu => context_menu(rcx, node),
        };
        layer.child(el).into_any_element()
    }
}

// ---- dialog, alert-dialog, sheet -------------------------------------------

fn overlay_color(rcx: &RenderCx) -> gpui::Hsla {
    rcx.cx_ref().theme().overlay
}

/// Asks the client to close (a `close` request, default `close`).
fn ask_close(node: &NodeView) {
    node.emitter().request("close", &[], "close");
}

/// The alert-dialog's Esc and buttons.
fn alert_answer(node: &NodeView, ev: &str, window: &mut Window, cx: &mut App) {
    set_open(node, false, window, cx);
    node.emitter().event(ev, &[]);
}

fn backdrop(rcx: &RenderCx, node: &NodeView, closes: bool, modal: bool) -> gpui::Stateful<gpui::Div> {
    let n = node.clone();
    let mut b = div()
        .id(part_id(node, "backdrop"))
        .absolute()
        .top_0()
        .left_0()
        .size_full();
    if modal {
        b = b.occlude().bg(overlay_color(rcx));
    }
    if closes {
        b = b.on_mouse_down(MouseButton::Left, move |_, _, cx| {
            cx.stop_propagation();
            ask_close(&n);
        });
    }
    b
}

/// Records the panel's bounds in the overlay's state.
fn track_panel(node: &NodeView, st: Option<Entity<OverlayState>>) -> impl IntoElement {
    let _ = node;
    canvas(
        move |b, _, cx| {
            if let Some(st) = &st {
                st.update(cx, |s, _| s.panel = Some(b));
            }
        },
        |_, _, _, _| {},
    )
    .absolute()
    .top_0()
    .left_0()
    .size_full()
}

fn header(rcx: &mut RenderCx, node: &NodeView, closable: bool) -> Option<AnyElement> {
    let title = node.text("title").filter(|t| !t.is_empty());
    let desc = node.text("description").filter(|t| !t.is_empty());
    if title.is_none() && desc.is_none() && !closable {
        return None;
    }
    let muted = rcx.cx_ref().theme().muted_foreground;
    let n = node.clone();
    let close = closable.then(|| {
        let b = Button::new(part_id(node, "close"))
            .ghost()
            .xsmall()
            .icon(IconName::Close)
            .on_click(move |_, _, cx| {
                cx.stop_propagation();
                ask_close(&n);
            });
        part(node, "close", b)
    });
    Some(
        h_flex()
            .w_full()
            .items_start()
            .justify_between()
            .gap_4()
            .child(
                v_flex()
                    .gap_1()
                    .children(title.map(|t| div().text_lg().font_semibold().child(t)))
                    .children(desc.map(|d| div().text_sm().text_color(muted).child(d))),
            )
            .children(close)
            .into_any_element(),
    )
}

/// Body children and the `footer` slot.
fn body_and_footer(rcx: &mut RenderCx, node: &NodeView) -> (Vec<AnyElement>, Option<AnyElement>) {
    let mut body = Vec::new();
    let mut footer = None;
    for c in node.children() {
        if c.name() == "footer" {
            footer = Some(rcx.render(&c));
        } else {
            body.push(rcx.render(&c));
        }
    }
    (body, footer)
}

fn dialog(rcx: &mut RenderCx, node: &NodeView, kind: Kind) -> AnyElement {
    let alert = kind == Kind::AlertDialog;
    let width = super::nav::number(node, "width", if alert { 420. } else { 480. }) as f32;
    let modal = alert || text_or_default(node, "modal") != "off";
    let closes = !alert && text_or_default(node, "overlay-closable") != "off";
    let keyboard = alert || text_or_default(node, "keyboard") != "off";
    let fh = rcx.focus_handle(node);
    let st = rcx.state::<OverlayState>(node);
    let head = header(rcx, node, !alert);
    let (body, mut footer) = body_and_footer(rcx, node);

    if alert {
        let confirm = text_or_default(node, "confirm");
        let cancel = node.text("cancel").filter(|c| !c.is_empty());
        let danger = text_or_default(node, "variant") == "danger";
        let (n1, n2) = (node.clone(), node.clone());
        let ok = Button::new(part_id(node, "confirm"))
            .label(confirm)
            .with_variant(if danger {
                gpui_component::button::ButtonVariant::Danger
            } else {
                gpui_component::button::ButtonVariant::Primary
            })
            .on_click(move |_, window, cx| alert_answer(&n1, "confirm", window, cx));
        let cancel = cancel.map(|c| {
            Button::new(part_id(node, "cancel"))
                .label(c)
                .outline()
                .on_click(move |_, window, cx| alert_answer(&n2, "cancel", window, cx))
        });
        footer = Some(
            h_flex()
                .w_full()
                .justify_end()
                .gap_2()
                .children(footer)
                .children(cancel.map(|c| part(node, "cancel", c)))
                .child(part(node, "confirm", ok))
                .into_any_element(),
        );
    }

    let theme = rcx.cx_ref().theme();
    let (bg, border, radius) = (theme.background, theme.border, theme.radius_lg);
    let n = node.clone();
    let base = v_flex()
        .w(px(width))
        .max_w_full()
        .mt(px(100.))
        .gap_4()
        .p_6()
        .bg(bg)
        .border_1()
        .border_color(border)
        .rounded(radius)
        .shadow_xl();
    let panel = rcx
        .element_from(node, base)
        .track_focus(&fh)
        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
        .on_key_down(move |ev, window, cx| {
            if keyboard && ev.keystroke.key == "escape" {
                cx.stop_propagation();
                if alert {
                    alert_answer(&n, "cancel", window, cx);
                } else {
                    ask_close(&n);
                }
            }
        })
        .child(track_panel(node, st))
        .children(head)
        .children(body)
        .children(footer.map(|f| h_flex().w_full().justify_end().gap_2().child(f)));
    backdrop(rcx, node, closes, modal)
        .flex()
        .justify_center()
        .items_start()
        .child(panel)
        .into_any_element()
}

fn sheet(rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
    let side = text_or_default(node, "side");
    let size = super::nav::number(node, "size", 350.) as f32;
    let closes = text_or_default(node, "overlay-closable") != "off";
    let fh = rcx.focus_handle(node);
    let st = rcx.state::<OverlayState>(node);
    let head = header(rcx, node, true);
    let (body, footer) = body_and_footer(rcx, node);
    let theme = rcx.cx_ref().theme();
    let (bg, border) = (theme.background, theme.border);
    let mut base = v_flex().absolute().gap_4().p_6().bg(bg).border_color(border).shadow_xl();
    base = match side.as_str() {
        "left" => base.top_0().left_0().h_full().w(px(size)).border_r_1(),
        "top" => base.top_0().left_0().w_full().h(px(size)).border_b_1(),
        "bottom" => base.bottom_0().left_0().w_full().h(px(size)).border_t_1(),
        _ => base.top_0().right_0().h_full().w(px(size)).border_l_1(),
    };
    let n = node.clone();
    let panel = rcx
        .element_from(node, base)
        .track_focus(&fh)
        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
        .on_key_down(move |ev, _, cx| {
            if ev.keystroke.key == "escape" {
                cx.stop_propagation();
                ask_close(&n);
            }
        })
        .child(track_panel(node, st))
        .children(head)
        .child(v_flex().flex_1().min_h_0().gap_2().children(body))
        .children(footer.map(|f| h_flex().w_full().justify_end().gap_2().child(f)));
    backdrop(rcx, node, closes, true).child(panel).into_any_element()
}

// ---- anchored: popover, hover-card, context-menu ---------------------------

/// The anchor node's bounds from the last layout (window coordinates).
fn anchor_bounds(node: &NodeView) -> Option<Bounds<Pixels>> {
    let a = node.text("anchor")?;
    let a = a.trim();
    if a.is_empty() {
        return None;
    }
    let anchor = node.host.node_at(&format!("{}/{}", node.win(), a))?;
    let v: Vec<f32> = anchor.bounds()?.to_vec();
    match v[..] {
        [x, y, w, h] if w > 0. || h > 0. => Some(Bounds::new(
            point(px(x), px(y)),
            gpui::size(px(w), px(h)),
        )),
        _ => None,
    }
}

fn panel_bounds(node: &NodeView, cx: &App) -> Option<Bounds<Pixels>> {
    node.host
        .states
        .borrow()
        .get(&node.node())
        .and_then(|s| s.entity.clone())
        .and_then(|e| e.downcast::<OverlayState>().ok())
        .and_then(|e| e.read(cx).panel)
}

fn state_of(node: &NodeView) -> Option<Entity<OverlayState>> {
    node.host
        .states
        .borrow()
        .get(&node.node())
        .and_then(|s| s.entity.clone())
        .and_then(|e| e.downcast::<OverlayState>().ok())
}

fn delays(node: &NodeView, kind: Kind) -> (u64, u64) {
    match kind {
        Kind::HoverCard => (
            super::nav::number(node, "open-delay", 600.).max(0.) as u64,
            super::nav::number(node, "close-delay", 300.).max(0.) as u64,
        ),
        _ => (0, 150),
    }
}

/// Opens or closes after the overlay's delay, unless the pointer changed
/// its mind first.
fn hover_to(node: &NodeView, kind: Kind, want: bool, window: &mut Window, cx: &mut App) {
    let Some(st) = state_of(node) else { return };
    let (open_d, close_d) = delays(node, kind);
    let (open, pending) = {
        let s = st.read(cx);
        (s.open, s.hover_want)
    };
    if pending == Some(want) || (pending.is_none() && open == want) {
        return;
    }
    let gen_ = st.update(cx, |s, _| {
        s.hover_gen += 1;
        s.hover_want = (s.open != want).then_some(want);
        s.hover_gen
    });
    if open == want {
        return;
    }
    let d = if want { open_d } else { close_d };
    if d == 0 {
        st.update(cx, |s, _| s.hover_want = None);
        user_toggle(node, want, window, cx);
        return;
    }
    let n = node.clone();
    let win = node.win().to_string();
    cx.spawn(async move |cx: &mut AsyncApp| {
        cx.background_executor()
            .timer(Duration::from_millis(d))
            .await;
        cx.update(|cx| {
            let Some(st) = state_of(&n) else { return };
            let ok = st.read(cx).hover_gen == gen_;
            if !ok {
                return;
            }
            st.update(cx, |s, _| s.hover_want = None);
            crate::runtime::with_window(&n.host, &win, cx, |window, cx| {
                user_toggle(&n, want, window, cx)
            });
        });
    })
    .detach();
}

/// A zero-size element that paints window-level listeners binding the
/// overlay to its anchor: click (popover), hover (popover, hover-card),
/// right click (context-menu), and clicks outside an open panel.
fn trigger_listener(kind: Kind, node: &NodeView) -> impl IntoElement {
    let node = node.clone();
    let hover = kind == Kind::HoverCard || text_or_default(&node, "trigger") == "hover";
    canvas(
        |_, _, _| {},
        move |_, _, window, _| {
            let n = node.clone();
            window.on_mouse_event(move |ev: &MouseDownEvent, phase, window, cx| {
                if phase != DispatchPhase::Bubble {
                    return;
                }
                let Some(st) = state_of(&n) else { return };
                let open = st.read(cx).open;
                let in_anchor = anchor_bounds(&n).is_some_and(|b| b.contains(&ev.position));
                let in_panel = panel_bounds(&n, cx).is_some_and(|b| b.contains(&ev.position));
                match kind {
                    Kind::ContextMenu => {
                        if ev.button == MouseButton::Right && in_anchor {
                            st.update(cx, |s, _| s.pos = Some(ev.position));
                            if !set_open(&n, true, window, cx) {
                                window.refresh();
                            }
                            // Keep the position set_open cleared on a reopen.
                            st.update(cx, |s, _| s.pos = Some(ev.position));
                        } else if open && !in_panel {
                            set_open(&n, false, window, cx);
                        }
                    }
                    _ => {
                        if ev.button != MouseButton::Left {
                            return;
                        }
                        if in_anchor && !hover {
                            user_toggle(&n, !open, window, cx);
                        } else if open && !in_panel && !in_anchor {
                            user_toggle(&n, false, window, cx);
                        }
                    }
                }
            });
            if hover {
                let n = node.clone();
                window.on_mouse_event(move |ev: &MouseMoveEvent, phase, window, cx| {
                    if phase != DispatchPhase::Bubble {
                        return;
                    }
                    let in_anchor = anchor_bounds(&n).is_some_and(|b| b.contains(&ev.position));
                    let in_panel = panel_bounds(&n, cx).is_some_and(|b| b.contains(&ev.position));
                    hover_to(&n, kind, in_anchor || in_panel, window, cx);
                });
            }
        },
    )
    .absolute()
    .size_0()
}

/// `placement` to (the panel's corner, the anchor's corner, offset).
fn placement(p: &str) -> (Anchor, Anchor, Point<Pixels>) {
    let g = px(4.);
    let z = px(0.);
    match p {
        "top-start" => (Anchor::BottomLeft, Anchor::TopLeft, point(z, -g)),
        "top" => (Anchor::BottomCenter, Anchor::TopCenter, point(z, -g)),
        "top-end" => (Anchor::BottomRight, Anchor::TopRight, point(z, -g)),
        "bottom" => (Anchor::TopCenter, Anchor::BottomCenter, point(z, g)),
        "bottom-end" => (Anchor::TopRight, Anchor::BottomRight, point(z, g)),
        "left-start" => (Anchor::TopRight, Anchor::TopLeft, point(-g, z)),
        "left" => (Anchor::RightCenter, Anchor::LeftCenter, point(-g, z)),
        "left-end" => (Anchor::BottomRight, Anchor::BottomLeft, point(-g, z)),
        "right-start" => (Anchor::TopLeft, Anchor::TopRight, point(g, z)),
        "right" => (Anchor::LeftCenter, Anchor::RightCenter, point(g, z)),
        "right-end" => (Anchor::BottomLeft, Anchor::BottomRight, point(g, z)),
        _ => (Anchor::TopLeft, Anchor::BottomLeft, point(z, g)),
    }
}

fn popover(rcx: &mut RenderCx, node: &NodeView, kind: Kind) -> AnyElement {
    let fh = rcx.focus_handle(node);
    let st = rcx.state::<OverlayState>(node);
    let kids = rcx.children(node);
    let n = node.clone();
    let base = v_flex().popover_style(rcx.cx_ref()).p_3().gap_2();
    let panel = rcx
        .element_from(node, base)
        .occlude()
        .track_focus(&fh)
        .on_key_down(move |ev, window, cx| {
            if ev.keystroke.key == "escape" {
                cx.stop_propagation();
                user_toggle(&n, false, window, cx);
            }
        })
        .child(track_panel(node, st))
        .children(kids);
    let (corner, at, offset) = placement(&text_or_default(node, "placement"));
    let mut a = anchored().anchor(corner).snap_to_window_with_margin(px(8.));
    match anchor_bounds(node) {
        Some(b) => a = a.attach(b, at).offset(offset),
        None => {
            // No anchor (or not drawn yet): the middle of the window's top.
            a = a.position(point(rcx.window().viewport_size().width / 2., px(80.)))
        }
    }
    let _ = kind;
    a.child(panel).into_any_element()
}

/// The `menu` file's items, with `set id enabled= check=` applied.
fn context_menu(rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
    let lines = node.typed_lines::<MenuLine>("menu");
    let fh = rcx.focus_handle(node);
    let st = rcx.state::<OverlayState>(node);
    let theme = rcx.cx_ref().theme();
    let (muted, accent, accent_fg, border) = (
        theme.muted_foreground,
        theme.accent,
        theme.accent_foreground,
        theme.border,
    );
    let states = node.host.action_state.borrow().clone();
    let mut rows: Vec<AnyElement> = Vec::new();
    for (i, l) in lines.iter().enumerate() {
        let indent = px(8. + 12. * l.depth as f32);
        match l.kind {
            MenuKind::Sep => rows.push(
                div()
                    .my_1()
                    .h(px(1.))
                    .w_full()
                    .bg(border)
                    .into_any_element(),
            ),
            MenuKind::Sub => rows.push(
                h_flex()
                    .pl(indent)
                    .pr_2()
                    .py_1()
                    .text_xs()
                    .text_color(muted)
                    .child(label_of(l))
                    .into_any_element(),
            ),
            MenuKind::Item => {
                let (en, ck) = states.get(&l.id).copied().unwrap_or((true, -1));
                let enabled = en && l.prop("enabled") != Some("off");
                let checked = ck == 1 || (ck < 0 && l.prop("check") == Some("on"));
                let id = l.id.clone();
                let n = node.clone();
                let mut row = h_flex()
                    .id(gpui::ElementId::Name(format!("{}#item-{i}", node.path()).into()))
                    .w_full()
                    .gap_2()
                    .pl(indent)
                    .pr_2()
                    .py_1()
                    .rounded_sm()
                    .child(
                        div()
                            .w(px(14.))
                            .children(checked.then(|| gpui_component::Icon::new(IconName::Check).xsmall())),
                    )
                    .child(div().flex_1().child(label_of(l)))
                    .children(
                        l.prop("key")
                            .map(|k| div().text_xs().text_color(muted).child(k.to_string())),
                    );
                if enabled {
                    row = row
                        .cursor_pointer()
                        .hover(move |s| s.bg(accent).text_color(accent_fg))
                        .on_click(move |_, window, cx| {
                            set_open(&n, false, window, cx);
                            n.emitter().menu_action(&id);
                        });
                } else {
                    row = row.opacity(0.5);
                }
                let key = format!("{}#item:{}", node.path(), l.id);
                rows.push(
                    row.child(
                        canvas(move |b, _, _| super::nav::record_part(key, b), |_, _, _, _| {})
                            .absolute()
                            .top_0()
                            .left_0()
                            .size_full(),
                    )
                    .into_any_element(),
                );
            }
        }
    }
    let n = node.clone();
    let base = v_flex().popover_style(rcx.cx_ref()).p_1().min_w(px(160.)).text_sm();
    let panel = rcx
        .element_from(node, base)
        .occlude()
        .track_focus(&fh)
        .on_key_down(move |ev, window, cx| {
            if ev.keystroke.key == "escape" {
                cx.stop_propagation();
                set_open(&n, false, window, cx);
            }
        })
        .child(track_panel(node, st.clone()))
        .children(rows);
    let pos = st
        .and_then(|s| s.read(rcx.cx_ref()).pos)
        .or_else(|| anchor_bounds(node).map(|b| b.bottom_left()))
        .unwrap_or_else(|| point(px(80.), px(80.)));
    anchored()
        .position(pos)
        .snap_to_window_with_margin(px(8.))
        .child(panel)
        .into_any_element()
}

fn label_of(l: &MenuLine) -> String {
    l.prop("label").unwrap_or(&l.id).to_string()
}
