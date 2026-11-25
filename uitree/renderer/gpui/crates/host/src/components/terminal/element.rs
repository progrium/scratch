//! The painter: a hand port of gpui-ghostty's `TerminalTextElement` to
//! gpui-pre 0.3.12 and uitree's run-based rows.
//!
//! Prepaint measures a cell, fits the grid to the box (and tells the core),
//! re-reads dirty rows and reshapes only those; paint draws, in order, run
//! backgrounds, the selection, text, box-drawing quads, the IME
//! composition and the cursor.

use std::collections::HashMap;

use gpui::{
    App, Bounds, Element, ElementId, ElementInputHandler, Entity, FocusHandle, Font, FontStyle, FontWeight,
    GlobalElementId, Hsla, InspectorElementId, IntoElement, LayoutId, PaintQuad, Pixels, ShapedLine, SharedString,
    StrikethroughStyle, Style, TextAlign, TextRun, UnderlineStyle, Window, fill, outline, point, px, relative, size,
};
use gpui_component::ActiveTheme as _;
use uitcore::{TermStyle, sys};

use super::TermState;
use super::grid::{self, BOX_DOWN, BOX_LEFT, BOX_RIGHT, BOX_UP, BoxCell, CoreCells, Piece};

pub(crate) struct TerminalElement {
    state: Entity<TermState>,
    focus: FocusHandle,
}

impl TerminalElement {
    pub(crate) fn new(state: Entity<TermState>, focus: FocusHandle) -> TerminalElement {
        TerminalElement { state, focus }
    }
}

impl IntoElement for TerminalElement {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}

/// The colors and font a frame draws with.
#[derive(Clone, PartialEq)]
pub(crate) struct Look {
    pub font: Font,
    pub font_size: Pixels,
    pub fg: Hsla,
    pub bg: Hsla,
    pub selection: Hsla,
    pub cursor: Hsla,
}

impl Look {
    fn from_theme(cx: &App) -> Look {
        let t = cx.theme();
        let mut font = gpui::font(t.mono_font_family.clone());
        // No ligatures or kerning: one glyph per cell.
        font.features = gpui::FontFeatures(std::sync::Arc::new(vec![
            ("calt".to_string(), 0),
            ("liga".to_string(), 0),
            ("kern".to_string(), 0),
        ]));
        Look {
            font,
            font_size: t.mono_font_size,
            fg: t.foreground,
            bg: t.background,
            selection: t.selection,
            cursor: t.caret,
        }
    }
}

/// One cell's size: the advance of `M` in the mono font, and a line
/// height from the font's ascent and descent.
pub(crate) fn cell_size(look: &Look, window: &Window) -> (Pixels, Pixels) {
    let ts = window.text_system();
    let id = ts.resolve_font(&look.font);
    let w = ts.advance(id, look.font_size, 'M').map(|s| s.width).unwrap_or(look.font_size * 0.6);
    let a = ts.ascent(id, look.font_size);
    let d = ts.descent(id, look.font_size);
    let h = (f32::from(a) + f32::from(d).abs()).max(f32::from(look.font_size) * 1.15).ceil();
    (w.max(px(1.)), px(h.max(1.)))
}

/// Shaped rows, kept across frames on the node's state, keyed by the
/// line's revision and the look.
#[derive(Default)]
pub(crate) struct ShapeCache {
    look: Option<(Look, Pixels)>,
    rows: HashMap<usize, (u64, RowShapes)>,
}

impl ShapeCache {
    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.rows.len()
    }
}

#[derive(Clone)]
pub(crate) struct RowShapes {
    pieces: Vec<(u32, ShapedLine)>,
    boxes: Vec<BoxCell>,
}

pub(crate) struct Prepaint {
    cell: (Pixels, Pixels),
    rows: Vec<RowShapes>,
    quads_under: Vec<PaintQuad>,
    quads_over: Vec<PaintQuad>,
    cursor: Vec<PaintQuad>,
    cursor_glyph: Option<(gpui::Point<Pixels>, ShapedLine)>,
    marked: Option<(gpui::Point<Pixels>, ShapedLine, PaintQuad)>,
}

fn rgba(c: u32) -> Hsla {
    gpui::rgba(c).into()
}

/// A style's colors, defaults filled in and inverse applied.
fn colors(st: &TermStyle, look: &Look) -> (Hsla, Option<Hsla>) {
    let mut fg = if st.fg == 0 { look.fg } else { rgba(st.fg) };
    let mut bg = (st.bg != 0).then(|| rgba(st.bg));
    if st.flags & sys::UIT_TERM_INVERSE != 0 {
        let b = bg.unwrap_or(look.bg);
        bg = Some(fg);
        fg = b;
    }
    if st.flags & sys::UIT_TERM_FAINT != 0 {
        fg = fg.opacity(0.6);
    }
    (fg, bg)
}

fn text_run(st: &TermStyle, look: &Look, len: usize) -> TextRun {
    let (fg, _) = colors(st, look);
    let mut font = look.font.clone();
    if st.flags & sys::UIT_TERM_BOLD != 0 {
        font.weight = FontWeight::BOLD;
    }
    if st.flags & sys::UIT_TERM_ITALIC != 0 {
        font.style = FontStyle::Italic;
    }
    let color = if st.flags & sys::UIT_TERM_INVISIBLE != 0 { gpui::transparent_black() } else { fg };
    let ucolor = if st.underline_color != 0 { rgba(st.underline_color) } else { color };
    let underline = match st.underline {
        sys::UIT_TERM_UNDERLINE_NONE => None,
        sys::UIT_TERM_UNDERLINE_DOUBLE => Some(UnderlineStyle { thickness: px(2.), color: Some(ucolor), wavy: false }),
        sys::UIT_TERM_UNDERLINE_CURLY => Some(UnderlineStyle { thickness: px(1.), color: Some(ucolor), wavy: true }),
        _ => Some(UnderlineStyle { thickness: px(1.), color: Some(ucolor), wavy: false }),
    };
    let strikethrough = (st.flags & sys::UIT_TERM_STRIKE != 0).then_some(StrikethroughStyle { thickness: px(1.), color: Some(color) });
    TextRun { len, font, color, background_color: None, underline, strikethrough }
}

fn shape_piece(p: &Piece, styles: &dyn Fn(u32) -> TermStyle, look: &Look, cw: Pixels, window: &Window) -> ShapedLine {
    let runs: Vec<TextRun> = p.spans.iter().map(|(len, id)| text_run(&styles(*id), look, *len)).collect();
    let force = (!p.wide).then_some(cw);
    window.text_system().shape_line(SharedString::from(p.text.clone()), look.font_size, &runs, force)
}

/// gpui-ghostty's `box_drawing_quads_for_char`: a bar from the cell's
/// center toward each arm.
fn box_quads(b: Bounds<Pixels>, color: Hsla, ch: char, out: &mut Vec<PaintQuad>) {
    let Some((mask, weight)) = grid::grid_box_mask(ch) else { return };
    let (x0, y0) = (b.left(), b.top());
    let (x1, y1) = (b.right(), b.bottom());
    let mid_x = x0 + b.size.width * 0.5;
    let mid_y = y0 + b.size.height * 0.5;
    let t = px(((f32::from(b.size.height) / 12.0).max(1.0) * weight).max(1.0).round());
    let half = t * 0.5;
    let (l, r, u, d) = (mask & BOX_LEFT != 0, mask & BOX_RIGHT != 0, mask & BOX_UP != 0, mask & BOX_DOWN != 0);
    if l || r {
        let (sx, ex) = if l && r { (x0, x1) } else if l { (x0, mid_x + half) } else { (mid_x - half, x1) };
        out.push(fill(Bounds::from_corners(point(sx, mid_y - half), point(ex, mid_y + half)), color));
    }
    if u || d {
        let (sy, ey) = if u && d { (y0, y1) } else if u { (y0, mid_y + half) } else { (mid_y - half, y1) };
        out.push(fill(Bounds::from_corners(point(mid_x - half, sy), point(mid_x + half, ey)), color));
    }
}

impl Element for TerminalElement {
    type RequestLayoutState = ();
    type PrepaintState = Prepaint;

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }

    fn request_layout(&mut self, _: Option<&GlobalElementId>, _: Option<&InspectorElementId>, window: &mut Window, cx: &mut App) -> (LayoutId, ()) {
        let mut style = Style::default();
        style.size.width = relative(1.).into();
        style.size.height = relative(1.).into();
        style.flex_grow = 1.;
        (window.request_layout(style, [], cx), ())
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) -> Prepaint {
        let look = Look::from_theme(cx);
        let (cw, ch) = cell_size(&look, window);
        let cols = ((bounds.size.width / cw).floor() as u32).max(1);
        let rows = ((bounds.size.height / ch).floor() as u32).max(1);
        let scale = window.scale_factor();
        let size_px = (cols, rows, (f32::from(cw) * scale).round() as u32, (f32::from(ch) * scale).round() as u32);
        let focused = self.focus.is_focused(window);

        // Fit, tell the core, and re-read what changed.
        self.state.update(cx, |s, _| {
            s.bounds = Some(Bounds::new(bounds.origin, size(cw * cols as f32, ch * rows as f32)));
            s.cell = (cw, ch);
            s.grid.fit(cols, rows);
            if s.sent_size != Some(size_px) {
                s.sent_size = Some(size_px);
                let n = s.node;
                s.with_core(|c| {
                    if let Err(e) = c.term_resize(n, size_px.0, size_px.1, size_px.2, size_px.3) {
                        super::note_unsupported("term_resize", &e);
                    }
                });
            }
            if !s.grid.is_dirty() {
                return;
            }
            if let Some(f) = s.fake.take() {
                s.grid.sync(f.as_ref());
                s.fake = Some(f);
                return;
            }
            let Some(host) = s.host.upgrade() else { return };
            let Ok(core) = host.core.try_borrow() else { return };
            s.grid.sync(&CoreCells { core: &core, node: s.node });
        });

        let mut cache = self.state.update(cx, |s, _| std::mem::take(&mut s.shapes));
        let s = self.state.read(cx);
        let grid = &s.grid;
        let styles = |id: u32| grid.style(id);

        // Shape the lines whose revision moved (all of them when the look did).
        let rows_shaped: Vec<RowShapes> = {
            let c = &mut cache;
            let key = (look.clone(), cw);
            if c.look.as_ref() != Some(&key) {
                c.rows.clear();
                c.look = Some(key);
            }
            c.rows.retain(|i, _| *i < grid.lines.len());
            grid.lines
                .iter()
                .enumerate()
                .map(|(i, line)| {
                    if let Some((rev, shapes)) = c.rows.get(&i)
                        && *rev == line.rev
                    {
                        return shapes.clone();
                    }
                    let (pieces, boxes) = grid::pieces(&line.runs);
                    let shapes = RowShapes {
                        pieces: pieces.iter().map(|p| (p.col, shape_piece(p, &styles, &look, cw, window))).collect(),
                        boxes,
                    };
                    c.rows.insert(i, (line.rev, shapes.clone()));
                    shapes
                })
                .collect()
        };

        let origin = bounds.origin;
        let cell = |col: u32, row: u32, w: u32| Bounds::new(point(origin.x + cw * col as f32, origin.y + ch * row as f32), size(cw * w as f32, ch));

        // Backgrounds and the selection, per run.
        let mut under = Vec::new();
        for (y, line) in grid.lines.iter().enumerate() {
            for run in &line.runs {
                let (_, bg) = colors(&styles(run.style), &look);
                if let Some(bg) = bg {
                    under.push(fill(cell(run.col, y as u32, run.width), bg));
                }
                if run.selected {
                    under.push(fill(cell(run.col, y as u32, run.width), look.selection));
                }
            }
        }

        // Box drawing and overlines, over the text.
        let mut over = Vec::new();
        for (y, r) in rows_shaped.iter().enumerate() {
            for b in &r.boxes {
                let (fg, _) = colors(&styles(b.style), &look);
                box_quads(cell(b.col, y as u32, 1), fg, b.ch, &mut over);
            }
        }
        for (y, line) in grid.lines.iter().enumerate() {
            for run in &line.runs {
                let st = styles(run.style);
                if st.flags & sys::UIT_TERM_OVERLINE != 0 {
                    let (fg, _) = colors(&st, &look);
                    let b = cell(run.col, y as u32, run.width);
                    over.push(fill(Bounds::new(b.origin, size(b.size.width, px(1.))), fg));
                }
            }
        }

        // The IME composition, at the cursor, over its cells.
        let cur = grid.cursor();
        let marked = s.marked.as_ref().filter(|m| !m.is_empty()).map(|m| {
            let at = point(origin.x + cw * cur.x as f32, origin.y + ch * cur.y as f32);
            let run = TextRun {
                len: m.len(),
                font: look.font.clone(),
                color: look.fg,
                background_color: None,
                underline: Some(UnderlineStyle { thickness: px(1.), color: Some(look.fg), wavy: false }),
                strikethrough: None,
            };
            let line = window.text_system().shape_line(SharedString::from(m.clone()), look.font_size, &[run], None);
            let w = line.width.max(cw);
            (at, line, fill(Bounds::new(at, size(w, ch)), look.bg))
        });

        // The cursor: a block with its cell's character in the background
        // color when focused, a hollow block when not; bar and underline as
        // the program asked.
        let mut cursor = Vec::new();
        let mut cursor_glyph = None;
        let (cols_now, rows_now) = grid.size();
        if cur.visible != 0 && cur.x < cols_now && cur.y < rows_now && marked.is_none() {
            let (gch, gstyle) = grid.char_at(cur.x, cur.y).map(|(c, s)| (Some(c), s)).unwrap_or((None, 0));
            let wide = gch.and_then(|c| unicode_width::UnicodeWidthChar::width(c)).unwrap_or(1).max(1) as u32;
            let b = cell(cur.x, cur.y, wide);
            let color = look.cursor;
            match (cur.shape, focused) {
                (sys::UIT_TERM_CURSOR_BAR, _) => cursor.push(fill(Bounds::new(b.origin, size(px(2.), ch)), color)),
                (sys::UIT_TERM_CURSOR_UNDERLINE, _) => {
                    cursor.push(fill(Bounds::new(point(b.left(), b.bottom() - px(2.)), size(b.size.width, px(2.))), color))
                }
                (sys::UIT_TERM_CURSOR_BLOCK, true) => {
                    cursor.push(fill(b, color));
                    if let Some(c) = gch.filter(|c| !c.is_whitespace()) {
                        let mut st = styles(gstyle);
                        st.flags &= !(sys::UIT_TERM_INVERSE | sys::UIT_TERM_INVISIBLE);
                        let mut run = text_run(&st, &look, c.len_utf8());
                        run.color = look.bg;
                        let line = window.text_system().shape_line(SharedString::from(c.to_string()), look.font_size, &[run], (wide == 1).then_some(cw));
                        cursor_glyph = Some((b.origin, line));
                    }
                }
                _ => cursor.push(outline(b, color, gpui::BorderStyle::Solid)),
            }
        }

        self.state.update(cx, |s, _| s.shapes = cache);
        Prepaint {
            cell: (cw, ch),
            rows: rows_shaped,
            quads_under: under,
            quads_over: over,
            cursor,
            cursor_glyph,
            marked,
        }
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        pp: &mut Prepaint,
        window: &mut Window,
        cx: &mut App,
    ) {
        window.handle_input(&self.focus, ElementInputHandler::new(bounds, self.state.clone()), cx);
        let (cw, ch) = pp.cell;
        window.paint_layer(bounds, |window| {
            for q in pp.quads_under.drain(..) {
                window.paint_quad(q);
            }
            for (y, r) in pp.rows.iter().enumerate() {
                let top = bounds.top() + ch * y as f32;
                for (col, line) in &r.pieces {
                    let _ = line.paint(point(bounds.left() + cw * *col as f32, top), ch, TextAlign::Left, None, window, cx);
                }
            }
            for q in pp.quads_over.drain(..) {
                window.paint_quad(q);
            }
            if let Some((at, line, bg)) = pp.marked.take() {
                window.paint_quad(bg);
                let _ = line.paint(at, ch, TextAlign::Left, None, window, cx);
            }
            for q in pp.cursor.drain(..) {
                window.paint_quad(q);
            }
            if let Some((at, line)) = pp.cursor_glyph.take() {
                let _ = line.paint(at, ch, TextAlign::Left, None, window, cx);
            }
        });
    }
}
