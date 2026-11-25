//! `terminal` on GPUI's test platform, and its grid on its own.
//!
//! Until the core wires terminals in (T3), ABI 9 answers UIT_ENOTSUP, so
//! these feed the painter from [`Fake`] cells, as the `plain` engine
//! would lay them out.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gpui::TestAppContext;
use uitcore::{TermChange, TermCursor, TermRow, TermRun, TermStyle, sys};

use super::grid::{self, Cells, Grid};
use super::{TermState, typed_text};
use crate::testing::Harness;

#[derive(Clone, Default)]
struct Fake {
    rows: Rc<RefCell<Vec<TermRow>>>,
    styles: Vec<TermStyle>,
    cursor: TermCursor,
    /// Rows handed out, total.
    reads: Rc<Cell<usize>>,
}

impl Cells for Fake {
    fn rows(&self, first: u32, n: u32) -> Vec<TermRow> {
        let v: Vec<TermRow> = self.rows.borrow().iter().filter(|r| r.y >= first && r.y < first + n).cloned().collect();
        self.reads.set(self.reads.get() + v.len());
        v
    }
    fn styles(&self) -> Vec<TermStyle> {
        self.styles.clone()
    }
    fn cursor(&self) -> Option<TermCursor> {
        Some(self.cursor)
    }
}

fn run(col: u32, style: u32, text: &str) -> TermRun {
    let width = text.chars().map(|c| unicode_width::UnicodeWidthChar::width(c).unwrap_or(0) as u32).sum();
    TermRun { col, width, style, selected: false, text: text.into() }
}

fn screen() -> Fake {
    let red = TermStyle { fg: 0xcc3333ff, ..Default::default() };
    let inv = TermStyle { flags: sys::UIT_TERM_INVERSE | sys::UIT_TERM_BOLD, ..Default::default() };
    let rows = vec![
        TermRow { y: 0, runs: vec![run(0, 0, "$ ls --color"), run(13, 1, "red")] },
        TermRow { y: 1, runs: vec![run(0, 2, "selected"), TermRun { selected: true, ..run(9, 0, "sel") }] },
        TermRow { y: 2, runs: vec![run(0, 0, "┌──┐ 日本 é")] },
    ];
    Fake {
        rows: Rc::new(RefCell::new(rows)),
        styles: vec![TermStyle::default(), red, inv],
        cursor: TermCursor { x: 2, y: 0, shape: sys::UIT_TERM_CURSOR_BLOCK, visible: 1, blink: 1, cols: 0, rows: 0 },
        reads: Rc::new(Cell::new(0)),
    }
}

#[test]
fn pieces_fill_gaps_and_split_wide_characters() {
    let (p, boxes) = grid::pieces(&[run(0, 0, "ab"), run(4, 1, "cd")]);
    assert_eq!(p.len(), 1);
    assert_eq!(p[0].text, "ab  cd");
    assert_eq!(p[0].spans, vec![(4, 0), (2, 1)]);
    assert!(boxes.is_empty());

    let (p, _) = grid::pieces(&[run(0, 0, "a日b")]);
    let got: Vec<_> = p.iter().map(|p| (p.col, p.text.as_str(), p.wide)).collect();
    assert_eq!(got, vec![(0, "a", false), (1, "日", true), (3, "b", false)]);
}

#[test]
fn pieces_draw_box_characters_as_quads_and_drop_trailing_blanks() {
    let (p, boxes) = grid::pieces(&[run(0, 3, "┌─┐"), run(3, 0, "   ")]);
    assert_eq!(boxes.iter().map(|b| (b.col, b.ch, b.style)).collect::<Vec<_>>(), vec![(0, '┌', 3), (1, '─', 3), (2, '┐', 3)]);
    // The box cells are blanks in their own style; the default-style tail is gone.
    assert_eq!(p.len(), 1);
    assert_eq!(p[0].text, "   ");
    assert_eq!(p[0].spans, vec![(3, 3)]);

    let (p, _) = grid::pieces(&[run(0, 0, "e\u{301}x")]);
    assert_eq!(p[0].text, "e\u{301}x");
    assert_eq!(p[0].spans, vec![("e\u{301}x".len(), 0)]);
}

#[test]
fn grid_rereads_only_dirty_rows() {
    let f = screen();
    let mut g = Grid::default();
    g.fit(20, 3);
    let changed = g.sync(&f);
    assert_eq!(changed, vec![0, 1, 2]);
    assert_eq!(f.reads.get(), 3);
    assert!(!g.is_dirty());

    // One row changes: only it is read again.
    f.rows.borrow_mut()[1].runs = vec![run(0, 0, "new")];
    g.mark(&TermChange { node: 1, what: sys::UIT_TERM_ROWS | sys::UIT_TERM_CURSOR, rows: vec![1] });
    let rev0 = g.lines[0].rev;
    assert_eq!(g.sync(&f), vec![1]);
    assert_eq!(f.reads.get(), 4);
    assert_eq!(g.lines[1].runs[0].text, "new");
    assert_eq!(g.lines[0].rev, rev0, "row 0 keeps its shapes");

    // A row the core no longer returns is blank.
    f.rows.borrow_mut().retain(|r| r.y != 2);
    g.mark(&TermChange { node: 1, what: sys::UIT_TERM_ROWS, rows: vec![2] });
    assert_eq!(g.sync(&f), vec![2]);
    assert!(g.lines[2].runs.is_empty());

    // ALL re-reads everything.
    g.mark(&TermChange { node: 1, what: sys::UIT_TERM_ALL, rows: vec![] });
    g.sync(&f);
    assert_eq!(f.reads.get(), 4 + 2);
}

#[test]
fn grid_size_follows_the_core_once_it_has_one() {
    let mut f = screen();
    let mut g = Grid::default();
    g.fit(80, 24);
    g.sync(&f);
    assert_eq!(g.size(), (80, 24));
    assert_eq!(g.lines.len(), 24);
    f.cursor.cols = 40;
    f.cursor.rows = 10;
    g.mark(&TermChange { node: 1, what: sys::UIT_TERM_SIZE, rows: vec![] });
    g.sync(&f);
    assert_eq!(g.size(), (40, 10));
    assert_eq!(g.lines.len(), 10);
    assert_eq!(g.char_at(14, 0), Some(('e', 1)));
    assert_eq!(g.char_at(5, 2), Some(('日', 0)));
    assert_eq!(g.char_at(6, 2), Some(('日', 0)));
    assert_eq!(g.char_at(7, 2), Some(('本', 0)));
}

#[test]
fn text_keys_are_text_and_the_rest_are_keys() {
    let k = |s: &'static str| gpui::Keystroke::parse(s).unwrap();
    let mut a = k("a");
    a.key_char = Some("a".into());
    assert_eq!(typed_text(&a), Some("a"));
    let mut bang = k("shift-1");
    bang.key_char = Some("!".into());
    assert_eq!(typed_text(&bang), Some("!"));
    let mut ctrl_c = k("ctrl-c");
    ctrl_c.key_char = Some("c".into());
    assert_eq!(typed_text(&ctrl_c), None);
    let mut enter = k("enter");
    enter.key_char = Some("\n".into());
    assert_eq!(typed_text(&enter), None);
    assert_eq!(typed_text(&k("up")), None);
}

const R: &str = "win/main";

fn window(cx: &mut TestAppContext) -> Harness {
    let mut h = Harness::new(cx);
    h.ctl("", "window main title=Test size=640,480");
    h.ctl("win/main", "show");
    h.write(&format!("{R}/style"), "v-flex size-full");
    h
}

fn state(h: &Harness, path: &str) -> gpui::Entity<TermState> {
    let n = h.node(path);
    let ent = n.host.states.borrow().get(&n.node()).and_then(|s| s.entity.clone()).expect("terminal state");
    ent.downcast::<TermState>().ok().expect("TermState")
}

#[gpui::test]
fn terminal_fills_its_parent_and_fits_a_grid(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new terminal sh");
    let t = format!("{R}/sh");
    let [_, _, w, hh] = h.bounds(&t);
    assert!((w - 640.).abs() < 1. && (hh - 480.).abs() < 1., "{w}x{hh}");
    assert_eq!(h.read(&format!("{t}/type")).unwrap().trim(), "terminal");
    let ent = state(&h, &t);
    let (size, cell) = h.cx.update(|cx| {
        let s = ent.read(cx);
        (s.sent_size, s.cell)
    });
    let (cols, rows, cw, ch) = size.expect("a size was sent");
    assert!(cell.0 > gpui::px(0.) && cell.1 > gpui::px(0.));
    assert_eq!(cols, (640. / f32::from(cell.0)).floor() as u32, "{size:?} {cell:?}");
    assert_eq!(rows, (480. / f32::from(cell.1)).floor() as u32, "{size:?} {cell:?}");
    assert!(cw > 0 && ch > 0);
}

#[gpui::test]
fn terminal_paints_cells_and_reshapes_only_dirty_rows(cx: &mut TestAppContext) {
    let mut h = window(cx);
    h.ctl(R, "new terminal sh");
    let t = format!("{R}/sh");
    let ent = state(&h, &t);
    let f = screen();
    h.cx.update(|cx| {
        ent.update(cx, |s, cx| {
            s.fake = Some(Box::new(f.clone()));
            s.grid.mark_all();
            cx.notify();
        })
    });
    h.settle();
    let reads = f.reads.get();
    assert_eq!(reads, 3, "every row read once");
    let (rev, shaped, cursor) = h.cx.update(|cx| {
        let s = ent.read(cx);
        (s.grid.lines[0].rev, s.shapes.len(), s.grid.cursor())
    });
    assert!(shaped >= 3, "{shaped}");
    assert_eq!((cursor.x, cursor.y), (2, 0));

    // A pump that marks row 1 re-reads that row only.
    f.rows.borrow_mut()[1].runs = vec![run(0, 1, "changed")];
    h.cx.update(|cx| {
        ent.update(cx, |s, cx| {
            s.grid.mark(&TermChange { node: s.node, what: sys::UIT_TERM_ROWS, rows: vec![1] });
            cx.notify();
        })
    });
    h.settle();
    assert_eq!(f.reads.get(), reads + 1);
    h.cx.update(|cx| assert_eq!(ent.read(cx).grid.lines[0].rev, rev));
}

#[gpui::test]
fn ime_commit_and_composition(cx: &mut TestAppContext) {
    use gpui::EntityInputHandler as _;
    let mut h = window(cx);
    h.ctl(R, "new terminal sh");
    let ent = state(&h, &format!("{R}/sh"));
    let win = h.window("main");
    let _ = h.cx.update(|cx| win.update(cx, |_, window, cx| {
        ent.update(cx, |s, cx| {
            s.replace_and_mark_text_in_range(None, "にほ", None, window, cx);
            assert_eq!(s.marked_text_range(window, cx), Some(0..2));
            // The core has no terminal engine yet: the commit is dropped
            // there, but the composition ends.
            s.replace_text_in_range(None, "日本", window, cx);
            assert_eq!(s.marked, None);
        })
    }));
}
