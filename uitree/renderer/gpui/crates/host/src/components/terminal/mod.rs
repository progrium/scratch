//! `terminal` (profile `desktop`, components.md § New in this spec): a VT
//! screen as a node.
//!
//! The core owns the screen (libghostty-vt, or the `plain` stand-in): it
//! parses the program's output, keeps scrollback and selection, and
//! encodes keys and mouse. This renderer only draws cells and sends
//! structured input, through ABI 9 (uitcore.h § Terminal nodes):
//!
//! - **Cells.** [`Grid`] keeps a copy of the viewport, as runs per row,
//!   with the style table and the cursor. A pump's `UitChanges.terms`
//!   marks rows dirty ([`changed`]); the next frame re-reads only those
//!   rows and reshapes only those lines.
//! - **Size.** [`element::TerminalElement`] measures a cell from the
//!   theme's mono font, fits a grid to its layout box, and calls
//!   `uit_term_resize` when the grid or the cell changes.
//! - **Keys.** A keystroke that is text (no modifier but shift, a
//!   printable `key_char`) goes to the program with `uit_term_text`, unless
//!   an app binding takes it first; anything else (enter, arrows, ctrl-c,
//!   alt-x) bubbles to the window, whose `uit_key` reaches the focused
//!   terminal and is encoded by the core under the program's modes. IME
//!   commits come through the input handler as `uit_term_text` too, and the
//!   composition in progress is drawn at the cursor.
//! - **Mouse.** Presses, releases and moves over the grid go to
//!   `uit_term_mouse` by cell; the wheel to `uit_term_scroll` in lines.
//!   The core decides whether they reach the program or select.
//! - **Copy and paste.** The copy keystroke (cmd-c on macOS, ctrl-shift-c)
//!   goes to the core through `uit_key` like any other: with text selected
//!   it puts the selection on the clipboard, which comes back as the
//!   clipboard host command. Paste (cmd-v, ctrl-shift-v, shift-insert) is
//!   this renderer's: it reads the platform clipboard and sends the text
//!   with `uit_term_paste`, which brackets it when the program asked.
//!
//! The painter ([`element`]) is a hand port of gpui-ghostty's
//! `TerminalTextElement` (Apache-2.0, github.com/Xuanwo/gpui-ghostty,
//! `crates/gpui_ghostty_terminal/src/view/mod.rs`) to gpui-pre 0.3.12 and
//! uitree's run-based rows: background quads per run, shaped text forced to
//! the cell width, box-drawing characters as quads, then the cursor.

mod element;
mod grid;
#[cfg(test)]
mod tests;

use std::rc::{Rc, Weak};

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, Bounds, Context, EntityInputHandler,
    InteractiveElement, IntoElement, KeyBinding, KeyDownEvent, Modifiers, MouseButton, MouseDownEvent, MouseMoveEvent,
    MouseUpEvent, ParentElement, Pixels, ScrollDelta, ScrollEvent, Styled, UTF16Selection, Window, actions, div,
};
use uitcore::{Node, TermChange, TermMouse, sys};

use crate::runtime::Inner;
use crate::*;

pub(crate) use grid::{Cells, Grid};

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(Terminal);
}

/// The key context of a terminal, so its bindings win over GPUI Kit's
/// `Root` (which takes tab and shift-tab for focus moves).
const KEY_CONTEXT: &str = "UitreeTerminal";

actions!(uitree_terminal, [SendTab, SendBackTab, Paste]);

fn ensure_key_bindings(cx: &mut App) {
    struct Bound;
    impl gpui::Global for Bound {}
    if cx.has_global::<Bound>() {
        return;
    }
    cx.set_global(Bound);
    cx.bind_keys([
        KeyBinding::new("tab", SendTab, Some(KEY_CONTEXT)),
        KeyBinding::new("shift-tab", SendBackTab, Some(KEY_CONTEXT)),
        KeyBinding::new("cmd-v", Paste, Some(KEY_CONTEXT)),
        KeyBinding::new("ctrl-shift-v", Paste, Some(KEY_CONTEXT)),
        KeyBinding::new("shift-insert", Paste, Some(KEY_CONTEXT)),
    ]);
}

/// A terminal node's renderer state: the viewport copy, the size last
/// sent to the core, and the IME composition.
pub struct TermState {
    pub(crate) node: Node,
    pub(crate) win: String,
    pub(crate) host: Weak<Inner>,
    pub(crate) grid: Grid,
    /// `(cols, rows, cell_w_px, cell_h_px)` as last given to `uit_term_resize`.
    pub(crate) sent_size: Option<(u32, u32, u32, u32)>,
    /// The grid's box and cell size from the last paint, for the mouse
    /// and the IME.
    pub(crate) bounds: Option<Bounds<Pixels>>,
    pub(crate) cell: (Pixels, Pixels),
    /// The IME composition in progress (`replace_and_mark_text_in_range`).
    pub(crate) marked: Option<String>,
    /// The cell the pointer was last reported at, so moves inside one cell
    /// aren't sent again.
    pub(crate) last_move: Option<(u32, u32, u32)>,
    /// Wheel pixels not yet worth a line.
    pub(crate) wheel_rest: f32,
    /// A stand-in for the core's cells (tests, and a renderer with no
    /// terminal support in its core yet).
    pub(crate) fake: Option<Box<dyn Cells>>,
    /// Shaped rows from earlier frames.
    pub(crate) shapes: element::ShapeCache,
}

impl TermState {
    fn new(node: &NodeView) -> TermState {
        TermState {
            node: node.node(),
            win: node.win().to_string(),
            host: Rc::downgrade(&node.host),
            grid: Grid::default(),
            sent_size: None,
            bounds: None,
            cell: (gpui::px(0.), gpui::px(0.)),
            marked: None,
            last_move: None,
            wheel_rest: 0.,
            fake: None,
            shapes: Default::default(),
        }
    }

    /// Runs `f` with the core, if it isn't borrowed (it never is during a
    /// frame or a listener, only inside a pump).
    fn with_core<R>(&self, f: impl FnOnce(&uitcore::Core) -> R) -> Option<R> {
        let host = self.host.upgrade()?;
        let core = host.core.try_borrow().ok()?;
        let r = f(&core);
        core.wake();
        Some(r)
    }

    /// Committed text for the program.
    pub(crate) fn send_text(&self, text: &str) {
        if text.is_empty() {
            return;
        }
        let n = self.node;
        self.with_core(|c| {
            if let Err(e) = c.term_text(n, text) {
                note_unsupported("term_text", &e);
            }
        });
    }

    /// A paste from the platform clipboard.
    pub(crate) fn paste(&self, text: &str) {
        if text.is_empty() {
            return;
        }
        let n = self.node;
        self.with_core(|c| {
            if let Err(e) = c.term_paste(n, text) {
                note_unsupported("term_paste", &e);
            }
        });
    }

    /// A keystroke through `uit_key`, with this terminal focused.
    fn send_key(&self, stroke: &str) {
        let (n, win) = (self.node, self.win.clone());
        self.with_core(|c| c.key(&win, stroke, n));
    }

    /// The viewport cell under a window-space point, clamped to the grid.
    pub(crate) fn cell_at(&self, p: gpui::Point<Pixels>) -> Option<(u32, u32)> {
        let b = self.bounds?;
        let (cw, ch) = self.cell;
        if cw <= gpui::px(0.) || ch <= gpui::px(0.) {
            return None;
        }
        let (cols, rows) = self.grid.size();
        let x = ((p.x - b.origin.x) / cw).floor().max(0.) as u32;
        let y = ((p.y - b.origin.y) / ch).floor().max(0.) as u32;
        Some((x.min(cols.saturating_sub(1)), y.min(rows.saturating_sub(1))))
    }

    fn mouse(&mut self, action: u32, button: u32, p: gpui::Point<Pixels>, mods: &Modifiers, clicks: usize) {
        let Some((col, row)) = self.cell_at(p) else { return };
        if action == sys::UIT_TERM_MOVE {
            if self.last_move == Some((col, row, button)) {
                return;
            }
            self.last_move = Some((col, row, button));
        }
        let m = TermMouse { action, button, col, row, mods: term_mods(mods), clicks: clicks.clamp(1, 3) as u32 };
        let n = self.node;
        self.with_core(|c| {
            if let Err(e) = c.term_mouse(n, &m) {
                note_unsupported("term_mouse", &e);
            }
        });
    }

    fn wheel(&mut self, delta: ScrollDelta) {
        // GPUI's wheel is positive toward the top (history); the ABI's
        // lines are negative into history.
        let lines = match delta {
            ScrollDelta::Lines(p) => p.y,
            ScrollDelta::Pixels(p) => {
                let ch = f32::from(self.cell.1).max(1.);
                self.wheel_rest += f32::from(p.y) / ch;
                let whole = self.wheel_rest.trunc();
                self.wheel_rest -= whole;
                whole
            }
        };
        let lines = -(lines.round() as i32);
        if lines == 0 {
            return;
        }
        let n = self.node;
        self.with_core(|c| {
            if let Err(e) = c.term_scroll(n, lines) {
                note_unsupported("term_scroll", &e);
            }
        });
    }
}

/// ABI 9 calls answer UIT_ENOTSUP until the core wires terminals in (T3):
/// say so once, not per keystroke.
fn note_unsupported(what: &str, e: &uitcore::Error) {
    use std::sync::atomic::{AtomicBool, Ordering};
    static SAID: AtomicBool = AtomicBool::new(false);
    if e.code == sys::UIT_ENOTSUP {
        if !SAID.swap(true, Ordering::Relaxed) {
            eprintln!("uitree: terminal: this core has no terminal engine yet ({what})");
        }
    } else {
        eprintln!("uitree: terminal: {what}: {e}");
    }
}

fn term_mods(m: &Modifiers) -> u32 {
    let mut v = 0;
    if m.shift {
        v |= sys::UIT_TERM_MOD_SHIFT;
    }
    if m.alt {
        v |= sys::UIT_TERM_MOD_ALT;
    }
    if m.control {
        v |= sys::UIT_TERM_MOD_CTRL;
    }
    if m.platform {
        v |= sys::UIT_TERM_MOD_SUPER;
    }
    v
}

fn term_button(b: MouseButton) -> u32 {
    match b {
        MouseButton::Left => sys::UIT_TERM_BUTTON_LEFT,
        MouseButton::Middle => sys::UIT_TERM_BUTTON_MIDDLE,
        MouseButton::Right => sys::UIT_TERM_BUTTON_RIGHT,
        _ => sys::UIT_TERM_BUTTON_NONE,
    }
}

/// The text a keystroke types, if it is text: no modifier but shift, and
/// a `key_char` with no control characters (enter, tab, escape and
/// backspace are keys, which the core encodes).
pub(crate) fn typed_text(k: &gpui::Keystroke) -> Option<&str> {
    if !k.modifiers.is_subset_of(&Modifiers::shift()) {
        return None;
    }
    let t = k.key_char.as_deref()?;
    (!t.is_empty() && !t.chars().any(char::is_control)).then_some(t)
}

/// A pump's `UitChanges.terms`: mark what to re-read, and redraw.
pub(crate) fn changed(inner: &Rc<Inner>, terms: &[TermChange], cx: &mut App) {
    for t in terms {
        let Some(ent) = inner.states.borrow().get(&t.node).and_then(|s| s.entity.clone()) else { continue };
        let Ok(ent) = ent.downcast::<TermState>() else { continue };
        ent.update(cx, |s, cx| {
            s.grid.mark(t);
            cx.notify();
        });
        if let Some(v) = inner.view(t.node) {
            crate::runtime::notify_window(inner, v.win(), cx);
        }
    }
}

struct Terminal;

impl Component for Terminal {
    fn spec(&self) -> &'static Spec {
        spec::must("terminal")
    }

    fn create(&self, node: &NodeView, _window: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        ensure_key_bindings(cx);
        Some(cx.new(|_| TermState::new(node)).into_any())
    }

    fn verb(&self, _: &NodeView, state: Option<&AnyEntity>, cmd: &Ctl, _: &mut Window, cx: &mut App) -> VerbResult {
        // The core runs every terminal verb itself (write, paste, reset,
        // scroll); a redraw follows through UitChanges.terms.
        let _ = (state, cmd, cx);
        Err(Unhandled)
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        // Fills what it's given by default; style words override (a
        // `bg=` shows where cells have no background of their own).
        let base = div().flex().flex_col().flex_1().w_full().min_h(gpui::px(0.)).overflow_hidden();
        let el = rcx.element_except(node, base, &[]);
        let Some(ent) = rcx.state::<TermState>(node) else { return el.into_any_element() };
        let focus = rcx.focus_handle(node);

        let e = ent.clone();
        let fh = focus.clone();
        let on_down = move |ev: &MouseDownEvent, window: &mut Window, cx: &mut App| {
            fh.focus(window, cx);
            e.update(cx, |s, _| {
                s.mouse(sys::UIT_TERM_PRESS, term_button(ev.button), ev.position, &ev.modifiers, ev.click_count)
            });
        };
        let e = ent.clone();
        let on_up = move |ev: &MouseUpEvent, _: &mut Window, cx: &mut App| {
            e.update(cx, |s, _| {
                s.mouse(sys::UIT_TERM_RELEASE, term_button(ev.button), ev.position, &ev.modifiers, ev.click_count)
            });
        };
        let e = ent.clone();
        let on_move = move |ev: &MouseMoveEvent, _: &mut Window, cx: &mut App| {
            let b = ev.pressed_button.map(term_button).unwrap_or(sys::UIT_TERM_BUTTON_NONE);
            e.update(cx, |s, _| {
                if s.bounds.is_some_and(|bb| bb.contains(&ev.position)) || b != sys::UIT_TERM_BUTTON_NONE {
                    s.mouse(sys::UIT_TERM_MOVE, b, ev.position, &ev.modifiers, 1)
                }
            });
        };
        let e = ent.clone();
        let on_wheel = move |ev: &ScrollEvent, _: &mut Window, cx: &mut App| {
            e.update(cx, |s, _| s.wheel(ev.delta));
            cx.stop_propagation();
        };
        let e = ent.clone();
        let win = node.win().to_string();
        let on_key = move |ev: &KeyDownEvent, _: &mut Window, cx: &mut App| {
            let Some(text) = typed_text(&ev.keystroke) else { return };
            // The app's bindings first; then the text is the program's.
            // Either way the window mustn't also encode it as a key.
            cx.stop_propagation();
            let s = e.read(cx);
            let ks = crate::window::keystroke(&ev.keystroke);
            let bound = s.with_core(|c| c.key(&win, &ks, 0)).unwrap_or(false);
            if !bound {
                s.send_text(text);
            }
        };
        let e1 = ent.clone();
        let e2 = ent.clone();
        let e3 = ent.clone();

        let inner = element::TerminalElement::new(ent, focus.clone());
        el.track_focus(&focus)
            .key_context(KEY_CONTEXT)
            .on_action(move |_: &SendTab, _, cx| e1.read(cx).send_key("tab"))
            .on_action(move |_: &SendBackTab, _, cx| e2.read(cx).send_key("shift-tab"))
            .on_action(move |_: &Paste, _, cx| {
                let text = cx.read_from_clipboard().and_then(|i| i.text()).unwrap_or_default();
                e3.read(cx).paste(&text);
            })
            .on_key_down(on_key)
            .on_mouse_down(MouseButton::Left, on_down.clone())
            .on_mouse_down(MouseButton::Middle, on_down.clone())
            .on_mouse_down(MouseButton::Right, on_down)
            .on_mouse_up(MouseButton::Left, on_up.clone())
            .on_mouse_up(MouseButton::Middle, on_up.clone())
            .on_mouse_up(MouseButton::Right, on_up)
            .on_mouse_move(on_move)
            .on_scroll(on_wheel)
            .cursor(gpui::CursorStyle::IBeam)
            .child(inner)
            .into_any_element()
    }
}

/// The IME: commits become `uit_term_text`; a composition is kept to draw
/// at the cursor. The terminal has no editable text of its own, so ranges
/// are relative to the composition.
impl EntityInputHandler for TermState {
    fn text_for_range(
        &mut self,
        range: std::ops::Range<usize>,
        adjusted: &mut Option<std::ops::Range<usize>>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<String> {
        let m = self.marked.as_deref().unwrap_or("");
        let u: Vec<u16> = m.encode_utf16().collect();
        let r = range.start.min(u.len())..range.end.min(u.len());
        *adjusted = Some(r.clone());
        Some(String::from_utf16_lossy(&u[r]))
    }

    fn selected_text_range(&mut self, _: bool, _: &mut Window, _: &mut Context<Self>) -> Option<UTF16Selection> {
        let n = self.marked.as_deref().map(|m| m.encode_utf16().count()).unwrap_or(0);
        Some(UTF16Selection { range: n..n, reversed: false })
    }

    fn marked_text_range(&self, _: &mut Window, _: &mut Context<Self>) -> Option<std::ops::Range<usize>> {
        self.marked.as_deref().map(|m| 0..m.encode_utf16().count())
    }

    fn unmark_text(&mut self, _: &mut Window, cx: &mut Context<Self>) {
        self.marked = None;
        cx.notify();
    }

    fn replace_text_in_range(&mut self, _: Option<std::ops::Range<usize>>, text: &str, _: &mut Window, cx: &mut Context<Self>) {
        self.marked = None;
        self.send_text(text);
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        _: Option<std::ops::Range<usize>>,
        text: &str,
        _: Option<std::ops::Range<usize>>,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.marked = (!text.is_empty()).then(|| text.to_string());
        cx.notify();
    }

    fn bounds_for_range(
        &mut self,
        _: std::ops::Range<usize>,
        element_bounds: Bounds<Pixels>,
        _: &mut Window,
        _: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        // The cursor's cell: where the IME puts its candidate window.
        let (cw, ch) = self.cell;
        let c = self.grid.cursor();
        let origin = element_bounds.origin + gpui::point(cw * c.x as f32, ch * c.y as f32);
        Some(Bounds::new(origin, gpui::size(cw, ch)))
    }

    fn character_index_for_point(&mut self, _: gpui::Point<Pixels>, _: &mut Window, _: &mut Context<Self>) -> Option<usize> {
        None
    }
}
