//! Tray icons (shell.md § Tray) through the `tray-icon` crate: a menu bar
//! extra on macOS, a notification area icon on Windows. Like `native.rs`
//! it knows nothing of GPUI or the core, so it can be checked for every
//! target on its own: the host hands it plain items and gets chosen ids
//! back through a callback.
//!
//! Linux needs a GTK main loop for tray icons, which a GPUI app doesn't
//! run, so there `set` returns false and the tray is not shown.

/// One line of a tray's menu, from the core's parsed `menu/NAME`.
#[derive(Clone, Debug, PartialEq)]
pub enum Item {
    Sep,
    /// `check`: None for a plain item, Some(on) for one with a checkmark.
    Action { id: String, label: String, enabled: bool, check: Option<bool> },
    Sub { label: String, items: Vec<Item> },
}

/// What the host wants a tray to look like now.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Spec {
    pub title: String,
    pub tooltip: String,
    /// PNG bytes, from `asset/NAME`.
    pub icon: Option<Vec<u8>>,
    pub items: Vec<Item>,
}

/// A menu id carries its tray and its action: `TRAY<US>ACTION`.
#[cfg_attr(not(any(target_os = "macos", target_os = "windows")), allow(dead_code))]
const SEP: char = '\u{1f}';

#[cfg_attr(not(any(target_os = "macos", target_os = "windows")), allow(dead_code))]
pub fn split_id(id: &str) -> Option<(&str, &str)> {
    id.split_once(SEP)
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
pub use imp::Trays;

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub use none::Trays;

#[cfg(any(target_os = "macos", target_os = "windows"))]
mod imp {
    use super::{Item, SEP, Spec, split_id};
    use std::collections::HashMap;
    use tray_icon::menu::{CheckMenuItem, IsMenuItem, Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem, Submenu};
    use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

    /// The live tray icons, by name. Main thread only.
    #[derive(Default)]
    pub struct Trays {
        live: HashMap<String, (TrayIcon, Spec)>,
        hooked: bool,
    }

    fn icon(png: &[u8]) -> Option<Icon> {
        let img = image::load_from_memory_with_format(png, image::ImageFormat::Png).ok()?.into_rgba8();
        let (w, h) = img.dimensions();
        Icon::from_rgba(img.into_raw(), w, h).ok()
    }

    fn build(tray: &str, items: &[Item]) -> Vec<Box<dyn IsMenuItem>> {
        items
            .iter()
            .map(|it| -> Box<dyn IsMenuItem> {
                match it {
                    Item::Sep => Box::new(PredefinedMenuItem::separator()),
                    Item::Action { id, label, enabled, check } => {
                        let mid = MenuId::new(format!("{tray}{SEP}{id}"));
                        match check {
                            Some(on) => Box::new(CheckMenuItem::with_id(mid, label, *enabled, *on, None)),
                            None => Box::new(MenuItem::with_id(mid, label, *enabled, None)),
                        }
                    }
                    Item::Sub { label, items } => {
                        let kids = build(tray, items);
                        let refs: Vec<&dyn IsMenuItem> = kids.iter().map(|b| b.as_ref()).collect();
                        Box::new(Submenu::with_items(label, true, &refs).expect("submenu"))
                    }
                }
            })
            .collect()
    }

    fn menu(tray: &str, items: &[Item]) -> Menu {
        let kids = build(tray, items);
        let refs: Vec<&dyn IsMenuItem> = kids.iter().map(|b| b.as_ref()).collect();
        Menu::with_items(&refs).unwrap_or_else(|_| Menu::new())
    }

    impl Trays {
        /// Calls `chosen(tray, action)` for every menu item picked, from
        /// whatever thread the platform reports it on.
        pub fn on_choose(&mut self, chosen: impl Fn(&str, &str) + Send + Sync + 'static) {
            if self.hooked {
                return;
            }
            self.hooked = true;
            MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
                if let Some((tray, id)) = split_id(e.id.as_ref()) {
                    chosen(tray, id);
                }
            }));
        }

        /// Makes the tray `name` look like `spec`. False if the platform
        /// refused it.
        pub fn set(&mut self, name: &str, spec: Spec) -> bool {
            if let Some((t, old)) = self.live.get_mut(name) {
                if *old == spec {
                    return true;
                }
                if old.items != spec.items {
                    t.set_menu(Some(Box::new(menu(name, &spec.items))));
                }
                if old.title != spec.title {
                    t.set_title((!spec.title.is_empty()).then_some(&spec.title));
                }
                if old.tooltip != spec.tooltip {
                    let _ = t.set_tooltip((!spec.tooltip.is_empty()).then_some(&spec.tooltip));
                }
                if old.icon != spec.icon {
                    let _ = t.set_icon(spec.icon.as_deref().and_then(icon));
                }
                *old = spec;
                return true;
            }
            let mut b = TrayIconBuilder::new().with_menu(Box::new(menu(name, &spec.items)));
            if !spec.title.is_empty() {
                b = b.with_title(&spec.title);
            }
            if !spec.tooltip.is_empty() {
                b = b.with_tooltip(&spec.tooltip);
            }
            if let Some(i) = spec.icon.as_deref().and_then(icon) {
                b = b.with_icon(i);
            }
            match b.build() {
                Ok(t) => {
                    self.live.insert(name.to_string(), (t, spec));
                    true
                }
                Err(e) => {
                    eprintln!("uitree: tray {name}: {e}");
                    false
                }
            }
        }

        pub fn remove(&mut self, name: &str) {
            self.live.remove(name);
        }

    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
mod none {
    use super::Spec;
    use std::collections::HashMap;

    /// No tray icons on this platform: the specs are kept, so the host's
    /// bookkeeping is the same everywhere, but nothing is shown.
    #[derive(Default)]
    pub struct Trays {
        live: HashMap<String, Spec>,
    }

    impl Trays {
        pub fn on_choose(&mut self, _chosen: impl Fn(&str, &str) + Send + Sync + 'static) {}

        pub fn set(&mut self, name: &str, spec: Spec) -> bool {
            self.live.insert(name.to_string(), spec);
            false
        }

        pub fn remove(&mut self, name: &str) {
            self.live.remove(name);
        }

    }
}
