//! The theme: GPUI Kit's `Theme` follows the core's mode and tokens.
//!
//! The core resolves tokens for style words itself (`uit_style` carries
//! RGBA). GPUI Kit components read `cx.theme()`, so on `UIT_CMD_THEME` the
//! host copies every token the core knows (`uit_token`, for the names in
//! W1's generated `theme-tokens`) into `ThemeColor`, by field name through
//! serde, and switches the mode to `uit_theme_dark`. The look tokens
//! (`radius`, `font-size`, `font-family`, `shadow`, `spacing`) come as text
//! (`uit_token_text`) and set `Theme`'s fields and the windows' rem size.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use gpui::{App, Hsla};
use gpui_component::{ActiveTheme as _, Theme, ThemeColor, ThemeMode, ThemeRegistry, ThemeSet};

use crate::runtime::Inner;

thread_local! {
    /// GPUI Kit's own UI font, which `font-family system` means.
    static SYSTEM_FONT: RefCell<Option<gpui::SharedString>> = const { RefCell::new(None) };
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
    let f = cx.theme().font_family.clone();
    SYSTEM_FONT.with(|s| *s.borrow_mut() = Some(f));
    apply(inner, cx);
}

/// The token names the core knows, from W1's `theme-tokens`.
fn token_names() -> impl Iterator<Item = &'static str> {
    crate::spec::THEME_TOKENS.lines().filter(|l| !l.starts_with('#')).filter_map(|l| l.split_whitespace().next())
}

/// Re-reads the mode and every token from the core.
pub(crate) fn apply(inner: &Rc<Inner>, cx: &mut App) {
    let (dark, tokens, look) = {
        let core = inner.core.borrow();
        let tokens: Vec<(&str, u32)> = token_names().filter_map(|n| core.token(n).map(|v| (n, v))).collect();
        (core.theme_dark(), tokens, Look::read(&core))
    };
    let m = if dark { ThemeMode::Dark } else { ThemeMode::Light };
    if cx.theme().mode != m {
        Theme::change(m, None, cx);
    }
    apply_look(inner, &look, cx);
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

/// The look tokens (core.md § Style, Theme), as the core resolves them.
struct Look {
    radius: Option<f32>,
    radius_lg: Option<f32>,
    font_size: Option<f32>,
    font_family: Option<String>,
    spacing: Option<f32>,
    shadow: Option<bool>,
}

impl Look {
    fn read(core: &uitcore::Core) -> Look {
        let num = |n: &str| core.token_text(n).and_then(|v| v.trim().parse::<f32>().ok());
        Look {
            radius: num("radius"),
            radius_lg: num("radius-lg"),
            font_size: num("font-size"),
            font_family: core.token_text("font-family"),
            spacing: num("spacing"),
            shadow: core.token_text("shadow").map(|v| v.trim() == "on"),
        }
    }
}

/// GPUI Kit's `Theme` fields for radius, fonts and shadow; `spacing` sets
/// every window's rem size (a Tailwind step is a quarter rem, so the
/// default 4 is GPUI's 16).
fn apply_look(inner: &Rc<Inner>, l: &Look, cx: &mut App) {
    if let Some(s) = l.spacing {
        inner.rem.set((s * 4.).max(1.));
    }
    let system = SYSTEM_FONT.with(|s| s.borrow().clone());
    Theme::update(cx, |t| {
        if let Some(r) = l.radius {
            t.radius = gpui::px(r);
        }
        if let Some(r) = l.radius_lg {
            t.radius_lg = gpui::px(r);
        }
        if let Some(f) = l.font_size {
            t.font_size = gpui::px(f.max(1.));
        }
        if let Some(f) = &l.font_family {
            match (f.trim(), &system) {
                ("system", Some(s)) => t.font_family = s.clone(),
                ("system", None) => {}
                (name, _) => t.font_family = name.to_string().into(),
            }
        }
        if let Some(s) = l.shadow {
            t.shadow = s;
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
