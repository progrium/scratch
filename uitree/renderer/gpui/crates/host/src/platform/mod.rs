//! The shell layer's platform objects (protocols/shell.md): window
//! platform props GPUI doesn't expose (`top`, `fill`, `all-spaces`,
//! `shadow`, hiding), tray icons, `open URL` and the app props. The OS
//! work is in `native` and `tray`, which take plain data; this is the glue
//! to GPUI windows and the core.

pub mod native;
pub mod tray;

use std::rc::Rc;

use gpui::{App, Bounds, Pixels, Window};
use raw_window_handle::HasWindowHandle;
use uitcore::{Ctl, MenuItem as CoreItem, MenuKind};

use crate::runtime::{Input, Inner};

/// The window props this module owns.
pub(crate) const WINDOW_PROPS: [&str; 4] = ["top", "fill", "all-spaces", "shadow"];

fn on(v: &str) -> bool {
    v == "on"
}

/// One window prop, on a live window. False if it isn't one of ours.
pub(crate) fn set_window_prop(window: &mut Window, cx: &App, key: &str, value: &str) -> bool {
    let Ok(h) = HasWindowHandle::window_handle(&*window) else { return WINDOW_PROPS.contains(&key) };
    let h = h.as_raw();
    match key {
        "top" => {
            native::set_top(h, native::Top::parse(value));
        }
        "all-spaces" => {
            native::set_all_spaces(h, on(value));
        }
        "shadow" => {
            native::set_shadow(h, on(value));
        }
        "fill" => {
            let fill = native::Fill::parse(value);
            if !native::set_fill(h, fill)
                && fill != native::Fill::None
                && let Some(b) = display_bounds(window, cx, fill)
            {
                window.resize(b.size);
            }
        }
        _ => return false,
    }
    true
}

/// Every one of our props the window was made with.
pub(crate) fn apply_window_props(window: &mut Window, cx: &App, prop: &dyn Fn(&str) -> Option<String>) {
    for k in WINDOW_PROPS {
        if let Some(v) = prop(k) {
            set_window_prop(window, cx, k, &v);
        }
    }
}

/// `state hidden` orders the window out without closing it; any other
/// state after it brings it back.
pub(crate) fn set_hidden(window: &mut Window, hidden: bool) {
    let ok = HasWindowHandle::window_handle(&*window).map(|h| native::set_hidden(h.as_raw(), hidden)).unwrap_or(false);
    if !ok && hidden {
        window.minimize_window();
    }
}

fn display_bounds(window: &Window, cx: &App, fill: native::Fill) -> Option<Bounds<Pixels>> {
    let d = window.display(cx).or_else(|| cx.primary_display())?;
    Some(if fill == native::Fill::Work { d.visible_bounds() } else { d.bounds() })
}

/// The bounds a window with `fill=` opens at: its display's, or the
/// display's work area. None for `fill=none` or no display.
pub(crate) fn open_bounds(fill: Option<&str>, cx: &App) -> Option<Bounds<Pixels>> {
    let fill = native::Fill::parse(fill?);
    if fill == native::Fill::None {
        return None;
    }
    let d = cx.primary_display()?;
    Some(if fill == native::Fill::Work { d.visible_bounds() } else { d.bounds() })
}

/// A shell command from the core (`UIT_CMD_APP_CTL`).
pub(crate) fn app_ctl(inner: &Rc<Inner>, ctl: &Ctl, cx: &mut App) {
    match ctl.verb.as_str() {
        "tray" => {
            let Some(name) = ctl.arg(0) else { return };
            inner.tray_props.borrow_mut().insert(name.to_string(), ctl.attrs.clone());
            hook_trays(inner);
            refresh_trays(inner);
        }
        "delete" => {
            if let Some(name) = ctl.arg(0).and_then(|p| p.strip_prefix("tray/")) {
                inner.tray_props.borrow_mut().remove(name);
                inner.trays.borrow_mut().remove(name);
            }
        }
        "open" => {
            if let Some(url) = ctl.arg(0) {
                cx.open_url(url);
            }
        }
        "set" if ctl.arg(0) == Some("app") => {
            for (k, v) in &ctl.attrs {
                match k.as_str() {
                    "agent" => inner.agent.set(on(v)),
                    "accessory" => {
                        native::set_accessory(on(v));
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
}

/// Tray menu picks go to the core, in order with other input.
fn hook_trays(inner: &Rc<Inner>) {
    let tx = inner.input.clone();
    inner.trays.borrow_mut().on_choose(move |tray, id| {
        let _ = tx.unbounded_send(Input::TrayAction { tray: tray.to_string(), id: id.to_string() });
    });
}

/// Menus, action states or assets changed: every tray is rebuilt from its
/// props, its `menu/NAME` and its icon asset. Unchanged trays are left be.
pub(crate) fn refresh_trays(inner: &Rc<Inner>) {
    let props = inner.tray_props.borrow().clone();
    if props.is_empty() {
        return;
    }
    for (name, attrs) in props {
        let get = |k: &str| attrs.iter().find(|(a, _)| a == k).map(|(_, v)| v.clone()).unwrap_or_default();
        let menu = get("menu");
        let menu = if menu.is_empty() { name.clone() } else { menu };
        let icon_name = get("icon");
        let (items, icon) = {
            let core = inner.core.borrow();
            let items = core.menu(&menu);
            let icon = (!icon_name.is_empty()).then(|| core.asset(&icon_name).map(<[u8]>::to_vec)).flatten();
            (items, icon)
        };
        let mut i = 0;
        let items = tray_items(inner, &items, &mut i, 0);
        let spec = tray::Spec { title: get("title"), tooltip: get("tooltip"), icon, items };
        inner.trays.borrow_mut().set(&name, spec);
    }
}

/// The core's flat menu lines at `depth` from `items[*i..]`, as tray items.
fn tray_items(inner: &Inner, items: &[CoreItem], i: &mut usize, depth: u32) -> Vec<tray::Item> {
    let mut out = Vec::new();
    while *i < items.len() {
        let l = &items[*i];
        if l.depth < depth {
            break;
        }
        *i += 1;
        let label = if l.label.is_empty() { l.id.clone() } else { l.label.clone() };
        match l.kind {
            MenuKind::Sep => out.push(tray::Item::Sep),
            MenuKind::Sub => {
                let sub = tray_items(inner, items, i, l.depth + 1);
                out.push(tray::Item::Sub { label, items: sub });
            }
            MenuKind::Item => {
                let (enabled, check) = inner.action_state.borrow().get(&l.id).copied().unwrap_or((true, -1));
                let check = if check >= 0 { check } else { l.check };
                out.push(tray::Item::Action { id: l.id.clone(), label, enabled: enabled && l.enabled, check: (check >= 0).then_some(check == 1) });
            }
        }
    }
    out
}
