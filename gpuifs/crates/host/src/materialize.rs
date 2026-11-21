//! The materialize step: a committed node to GPUI elements.

use gpui::{
    AnyElement, App, Bounds, ElementId, InteractiveElement, IntoElement, Keystroke, MouseButton,
    ParentElement, Pixels, StatefulInteractiveElement, Styled, Window,
};
use gpui::Refineable as _;
use gpui_component::ElementExt as _;
use gpui_component::tooltip::Tooltip;

use crate::{NodeState, NodeView, RenderCx};

/// Renders a node through its component, creating its GPUI state first.
pub(crate) fn render_node(rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
    let host = rcx.host.clone();
    let Some(comp) = host.components.get(node.ty()) else {
        // A type with no renderer yet (a W6 group still in progress): a box
        // that still shows its children, so a tree is never invisible.
        let kids = rcx.children(node);
        return rcx.element(node).children(kids).into_any_element();
    };
    let need = host
        .states
        .borrow()
        .get(node.path())
        .is_none_or(|s| s.ty != node.ty());
    if need {
        let entity = comp.create(node, rcx.window, rcx.cx);
        host.states.borrow_mut().insert(
            node.path().to_string(),
            NodeState {
                ty: node.ty().to_string(),
                entity,
            },
        );
    }
    comp.render(rcx, node)
}

fn mouse_button(b: MouseButton) -> &'static str {
    match b {
        MouseButton::Left => "left",
        MouseButton::Right => "right",
        MouseButton::Middle => "middle",
        _ => "other",
    }
}

fn num(p: Pixels) -> String {
    let v = (f32::from(p) * 10.).round() / 10.;
    if v.fract() == 0.0 {
        format!("{}", v as i64)
    } else {
        format!("{v:.1}")
    }
}

/// A keystroke in GPUI keymap syntax (`cmd-shift-p`).
pub(crate) fn keystroke(k: &Keystroke) -> String {
    let m = &k.modifiers;
    let mut s = String::new();
    if m.control {
        s.push_str("ctrl-");
    }
    if m.alt {
        s.push_str("alt-");
    }
    if m.shift {
        s.push_str("shift-");
    }
    if m.platform {
        s.push_str(if cfg!(target_os = "macos") { "cmd-" } else { "super-" });
    }
    if m.function {
        s.push_str("fn-");
    }
    s.push_str(&k.key);
    s
}

/// The element-tier box for a node: id, style words, state styles, group,
/// `on` listeners, `context`, `tooltip` and `bounds`.
pub(crate) fn element(rcx: &mut RenderCx, node: &NodeView, base: gpui::Div) -> gpui::Stateful<gpui::Div> {
    let st = rcx.style_of(node);
    let path = node.path().to_string();
    let mut el = base;
    if let Some(g) = &st.group {
        el = el.group(g.clone());
    }
    el.style().refine(&st.base);
    if node.flag("disabled")
        && let Some(d) = &st.disabled
    {
        el.style().refine(d);
    }
    if let Some(h) = st.hover.clone() {
        el = el.hover(move |mut s| {
            s.refine(&h);
            s
        });
    }
    if let Some((g, h)) = st.group_hover.first().cloned() {
        el = el.group_hover(g, move |mut s| {
            s.refine(&h);
            s
        });
    }
    if let Some(ctx) = node
        .text("context")
        .and_then(|c| gpui::KeyContext::parse(c.trim()).ok())
        .filter(|_| node.is_set("context"))
    {
        el = el.key_context(ctx);
    }

    let on = node.on_words();
    let em = node.emitter();
    let wants = |w: &str| on.iter().any(|x| x == w);

    if wants("key") || wants("focus") || wants("blur") || st.focus.is_some() {
        let fh = rcx.focus_handle(node);
        el = el.track_focus(&fh);
        if let Some(f) = st.focus.clone() {
            el = el.focus(move |mut s| {
                s.refine(&f);
                s
            });
        }
        if wants("key") {
            let em = em.clone();
            el = el.on_key_down(move |ev, _, _| {
                em.event("key", &[("key", &keystroke(&ev.keystroke))]);
            });
        }
        if wants("focus") || wants("key") {
            // Clicking a focusable node focuses it.
            let fh = fh.clone();
            el = el.on_any_mouse_down(move |_, window, cx| fh.focus(window, cx));
        }
    }
    if wants("mouse_down") {
        let em = em.clone();
        el = el.on_any_mouse_down(move |ev, _, _| {
            em.event(
                "mouse_down",
                &[
                    ("x", &num(ev.position.x)),
                    ("y", &num(ev.position.y)),
                    ("button", mouse_button(ev.button)),
                ],
            );
        });
    }
    if wants("mouse_up") {
        for b in [MouseButton::Left, MouseButton::Right, MouseButton::Middle] {
            let em = em.clone();
            el = el.on_mouse_up(b, move |ev, _, _| {
                em.event(
                    "mouse_up",
                    &[
                        ("x", &num(ev.position.x)),
                        ("y", &num(ev.position.y)),
                        ("button", mouse_button(ev.button)),
                    ],
                );
            });
        }
    }
    if wants("move") {
        let em = em.clone();
        el = el.on_mouse_move(move |ev, window, _| {
            let _ = window;
            em.event("move", &[("x", &num(ev.position.x)), ("y", &num(ev.position.y))]);
        });
    }

    let mut el = el.id(ElementId::Name(path.clone().into()));
    if let Some(a) = st.active.clone() {
        el = el.active(move |mut s| {
            s.refine(&a);
            s
        });
    }
    if wants("click") {
        let em = em.clone();
        el = el.on_click(move |ev, _, _| {
            let p = ev.position();
            let button = if ev.is_right_click() {
                "right"
            } else if ev.is_middle_click() {
                "middle"
            } else {
                "left"
            };
            em.event(
                "click",
                &[("x", &num(p.x)), ("y", &num(p.y)), ("button", button)],
            );
        });
    }
    if wants("hover") {
        let em = em.clone();
        el = el.on_hover(move |h, _, _| {
            em.event("hover", &[("value", if *h { "on" } else { "off" })]);
        });
    }
    if wants("scroll") {
        let em = em.clone();
        el = el.on_scroll(move |ev, window, _| {
            let d = ev.delta.pixel_delta(window.line_height());
            em.event("scroll", &[("dx", &num(d.x)), ("dy", &num(d.y))]);
        });
    }
    if let Some(tip) = node.text("tooltip").filter(|t| !t.is_empty()) {
        el = el.tooltip(move |window, cx| Tooltip::new(tip.clone()).build(window, cx));
    }

    // `bounds`: window-relative x y w h from the last layout.
    let host = rcx.host.clone();
    el.on_prepaint(move |b: Bounds<Pixels>, _: &mut Window, _: &mut App| {
        let nb = [
            f32::from(b.origin.x),
            f32::from(b.origin.y),
            f32::from(b.size.width),
            f32::from(b.size.height),
        ];
        if let Ok(mut t) = host.tree.try_borrow_mut() {
            t.report_bounds(&path, nb);
        }
    })
}
