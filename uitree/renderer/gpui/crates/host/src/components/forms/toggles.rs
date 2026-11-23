//! `checkbox`, `radio-group`, `switch`, `toggle`, `rating`, `slider`.

use gpui::{AnyElement, AnyEntity, App, AppContext as _, Axis, ElementId, Entity, Window};
use gpui_component::button::{Toggle, ToggleVariants as _};
use gpui_component::checkbox::Checkbox;
use gpui_component::radio::{Radio, RadioGroup};
use gpui_component::rating::Rating;
use gpui_component::slider::{Slider, SliderEvent, SliderState, SliderValue};
use gpui_component::switch::Switch;
use gpui_component::{Disableable as _, Sizable as _};
use crate::data_lines::RadioItem;

use super::{boxed, common, fmt_num, icon, nonempty, num, rebuild, size, user_change};
use crate::{Component, ComponentRegistry, NodeView, RenderCx};

pub(super) fn register(reg: &mut ComponentRegistry) {
    reg.add(CheckboxC);
    reg.add(RadioGroupC);
    reg.add(SwitchC);
    reg.add(ToggleC);
    reg.add(RatingC);
    reg.add(SliderC);
}

fn id(node: &NodeView, part: &str) -> ElementId {
    ElementId::Name(format!("{}#{part}", node.path()).into())
}

fn on_off(b: bool) -> &'static str {
    if b { "on" } else { "off" }
}

struct CheckboxC;
impl Component for CheckboxC {
    common!("checkbox");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let st = rcx.style_of(node);
        let v = node.text("value").unwrap_or_default();
        let (em, n) = (node.emitter(), node.clone());
        let mut c = Checkbox::new(id(node, "checkbox"))
            .checked(v == "on")
            .indeterminate(v == "mixed")
            .disabled(node.flag("disabled"))
            .on_click(move |checked, _, _| user_change(&n, &em, on_off(*checked), true));
        if let Some(l) = nonempty(node, "label") {
            c = c.label(l);
        }
        if let Some(s) = size(&st) {
            c = c.with_size(s);
        }
        boxed(rcx, node, c)
    }
}

struct SwitchC;
impl Component for SwitchC {
    common!("switch");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let st = rcx.style_of(node);
        let (em, n) = (node.emitter(), node.clone());
        let mut c = Switch::new(id(node, "switch"))
            .checked(node.flag("value"))
            .disabled(node.flag("disabled"))
            .on_click(move |checked, _, _| user_change(&n, &em, on_off(*checked), true));
        if let Some(l) = nonempty(node, "label") {
            c = c.label(l);
        }
        if let Some(s) = size(&st) {
            c = c.with_size(s);
        }
        boxed(rcx, node, c)
    }
}

struct ToggleC;
impl Component for ToggleC {
    common!("toggle");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let st = rcx.style_of(node);
        let (em, n) = (node.emitter(), node.clone());
        let mut c = Toggle::new(id(node, "toggle"))
            .checked(node.flag("value"))
            .disabled(node.flag("disabled"))
            .on_click(move |checked, _, _| user_change(&n, &em, on_off(*checked), true));
        if let Some(l) = nonempty(node, "label") {
            c = c.label(l);
        }
        if let Some(i) = icon(node) {
            c = c.icon(i);
        }
        if st.has_variant("outline") {
            c = c.outline();
        }
        if let Some(s) = size(&st) {
            c = c.with_size(s);
        }
        boxed(rcx, node, c)
    }
}

fn radio_items(node: &NodeView) -> Vec<RadioItem> {
    node.typed_lines("items")
}

struct RadioGroupC;
impl Component for RadioGroupC {
    common!("radio-group");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let items = radio_items(node);
        let value = node.text("value").unwrap_or_default();
        let sel = items.iter().position(|i| i.id == value);
        let ids: Vec<String> = items.iter().map(|i| i.id.clone()).collect();
        let radios: Vec<Radio> = items
            .iter()
            .map(|i| {
                Radio::new(id(node, &format!("radio-{}", i.id)))
                    .label(if i.label.is_empty() { i.id.clone() } else { i.label.clone() })
                    .disabled(i.disabled)
            })
            .collect();
        let axis = if node.text("dir").as_deref() == Some("row") {
            Axis::Horizontal
        } else {
            Axis::Vertical
        };
        let (em, n) = (node.emitter(), node.clone());
        let g = RadioGroup::new(id(node, "radios"))
            .layout(axis)
            .children(radios)
            .selected_index(sel)
            .disabled(node.flag("disabled"))
            .on_click(move |ix, _, _| {
                if let Some(v) = ids.get(*ix) {
                    user_change(&n, &em, v, true);
                }
            });
        boxed(rcx, node, g)
    }
}

struct RatingC;
impl Component for RatingC {
    common!("rating");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let st = rcx.style_of(node);
        let max = num(node, "max").unwrap_or(5.).max(0.) as usize;
        let v = num(node, "value").unwrap_or(0.).max(0.) as usize;
        let (em, n) = (node.emitter(), node.clone());
        let mut r = Rating::new(id(node, "rating"))
            .max(max)
            .value(v)
            .disabled(node.flag("disabled"))
            .on_click(move |v, _, _| user_change(&n, &em, &v.to_string(), true));
        if let Some(s) = size(&st) {
            r = r.with_size(s);
        }
        boxed(rcx, node, r)
    }
}

/// `value` as a slider value: one number, or `lo hi`.
fn slider_value(node: &NodeView) -> SliderValue {
    let v: Vec<f32> = node
        .text("value")
        .unwrap_or_default()
        .split(|c: char| c == ',' || c.is_whitespace())
        .filter_map(|x| x.parse().ok())
        .collect();
    match v[..] {
        [lo, hi, ..] => SliderValue::Range(lo, hi),
        [x] => SliderValue::Single(x),
        _ => SliderValue::Single(0.),
    }
}

fn fmt_slider(v: &SliderValue) -> String {
    match v {
        SliderValue::Single(x) => fmt_num(*x as f64),
        SliderValue::Range(a, b) => format!("{} {}", fmt_num(*a as f64), fmt_num(*b as f64)),
    }
}

struct SliderC;
impl Component for SliderC {
    common!("slider");
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let min = num(node, "min").unwrap_or(0.) as f32;
        let max = num(node, "max").unwrap_or(100.) as f32;
        let step = num(node, "step").unwrap_or(1.) as f32;
        let value = slider_value(node);
        let state: Entity<SliderState> = cx.new(|_| {
            SliderState::new()
                .min(min)
                .max(max)
                .step(step)
                .default_value(value)
        });
        let n = node.clone();
        let em = node.emitter();
        window
            .subscribe(&state, cx, move |state, ev: &SliderEvent, window, cx| {
                let (v, release) = match ev {
                    SliderEvent::Change(v) => (*v, false),
                    SliderEvent::Release(v) => (*v, true),
                };
                let s = fmt_slider(&v);
                if release {
                    em.event("commit", &[("value", &s)]);
                    if n.flag("controlled") {
                        // Back to what the client last wrote.
                        let cur = slider_value(&n);
                        state.update(cx, |st, cx| st.set_value(cur, window, cx));
                    }
                } else if n.text("value").as_deref() != Some(s.as_str()) {
                    user_change(&n, &em, &s, true);
                }
            })
            .detach();
        Some(state.into())
    }
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {
        match prop {
            "min" | "max" | "step" => rebuild(node, window, cx),
            "value" => {
                if let Some(s) = state.and_then(|s| s.clone().downcast::<SliderState>().ok()) {
                    let v = slider_value(node);
                    s.update(cx, |st, cx| st.set_value(v, window, cx));
                }
            }
            _ => {}
        }
    }
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(state) = rcx.state::<SliderState>(node) else {
            return rcx.element(node).into_any_element();
        };
        let mut s = Slider::new(&state).disabled(node.flag("disabled"));
        if node.text("dir").as_deref() == Some("col") {
            s = s.vertical();
        }
        boxed(rcx, node, s)
    }
}

use gpui::IntoElement as _;
