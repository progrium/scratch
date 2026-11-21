//! Client-named actions: the `keymap` file, `menus/`, `set id enabled= check=`.
//!
//! Every client action is one GPUI action type, [`ClientAction`], carrying
//! the id. Bindings from the keymap (and menu `key=`s) dispatch it up the
//! focus path like any GPUI action, so GPUI Kit's built-in bindings still
//! win inside inputs and editors. One global handler turns it into
//! `action id=... win=... focus=...`.

use std::rc::Rc;

use gpui::{Action, App, KeyBinding, Menu, MenuItem, SharedString};
use gpui::{KeyBindingContextPredicate};

use proto::lines::{KeyBinding as KeyLine, MenuKind, MenuLine};
use tree::{EventKind, EventMsg};

use crate::runtime::{Inner, with_window};

/// An action the client named in `keymap` or `menus/`.
#[derive(Clone, PartialEq, Debug, Action)]
#[action(namespace = gpuifs, no_json)]
pub struct ClientAction {
    pub id: SharedString,
}

pub(crate) fn init(inner: &Rc<Inner>, cx: &mut App) {
    let h = inner.clone();
    cx.on_action(move |a: &ClientAction, cx| dispatch(&h, &a.id, cx));
}

/// `action id=` for the active window, with the focused node.
pub(crate) fn dispatch(inner: &Rc<Inner>, id: &str, cx: &mut App) {
    let active = cx.active_window();
    let win = active.and_then(|a| {
        inner
            .windows
            .borrow()
            .iter()
            .find(|(_, e)| e.handle.window_id() == a.window_id())
            .map(|(n, _)| n.clone())
    });
    let focus = win
        .as_deref()
        .and_then(|w| with_window(inner, w, cx, |window, _| inner.focused_path(w, window)).flatten());
    dispatch_in(inner, id, win, focus, cx)
}

/// `action id=` for a window (the one whose root view caught the action).
pub(crate) fn dispatch_in(
    inner: &Rc<Inner>,
    id: &str,
    win: Option<String>,
    focus: Option<String>,
    _cx: &mut App,
) {
    if inner
        .action_state
        .borrow()
        .get(id)
        .is_some_and(|(enabled, _)| !enabled)
    {
        return;
    }
    let mut ev = EventMsg::new(EventKind::Action, "action").attr("id", id);
    if let Some(w) = &win {
        ev = ev.win(w);
        if let Some(f) = focus {
            let rel = f
                .strip_prefix(&format!("windows/{w}/"))
                .unwrap_or(&f)
                .to_string();
            ev = ev.attr("focus", &rel);
        }
    }
    inner.tree.borrow_mut().emit(ev);
}

fn keymap_lines(inner: &Inner) -> Vec<KeyLine> {
    let text = inner
        .tree
        .borrow()
        .root_file("keymap")
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| KeyLine::parse(l).ok())
        .collect()
}

fn menu_lines(inner: &Inner) -> Vec<(String, Vec<MenuLine>)> {
    inner
        .tree
        .borrow()
        .menus()
        .into_iter()
        .map(|(name, b)| {
            let text = String::from_utf8_lossy(&b).into_owned();
            let lines = text
                .lines()
                .filter(|l| !l.trim().is_empty())
                .filter_map(|l| MenuLine::parse(l).ok())
                .collect();
            (name, lines)
        })
        .collect()
}

fn prop<'a>(props: &'a [(String, String)], k: &str) -> Option<&'a str> {
    props.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str())
}

/// Rebuilds the client's key bindings: the `keymap` file, plus each menu
/// item's `key=`. GPUI Kit's own bindings are kept.
pub(crate) fn set_keymap(inner: &Rc<Inner>, cx: &mut App) {
    let keymap = cx.key_bindings();
    if inner.base_bindings.borrow().is_none() {
        let base: Vec<KeyBinding> = keymap
            .borrow()
            .bindings()
            .filter(|b| b.action().as_any().downcast_ref::<ClientAction>().is_none())
            .cloned()
            .collect();
        *inner.base_bindings.borrow_mut() = Some(base);
    }
    let mut bindings: Vec<KeyBinding> = inner.base_bindings.borrow().clone().unwrap_or_default();
    let mut add = |keys: &str, id: &str, context: Option<&str>, cx: &App| {
        let pred = context.and_then(|c| KeyBindingContextPredicate::parse(c).ok().map(Rc::new));
        match KeyBinding::load(
            keys,
            Box::new(ClientAction { id: id.to_string().into() }),
            pred,
            false,
            None,
            cx,
        ) {
            Ok(b) => bindings.push(b),
            Err(e) => eprintln!("gpuifs: keymap {keys}: {e:?}"),
        }
    };
    for (_, lines) in menu_lines(inner) {
        for l in lines {
            if l.kind == MenuKind::Item
                && let Some(k) = prop(&l.props, "key")
            {
                add(k, &l.id, None, cx);
            }
        }
    }
    for l in keymap_lines(inner) {
        add(&l.keys.join(" "), &l.action, prop(&l.props, "context"), cx);
    }
    cx.clear_key_bindings();
    cx.bind_keys(bindings);
    // Menus show bindings, so rebuild them too.
    build_menus(inner, cx);
}

/// `menus/` changed: rebuild the menu bar (and the menu keys).
pub(crate) fn set_menus(inner: &Rc<Inner>, cx: &mut App) {
    set_keymap(inner, cx);
}

fn build_menus(inner: &Rc<Inner>, cx: &mut App) {
    let menus: Vec<Menu> = menu_lines(inner)
        .into_iter()
        .map(|(name, lines)| {
            let mut i = 0;
            let items = build_items(inner, &lines, &mut i, 0);
            Menu::new(name).items(items)
        })
        .collect();
    cx.set_menus(menus);
}

/// Items at `depth` from `lines[*i..]`, consuming deeper lines into submenus.
fn build_items(inner: &Inner, lines: &[MenuLine], i: &mut usize, depth: usize) -> Vec<MenuItem> {
    let mut out = Vec::new();
    while *i < lines.len() {
        let l = &lines[*i];
        if l.depth < depth {
            break;
        }
        *i += 1;
        match l.kind {
            MenuKind::Sep => out.push(MenuItem::separator()),
            MenuKind::Sub => {
                let label = prop(&l.props, "label").unwrap_or(&l.id).to_string();
                let items = build_items(inner, lines, i, l.depth + 1);
                out.push(MenuItem::submenu(Menu::new(label).items(items)));
            }
            MenuKind::Item => {
                let label = prop(&l.props, "label").unwrap_or(&l.id).to_string();
                let (enabled, checked) = inner
                    .action_state
                    .borrow()
                    .get(&l.id)
                    .copied()
                    .unwrap_or((true, false));
                let enabled = enabled && prop(&l.props, "disabled") != Some("on");
                let item = MenuItem::action(label, ClientAction { id: l.id.clone().into() })
                    .checked(checked || prop(&l.props, "check") == Some("on"))
                    .disabled(!enabled);
                out.push(item);
            }
        }
    }
    out
}
