//! `input`, `textarea`, `number-input`, `otp-input`.
//!
//! The text lives in GPUI Kit's state. Every edit mirrors it into `value`
//! and sends a `change` with no text (with `value=` for `number-input`);
//! the tree coalesces those, so a slow client sees the newest text only.
//! A client write to `value` goes into the state without an event back.

use std::cell::RefCell;
use std::rc::Rc;

use gpui::{AnyElement, AnyEntity, App, AppContext as _, Entity, IntoElement as _, Window};
use gpui_component::input::{
    Input, InputEvent, InputState, MaskPattern, NumberInput, OtpEvent, OtpInput, OtpState, Textarea,
    TextareaState,
};
use gpui_component::{Disableable as _, Sizable as _};

use super::{boxed, common, enclosing_form, has_flag, num, rebuild, size};
use crate::{Component, ComponentRegistry, Emitter, NodeView, RenderCx};

pub(super) fn register(reg: &mut ComponentRegistry) {
    reg.add(InputC);
    reg.add(TextareaC);
    reg.add(NumberInputC);
    reg.add(OtpInputC);
}

/// What the host last saw in `value`, so edits are told from client writes.
#[derive(Clone, Default)]
struct Last(Rc<RefCell<String>>);

impl Last {
    fn new(v: String) -> Self {
        Last(Rc::new(RefCell::new(v)))
    }
    /// True if `v` is new; remembers it.
    fn update(&self, v: &str) -> bool {
        let mut l = self.0.borrow_mut();
        if *l == v {
            return false;
        }
        *l = v.to_string();
        true
    }
}

/// Text state plus the bookkeeping the host keeps beside it.
pub(crate) struct TextState<T: 'static> {
    pub state: Entity<T>,
    last: Last,
}

/// The value as written: a single-line input drops one trailing newline
/// (NodeView::text), a textarea keeps the bytes.
fn value_of(node: &NodeView) -> String {
    if node.ty() == "textarea" {
        node.prop("value")
            .map(|b| String::from_utf8_lossy(&b).into_owned())
            .unwrap_or_default()
    } else {
        node.text("value").unwrap_or_default()
    }
}

/// Edits to `value` and `change`; enter to `submit` (on the node and on its
/// form); focus and blur. `with_value` adds `value=` to `change`.
fn wire<T: gpui::EventEmitter<InputEvent> + 'static>(
    node: &NodeView,
    state: &Entity<T>,
    value: fn(&T) -> String,
    last: &Last,
    with_value: bool,
    submit_on_enter: bool,
    window: &mut Window,
    cx: &mut App,
) {
    let (n, em, l) = (node.clone(), node.emitter(), last.clone());
    cx.observe(state, move |s, cx| {
        let v = value(s.read(cx));
        if l.update(&v) {
            changed(&n, &em, &v, with_value);
        }
    })
    .detach();
    let (n, em) = (node.clone(), node.emitter());
    window
        .subscribe(state, cx, move |_, ev: &InputEvent, _, _| match ev {
            InputEvent::PressEnter { secondary, .. } => {
                if submit_on_enter || *secondary {
                    em.event("submit", &[]);
                    if let Some(f) = enclosing_form(&n) {
                        f.emitter().event("submit", &[]);
                    }
                }
            }
            InputEvent::Focus => em.event("focus", &[]),
            InputEvent::Blur => em.event("blur", &[]),
            InputEvent::Change => {}
        })
        .detach();
}

fn input_value(s: &InputState) -> String {
    s.value().to_string()
}
fn textarea_value(s: &TextareaState) -> String {
    s.value().to_string()
}

fn changed(n: &NodeView, em: &Emitter, v: &str, with_value: bool) {
    em.mirror("value", v.to_string());
    if with_value {
        em.event("change", &[("value", v)]);
    } else {
        em.event("change", &[]);
    }
}

fn input_state<T: 'static>(state: Option<&AnyEntity>) -> Option<Entity<TextState<T>>> {
    state.and_then(|s| s.clone().downcast::<TextState<T>>().ok())
}

/// Pushes a client-written `value` into the state.
macro_rules! push_value {
    ($node:expr, $ts:expr, $window:expr, $cx:expr) => {{
        let v = value_of($node);
        let (state, last) = {
            let t = $ts.read($cx);
            (t.state.clone(), t.last.clone())
        };
        last.update(&v);
        if state.read($cx).value().as_ref() != v {
            state.update($cx, |s, cx| s.set_value(v, $window, cx));
        }
    }};
}

fn mask(node: &NodeView) -> Option<MaskPattern> {
    node.text("mask").filter(|m| !m.is_empty()).map(|m| MaskPattern::new(&m))
}

struct InputC;
impl Component for InputC {
    common!("input");
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let v = value_of(node);
        let max_len = num(node, "max_len").map(|n| n.max(0.) as usize);
        let state = cx.new(|cx| {
            let mut s = InputState::new(window, cx)
                .placeholder(node.text("placeholder").unwrap_or_default())
                .masked(has_flag(node, "secret"));
            if let Some(m) = mask(node) {
                s = s.mask_pattern(m);
            }
            if let Some(n) = max_len {
                s = s.validate(move |t, _| t.chars().count() <= n);
            }
            s.default_value(v.clone())
        });
        let last = Last::new(v);
        wire(node, &state, input_value, &last, false, true, window, cx);
        Some(cx.new(|_| TextState { state, last }).into())
    }
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {
        let Some(ts) = input_state::<InputState>(state) else { return };
        let s = ts.read(cx).state.clone();
        match prop {
            "value" => push_value!(node, &ts, window, cx),
            "placeholder" => {
                let p = node.text("placeholder").unwrap_or_default();
                s.update(cx, |s, cx| s.set_placeholder(p, window, cx));
            }
            "flags" => {
                let m = has_flag(node, "secret");
                s.update(cx, |s, cx| s.set_masked(m, window, cx));
            }
            "mask" | "max_len" => rebuild(node, window, cx),
            _ => {}
        }
    }
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(ts) = rcx.state::<TextState<InputState>>(node) else {
            return rcx.element(node).into_any_element();
        };
        let st = rcx.style_of(node);
        let state = ts.read(rcx.cx_ref()).state.clone();
        let mut i = Input::new(&state)
            .cleanable(has_flag(node, "cleanable"))
            .readonly(has_flag(node, "readonly"))
            .disabled(node.flag("disabled"));
        if has_flag(node, "secret") {
            i = i.mask_toggle();
        }
        if let Some(p) = rcx.slot(node, "prefix") {
            i = i.prefix(p);
        }
        if let Some(p) = rcx.slot(node, "suffix") {
            i = i.suffix(p);
        }
        if let Some(s) = super::size(&st) {
            i = i.with_size(s);
        }
        boxed(rcx, node, i)
    }
}

/// `auto_grow=min,max`.
fn auto_grow(node: &NodeView) -> Option<(usize, usize)> {
    let v: Vec<usize> = node
        .text("auto_grow")?
        .split(|c: char| c == ',' || c.is_whitespace())
        .filter_map(|x| x.parse::<f64>().ok().map(|f| f.max(1.) as usize))
        .collect();
    match v[..] {
        [a, b, ..] => Some((a, b.max(a))),
        [a] => Some((a, a)),
        _ => None,
    }
}

struct TextareaC;
impl Component for TextareaC {
    common!("textarea");
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let v = value_of(node);
        let rows = num(node, "rows").map(|n| n.max(1.) as usize);
        let grow = auto_grow(node);
        let state = cx.new(|cx| {
            let mut s = TextareaState::new(window, cx)
                .placeholder(node.text("placeholder").unwrap_or_default());
            if let Some(r) = rows {
                s = s.rows(r);
            }
            if let Some((a, b)) = grow {
                s = s.auto_grow(a, b);
            }
            s.default_value(v.clone())
        });
        let last = Last::new(v);
        // Enter is a newline; cmd-enter submits.
        wire(node, &state, textarea_value, &last, false, false, window, cx);
        Some(cx.new(|_| TextState { state, last }).into())
    }
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {
        let Some(ts) = input_state::<TextareaState>(state) else { return };
        let s = ts.read(cx).state.clone();
        match prop {
            "value" => push_value!(node, &ts, window, cx),
            "placeholder" => {
                let p = node.text("placeholder").unwrap_or_default();
                s.update(cx, |s, cx| s.set_placeholder(p, window, cx));
            }
            "rows" => {
                if let Some(r) = num(node, "rows") {
                    s.update(cx, |s, cx| s.set_rows(r.max(1.) as usize, cx));
                }
            }
            "auto_grow" => {
                if let Some((a, b)) = auto_grow(node) {
                    s.update(cx, |s, cx| s.set_auto_grow(a, b, cx));
                }
            }
            _ => {}
        }
    }
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(ts) = rcx.state::<TextState<TextareaState>>(node) else {
            return rcx.element(node).into_any_element();
        };
        let st = rcx.style_of(node);
        let state = ts.read(rcx.cx_ref()).state.clone();
        let mut t = Textarea::new(&state)
            .readonly(has_flag(node, "readonly"))
            .disabled(node.flag("disabled"));
        if let Some(s) = size(&st) {
            t = t.with_size(s);
        }
        boxed(rcx, node, t)
    }
}

struct NumberInputC;
impl Component for NumberInputC {
    common!("number-input");
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let v = value_of(node);
        let (min, max) = (num(node, "min"), num(node, "max"));
        let step = num(node, "step").unwrap_or(1.);
        let state = cx.new(|cx| {
            let mut s = InputState::new(window, cx)
                .placeholder(node.text("placeholder").unwrap_or_default())
                .step(step)
                .validate(|t, _| t.is_empty() || t == "-" || t.parse::<f64>().is_ok());
            if let Some(m) = min {
                s = s.min(m);
            }
            if let Some(m) = max {
                s = s.max(m);
            }
            s.default_value(v.clone())
        });
        let last = Last::new(v);
        wire(node, &state, input_value, &last, true, true, window, cx);
        Some(cx.new(|_| TextState { state, last }).into())
    }
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {
        let Some(ts) = input_state::<InputState>(state) else { return };
        let s = ts.read(cx).state.clone();
        match prop {
            "value" => push_value!(node, &ts, window, cx),
            "min" => {
                let m = num(node, "min");
                s.update(cx, |s, cx| s.set_min(m, window, cx));
            }
            "max" => {
                let m = num(node, "max");
                s.update(cx, |s, cx| s.set_max(m, window, cx));
            }
            "step" | "placeholder" => rebuild(node, window, cx),
            _ => {}
        }
    }
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(ts) = rcx.state::<TextState<InputState>>(node) else {
            return rcx.element(node).into_any_element();
        };
        let st = rcx.style_of(node);
        let state = ts.read(rcx.cx_ref()).state.clone();
        let mut i = NumberInput::new(&state).disabled(node.flag("disabled"));
        if let Some(p) = rcx.slot(node, "prefix") {
            i = i.prefix(p);
        }
        if let Some(p) = rcx.slot(node, "suffix") {
            i = i.suffix(p);
        }
        if let Some(s) = size(&st) {
            i = i.with_size(s);
        }
        boxed(rcx, node, i)
    }
}

struct OtpInputC;
impl Component for OtpInputC {
    common!("otp-input");
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let v = value_of(node);
        let len = num(node, "length").unwrap_or(6.).clamp(1., 32.) as usize;
        let secret = has_flag(node, "secret");
        let state = cx.new(|cx| OtpState::new(len, window, cx).masked(secret).default_value(v.clone()));
        let last = Last::new(v);
        let (n, em, l) = (node.clone(), node.emitter(), last.clone());
        window
            .subscribe(&state, cx, move |s, ev: &OtpEvent, _, cx| {
                let v = s.read(cx).value().to_string();
                match ev {
                    OtpEvent::Change => {
                        if l.update(&v) {
                            changed(&n, &em, &v, false);
                        }
                    }
                    OtpEvent::Complete => {
                        if l.update(&v) {
                            changed(&n, &em, &v, false);
                        }
                        if super::has_flag(&n, "secret") {
                            em.event("complete", &[]);
                        } else {
                            em.event("complete", &[("value", &v)]);
                        }
                    }
                    _ => {}
                }
            })
            .detach();
        Some(cx.new(|_| TextState { state, last }).into())
    }
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {
        let Some(ts) = input_state::<OtpState>(state) else { return };
        let (s, last) = {
            let t = ts.read(cx);
            (t.state.clone(), t.last.clone())
        };
        match prop {
            "value" => {
                let v = value_of(node);
                last.update(&v);
                s.update(cx, |s, cx| s.set_value(v, window, cx));
            }
            "flags" => {
                let m = has_flag(node, "secret");
                s.update(cx, |s, cx| s.set_masked(m, window, cx));
            }
            "length" => rebuild(node, window, cx),
            _ => {}
        }
    }
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(ts) = rcx.state::<TextState<OtpState>>(node) else {
            return rcx.element(node).into_any_element();
        };
        let st = rcx.style_of(node);
        let state = ts.read(rcx.cx_ref()).state.clone();
        let mut o = OtpInput::new(&state).disabled(node.flag("disabled"));
        if let Some(s) = size(&st) {
            o = o.with_size(s);
        }
        rcx.element(node).child(o).into_any_element()
    }
}

use gpui::ParentElement as _;
