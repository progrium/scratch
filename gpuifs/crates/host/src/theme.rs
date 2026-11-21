//! `theme/tokens`, `theme/mode`, `theme/name` and `theme load`.
//!
//! Tokens are `gpui-component`'s `ThemeColor` field names. The host reads
//! and writes them by name through serde, so the table never goes stale.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use gpui::{App, Hsla, px};
use gpui_component::{ActiveTheme as _, Theme, ThemeColor, ThemeMode, ThemeRegistry, ThemeSet};

use crate::runtime::Inner;
use crate::styling::Tokens;

thread_local! {
    static CACHE: RefCell<Option<(ThemeColor, HashMap<String, Hsla>)>> = const { RefCell::new(None) };
}

fn color_map(colors: &ThemeColor) -> HashMap<String, Hsla> {
    let mut out = HashMap::new();
    if let Ok(serde_json::Value::Object(m)) = serde_json::to_value(colors) {
        for (k, v) in m {
            if let Ok(c) = serde_json::from_value::<Hsla>(v) {
                out.insert(k, c);
            }
        }
    }
    out
}

/// A theme token's current color.
pub fn token(cx: &App, name: &str) -> Option<Hsla> {
    let colors = cx.theme().colors;
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        if c.as_ref().is_none_or(|(k, _)| *k != colors) {
            *c = Some((colors, color_map(&colors)));
        }
        c.as_ref().unwrap().1.get(name).copied()
    })
}

/// Token lookup for style parsing.
pub struct TokenView<'a>(pub &'a App);

impl Tokens for TokenView<'_> {
    fn color(&self, t: &str) -> Option<Hsla> {
        token(self.0, t)
    }
}

pub(crate) fn init(_inner: &Rc<Inner>, cx: &mut App) {
    if !cx.has_global::<Theme>() {
        Theme::change(ThemeMode::Light, None, cx);
    }
}

#[derive(Default)]
struct Applied {
    mode: String,
    name: String,
}

thread_local! {
    static APPLIED: RefCell<Applied> = RefCell::new(Applied::default());
}

/// Re-reads `theme/mode`, `theme/name` and the token overrides.
pub(crate) fn apply(inner: &Rc<Inner>, cx: &mut App) {
    let (mode, name, overrides) = {
        let t = inner.tree.borrow();
        let read = |p: &str| {
            t.root_file(p)
                .map(|b| String::from_utf8_lossy(&b).trim().to_string())
                .unwrap_or_default()
        };
        (read("theme/mode"), read("theme/name"), t.theme_overrides().clone())
    };
    let changed = APPLIED.with(|a| {
        let mut a = a.borrow_mut();
        let ch = a.mode != mode || a.name != name;
        a.mode = mode.clone();
        a.name = name.clone();
        ch
    });
    if changed {
        if !name.is_empty() {
            let cfg = ThemeRegistry::global(cx)
                .themes()
                .get(name.as_str())
                .cloned()
                .or_else(|| {
                    // A set name (`Catppuccin`) picks its first theme.
                    style::find_theme(&name).and_then(|(n, _)| {
                        ThemeRegistry::global(cx).themes().get(n).cloned()
                    })
                });
            match cfg {
                Some(cfg) => Theme::update(cx, |t| t.apply_config(&cfg)),
                None => eprintln!("gpuifs: theme {name}: not found"),
            }
        }
        if !mode.is_empty() {
            let m = if mode == "dark" { ThemeMode::Dark } else { ThemeMode::Light };
            if cx.theme().mode != m {
                Theme::change(m, None, cx);
            }
        }
    }
    if !overrides.is_empty() {
        Theme::update(cx, |t| {
            let mut v = serde_json::to_value(t.colors).unwrap_or_default();
            for (k, val) in &overrides {
                if k == "radius" {
                    if let Ok(r) = val.trim().parse::<f32>() {
                        t.radius = px(r);
                    }
                    continue;
                }
                if let Some(c) = crate::styling::parse_color(val.trim(), &HashMap::new())
                    && let Some(obj) = v.as_object_mut()
                    && obj.contains_key(k)
                {
                    obj.insert(k.clone(), serde_json::to_value(c).unwrap_or_default());
                }
            }
            if let Ok(c) = serde_json::from_value::<ThemeColor>(v) {
                t.colors = c;
            }
        });
    }
    inner.theme_gen.set(inner.theme_gen.get() + 1);
    cx.refresh_windows();
}

/// `theme load path`: a GPUI Kit theme JSON file on the host.
pub(crate) fn load(inner: &Rc<Inner>, path: &str, cx: &mut App) {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("gpuifs: theme load {path}: {e}");
            return;
        }
    };
    let set: ThemeSet = match serde_json::from_str(&text) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("gpuifs: theme load {path}: {e}");
            return;
        }
    };
    let _ = ThemeRegistry::global_mut(cx).load_themes_from_str(&text);
    let mode = cx.theme().mode;
    let pick = set
        .themes
        .iter()
        .find(|t| t.mode == mode)
        .or_else(|| set.themes.first())
        .map(|t| t.name.clone());
    if let Some(n) = pick
        && let Some(cfg) = ThemeRegistry::global(cx).themes().get(&n).cloned()
    {
        Theme::update(cx, |t| t.apply_config(&cfg));
    }
    inner.theme_gen.set(inner.theme_gen.get() + 1);
    cx.refresh_windows();
}
