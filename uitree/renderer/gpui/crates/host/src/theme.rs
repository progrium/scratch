//! The theme: GPUI Kit's `Theme` follows the core's mode and tokens.
//!
//! The core resolves tokens for style words itself (`uit_style` carries
//! RGBA). GPUI Kit components read `cx.theme()`, so on `UIT_CMD_THEME` the
//! host copies every token the core knows (`uit_token`, for the names in
//! W1's generated `theme-tokens`) into `ThemeColor`, by field name through
//! serde, and switches the mode to `uit_theme_dark`.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use gpui::{App, Hsla};
use gpui_component::{ActiveTheme as _, Theme, ThemeColor, ThemeMode, ThemeRegistry, ThemeSet};

use crate::runtime::Inner;

thread_local! {
    static CACHE: RefCell<Option<(ThemeColor, HashMap<String, Hsla>)>> = const { RefCell::new(None) };
}

fn color_map(colors: &ThemeColor) -> HashMap<String, Hsla> {
    let mut out = HashMap::new();
    if let Ok(serde_json::Value::Object(m)) = serde_json::to_value(colors) {
        for (k, v) in m {
            if let Ok(c) = serde_json::from_value::<Hsla>(v) {
                out.insert(k.replace('_', "-"), c);
            }
        }
    }
    out
}

/// A theme token's current color, by its dashed name (`muted-foreground`).
/// Underscored names are accepted too.
pub fn token(cx: &App, name: &str) -> Option<Hsla> {
    let colors = cx.theme().colors;
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        if c.as_ref().is_none_or(|(k, _)| *k != colors) {
            *c = Some((colors, color_map(&colors)));
        }
        let m = &c.as_ref().unwrap().1;
        m.get(name).or_else(|| m.get(&name.replace('_', "-"))).copied()
    })
}

pub(crate) fn init(inner: &Rc<Inner>, cx: &mut App) {
    if !cx.has_global::<Theme>() {
        Theme::change(ThemeMode::Light, None, cx);
    }
    apply(inner, cx);
}

/// The token names the core knows, from W1's `theme-tokens`.
fn token_names() -> impl Iterator<Item = &'static str> {
    crate::spec::THEME_TOKENS.lines().filter(|l| !l.starts_with('#')).filter_map(|l| l.split_whitespace().next())
}

/// Re-reads the mode and every token from the core.
pub(crate) fn apply(inner: &Rc<Inner>, cx: &mut App) {
    let (dark, tokens) = {
        let core = inner.core.borrow();
        let tokens: Vec<(&str, u32)> = token_names().filter_map(|n| core.token(n).map(|v| (n, v))).collect();
        (core.theme_dark(), tokens)
    };
    let m = if dark { ThemeMode::Dark } else { ThemeMode::Light };
    if cx.theme().mode != m {
        Theme::change(m, None, cx);
    }
    if tokens.is_empty() {
        return;
    }
    Theme::update(cx, |t| {
        let mut v = serde_json::to_value(t.colors).unwrap_or_default();
        if let Some(obj) = v.as_object_mut() {
            for (name, rgba) in &tokens {
                let k = name.replace('-', "_");
                if obj.contains_key(&k) {
                    obj.insert(k, serde_json::to_value(crate::styling::rgba(*rgba)).unwrap_or_default());
                }
            }
        }
        if let Ok(c) = serde_json::from_value::<ThemeColor>(v) {
            t.colors = c;
        }
    });
}

/// `theme load PATH`: a GPUI Kit theme JSON file on the host.
pub(crate) fn load(_inner: &Rc<Inner>, path: &str, cx: &mut App) {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("uitree: theme load {path}: {e}");
            return;
        }
    };
    let set: ThemeSet = match serde_json::from_str(&text) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("uitree: theme load {path}: {e}");
            return;
        }
    };
    let _ = ThemeRegistry::global_mut(cx).load_themes_from_str(&text);
    let mode = cx.theme().mode;
    let pick = set.themes.iter().find(|t| t.mode == mode).or_else(|| set.themes.first()).map(|t| t.name.clone());
    if let Some(n) = pick
        && let Some(cfg) = ThemeRegistry::global(cx).themes().get(&n).cloned()
    {
        Theme::update(cx, |t| t.apply_config(&cfg));
    }
    cx.refresh_windows();
}
