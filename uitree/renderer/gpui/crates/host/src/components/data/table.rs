//! `table`: GPUI Kit's `TableState` with a delegate that reads `columns`
//! and the TSV `rows` (first field is the row ID). Sorting is the client's
//! unless `sorted=on`; either way the user's choice goes out as a `sort`
//! event and into the `sort` file.

use std::cmp::Ordering;
use std::collections::HashMap;

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, Context, Entity, IntoElement, ParentElement,
    Styled, Subscription, Window, div, px,
};
use gpui_component::table::{
    Column as KitColumn, ColumnSort, DataTable, TableDelegate, TableEvent, TableState,
};
use gpui_component::Sizable as _;
use crate::data_lines::{Align, Column, Row};

use super::{Watch, kit_size, lines, no_verbs, spec};
use crate::{Component, ComponentRegistry, NodeView, RenderCx};

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(TableComp);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Row,
    Cell,
    Off,
}

/// The flags a `TableState` is built with; a change rebuilds it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Flags {
    mode: Mode,
    sortable: bool,
    resizable: bool,
}

fn flags(node: &NodeView) -> Flags {
    Flags {
        mode: match node.text("selectable").as_deref().map(str::trim) {
            Some("cell") => Mode::Cell,
            Some("off") => Mode::Off,
            _ => Mode::Row,
        },
        sortable: node.flag("sortable"),
        resizable: node.flag("resizable"),
    }
}

pub(crate) struct TableData {
    node: NodeView,
    flags: Flags,
    pub(crate) columns: Vec<Column>,
    pub(crate) rows: Vec<Row>,
    /// Display order: indexes into `rows`.
    pub(crate) order: Vec<usize>,
    /// The user's (or the client's) sort: column ID and ascending.
    sort: Option<(String, bool)>,
    sorted: bool,
    loading: bool,
    /// Widths after a user resize, by column ID.
    widths: HashMap<String, f32>,
    /// The selection as mirrored to `value`.
    value: String,
    asked_at: Option<usize>,
    w_columns: Watch,
    w_rows: Watch,
    w_value: Watch,
    w_sort: Watch,
    w_widths: Watch,
}

impl TableData {
    fn new(node: &NodeView, flags: Flags) -> Self {
        TableData {
            node: node.clone(),
            flags,
            columns: vec![],
            rows: vec![],
            order: vec![],
            sort: None,
            sorted: false,
            loading: false,
            widths: HashMap::new(),
            value: String::new(),
            asked_at: None,
            w_columns: Watch::default(),
            w_rows: Watch::default(),
            w_value: Watch::default(),
            w_sort: Watch::default(),
            w_widths: Watch::default(),
        }
    }

    fn reorder(&mut self) {
        self.order = (0..self.rows.len()).collect();
        let Some((col, asc)) = self.sort.clone().filter(|_| self.sorted) else {
            return;
        };
        let Some(ci) = self.columns.iter().position(|c| c.id == col) else {
            return;
        };
        let rows = &self.rows;
        let cell = |r: usize| rows[r].cells.get(ci).map(|s| s.as_str()).unwrap_or("");
        self.order.sort_by(|a, b| {
            let o = compare(cell(*a), cell(*b));
            if asc { o } else { o.reverse() }
        });
    }

    fn row_id(&self, ix: usize) -> Option<&str> {
        self.order
            .get(ix)
            .and_then(|r| self.rows.get(*r))
            .map(|r| r.id.as_str())
    }

    fn row_ix(&self, id: &str) -> Option<usize> {
        self.order.iter().position(|r| self.rows[*r].id == id)
    }

    fn col_id(&self, ix: usize) -> &str {
        self.columns.get(ix).map(|c| c.id.as_str()).unwrap_or("")
    }

    fn width_of(&self, c: &Column) -> f32 {
        self.widths
            .get(&c.id)
            .copied()
            .or(c.width)
            .unwrap_or(120.)
    }
}

/// Numbers compare as numbers, everything else as text, case folded.
fn compare(a: &str, b: &str) -> Ordering {
    let num = |s: &str| s.trim().replace(',', "").parse::<f64>().ok();
    match (num(a), num(b)) {
        (Some(x), Some(y)) => x.partial_cmp(&y).unwrap_or(Ordering::Equal),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        _ => a.to_lowercase().cmp(&b.to_lowercase()).then_with(|| a.cmp(b)),
    }
}

impl TableDelegate for TableData {
    fn columns_count(&self, _: &App) -> usize {
        self.columns.len()
    }

    fn rows_count(&self, _: &App) -> usize {
        self.order.len()
    }

    fn column(&self, ix: usize, _: &App) -> KitColumn {
        let c = &self.columns[ix];
        let mut k = KitColumn::new(c.id.clone(), c.label.clone())
            .width(px(self.width_of(c)))
            .resizable(self.flags.resizable)
            .movable(false);
        if self.flags.sortable && c.sort {
            k = match &self.sort {
                Some((id, true)) if *id == c.id => k.ascending(),
                Some((id, false)) if *id == c.id => k.descending(),
                _ => k.sortable(),
            };
        }
        k = match c.align {
            Some(Align::Right) => k.text_right(),
            Some(Align::Center) => k.text_center(),
            _ => k,
        };
        if c.fixed {
            k = k.fixed_left();
        }
        k
    }

    fn perform_sort(
        &mut self,
        col_ix: usize,
        sort: ColumnSort,
        _: &mut Window,
        cx: &mut Context<TableState<Self>>,
    ) {
        let col = self.col_id(col_ix).to_string();
        let dir = match sort {
            ColumnSort::Ascending => "asc",
            ColumnSort::Descending => "desc",
            ColumnSort::Default => "none",
        };
        self.sort = match sort {
            ColumnSort::Ascending => Some((col.clone(), true)),
            ColumnSort::Descending => Some((col.clone(), false)),
            ColumnSort::Default => None,
        };
        let file = self
            .sort
            .as_ref()
            .map(|(c, a)| format!("{c} {}", if *a { "asc" } else { "desc" }))
            .unwrap_or_default();
        let em = self.node.emitter();
        em.mirror("sort", file.into_bytes());
        em.event("sort", &[("col", &col), ("dir", dir)]);
        if self.sorted {
            self.reorder();
        }
        cx.notify();
    }

    fn render_td(
        &mut self,
        row_ix: usize,
        col_ix: usize,
        _: &mut Window,
        _: &mut Context<TableState<Self>>,
    ) -> impl IntoElement {
        let text = self
            .order
            .get(row_ix)
            .and_then(|r| self.rows.get(*r))
            .and_then(|r| r.cells.get(col_ix))
            .cloned()
            .unwrap_or_default();
        div().overflow_hidden().text_ellipsis().whitespace_nowrap().child(text)
    }

    fn cell_text(&self, row_ix: usize, col_ix: usize, _: &App) -> String {
        self.order
            .get(row_ix)
            .and_then(|r| self.rows.get(*r))
            .and_then(|r| r.cells.get(col_ix))
            .cloned()
            .unwrap_or_default()
    }

    fn loading(&self, _: &App) -> bool {
        self.loading && self.rows.is_empty()
    }

    fn has_more(&self, _: &App) -> bool {
        !self.loading && !self.rows.is_empty() && self.asked_at != Some(self.rows.len())
    }

    fn load_more_threshold(&self) -> usize {
        5
    }

    fn load_more(&mut self, _: &mut Window, _: &mut Context<TableState<Self>>) {
        if !self.loading && !self.rows.is_empty() && self.asked_at != Some(self.rows.len()) {
            self.asked_at = Some(self.rows.len());
            self.node.emitter().event("scrolled_to_end", &[]);
        }
    }
}

pub(crate) struct TableHolder {
    pub(crate) state: Entity<TableState<TableData>>,
    _sub: Subscription,
}

fn build(node: &NodeView, f: Flags, window: &mut Window, cx: &mut App) -> TableHolder {
    let data = TableData::new(node, f);
    let state = cx.new(|cx| {
        TableState::new(data, window, cx)
            .row_selectable(f.mode == Mode::Row)
            .cell_selectable(f.mode == Mode::Cell)
            .col_selectable(false)
            .col_movable(false)
            .col_resizable(f.resizable)
            .sortable(f.sortable)
    });
    let sub = cx.subscribe(&state, on_event);
    TableHolder { state, _sub: sub }
}

fn on_event(state: Entity<TableState<TableData>>, ev: &TableEvent, cx: &mut App) {
    let d = state.read(cx).delegate();
    let em = d.node.emitter();
    let (row, col) = match ev {
        TableEvent::SelectRow(r) => (d.row_id(*r).map(str::to_string), None),
        TableEvent::SelectCell(r, c) => (d.row_id(*r).map(str::to_string), Some(d.col_id(*c).to_string())),
        TableEvent::ClearSelection => (Some(String::new()), None),
        TableEvent::DoubleClickedRow(r) => {
            if let Some(id) = d.row_id(*r) {
                em.event("open", &[("row", id)]);
            }
            return;
        }
        TableEvent::DoubleClickedCell(r, c) => {
            if let Some(id) = d.row_id(*r) {
                em.event("open", &[("row", id), ("col", d.col_id(*c))]);
            }
            return;
        }
        TableEvent::ColumnWidthsChanged(ws) => {
            let ws: Vec<(String, f32)> = d
                .columns
                .iter()
                .zip(ws.iter())
                .map(|(c, w)| (c.id.clone(), f32::from(*w)))
                .collect();
            let changed: Vec<(String, f32)> = ws
                .iter()
                .filter(|(id, w)| {
                    let c = d.columns.iter().find(|c| c.id == *id).unwrap();
                    (d.width_of(c) - w).abs() > 0.5
                })
                .cloned()
                .collect();
            if changed.is_empty() {
                return;
            }
            let file: String = ws.iter().map(|(id, w)| format!("{id} {}\n", w.round())).collect();
            for (id, w) in &changed {
                em.event("resize", &[("col", id), ("width", &format!("{}", w.round()))]);
            }
            em.mirror("widths", file.into_bytes());
            state.update(cx, |s, _| {
                let d = s.delegate_mut();
                for (id, w) in ws {
                    d.widths.insert(id, w);
                }
            });
            return;
        }
        _ => return,
    };
    let Some(row) = row else { return };
    let value = match &col {
        Some(c) if !row.is_empty() => format!("{row} {c}"),
        _ => row.clone(),
    };
    if value == d.value {
        return;
    }
    let mut attrs = vec![("row", row.as_str())];
    if let Some(c) = &col {
        attrs.push(("col", c.as_str()));
    }
    em.event("select", &attrs);
    em.mirror("value", value.clone().into_bytes());
    state.update(cx, |s, _| s.delegate_mut().value = value);
}

struct TableComp;

impl Component for TableComp {
    fn spec(&self) -> &'static crate::Spec {
        spec("table")
    }

    fn create(&self, node: &NodeView, window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        let h = build(node, flags(node), window, cx);
        Some(cx.new(|_| h).into())
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
        let Some(holder) = rcx.state::<TableHolder>(node) else {
            return rcx.element(node).into_any_element();
        };
        let f = flags(node);
        let built = holder.read(rcx.cx_ref()).state.read(rcx.cx_ref()).delegate().flags;
        if built != f {
            let (window, cx) = (&mut *rcx.window, &mut *rcx.cx);
            let h = build(node, f, window, cx);
            holder.update(cx, |old, _| *old = h);
        }
        let state = holder.read(rcx.cx_ref()).state.clone();
        sync(&state, node, rcx);
        let st = rcx.style_of(node);
        let mut table = DataTable::new(&state)
            .stripe(node.flag("stripe"))
            .bordered(node.flag("bordered"));
        if let Some(s) = kit_size(&st) {
            table = table.with_size(s);
        }
        rcx.element(node)
            .flex()
            .flex_col()
            .child(div().size_full().child(table))
            .into_any_element()
    }
}

fn parse_sort(s: &str) -> Option<(String, bool)> {
    let mut w = s.split_whitespace();
    let col = w.next()?.to_string();
    let asc = !matches!(w.next(), Some("desc"));
    Some((col, asc))
}

fn parse_widths(s: &str) -> HashMap<String, f32> {
    s.lines()
        .filter_map(|l| {
            let mut w = l.split_whitespace();
            Some((w.next()?.to_string(), w.next()?.parse().ok()?))
        })
        .collect()
}

fn sync(state: &Entity<TableState<TableData>>, node: &NodeView, rcx: &mut RenderCx) {
    let cx = &mut *rcx.cx;
    state.update(cx, |s, cx| {
        let d = s.delegate_mut();
        d.loading = node.flag("loading");
        let sorted = node.flag("sorted");
        let mut cols_dirty = false;
        let mut rows_dirty = sorted != d.sorted;
        d.sorted = sorted;
        if d.w_columns.changed(node, "columns") {
            d.columns = lines::<Column>(node, "columns");
            cols_dirty = true;
            rows_dirty = true;
        }
        if d.w_rows.changed(node, "rows") {
            d.rows = lines::<Row>(node, "rows");
            if d.asked_at.is_some_and(|n| n > d.rows.len()) {
                d.asked_at = None;
            }
            rows_dirty = true;
        }
        if d.w_sort.changed(node, "sort") {
            let s = parse_sort(&node.text("sort").unwrap_or_default());
            if s != d.sort {
                d.sort = s;
                cols_dirty = true;
                rows_dirty = true;
            }
        }
        if d.w_widths.changed(node, "widths") {
            let w = parse_widths(&node.text("widths").unwrap_or_default());
            if w != d.widths {
                d.widths = w;
                cols_dirty = true;
            }
        }
        if rows_dirty {
            d.reorder();
        }
        let value_changed = d.w_value.changed(node, "value");
        if value_changed {
            d.value = node.text("value").unwrap_or_default().trim().to_string();
        }
        let want = {
            let mut w = d.value.split_whitespace();
            let r = w.next().and_then(|id| d.row_ix(id));
            let c = w
                .next()
                .and_then(|c| d.columns.iter().position(|x| x.id == c));
            (r, c, d.flags.mode)
        };
        if cols_dirty {
            s.refresh(cx);
        }
        if value_changed || rows_dirty {
            match want {
                (Some(r), Some(c), Mode::Cell) => {
                    if s.selected_cell() != Some((r, c)) {
                        s.set_selected_cell(r, c, cx)
                    }
                }
                (Some(r), _, Mode::Row) => {
                    if s.selected_row() != Some(r) {
                        s.set_selected_row(r, cx)
                    }
                }
                (None, _, _) if value_changed => s.clear_selection(cx),
                _ => {}
            }
        }
        if value_changed || rows_dirty || cols_dirty {
            cx.notify();
        }
    });
}
