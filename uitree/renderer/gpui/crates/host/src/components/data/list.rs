//! `list` and `virtual-list`: GPUI Kit's `List` with a delegate that reads
//! the node's `items` file (the select format) and stamps the `row`
//! template, if there is one, per visible item.
//!
//! Group headers (`# name`) become list sections with a header; a `-`
//! separator starts a section with none.

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, ClickEvent, Context, Entity, IntoElement,
    ParentElement, Styled, Subscription, Task, Window, div, px,
};
use gpui_component::{
    ActiveTheme as _, IndexPath, h_flex,
    list::{List, ListDelegate, ListEvent, ListItem, ListState},
};
use crate::data_lines::Item;

use super::{Watch, id_set, item_values, lines, no_verbs, spec, stamp};
use crate::{Component, ComponentRegistry, NodeView, RenderCx};

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(ListComp { ty: "list" });
    reg.add(ListComp { ty: "virtual-list" });
}

struct Section {
    header: Option<String>,
    /// Indexes into `items`.
    rows: Vec<usize>,
}

pub(crate) struct ListData {
    node: NodeView,
    items: Vec<Item>,
    fields: Vec<String>,
    sections: Vec<Section>,
    query: String,
    /// The selection as mirrored to `value`.
    pub(crate) selected: Vec<String>,
    multiple: bool,
    selectable: bool,
    loading: bool,
    item_size: Option<f32>,
    /// Item count when `scrolled_to_end` was last sent, so it goes once per page.
    asked_at: Option<usize>,
    w_items: Watch,
    w_fields: Watch,
    w_value: Watch,
}

impl ListData {
    fn new(node: &NodeView) -> Self {
        ListData {
            node: node.clone(),
            items: Vec::new(),
            fields: Vec::new(),
            sections: Vec::new(),
            query: String::new(),
            selected: Vec::new(),
            multiple: false,
            selectable: false,
            loading: false,
            item_size: None,
            asked_at: None,
            w_items: Watch::default(),
            w_fields: Watch::default(),
            w_value: Watch::default(),
        }
    }

    fn rebuild(&mut self) {
        let q = self.query.to_lowercase();
        let mut secs = vec![Section {
            header: None,
            rows: vec![],
        }];
        for (i, it) in self.items.iter().enumerate() {
            match it {
                Item::Group(g) => secs.push(Section {
                    header: Some(g.clone()),
                    rows: vec![],
                }),
                Item::Separator => secs.push(Section {
                    header: None,
                    rows: vec![],
                }),
                Item::Entry(e) => {
                    let hit = q.is_empty()
                        || e.label.to_lowercase().contains(&q)
                        || e.id.to_lowercase().contains(&q)
                        || e.fields.iter().any(|f| f.to_lowercase().contains(&q));
                    if hit {
                        secs.last_mut().unwrap().rows.push(i);
                    }
                }
            }
        }
        // Kit needs at least one section; it skips empty ones.
        self.sections = secs;
    }

    fn entry(&self, ix: IndexPath) -> Option<&crate::data_lines::Entry> {
        let i = *self.sections.get(ix.section)?.rows.get(ix.row)?;
        self.items.get(i)?.entry()
    }

    fn index_of(&self, id: &str) -> Option<IndexPath> {
        for (s, sec) in self.sections.iter().enumerate() {
            for (r, i) in sec.rows.iter().enumerate() {
                if self.items[*i].entry().is_some_and(|e| e.id == id) {
                    return Some(IndexPath::new(r).section(s));
                }
            }
        }
        None
    }

    fn set_selection(&mut self, ids: Vec<String>) {
        if ids == self.selected {
            return;
        }
        self.selected = ids;
        let v = self.selected.join(" ");
        let em = self.node.emitter();
        em.mirror("value", v.clone().into_bytes());
        em.event("select", &[("value", &v)]);
    }
}

impl ListDelegate for ListData {
    type Item = ListItem;

    fn perform_search(
        &mut self,
        query: &str,
        _: &mut Window,
        _: &mut Context<ListState<Self>>,
    ) -> Task<()> {
        if query != self.query {
            self.query = query.to_string();
            self.rebuild();
            self.node
                .emitter()
                .mirror("query", query.as_bytes().to_vec());
        }
        Task::ready(())
    }

    fn sections_count(&self, _: &App) -> usize {
        self.sections.len().max(1)
    }

    fn items_count(&self, section: usize, _: &App) -> usize {
        self.sections.get(section).map_or(0, |s| s.rows.len())
    }

    fn render_section_header(
        &mut self,
        section: usize,
        _: &mut Window,
        cx: &mut Context<ListState<Self>>,
    ) -> Option<impl IntoElement> {
        let h = self.sections.get(section)?.header.clone()?;
        Some(
            h_flex()
                .px_3()
                .py_1()
                .text_xs()
                .text_color(cx.theme().muted_foreground)
                .child(h),
        )
    }

    fn render_item(
        &mut self,
        ix: IndexPath,
        window: &mut Window,
        cx: &mut Context<ListState<Self>>,
    ) -> Option<ListItem> {
        let e = self.entry(ix)?.clone();
        let id = e.id.clone();
        let em = self.node.emitter();
        let mut item = ListItem::new(("item", ix.section * 1_000_000 + ix.row))
            .disabled(e.disabled)
            .confirmed(self.multiple && self.selected.contains(&id))
            .on_click(move |ev: &ClickEvent, _, _| {
                if ev.click_count() >= 2 {
                    em.event("open", &[("id", &id)]);
                }
            });
        let content: AnyElement = if let Some(t) = self.node.child("row") {
            let vals = item_values(&self.fields, &e);
            let host = self.node.host.clone();
            let mut rcx = RenderCx::new(window, cx, host);
            stamp(&mut rcx, &t, &vals)
        } else {
            let mut row = h_flex().gap_2().items_center();
            if let Some(i) = &e.icon {
                row = row.child(super::icon(i));
            }
            let label = if e.label.is_empty() { e.id.clone() } else { e.label.clone() };
            row.child(label).into_any_element()
        };
        item = match self.item_size {
            Some(h) => item.child(div().h(px(h)).flex().items_center().child(content)),
            None => item.child(content),
        };
        Some(item)
    }

    fn loading(&self, _: &App) -> bool {
        self.loading && self.items.is_empty()
    }

    fn set_selected_index(
        &mut self,
        ix: Option<IndexPath>,
        _: &mut Window,
        _: &mut Context<ListState<Self>>,
    ) {
        if !self.selectable || self.multiple {
            return;
        }
        let ids = ix
            .and_then(|ix| self.entry(ix))
            .filter(|e| !e.disabled)
            .map(|e| vec![e.id.clone()])
            .unwrap_or_default();
        if ix.is_some() && ids.is_empty() {
            return;
        }
        self.set_selection(ids);
    }

    fn confirm(&mut self, _: bool, _: &mut Window, cx: &mut Context<ListState<Self>>) {
        if !self.selectable || !self.multiple {
            return;
        }
        let Some(ix) = cx.entity().read(cx).selected_index() else {
            return;
        };
        let Some(e) = self.entry(ix).filter(|e| !e.disabled) else {
            return;
        };
        let id = e.id.clone();
        let mut ids = self.selected.clone();
        if let Some(p) = ids.iter().position(|x| *x == id) {
            ids.remove(p);
        } else {
            ids.push(id);
        }
        self.set_selection(ids);
    }

    fn has_more(&self, _: &App) -> bool {
        self.has_more_now()
    }

    fn load_more_threshold(&self) -> usize {
        5
    }

    fn load_more(&mut self, _: &mut Window, _: &mut Context<ListState<Self>>) {
        if self.has_more_now() {
            self.asked_at = Some(self.items.len());
            self.node.emitter().event("scrolled_to_end", &[]);
        }
    }
}

impl ListData {
    fn has_more_now(&self) -> bool {
        !self.loading && !self.items.is_empty() && self.asked_at != Some(self.items.len())
    }
}

/// The node's state slot: the Kit list state and its subscription.
pub(crate) struct ListHolder {
    pub(crate) state: Entity<ListState<ListData>>,
    _sub: Subscription,
}

struct ListComp {
    ty: &'static str,
}

impl Component for ListComp {
    fn spec(&self) -> &'static crate::Spec {
        spec(self.ty)
    }

    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let data = ListData::new(node);
        let state = cx.new(|cx| ListState::new(data, window, cx));
        // Kit's own Select/Confirm events are covered by the delegate; a
        // Cancel (Esc) clears a single selection.
        let sub = cx.subscribe(&state, |state, ev: &ListEvent, cx| {
            if let ListEvent::Cancel = ev {
                state.update(cx, |s, _| {
                    let d = s.delegate_mut();
                    if d.selectable && !d.multiple {
                        d.set_selection(vec![]);
                    }
                });
            }
        });
        let holder = cx.new(|_| ListHolder { state, _sub: sub });
        Some(holder.into())
    }

    fn verb(
        &self,
        _: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &crate::Ctl,
        _: &mut Window,
        _: &mut App,
    ) -> crate::VerbResult {
        no_verbs(cmd)
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(holder) = rcx.state::<ListHolder>(node) else {
            return rcx.element(node).into_any_element();
        };
        let state = holder.read(rcx.cx_ref()).state.clone();
        sync(&state, node, self.ty == "virtual-list", rcx);
        let list = List::new(&state).size_full();
        rcx.element(node)
            .flex()
            .flex_col()
            .child(list)
            .into_any_element()
    }
}

/// Brings the Kit state up to date with the node's committed files.
fn sync(state: &Entity<ListState<ListData>>, node: &NodeView, virt: bool, rcx: &mut RenderCx) {
    let searchable = !virt && node.flag("searchable");
    let selectable = node.flag("selectable");
    let (window, cx) = (&mut *rcx.window, &mut *rcx.cx);
    state.update(cx, |s, cx| {
        s.delegate_mut().selectable = selectable;
        s.set_selectable(selectable, cx);
        s.set_searchable(searchable, cx);
        let d = s.delegate_mut();
        d.multiple = node.flag("multiple");
        d.loading = node.flag("loading");
        d.item_size = virt.then(|| super::number(node, "item_size", 32.));
        let mut dirty = false;
        if d.w_items.changed(node, "items") {
            d.items = lines::<Item>(node, "items");
            dirty = true;
        }
        if d.w_fields.changed(node, "fields") {
            d.fields = node
                .text("fields")
                .unwrap_or_default()
                .split(['\t', ' ', '\n'])
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect();
            dirty = true;
        }
        if dirty {
            d.rebuild();
            if d.asked_at.is_some_and(|n| n > d.items.len()) {
                d.asked_at = None;
            }
        }
        let value_changed = d.w_value.changed(node, "value");
        if value_changed {
            d.selected = id_set(&node.text("value").unwrap_or_default());
        }
        if dirty || value_changed {
            let none_selected = d.selected.is_empty();
            let want = if d.multiple {
                None
            } else {
                d.selected.first().and_then(|id| d.index_of(id))
            };
            // An ID not (yet) in `items` keeps the selection as written.
            if s.selected_index() != want && (want.is_some() || none_selected) {
                s.set_selected_index(want, window, cx);
            }
            cx.notify();
        }
    });
}
