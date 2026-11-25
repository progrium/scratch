//! The renderer's copy of a terminal's viewport: rows as runs, the style
//! table and the cursor, re-read from the core only where a pump said
//! they changed. No GPUI here, so it tests on its own.

use std::collections::BTreeSet;

use unicode_width::UnicodeWidthChar as _;
use uitcore::{Node, TermChange, TermCursor, TermRow, TermRun, TermStyle, sys};

/// Where cells come from: the core through ABI 9, or a stand-in.
pub(crate) trait Cells {
    /// Viewport rows `first .. first+n`, clipped to the grid.
    fn rows(&self, first: u32, n: u32) -> Vec<TermRow>;
    fn styles(&self) -> Vec<TermStyle>;
    fn cursor(&self) -> Option<TermCursor>;
}

/// The core's cells. A core without terminals (UIT_ENOTSUP, before T3)
/// reads as an empty screen.
pub(crate) struct CoreCells<'a> {
    pub core: &'a uitcore::Core,
    pub node: Node,
}

impl Cells for CoreCells<'_> {
    fn rows(&self, first: u32, n: u32) -> Vec<TermRow> {
        self.core.term_rows(self.node, first, n).unwrap_or_default()
    }
    fn styles(&self) -> Vec<TermStyle> {
        self.core.term_styles(self.node).map(<[_]>::to_vec).unwrap_or_default()
    }
    fn cursor(&self) -> Option<TermCursor> {
        self.core.term_cursor(self.node).ok()
    }
}

/// Which rows to re-read at the next frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Dirty {
    None,
    Rows(BTreeSet<u32>),
    All,
}

/// One viewport row: its runs, and whether its shaped text is stale.
#[derive(Debug, Clone, Default)]
pub(crate) struct Line {
    pub runs: Vec<TermRun>,
    /// Bumped each time the runs change; the painter's shape cache keys on it.
    pub rev: u64,
}

#[derive(Debug)]
pub(crate) struct Grid {
    pub lines: Vec<Line>,
    pub styles: Vec<TermStyle>,
    cursor: TermCursor,
    /// The size the renderer fitted to its box (until the core says otherwise).
    cols: u32,
    rows: u32,
    dirty: Dirty,
    styles_dirty: bool,
    cursor_dirty: bool,
    rev: u64,
}

impl Default for Grid {
    fn default() -> Grid {
        // A new node reads everything (uitcore.h: a renderer that just
        // learned of a terminal reads styles, every row, the cursor).
        Grid {
            lines: Vec::new(),
            styles: Vec::new(),
            cursor: TermCursor::default(),
            cols: 0,
            rows: 0,
            dirty: Dirty::All,
            styles_dirty: true,
            cursor_dirty: true,
            rev: 0,
        }
    }
}

impl Grid {
    /// The grid's size: the core's, once it has one, else the fitted one.
    pub fn size(&self) -> (u32, u32) {
        if self.cursor.cols > 0 && self.cursor.rows > 0 { (self.cursor.cols, self.cursor.rows) } else { (self.cols, self.rows) }
    }

    pub fn cursor(&self) -> TermCursor {
        self.cursor
    }

    pub fn is_dirty(&self) -> bool {
        self.dirty != Dirty::None || self.styles_dirty || self.cursor_dirty
    }

    /// The renderer fitted a new grid to its box. Everything is re-read:
    /// the core reflows on resize.
    pub fn fit(&mut self, cols: u32, rows: u32) {
        if (cols, rows) != (self.cols, self.rows) {
            self.cols = cols;
            self.rows = rows;
            self.mark_all();
        }
    }

    pub fn mark_all(&mut self) {
        self.dirty = Dirty::All;
        self.styles_dirty = true;
        self.cursor_dirty = true;
    }

    /// What a pump said changed.
    pub fn mark(&mut self, t: &TermChange) {
        if t.all() || t.what & sys::UIT_TERM_SIZE != 0 {
            self.dirty = Dirty::All;
        } else if t.what & sys::UIT_TERM_ROWS != 0 {
            match &mut self.dirty {
                Dirty::All => {}
                Dirty::Rows(set) => set.extend(t.rows.iter().copied()),
                d @ Dirty::None => *d = Dirty::Rows(t.rows.iter().copied().collect()),
            }
        }
        if t.what & (sys::UIT_TERM_STYLES | sys::UIT_TERM_STYLES_RESET) != 0 {
            self.styles_dirty = true;
        }
        if t.what & (sys::UIT_TERM_CURSOR | sys::UIT_TERM_SIZE | sys::UIT_TERM_ALL) != 0 {
            self.cursor_dirty = true;
        }
    }

    /// Re-reads what is dirty. Returns the rows whose runs changed.
    pub fn sync(&mut self, src: &dyn Cells) -> Vec<u32> {
        if self.styles_dirty {
            self.styles = src.styles();
            self.styles_dirty = false;
        }
        if self.cursor_dirty {
            if let Some(c) = src.cursor() {
                self.cursor = c;
            }
            self.cursor_dirty = false;
        }
        let (_, rows) = self.size();
        if self.lines.len() != rows as usize {
            self.lines.resize_with(rows as usize, Line::default);
        }
        let mut changed = Vec::new();
        match std::mem::replace(&mut self.dirty, Dirty::None) {
            Dirty::None => {}
            Dirty::All => {
                let got = src.rows(0, rows);
                // Rows the core didn't return are blank.
                let mut seen = vec![false; rows as usize];
                for r in got {
                    if let Some(i) = self.put(r) {
                        seen[i] = true;
                        changed.push(i as u32);
                    }
                }
                for (i, s) in seen.iter().enumerate() {
                    if !s && !self.lines[i].runs.is_empty() {
                        self.rev += 1;
                        self.lines[i] = Line { runs: Vec::new(), rev: self.rev };
                        changed.push(i as u32);
                    }
                }
                changed.sort_unstable();
            }
            Dirty::Rows(set) => {
                // Contiguous rows in one call.
                let ys: Vec<u32> = set.into_iter().filter(|y| *y < rows).collect();
                let mut i = 0;
                while i < ys.len() {
                    let first = ys[i];
                    let mut n = 1;
                    while i + n < ys.len() && ys[i + n] == first + n as u32 {
                        n += 1;
                    }
                    let got = src.rows(first, n as u32);
                    let mut seen = BTreeSet::new();
                    for r in got {
                        if let Some(k) = self.put(r) {
                            seen.insert(k as u32);
                        }
                    }
                    for y in first..first + n as u32 {
                        if !seen.contains(&y) {
                            self.rev += 1;
                            self.lines[y as usize] = Line { runs: Vec::new(), rev: self.rev };
                        }
                        changed.push(y);
                    }
                    i += n;
                }
            }
        }
        changed
    }

    fn put(&mut self, r: TermRow) -> Option<usize> {
        let i = r.y as usize;
        let line = self.lines.get_mut(i)?;
        self.rev += 1;
        *line = Line { runs: r.runs, rev: self.rev };
        Some(i)
    }

    pub fn style(&self, id: u32) -> TermStyle {
        self.styles.get(id as usize).copied().unwrap_or_default()
    }

    /// The character and style id at a cell, for drawing the cursor's cell.
    pub fn char_at(&self, col: u32, row: u32) -> Option<(char, u32)> {
        let line = self.lines.get(row as usize)?;
        for run in &line.runs {
            if col < run.col || col >= run.col + run.width {
                continue;
            }
            let mut c = run.col;
            for ch in run.text.chars() {
                let w = ch.width().unwrap_or(0) as u32;
                if w == 0 {
                    continue;
                }
                if col < c + w {
                    return Some((ch, run.style));
                }
                c += w;
            }
        }
        None
    }
}

/// A piece of a row shaped as one line: text in cell-width glyphs from
/// `col`, with style spans. A wide character is a piece of its own, so the
/// narrow pieces can be forced to the cell width.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Piece {
    pub col: u32,
    pub text: String,
    /// `(byte length, style id)` spans covering `text`.
    pub spans: Vec<(usize, u32)>,
    /// One wide character (two cells), drawn unforced.
    pub wide: bool,
}

/// A box-drawing character, drawn as quads rather than a glyph so lines
/// join across cells whatever the font.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct BoxCell {
    pub col: u32,
    pub ch: char,
    pub style: u32,
}

/// Splits a row's runs into shaped pieces and box-drawing cells. Gaps
/// between runs are spaces in style 0, so a row of narrow text is one
/// piece; box-drawing characters become spaces in the text.
pub(crate) fn pieces(runs: &[TermRun]) -> (Vec<Piece>, Vec<BoxCell>) {
    let mut out: Vec<Piece> = Vec::new();
    let mut boxes = Vec::new();
    let mut cur: Option<Piece> = None;

    fn push(cur: &mut Option<Piece>, col: u32, s: &str, style: u32) {
        let p = cur.get_or_insert_with(|| Piece { col, text: String::new(), spans: Vec::new(), wide: false });
        p.text.push_str(s);
        match p.spans.last_mut() {
            Some((len, st)) if *st == style => *len += s.len(),
            _ => p.spans.push((s.len(), style)),
        }
    }
    fn end(cur: &mut Option<Piece>) -> u32 {
        // The column after the piece.
        cur.as_ref().map(|p| p.col + p.text.chars().filter(|c| c.width().unwrap_or(0) > 0).count() as u32).unwrap_or(0)
    }

    for run in runs {
        // Fill a gap since the last piece with blanks in the default style.
        if let Some(_) = &cur {
            let e = end(&mut cur);
            if run.col > e {
                let gap = " ".repeat((run.col - e) as usize);
                push(&mut cur, e, &gap, 0);
            }
        }
        let mut col = run.col;
        let mut buf = [0u8; 4];
        for ch in run.text.chars() {
            let w = ch.width().unwrap_or(0) as u32;
            if w == 0 {
                // A combining mark rides on the character before it.
                if let Some(p) = cur.as_mut().or(out.last_mut()) {
                    p.text.push(ch);
                    if let Some((len, _)) = p.spans.last_mut() {
                        *len += ch.len_utf8();
                    }
                }
                continue;
            }
            if w > 1 {
                if let Some(p) = cur.take() {
                    out.push(p);
                }
                out.push(Piece { col, text: ch.to_string(), spans: vec![(ch.len_utf8(), run.style)], wide: true });
                col += w;
                continue;
            }
            if grid_box_mask(ch).is_some() {
                boxes.push(BoxCell { col, ch, style: run.style });
                push(&mut cur, col, " ", run.style);
            } else {
                push(&mut cur, col, ch.encode_utf8(&mut buf), run.style);
            }
            col += 1;
        }
    }
    if let Some(p) = cur.take() {
        out.push(p);
    }
    // Trailing blanks in the default style draw nothing.
    for p in &mut out {
        while let Some((len, 0)) = p.spans.last().copied() {
            let t = p.text.trim_end_matches(' ');
            let cut = p.text.len() - t.len();
            if cut == 0 {
                break;
            }
            let cut = cut.min(len);
            p.text.truncate(p.text.len() - cut);
            if cut == len {
                p.spans.pop();
            } else {
                p.spans.last_mut().unwrap().0 -= cut;
                break;
            }
        }
    }
    out.retain(|p| !p.text.is_empty());
    (out, boxes)
}

pub(crate) const BOX_LEFT: u8 = 1;
pub(crate) const BOX_RIGHT: u8 = 2;
pub(crate) const BOX_UP: u8 = 4;
pub(crate) const BOX_DOWN: u8 = 8;

/// The arms of a box-drawing character and its weight (gpui-ghostty's
/// `box_drawing_mask`).
pub(crate) fn grid_box_mask(ch: char) -> Option<(u8, f32)> {
    let mask = match ch {
        '─' | '━' | '═' => BOX_LEFT | BOX_RIGHT,
        '│' | '┃' | '║' => BOX_UP | BOX_DOWN,
        '┌' | '┏' | '╔' | '╭' => BOX_RIGHT | BOX_DOWN,
        '┐' | '┓' | '╗' | '╮' => BOX_LEFT | BOX_DOWN,
        '└' | '┗' | '╚' | '╰' => BOX_RIGHT | BOX_UP,
        '┘' | '┛' | '╝' | '╯' => BOX_LEFT | BOX_UP,
        '├' | '┣' | '╠' => BOX_RIGHT | BOX_UP | BOX_DOWN,
        '┤' | '┫' | '╣' => BOX_LEFT | BOX_UP | BOX_DOWN,
        '┬' | '┳' | '╦' => BOX_LEFT | BOX_RIGHT | BOX_DOWN,
        '┴' | '┻' | '╩' => BOX_LEFT | BOX_RIGHT | BOX_UP,
        '┼' | '╋' | '╬' => BOX_LEFT | BOX_RIGHT | BOX_UP | BOX_DOWN,
        _ => return None,
    };
    let weight = match ch {
        '━' | '┃' | '┏' | '┓' | '┗' | '┛' | '┣' | '┫' | '┳' | '┻' | '╋' => 1.35,
        '═' | '║' | '╔' | '╗' | '╚' | '╝' | '╠' | '╣' | '╦' | '╩' | '╬' => 1.15,
        _ => 1.0,
    };
    Some((mask, weight))
}
