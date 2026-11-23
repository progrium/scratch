//! `select`, `combobox`, `date-picker`, `calendar`, `color-picker`.

use std::cell::RefCell;
use std::rc::Rc;

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, Entity, Hsla, IntoElement, ParentElement as _,
    SharedString, Styled as _, Task, Window, div,
};
use gpui_component::calendar::{Calendar, CalendarEvent, CalendarState, Date, Matcher};
use gpui_component::color_picker::{ColorPicker, ColorPickerEvent, ColorPickerState};
use gpui_component::combobox::{Combobox, ComboboxEvent, ComboboxState};
use gpui_component::date_picker::{DatePicker, DatePickerEvent, DatePickerState, DateRangePreset};
use gpui_component::searchable_list::{SearchableListDelegate, SearchableListItem};
use gpui_component::select::{Select, SelectEvent, SelectState};
use gpui_component::{ActiveTheme as _, IndexPath, Sizable as _};
use jiff::civil;
use crate::data_lines::Item;

use super::{boxed, common, nonempty, rebuild, size, user_change};
use crate::{Component, ComponentRegistry, NodeView, RenderCx};

pub(super) fn register(reg: &mut ComponentRegistry) {
    reg.add(SelectC);
    reg.add(ComboboxC);
    reg.add(DatePickerC);
    reg.add(CalendarC);
    reg.add(ColorPickerC);
}

// MARK: items

/// One `items` line, as a select or combobox row.
#[derive(Clone, Debug)]
pub(crate) struct FormItem {
    id: SharedString,
    label: SharedString,
    icon: Option<String>,
    disabled: bool,
}

impl SearchableListItem for FormItem {
    type Value = SharedString;
    fn title(&self) -> SharedString {
        self.label.clone()
    }
    fn value(&self) -> &SharedString {
        &self.id
    }
    fn disabled(&self) -> bool {
        self.disabled
    }
    fn render(&self, _: &mut Window, _: &mut App) -> impl IntoElement {
        let mut row = gpui_component::h_flex().gap_2();
        if let Some(i) = &self.icon {
            row = row.child(gpui_component::Icon::default().path(format!("icons/{i}.svg")));
        }
        row.child(self.label.clone())
    }
}

/// Sections of items: `# name` starts a titled group, `-` an untitled one.
#[derive(Clone, Default)]
pub(crate) struct Items {
    all: Vec<(SharedString, Vec<FormItem>)>,
    shown: Vec<(SharedString, Vec<FormItem>)>,
}

impl Items {
    fn parse(lines: Vec<Item>) -> Self {
        let mut all: Vec<(SharedString, Vec<FormItem>)> = vec![(SharedString::default(), vec![])];
        for l in lines {
            match l {
                Item::Group(g) => all.push((g.into(), vec![])),
                Item::Separator => all.push((SharedString::default(), vec![])),
                Item::Entry(e) => {
                    let label = if e.label.is_empty() { e.id.clone() } else { e.label };
                    all.last_mut().unwrap().1.push(FormItem {
                        id: e.id.into(),
                        label: label.into(),
                        icon: e.icon,
                        disabled: e.disabled,
                    });
                }
            }
        }
        // Keep a titled group even when it is empty; drop empty untitled ones.
        all.retain(|(t, v)| !t.is_empty() || !v.is_empty());
        Items {
            shown: all.clone(),
            all,
        }
    }
    fn of(node: &NodeView) -> Self {
        Self::parse(node.typed_lines("items"))
    }
    fn index_of(&self, id: &str) -> Option<IndexPath> {
        self.shown.iter().enumerate().find_map(|(s, (_, v))| {
            v.iter()
                .position(|i| i.id.as_ref() == id)
                .map(|r| IndexPath::default().section(s).row(r))
        })
    }
}

impl SearchableListDelegate for Items {
    type Item = FormItem;
    fn sections_count(&self, _: &App) -> usize {
        self.shown.len()
    }
    fn items_count(&self, section: usize) -> usize {
        self.shown.get(section).map_or(0, |s| s.1.len())
    }
    fn item(&self, ix: IndexPath) -> Option<&FormItem> {
        self.shown.get(ix.section)?.1.get(ix.row)
    }
    fn position<V>(&self, value: &V) -> Option<IndexPath>
    where
        Self::Item: SearchableListItem<Value = V>,
        V: PartialEq,
    {
        self.shown.iter().enumerate().find_map(|(s, (_, v))| {
            v.iter()
                .position(|i| i.value() == value)
                .map(|r| IndexPath::default().section(s).row(r))
        })
    }
    fn perform_search(&mut self, query: &str, _: &mut Window, _: &mut App) -> Task<()> {
        self.shown = if query.is_empty() {
            self.all.clone()
        } else {
            self.all
                .iter()
                .map(|(t, v)| (t.clone(), v.iter().filter(|i| i.matches(query)).cloned().collect::<Vec<_>>()))
                .filter(|(_, v)| !v.is_empty())
                .collect()
        };
        Task::ready(())
    }
    fn render_section_header(&self, section: usize, _: &mut Window, cx: &mut App) -> Option<AnyElement> {
        let (t, _) = self.shown.get(section)?;
        if t.is_empty() {
            return Some(div().into_any_element());
        }
        Some(
            div()
                .py_0p5()
                .px_2()
                .text_sm()
                .text_color(cx.theme().muted_foreground)
                .child(t.clone())
                .into_any_element(),
        )
    }
}

// MARK: select

struct SelectC;
impl Component for SelectC {
    common!("select");
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let items = Items::of(node);
        let sel = node.text("value").and_then(|v| items.index_of(v.trim()));
        let searchable = node.flag("searchable");
        let state: Entity<SelectState<Items>> =
            cx.new(|cx| SelectState::new(items, sel, window, cx).searchable(searchable));
        let (n, em) = (node.clone(), node.emitter());
        window
            .subscribe(&state, cx, move |state, ev: &SelectEvent<Items>, window, cx| {
                let SelectEvent::Confirm(v) = ev;
                let v = v.as_ref().map(|s| s.to_string()).unwrap_or_default();
                if n.text("value").unwrap_or_default() == v {
                    return;
                }
                user_change(&n, &em, &v, true);
                if n.flag("controlled") {
                    let cur = n.text("value").unwrap_or_default();
                    state.update(cx, |s, cx| s.set_selected_value(&SharedString::from(cur), window, cx));
                }
            })
            .detach();
        Some(state.into())
    }
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {
        let Some(s) = state.and_then(|s| s.clone().downcast::<SelectState<Items>>().ok()) else {
            return;
        };
        let v = SharedString::from(node.text("value").unwrap_or_default().trim().to_string());
        match prop {
            "value" => s.update(cx, |s, cx| s.set_selected_value(&v, window, cx)),
            "items" => {
                let items = Items::of(node);
                s.update(cx, |s, cx| {
                    s.set_items(items, window, cx);
                    s.set_selected_value(&v, window, cx);
                });
            }
            "searchable" => rebuild(node, window, cx),
            _ => {}
        }
    }
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(state) = rcx.state::<SelectState<Items>>(node) else {
            return rcx.element(node).into_any_element();
        };
        let st = rcx.style_of(node);
        let mut s = Select::new(&state).disabled(node.flag("disabled"));
        if let Some(p) = nonempty(node, "placeholder") {
            s = s.placeholder(p);
        }
        if let Some(z) = size(&st) {
            s = s.with_size(z);
        }
        boxed(rcx, node, s)
    }
}

// MARK: combobox

fn ids(node: &NodeView) -> Vec<SharedString> {
    node.text("value")
        .unwrap_or_default()
        .split_whitespace()
        .map(|s| SharedString::from(s.to_string()))
        .collect()
}

fn join(v: &[SharedString]) -> String {
    v.iter().map(|s| s.as_ref()).collect::<Vec<_>>().join(" ")
}

struct ComboboxC;
impl Component for ComboboxC {
    common!("combobox");
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let items = Items::of(node);
        let sel: Vec<IndexPath> = ids(node).iter().filter_map(|v| items.index_of(v)).collect();
        let multiple = node.flag("multiple");
        let state: Entity<ComboboxState<Items>> = cx.new(|cx| {
            ComboboxState::new(items, sel, window, cx)
                .multiple(multiple)
                .searchable(true)
        });
        let (n, em) = (node.clone(), node.emitter());
        window
            .subscribe(&state, cx, move |state, ev: &ComboboxEvent<Items>, window, cx| {
                let v = match ev {
                    ComboboxEvent::Change(v) | ComboboxEvent::Confirm(v) => join(v),
                };
                if n.text("value").unwrap_or_default() == v {
                    return;
                }
                user_change(&n, &em, &v, true);
                if n.flag("controlled") {
                    let cur = ids(&n);
                    state.update(cx, |s, cx| s.set_selected_values(&cur, window, cx));
                }
            })
            .detach();
        // `query` follows what the user types.
        let (n, em) = (node.clone(), node.emitter());
        let last = Rc::new(RefCell::new(String::new()));
        cx.observe(&state, move |s, cx| {
            let q = s.read(cx).query(cx).to_string();
            if *last.borrow() != q {
                *last.borrow_mut() = q.clone();
                em.mirror("query", q.clone());
                em.event("query", &[("value", &q)]);
                let _ = &n;
            }
        })
        .detach();
        Some(state.into())
    }
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {
        let Some(s) = state.and_then(|s| s.clone().downcast::<ComboboxState<Items>>().ok()) else {
            return;
        };
        let v = ids(node);
        match prop {
            "value" => s.update(cx, |s, cx| s.set_selected_values(&v, window, cx)),
            "items" => {
                let items = Items::of(node);
                s.update(cx, |s, cx| {
                    s.set_items(items, window, cx);
                    s.set_selected_values(&v, window, cx);
                });
            }
            "multiple" => rebuild(node, window, cx),
            _ => {}
        }
    }
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(state) = rcx.state::<ComboboxState<Items>>(node) else {
            return rcx.element(node).into_any_element();
        };
        let st = rcx.style_of(node);
        let mut c = Combobox::new(&state).disabled(node.flag("disabled"));
        if let Some(p) = nonempty(node, "placeholder") {
            c = c.placeholder(p);
        }
        if let Some(z) = size(&st) {
            c = c.with_size(z);
        }
        boxed(rcx, node, c)
    }
}

// MARK: dates

fn parse_dates(s: &str) -> Vec<civil::Date> {
    s.split_whitespace().filter_map(|d| d.parse().ok()).collect()
}

/// `value` as a calendar date, single or range.
fn date_value(node: &NodeView) -> Date {
    let d = parse_dates(&node.text("value").unwrap_or_default());
    if node.flag("range") {
        Date::Range(d.first().copied(), d.get(1).copied())
    } else {
        Date::Single(d.first().copied())
    }
}

fn fmt_date(d: &Date) -> String {
    match d {
        Date::Single(Some(a)) => a.to_string(),
        Date::Single(None) => String::new(),
        Date::Range(a, b) => [a, b]
            .iter()
            .filter_map(|x| x.map(|x| x.to_string()))
            .collect::<Vec<_>>()
            .join(" "),
    }
}

/// `min`/`max` as a matcher for dates the user can't pick.
fn bounds_matcher(node: &NodeView) -> Option<Matcher> {
    let min = parse_dates(&node.text("min").unwrap_or_default()).first().copied();
    let max = parse_dates(&node.text("max").unwrap_or_default()).first().copied();
    if min.is_none() && max.is_none() {
        return None;
    }
    Some(Matcher::from(move |d: &civil::Date| {
        min.is_some_and(|m| *d < m) || max.is_some_and(|m| *d > m)
    }))
}

/// Today in UTC.
fn today() -> civil::Date {
    let days = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() / 86_400)
        .unwrap_or(0) as i64;
    let epoch = civil::date(1970, 1, 1);
    epoch.checked_add(jiff::Span::new().days(days)).unwrap_or(epoch)
}

/// GPUI Kit-style presets for `presets=on`.
fn presets(range: bool) -> Vec<DateRangePreset> {
    let t = today();
    let back = |days: i64| t.checked_sub(jiff::Span::new().days(days)).unwrap_or(t);
    if range {
        vec![
            DateRangePreset::range("Last 7 days", back(6), t),
            DateRangePreset::range("Last 30 days", back(29), t),
            DateRangePreset::range("Last 90 days", back(89), t),
        ]
    } else {
        vec![
            DateRangePreset::single("Today", t),
            DateRangePreset::single("Yesterday", back(1)),
            DateRangePreset::single("A week ago", back(7)),
        ]
    }
}

struct DatePickerC;
impl Component for DatePickerC {
    common!("date-picker");
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let range = node.flag("range");
        let value = date_value(node);
        let matcher = bounds_matcher(node);
        let state: Entity<DatePickerState> = cx.new(|cx| {
            let mut s = if range {
                DatePickerState::range(window, cx)
            } else {
                DatePickerState::new(window, cx)
            };
            if let Some(m) = matcher {
                s = s.disabled_matcher(m);
            }
            s.set_date(value, window, cx);
            s
        });
        let (n, em) = (node.clone(), node.emitter());
        window
            .subscribe(&state, cx, move |state, ev: &DatePickerEvent, window, cx| {
                let DatePickerEvent::Change(dt) = ev;
                let v = fmt_date(&dt.date());
                if n.text("value").unwrap_or_default() == v {
                    return;
                }
                user_change(&n, &em, &v, true);
                if n.flag("controlled") {
                    let cur = date_value(&n);
                    state.update(cx, |s, cx| s.set_date(cur, window, cx));
                }
            })
            .detach();
        Some(state.into())
    }
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {
        match prop {
            "value" => {
                if let Some(s) = state.and_then(|s| s.clone().downcast::<DatePickerState>().ok()) {
                    let v = date_value(node);
                    s.update(cx, |s, cx| s.set_date(v, window, cx));
                }
            }
            "range" | "min" | "max" => rebuild(node, window, cx),
            _ => {}
        }
    }
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(state) = rcx.state::<DatePickerState>(node) else {
            return rcx.element(node).into_any_element();
        };
        let st = rcx.style_of(node);
        let mut d = DatePicker::new(&state);
        if let Some(p) = nonempty(node, "placeholder") {
            d = d.placeholder(p);
        }
        if node.flag("presets") {
            d = d.presets(presets(node.flag("range")));
        }
        if node.flag("range") {
            d = d.number_of_months(2);
        }
        if let Some(z) = size(&st) {
            d = d.with_size(z);
        }
        boxed(rcx, node, d)
    }
}

struct CalendarC;
impl Component for CalendarC {
    common!("calendar");
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let value = date_value(node);
        let matcher = bounds_matcher(node);
        let state: Entity<CalendarState> = cx.new(|cx| {
            let mut s = CalendarState::new(window, cx);
            if let Some(m) = matcher {
                s = s.disabled_matcher(m);
            }
            s.set_date(value, window, cx);
            s
        });
        let (n, em) = (node.clone(), node.emitter());
        window
            .subscribe(&state, cx, move |state, ev: &CalendarEvent, window, cx| {
                let CalendarEvent::Selected(d) = ev;
                let v = fmt_date(d);
                if n.text("value").unwrap_or_default() == v {
                    return;
                }
                user_change(&n, &em, &v, true);
                if n.flag("controlled") {
                    let cur = date_value(&n);
                    state.update(cx, |s, cx| s.set_date(cur, window, cx));
                }
            })
            .detach();
        Some(state.into())
    }
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {
        match prop {
            "value" => {
                if let Some(s) = state.and_then(|s| s.clone().downcast::<CalendarState>().ok()) {
                    let v = date_value(node);
                    s.update(cx, |s, cx| s.set_date(v, window, cx));
                }
            }
            "range" | "min" | "max" => rebuild(node, window, cx),
            _ => {}
        }
    }
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(state) = rcx.state::<CalendarState>(node) else {
            return rcx.element(node).into_any_element();
        };
        let mut c = Calendar::new(&state);
        if node.flag("range") {
            c = c.number_of_months(2);
        }
        boxed(rcx, node, c)
    }
}

// MARK: color

/// `#rrggbbaa`, as `value` holds it.
pub(crate) fn hex(c: Hsla) -> String {
    let r = gpui::Rgba::from(c);
    let b = |x: f32| (x.clamp(0., 1.) * 255.).round() as u8;
    format!("#{:02x}{:02x}{:02x}{:02x}", b(r.r), b(r.g), b(r.b), b(r.a))
}

fn color(s: &str, cx: &App) -> Option<Hsla> {
    crate::styling::parse_color(s.trim(), cx)
}

struct ColorPickerC;
impl Component for ColorPickerC {
    common!("color-picker");
    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let value = node.text("value").and_then(|v| color(&v, cx));
        let state: Entity<ColorPickerState> = cx.new(|cx| {
            let s = ColorPickerState::new(window, cx);
            match value {
                Some(v) => s.default_value(v),
                None => s,
            }
        });
        let (n, em) = (node.clone(), node.emitter());
        window
            .subscribe(&state, cx, move |state, ev: &ColorPickerEvent, window, cx| {
                let ColorPickerEvent::Change(c) = ev;
                let v = c.map(hex).unwrap_or_default();
                if n.text("value").unwrap_or_default() != v {
                    user_change(&n, &em, &v, true);
                }
                em.event("commit", &[("value", &v)]);
                if n.flag("controlled") {
                    match n.text("value").and_then(|v| color(&v, cx)) {
                        Some(c) => state.update(cx, |s, cx| s.set_value(c, window, cx)),
                        None => state.update(cx, |s, cx| s.clear_value(window, cx)),
                    }
                }
            })
            .detach();
        // Dragging previews a color before it is committed.
        let (n, em) = (node.clone(), node.emitter());
        let last = Rc::new(RefCell::new(None::<String>));
        cx.observe(&state, move |s, cx| {
            let p = s.read(cx).preview().map(hex);
            if *last.borrow() != p {
                *last.borrow_mut() = p.clone();
                if let Some(p) = p {
                    em.event("change", &[("value", &p)]);
                }
                let _ = &n;
            }
        })
        .detach();
        Some(state.into())
    }
    fn prop_changed(&self, node: &NodeView, state: Option<&AnyEntity>, prop: &str, window: &mut Window, cx: &mut App) {
        if prop != "value" {
            return;
        }
        let Some(s) = state.and_then(|s| s.clone().downcast::<ColorPickerState>().ok()) else {
            return;
        };
        match node.text("value").and_then(|v| color(&v, cx)) {
            Some(c) => s.update(cx, |s, cx| s.set_value(c, window, cx)),
            None => s.update(cx, |s, cx| s.clear_value(window, cx)),
        }
    }
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(state) = rcx.state::<ColorPickerState>(node) else {
            return rcx.element(node).into_any_element();
        };
        let st = rcx.style_of(node);
        let swatches: Vec<Hsla> = node
            .text("swatches")
            .unwrap_or_default()
            .split(|c: char| c == ',' || c.is_whitespace())
            .filter_map(|s| color(s, rcx.cx_ref()))
            .collect();
        let mut c = ColorPicker::new(&state);
        if !swatches.is_empty() {
            c = c.featured_colors(swatches);
        }
        if let Some(z) = size(&st) {
            c = c.with_size(z);
        }
        boxed(rcx, node, c)
    }
}
