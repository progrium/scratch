//! Style words to GPUI `StyleRefinement`s: the renderer's half of I7.
//!
//! The core hands over words already parsed, validated and with tokens
//! resolved (`uit_style`); this module only maps a dashed name to a GPUI
//! call. No-argument words go through GPUI's own inspector reflection and
//! GPUI Kit's, as in uitreefs; words with an argument are one `match`.
//! [`words`] lists every word this dispatch can apply, which is what the
//! renderer registers as `UitConfig.style_words`, so the core rejects any
//! word the renderer couldn't draw. W1's style-gen replaces the list with
//! a generated table; the shape stays.

use std::collections::HashMap;
use std::sync::OnceLock;

use gpui::inspector_reflection::FunctionReflection;
use gpui::{AbsoluteLength, DefiniteLength, Hsla, Length, Overflow, Rgba, StyleRefinement, Styled, px, relative, rems};
use gpui_component::StyledExt as _;
use uitcore::Arg;

type NullaryFn = fn(StyleRefinement) -> StyleRefinement;

/// Nullary words reflection doesn't reach (macro-made font weights, the
/// scroll words), as in uitreefs's host.
const EXTRA_NULLARY: &[(&str, NullaryFn)] = &[
    ("font_thin", |s| s.font_thin()),
    ("font_light", |s| s.font_light()),
    ("font_normal", |s| s.font_normal()),
    ("font_medium", |s| s.font_medium()),
    ("font_semibold", |s| s.font_semibold()),
    ("font_bold", |s| s.font_bold()),
    ("font_extrabold", |s| s.font_extrabold()),
    ("font_black", |s| s.font_black()),
    ("overflow_x_scroll", |mut s| {
        s.overflow.x = Some(Overflow::Scroll);
        s
    }),
    ("overflow_y_scroll", |mut s| {
        s.overflow.y = Some(Overflow::Scroll);
        s
    }),
];

/// Words with an argument, and the argument kind for `style_words`.
const ARG_WORDS: &[(&str, &str)] = &[
    ("w", "length"), ("h", "length"), ("size", "length"), ("min-w", "length"), ("min-h", "length"),
    ("max-w", "length"), ("max-h", "length"), ("p", "length"), ("px", "length"), ("py", "length"),
    ("pt", "length"), ("pb", "length"), ("pl", "length"), ("pr", "length"), ("m", "length"),
    ("mx", "length"), ("my", "length"), ("mt", "length"), ("mb", "length"), ("ml", "length"),
    ("mr", "length"), ("top", "length"), ("bottom", "length"), ("left", "length"), ("right", "length"),
    ("gap", "length"), ("gap-x", "length"), ("gap-y", "length"), ("bg", "color"), ("text-color", "color"),
    ("border-color", "color"), ("text-size", "length"), ("rounded", "length"), ("border", "length"),
    ("opacity", "number"), ("flex-grow", "number"), ("flex-shrink", "number"), ("line-height", "length"),
];

struct Table {
    nullary: HashMap<&'static str, FunctionReflection<StyleRefinement>>,
}

fn table() -> &'static Table {
    static T: OnceLock<Table> = OnceLock::new();
    T.get_or_init(|| {
        let mut nullary = HashMap::new();
        for m in gpui_kit::base::styled_ext_reflection_methods::<StyleRefinement>()
            .into_iter()
            .chain(gpui::styled_reflection::methods::<StyleRefinement>())
        {
            nullary.entry(m.name).or_insert(m);
        }
        Table { nullary }
    })
}

/// `style_words` for UitConfig: `name argkind` per line, dashed.
pub fn words() -> String {
    let mut out = String::new();
    let mut names: Vec<String> = table().nullary.keys().map(|n| n.replace('_', "-")).collect();
    names.extend(EXTRA_NULLARY.iter().map(|(n, _)| n.replace('_', "-")));
    names.sort();
    names.dedup();
    for n in names {
        out.push_str(&n);
        out.push_str(" none\n");
    }
    for (n, k) in ARG_WORDS {
        out.push_str(&format!("{n} {k}\n"));
    }
    out
}

pub fn rgba(v: u32) -> Hsla {
    Rgba { r: ((v >> 24) & 0xff) as f32 / 255., g: ((v >> 16) & 0xff) as f32 / 255., b: ((v >> 8) & 0xff) as f32 / 255., a: (v & 0xff) as f32 / 255. }.into()
}

fn length(a: Arg) -> Option<Length> {
    Some(match a {
        Arg::Px(n) | Arg::Number(n) => px(n).into(),
        Arg::Percent(n) => relative(n / 100.).into(),
        Arg::Rem(n) => rems(n).into(),
        _ => return None,
    })
}

fn definite(a: Arg) -> Option<DefiniteLength> {
    Some(match a {
        Arg::Px(n) | Arg::Number(n) => px(n).into(),
        Arg::Percent(n) => relative(n / 100.),
        Arg::Rem(n) => rems(n).into(),
        _ => return None,
    })
}

fn absolute(a: Arg) -> Option<AbsoluteLength> {
    Some(match a {
        Arg::Px(n) | Arg::Number(n) => px(n).into(),
        Arg::Rem(n) => rems(n).into(),
        _ => return None,
    })
}

fn number(a: Arg) -> Option<f32> {
    match a {
        Arg::Px(n) | Arg::Number(n) => Some(n),
        _ => None,
    }
}

fn color(a: Arg) -> Option<Hsla> {
    match a {
        Arg::Rgba(v, _) => Some(rgba(v)),
        _ => None,
    }
}

/// Applies one word to `r`. `None` if it doesn't apply (the core already
/// validated it against [`words`], so that means a bad argument kind).
pub fn apply(r: StyleRefinement, name: &str, args: &[Arg]) -> Option<StyleRefinement> {
    let under = name.replace('-', "_");
    let Some(&a0) = args.first() else {
        if let Some(m) = table().nullary.get(under.as_str()) {
            return Some(m.invoke(r));
        }
        return EXTRA_NULLARY.iter().find(|(n, _)| *n == under).map(|(_, f)| f(r));
    };
    Some(match name {
        "w" => r.w(length(a0)?),
        "h" => r.h(length(a0)?),
        "size" => r.size(length(a0)?),
        "min-w" => r.min_w(length(a0)?),
        "min-h" => r.min_h(length(a0)?),
        "max-w" => r.max_w(length(a0)?),
        "max-h" => r.max_h(length(a0)?),
        "p" => r.p(definite(a0)?),
        "px" => r.px(definite(a0)?),
        "py" => r.py(definite(a0)?),
        "pt" => r.pt(definite(a0)?),
        "pb" => r.pb(definite(a0)?),
        "pl" => r.pl(definite(a0)?),
        "pr" => r.pr(definite(a0)?),
        "m" => r.m(length(a0)?),
        "mx" => r.mx(length(a0)?),
        "my" => r.my(length(a0)?),
        "mt" => r.mt(length(a0)?),
        "mb" => r.mb(length(a0)?),
        "ml" => r.ml(length(a0)?),
        "mr" => r.mr(length(a0)?),
        "top" => r.top(length(a0)?),
        "bottom" => r.bottom(length(a0)?),
        "left" => r.left(length(a0)?),
        "right" => r.right(length(a0)?),
        "gap" => r.gap(definite(a0)?),
        "gap-x" => r.gap_x(definite(a0)?),
        "gap-y" => r.gap_y(definite(a0)?),
        "bg" => r.bg(color(a0)?),
        "text-color" => r.text_color(color(a0)?),
        "border-color" => r.border_color(color(a0)?),
        "text-size" => r.text_size(absolute(a0)?),
        "rounded" => r.rounded(absolute(a0)?),
        "border" => r.border(absolute(a0)?),
        "opacity" => r.opacity(number(a0)?),
        "flex-grow" => r.flex_grow(number(a0)?),
        "flex-shrink" => r.flex_shrink(number(a0)?),
        "line-height" => r.line_height(definite(a0)?),
        _ => return None,
    })
}
