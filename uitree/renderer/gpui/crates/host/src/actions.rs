//! The menu bar, from the core's parsed menus (`uit_menu_bar`, `uit_menu`).
//!
//! Every menu item is one GPUI action type, [`ClientAction`], carrying its
//! id; choosing one calls `uit_menu_action`, and the core sends
//! `action ID - via=menu`. Key bindings are the core's: a keystroke no
//! widget took goes to `uit_key` (see `window.rs`), so the renderer never
//! reads `keys`.

use std::rc::Rc;

use gpui::{Action, App, Menu, MenuItem, SharedString};
use uitcore::{MenuItem as Item, MenuKind};

use crate::runtime::Inner;

/// A menu item the client named.
#[derive(Clone, PartialEq, Debug, Action)]
#[action(namespace = uitree, no_json)]
pub struct ClientAction {
    pub id: SharedString,
}

pub(crate) fn init(inner: &Rc<Inner>, cx: &mut App) {
    let h = inner.clone();
    cx.on_action(move |a: &ClientAction, _cx| {
        if h.action_state.borrow().get(a.id.as_ref()).is_some_and(|(enabled, _)| !enabled) {
            return;
        }
        if let Ok(core) = h.core.try_borrow() {
            core.menu_action(&a.id);
        }
    });
}

/// Menus or their actions' state changed: rebuild the menu bar.
pub(crate) fn set_menus(inner: &Rc<Inner>, cx: &mut App) {
    let menus: Vec<(String, Vec<Item>)> = {
        let core = inner.core.borrow();
        core.menu_bar().into_iter().map(|n| (n.clone(), core.menu(&n))).collect()
    };
    let menus: Vec<Menu> = menus
        .into_iter()
        .map(|(name, items)| {
            let mut i = 0;
            Menu::new(name).items(build_items(inner, &items, &mut i, 0))
        })
        .collect();
    cx.set_menus(menus);
}

/// Items at `depth` from `items[*i..]`, consuming deeper ones into submenus.
fn build_items(inner: &Inner, items: &[Item], i: &mut usize, depth: u32) -> Vec<MenuItem> {
    let mut out = Vec::new();
    while *i < items.len() {
        let l = &items[*i];
        if l.depth < depth {
            break;
        }
        *i += 1;
        let label = if l.label.is_empty() { l.id.clone() } else { l.label.clone() };
        match l.kind {
            MenuKind::Sep => out.push(MenuItem::separator()),
            MenuKind::Sub => {
                let sub = build_items(inner, items, i, l.depth + 1);
                out.push(MenuItem::submenu(Menu::new(label).items(sub)));
            }
            MenuKind::Item => {
                let (enabled, check) = inner.action_state.borrow().get(&l.id).copied().unwrap_or((true, -1));
                let check = if check >= 0 { check } else { l.check };
                out.push(
                    MenuItem::action(label, ClientAction { id: l.id.clone().into() })
                        .checked(check == 1)
                        .disabled(!(enabled && l.enabled)),
                );
            }
        }
    }
    out
}
