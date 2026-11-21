//! Style words to GPUI `StyleRefinement`s.
//!
//! The tree has already checked every word against W5a's table
//! (`style::lookup`), so this module only has to apply them. No-argument
//! words go through gpui's own inspector reflection (`gpui::styled_reflection`
//! and `gpui_base::styled_ext_reflection_methods`), the same table gpui-shell
//! uses, so they never need a hand-written list. Words with an argument are
//! one `match` below, one arm per `TABLE` entry with an argument. A test
//! checks that every `TABLE` entry resolves here.

use std::collections::HashMap;
use std::sync::OnceLock;

use gpui::inspector_reflection::FunctionReflection;
use gpui::{
    AbsoluteLength, BoxShadow, DefiniteLength, FontWeight, Hsla, Length, Overflow, StyleRefinement,
    Styled, point, px, relative, rems,
};
use gpui_component::StyledExt as _;
use proto::{StateSel, StyleArg, StyleWord};

/// A node's `style` file, parsed and split by state.
#[derive(Clone, Default)]
pub struct ParsedStyle {
    pub base: StyleRefinement,
    pub hover: Option<StyleRefinement>,
    pub active: Option<StyleRefinement>,
    pub focus: Option<StyleRefinement>,
    pub disabled: Option<StyleRefinement>,
    pub drop_over: Option<StyleRefinement>,
    /// `group:name`: the element joins that GPUI group.
    pub group: Option<String>,
    /// `group-hover(name):word`, per group.
    pub group_hover: Vec<(String, StyleRefinement)>,
    /// GPUI Kit size word (`xs` `sm` `md` `lg`), for components.
    pub size: Option<String>,
    /// GPUI Kit variant words (`primary` `ghost` ...), for components.
    pub variants: Vec<String>,
    /// Words that didn't apply (for diagnostics; the tree rejects most).
    pub unknown: Vec<String>,
}

impl ParsedStyle {
    pub fn has_variant(&self, v: &str) -> bool {
        self.variants.iter().any(|x| x == v)
    }
}

/// Resolves theme token names to colors.
pub trait Tokens {
    fn color(&self, token: &str) -> Option<Hsla>;
}

impl Tokens for HashMap<String, Hsla> {
    fn color(&self, token: &str) -> Option<Hsla> {
        self.get(token).copied()
    }
}

type NullaryFn = fn(StyleRefinement) -> StyleRefinement;

/// No-argument words reflection does not reach: macro-generated font weights
/// in gpui-base, and the scroll words, which live on
/// `StatefulInteractiveElement` rather than `Styled` but only set a style field.
const EXTRA_NULLARY: &[(&str, NullaryFn)] = &[
    ("font_thin", |s| s.font_thin()),
    ("font_extralight", |s| s.font_extralight()),
    ("font_light", |s| s.font_light()),
    ("font_normal", |s| s.font_normal()),
    ("font_medium", |s| s.font_medium()),
    ("font_semibold", |s| s.font_semibold()),
    ("font_bold", |s| s.font_bold()),
    ("font_extrabold", |s| s.font_extrabold()),
    ("font_black", |s| s.font_black()),
    ("overflow_scroll", |mut s| {
        s.overflow.x = Some(Overflow::Scroll);
        s.overflow.y = Some(Overflow::Scroll);
        s
    }),
    ("overflow_x_scroll", |mut s| {
        s.overflow.x = Some(Overflow::Scroll);
        s
    }),
    ("restrict_scroll_to_axis", |mut s| {
        s.restrict_scroll_to_axis = Some(true);
        s
    }),
    ("overflow_y_scroll", |mut s| {
        s.overflow.y = Some(Overflow::Scroll);
        s
    }),
];

struct Table {
    nullary: HashMap<&'static str, FunctionReflection<StyleRefinement>>,
}

fn table() -> &'static Table {
    static T: OnceLock<Table> = OnceLock::new();
    T.get_or_init(|| {
        let mut nullary = HashMap::new();
        for m in gpui_base_methods()
            .into_iter()
            .chain(gpui::styled_reflection::methods::<StyleRefinement>())
        {
            nullary.entry(m.name).or_insert(m);
        }
        Table { nullary }
    })
}

fn gpui_base_methods() -> Vec<FunctionReflection<StyleRefinement>> {
    gpui_kit::base::styled_ext_reflection_methods::<StyleRefinement>()
}

/// True if `name` is a no-argument word the host can apply.
pub fn is_nullary(name: &str) -> bool {
    table().nullary.contains_key(name) || EXTRA_NULLARY.iter().any(|(n, _)| *n == name)
}

/// True for words that only components interpret.
pub fn is_kit_word(name: &str) -> bool {
    style::is_size_word(name) || !style::variant_owners(name).is_empty()
}

/// Parses a `style` file into refinements.
pub fn parse(src: &str, tokens: &dyn Tokens) -> ParsedStyle {
    let mut out = ParsedStyle::default();
    let words = match proto::parse_style(src) {
        Ok(w) => w,
        Err(_) => return out,
    };
    for w in words {
        apply_word(&mut out, &w, tokens);
    }
    out
}

fn apply_word(out: &mut ParsedStyle, w: &StyleWord, tokens: &dyn Tokens) {
    if w.name == "group" && w.state.is_none() {
        if let Some(g) = &w.group {
            out.group = Some(g.clone());
        }
        return;
    }
    // Kit words: size and variants, for components. A word that is also a
    // gpui word (`underline`, `border`) applies as both.
    if w.state.is_none() && w.args.is_empty() {
        if style::is_size_word(&w.name) {
            out.size = Some(w.name.clone());
            return;
        }
        if !style::variant_owners(&w.name).is_empty() {
            out.variants.push(w.name.clone());
            if !is_nullary(&w.name) {
                return;
            }
        }
    }
    let target: &mut StyleRefinement = match &w.state {
        None => &mut out.base,
        Some(StateSel::Hover) => out.hover.get_or_insert_with(Default::default),
        Some(StateSel::Active) => out.active.get_or_insert_with(Default::default),
        Some(StateSel::Focus) => out.focus.get_or_insert_with(Default::default),
        Some(StateSel::Disabled) => out.disabled.get_or_insert_with(Default::default),
        Some(StateSel::DropOver) => out.drop_over.get_or_insert_with(Default::default),
        Some(StateSel::GroupHover(g)) => {
            let i = match out.group_hover.iter().position(|(n, _)| n == g) {
                Some(i) => i,
                None => {
                    out.group_hover.push((g.clone(), Default::default()));
                    out.group_hover.len() - 1
                }
            };
            &mut out.group_hover[i].1
        }
    };
    let r = std::mem::take(target);
    match apply(r.clone(), &w.name, &w.args, tokens) {
        Some(r) => *target = r,
        None => {
            *target = r;
            out.unknown.push(w.name.clone());
        }
    }
}

/// Applies one word. `None` if the word or its argument doesn't apply.
pub fn apply(r: StyleRefinement, name: &str, args: &[StyleArg], tokens: &dyn Tokens) -> Option<StyleRefinement> {
    if args.is_empty() {
        if let Some(m) = table().nullary.get(name) {
            return Some(m.invoke(r));
        }
        if let Some((_, f)) = EXTRA_NULLARY.iter().find(|(n, _)| *n == name) {
            return Some(f(r));
        }
        return None;
    }
    let a0 = &args[0];
    let length = || length(a0);
    let definite = || definite(a0);
    let absolute = || absolute(a0);
    let color = || color(a0, tokens);
    let number = || number(a0);
    Some(match name {
        "w" => r.w(length()?),
        "h" => r.h(length()?),
        "size" => r.size(length()?),
        "min_w" => r.min_w(length()?),
        "min_h" => r.min_h(length()?),
        "min_size" => r.min_size(length()?),
        "max_w" => r.max_w(length()?),
        "max_h" => r.max_h(length()?),
        "max_size" => r.max_size(length()?),
        "p" => r.p(definite()?),
        "px" => r.px(definite()?),
        "py" => r.py(definite()?),
        "pt" => r.pt(definite()?),
        "pb" => r.pb(definite()?),
        "pl" => r.pl(definite()?),
        "pr" => r.pr(definite()?),
        "m" => r.m(length()?),
        "mx" => r.mx(length()?),
        "my" => r.my(length()?),
        "mt" => r.mt(length()?),
        "mb" => r.mb(length()?),
        "ml" => r.ml(length()?),
        "mr" => r.mr(length()?),
        "inset" => r.inset(length()?),
        "top" => r.top(length()?),
        "bottom" => r.bottom(length()?),
        "left" => r.left(length()?),
        "right" => r.right(length()?),
        "gap" => r.gap(definite()?),
        "gap_x" => r.gap_x(definite()?),
        "gap_y" => r.gap_y(definite()?),
        "flex_grow" => r.flex_grow(number()?),
        "flex_shrink" => r.flex_shrink(number()?),
        "flex_basis" => r.flex_basis(length()?),
        "bg" => r.bg(color()?),
        "text_color" => r.text_color(color()?),
        "text_bg" => r.text_bg(color()?),
        "text_decoration_color" => r.text_decoration_color(color()?),
        "border_color" => r.border_color(color()?),
        "text_size" => r.text_size(absolute()?),
        "font_family" => match a0 {
            StyleArg::Token(t) => r.font_family(t.clone()),
            _ => return None,
        },
        "font_weight" => {
            let n = number()?;
            if !(100.0..=900.0).contains(&n) {
                return None;
            }
            r.font_weight(FontWeight(n))
        }
        "line_height" => match a0 {
            // A bare number is a multiplier, as in CSS.
            StyleArg::Px(n) if *n < 8.0 => r.line_height(relative(*n)),
            _ => r.line_height(definite()?),
        },
        "opacity" => r.opacity(number()?),
        "aspect_ratio" => r.aspect_ratio(number()?),
        "line_clamp" => r.line_clamp(number()? as usize),
        "scrollbar_width" => r.scrollbar_width(absolute()?),
        "border" => r.border(absolute()?),
        "border_t" => r.border_t(absolute()?),
        "border_b" => r.border_b(absolute()?),
        "border_l" => r.border_l(absolute()?),
        "border_r" => r.border_r(absolute()?),
        "border_x" => r.border_x(absolute()?),
        "border_y" => r.border_y(absolute()?),
        "rounded" => r.rounded(absolute()?),
        "rounded_t" => r.rounded_t(absolute()?),
        "rounded_b" => r.rounded_b(absolute()?),
        "rounded_l" => r.rounded_l(absolute()?),
        "rounded_r" => r.rounded_r(absolute()?),
        "rounded_tl" => r.rounded_tl(absolute()?),
        "rounded_tr" => r.rounded_tr(absolute()?),
        "rounded_bl" => r.rounded_bl(absolute()?),
        "rounded_br" => r.rounded_br(absolute()?),
        "grid_cols" => r.grid_cols(number()? as u16),
        "grid_cols_min_content" => r.grid_cols_min_content(number()? as u16),
        "grid_cols_max_content" => r.grid_cols_max_content(number()? as u16),
        "grid_rows" => r.grid_rows(number()? as u16),
        "grid_rows_min_content" => r.grid_rows_min_content(number()? as u16),
        "grid_rows_max_content" => r.grid_rows_max_content(number()? as u16),
        "col_start" => r.col_start(number()? as i16),
        "col_end" => r.col_end(number()? as i16),
        "col_span" => r.col_span(number()? as u16),
        "row_start" => r.row_start(number()? as i16),
        "row_end" => r.row_end(number()? as i16),
        "row_span" => r.row_span(number()? as u16),
        "shadow" => {
            // x, y, blur, color
            if args.len() != 4 {
                return None;
            }
            let x = pixels(&args[0])?;
            let y = pixels(&args[1])?;
            let blur = pixels(&args[2])?;
            let c = self::color(&args[3], tokens)?;
            r.shadow(vec![BoxShadow {
                color: c,
                offset: point(px(x), px(y)),
                blur_radius: px(blur),
                spread_radius: px(0.),
                inset: false,
            }])
        }
        _ => return None,
    })
}

fn pixels(a: &StyleArg) -> Option<f32> {
    match a {
        StyleArg::Px(n) => Some(*n),
        _ => None,
    }
}

fn number(a: &StyleArg) -> Option<f32> {
    match a {
        StyleArg::Px(n) => Some(*n),
        _ => None,
    }
}

fn length(a: &StyleArg) -> Option<Length> {
    match a {
        StyleArg::Token(t) if t == "auto" => Some(Length::Auto),
        _ => definite(a).map(Length::Definite),
    }
}

fn definite(a: &StyleArg) -> Option<DefiniteLength> {
    match a {
        StyleArg::Percent(p) => Some(relative(*p / 100.)),
        _ => absolute(a).map(DefiniteLength::Absolute),
    }
}

fn absolute(a: &StyleArg) -> Option<AbsoluteLength> {
    match a {
        StyleArg::Px(n) => Some(px(*n).into()),
        StyleArg::Rem(n) => Some(rems(*n).into()),
        _ => None,
    }
}

/// A literal color or a theme token.
pub fn color(a: &StyleArg, tokens: &dyn Tokens) -> Option<Hsla> {
    match a {
        StyleArg::Color(c) => Some(rgba_to_hsla(*c)),
        StyleArg::Token(t) => tokens.color(t),
        _ => None,
    }
}

pub fn rgba_to_hsla(c: proto::Rgba) -> Hsla {
    gpui::Rgba {
        r: c.r as f32 / 255.,
        g: c.g as f32 / 255.,
        b: c.b as f32 / 255.,
        a: c.a as f32 / 255.,
    }
    .into()
}

/// Parses `#rrggbb[aa]` or a token into a color.
pub fn parse_color(s: &str, tokens: &dyn Tokens) -> Option<Hsla> {
    if s.starts_with('#') {
        proto::Rgba::parse(s).ok().map(rgba_to_hsla)
    } else {
        tokens.color(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks() -> HashMap<String, Hsla> {
        let mut m = HashMap::new();
        m.insert("primary".to_string(), gpui::red());
        m.insert("accent".to_string(), gpui::blue());
        m
    }

    /// Every word in W5a's table applies here (kit words are read by components).
    #[test]
    fn every_table_word_resolves() {
        let mut missing = Vec::new();
        for e in style::TABLE {
            if is_kit_word(e.name) {
                continue;
            }
            let args: Vec<StyleArg> = match e.arg {
                style::ArgKind::None => vec![],
                style::ArgKind::Length => vec![StyleArg::Px(4.)],
                style::ArgKind::Number => vec![StyleArg::Px(400.)],
                style::ArgKind::Color => vec![StyleArg::Token("primary".into())],
                style::ArgKind::Text => vec![StyleArg::Token("monospace".into())],
                style::ArgKind::Many(_) => vec![
                    StyleArg::Px(0.),
                    StyleArg::Px(4.),
                    StyleArg::Px(12.),
                    StyleArg::Color(proto::Rgba { r: 0, g: 0, b: 0, a: 51 }),
                ],
            };
            if apply(StyleRefinement::default(), e.name, &args, &toks()).is_none() {
                missing.push(e.name);
            }
        }
        assert!(missing.is_empty(), "style words the host can't apply: {missing:?}");
    }

    #[test]
    fn states_groups_and_kit_words_split() {
        let p = parse(
            "h_flex gap=8 p=12 rounded_lg bg=primary hover:bg=accent cursor_pointer group:card group-hover(card):text_color=primary primary sm",
            &toks(),
        );
        assert!(p.unknown.is_empty(), "{:?}", p.unknown);
        assert!(p.hover.is_some());
        assert_eq!(p.group.as_deref(), Some("card"));
        assert_eq!(p.group_hover.len(), 1);
        assert_eq!(p.size.as_deref(), Some("sm"));
        assert!(p.has_variant("primary"));
        assert_eq!(p.base.background.is_some(), true);
    }
}
