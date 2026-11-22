//! `chart`: GPUI Kit's line, bar, area and pie charts over `data`, TSV with
//! a header row. `x` names the label column and `y` the value column (the
//! first of several names; the rest are ignored by this version). A click
//! sends `select x=<label>` for the point or band under the pointer.

use gpui::{
    AnyElement, AnyEntity, App, ClickEvent, Hsla, IntoElement, ParentElement, SharedString,
    StatefulInteractiveElement as _, Window,
};
use gpui_component::{
    ActiveTheme as _,
    chart::{AreaChart, BarChart, LineChart, PieChart},
};

use super::{no_verbs, spec, with_file};
use crate::{Component, ComponentRegistry, NodeView, RenderCx};

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(ChartComp);
}

#[derive(Clone)]
pub(crate) struct Point {
    pub(crate) x: SharedString,
    pub(crate) y: f64,
    color: Hsla,
}

/// The `(x, y)` pairs of `data`. Columns are found by header name; with no
/// `x`/`y`, the first and second columns. Rows whose value isn't a number
/// are skipped.
pub(crate) fn points(data: &str, x: &str, y: &str) -> Vec<(String, f64)> {
    let mut lines = data.lines().filter(|l| !l.trim().is_empty());
    let Some(head) = lines.next() else {
        return vec![];
    };
    let head: Vec<&str> = head.split('\t').map(str::trim).collect();
    let find = |n: &str, d: usize| {
        if n.is_empty() {
            Some(d)
        } else {
            head.iter().position(|h| *h == n)
        }
    };
    let (Some(xi), Some(yi)) = (find(x, 0), find(y, 1)) else {
        return vec![];
    };
    lines
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            let v = f.get(yi)?.trim().replace(',', "").parse::<f64>().ok()?;
            Some((f.get(xi).copied().unwrap_or("").trim().to_string(), v))
        })
        .collect()
}

struct ChartComp;

impl Component for ChartComp {
    fn spec(&self) -> &'static catalog::TypeSpec {
        spec("chart")
    }

    fn verb(
        &self,
        _: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &proto::Command,
        _: &mut Window,
        _: &mut App,
    ) -> Result<(), proto::Error> {
        no_verbs(cmd)
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let x = node.text("x").unwrap_or_default();
        let y = node.text("y").unwrap_or_default();
        let y = y.split_whitespace().next().unwrap_or("");
        let pts = with_file(node, "data", |s| points(s, x.trim(), y));
        let theme = rcx.cx_ref().theme();
        let palette = [
            theme.chart_1,
            theme.chart_2,
            theme.chart_3,
            theme.chart_4,
            theme.chart_5,
        ];
        let stroke = rcx.style_of(node).base.text.color.unwrap_or(theme.chart_1);
        let data: Vec<Point> = pts
            .iter()
            .enumerate()
            .map(|(i, (x, y))| Point {
                x: x.clone().into(),
                y: *y,
                color: palette[i % palette.len()],
            })
            .collect();
        let labels: Vec<String> = pts.iter().map(|(x, _)| x.clone()).collect();
        let kind = node.text("kind").unwrap_or_else(|| "line".into());
        let id = |k: &str| gpui::ElementId::Name(format!("{}#{k}", node.path()).into());
        let chart: AnyElement = match kind.trim() {
            "bar" => BarChart::new(data)
                .id(id("bar"))
                .band(|p: &Point| p.x.clone())
                .value(|p: &Point| p.y)
                .into_any_element(),
            "area" => AreaChart::new(data)
                .id(id("area"))
                .x(|p: &Point| p.x.clone())
                .y(|p: &Point| p.y)
                .stroke(stroke)
                .into_any_element(),
            "pie" => PieChart::new(data)
                .id(id("pie"))
                .value(|p: &Point| p.y as f32)
                .color(|p: &Point| p.color)
                .into_any_element(),
            _ => LineChart::new(data)
                .id(id("line"))
                .x(|p: &Point| p.x.clone())
                .y(|p: &Point| p.y)
                .stroke(stroke)
                .into_any_element(),
        };
        let em = node.emitter();
        let n = node.clone();
        let pie = kind.trim() == "pie";
        rcx.element(node)
            .child(chart)
            .on_click(move |ev: &ClickEvent, _, _| {
                if pie || labels.is_empty() {
                    return;
                }
                // Points and bands are spread evenly across the plot.
                let Some([bx, _, bw, _]) = super::bounds(&n) else {
                    return;
                };
                if bw <= 0. {
                    return;
                }
                let px = f32::from(ev.position().x) - bx;
                let i = ((px / bw) * labels.len() as f32).floor().max(0.) as usize;
                let i = i.min(labels.len() - 1);
                em.event("select", &[("x", &labels[i])]);
            })
            .into_any_element()
    }
}
