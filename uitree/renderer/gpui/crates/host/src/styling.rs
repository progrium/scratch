//! Style words to GPUI `StyleRefinement`s: the renderer's half of I7.
//!
//! The core hands over every word already parsed, validated and with theme
//! tokens resolved to RGBA (`uit_style`). This module maps a word to a GPUI
//! call through W1's generated dispatch table (`tools/style-gen`, the same
//! list that wrote `core/types/style-words`, so the two can't drift): the
//! table gives the GPUI method, no-argument methods go through GPUI's own
//! inspector reflection, and words with an argument are one `match` below.
//! A test checks that every table entry resolves here.
//!
//! Results are cached per node by the host ([`crate::runtime::Inner::style_of`])
//! and dropped when the node's `style` changes or the theme does.

use std::collections::HashMap;
use std::sync::OnceLock;

use gpui::inspector_reflection::FunctionReflection;
use gpui::{
    AbsoluteLength, BoxShadow, DefiniteLength, FontWeight, Hsla, Length, Overflow, StyleRefinement,
    Styled, point, px, relative, rems,
};
use gpui_component::StyledExt as _;
use uitcore::{Arg, State};

/// One entry of the generated table.
#[derive(Debug, Clone, Copy)]
pub struct StyleEntry {
    /// The wire (dashed) name.
    pub name: &'static str,
    /// The GPUI method it calls.
    pub gpui: &'static str,
    pub arg: ArgKind,
    /// A GPUI Kit size or variant word, read by components.
    pub kit: bool,
}

#[derive(Debug, Clone, Copy)]
pub enum ArgKind {
    None,
    Length,
    Number,
    Color,
    Text,
    Many(&'static [ArgKind]),
}

#[allow(dead_code)]
mod generated {
    use super::{ArgKind, StyleEntry};
    include!("../../../tools/style-gen/generated/table.rs");
}
pub use generated::{SIZE_WORDS, TABLE, VARIANT_WORDS};

/// The table entry for a dashed word.
pub fn lookup(name: &str) -> Option<&'static StyleEntry> {
    TABLE.binary_search_by(|e| e.name.cmp(name)).ok().map(|i| &TABLE[i])
}

pub fn is_size_word(name: &str) -> bool {
    SIZE_WORDS.contains(&name)
}

/// The GPUI Kit types a variant word applies to; empty if it isn't one.
pub fn variant_owners(name: &str) -> &'static [&'static str] {
    VARIANT_WORDS.iter().find(|(w, _)| *w == name).map(|(_, o)| *o).unwrap_or(&[])
}
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
    is_size_word(name) || !variant_owners(name).is_empty()
}

/// A node's style words, as the core gave them, into refinements.
/// `variant_props` are the bare variant and size words set as props
/// (`new button ok primary` arrives as `primary=on`).
pub fn parse<'a>(words: impl Iterator<Item = uitcore::StyleWord<'a>>) -> ParsedStyle {
    let mut out = ParsedStyle::default();
    for w in words {
        let args: Vec<Arg> = w.args().collect();
        apply_word(&mut out, w.name, w.state, w.group, &args);
    }
    out
}

fn apply_word(out: &mut ParsedStyle, name: &str, state: State, group: &str, args: &[Arg]) {
    if name == "group" && state == State::Base {
        if !group.is_empty() {
            out.group = Some(group.to_string());
        } else if let Some(Arg::Text(g)) = args.first() {
            out.group = Some(g.to_string());
        }
        return;
    }
    // Kit words: size and variants, for components. A word that is also a
    // gpui word (`underline`, `border`) applies as both.
    if state == State::Base && args.is_empty() {
        if is_size_word(name) {
            out.size = Some(name.to_string());
            return;
        }
        if !variant_owners(name).is_empty() {
            out.variants.push(name.to_string());
            if lookup(name).is_none_or(|e| e.kit) {
                return;
            }
        }
    }
    let target: &mut StyleRefinement = match state {
        State::Base => &mut out.base,
        State::Hover => out.hover.get_or_insert_with(Default::default),
        State::Active => out.active.get_or_insert_with(Default::default),
        State::Focus => out.focus.get_or_insert_with(Default::default),
        State::Disabled => out.disabled.get_or_insert_with(Default::default),
        State::DropOver => out.drop_over.get_or_insert_with(Default::default),
        State::GroupHover => {
            let i = match out.group_hover.iter().position(|(n, _)| n == group) {
                Some(i) => i,
                None => {
                    out.group_hover.push((group.to_string(), Default::default()));
                    out.group_hover.len() - 1
                }
            };
            &mut out.group_hover[i].1
        }
        State::Other(_) => return,
    };
    let r = std::mem::take(target);
    match apply(r.clone(), name, args) {
        Some(r) => *target = r,
        None => {
            *target = r;
            out.unknown.push(name.to_string());
        }
    }
}

/// Applies one word. `None` if the word or its argument doesn't apply.
pub fn apply(r: StyleRefinement, name: &str, args: &[Arg]) -> Option<StyleRefinement> {
    let owned;
    let name = match lookup(name) {
        Some(e) => e.gpui,
        None => {
            owned = name.replace('-', "_");
            owned.as_str()
        }
    };
    if args.is_empty() {
        if let Some(m) = table().nullary.get(name) {
            return Some(m.invoke(r));
        }
        if let Some((_, f)) = EXTRA_NULLARY.iter().find(|(n, _)| *n == name) {
            return Some(f(r));
        }
        return None;
    }
    let a0 = args[0];
    let length = || length(a0);
    let definite = || definite(a0);
    let absolute = || absolute(a0);
    let color = || color(a0);
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
            Arg::Text(t) => r.font_family(t.to_string()),
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
            Arg::Px(n) | Arg::Number(n) if n < 8.0 => r.line_height(relative(n)),
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
            let x = self::number(args[0])?;
            let y = self::number(args[1])?;
            let blur = self::number(args[2])?;
            let c = self::color(args[3])?;
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

fn number(a: Arg) -> Option<f32> {
    match a {
        Arg::Px(n) | Arg::Number(n) => Some(n),
        _ => None,
    }
}

fn length(a: Arg) -> Option<Length> {
    match a {
        Arg::Text("auto") => Some(Length::Auto),
        _ => definite(a).map(Length::Definite),
    }
}

fn definite(a: Arg) -> Option<DefiniteLength> {
    match a {
        Arg::Percent(p) => Some(relative(p / 100.)),
        _ => absolute(a).map(DefiniteLength::Absolute),
    }
}

fn absolute(a: Arg) -> Option<AbsoluteLength> {
    match a {
        Arg::Px(n) | Arg::Number(n) => Some(px(n).into()),
        Arg::Rem(n) => Some(rems(n).into()),
        _ => None,
    }
}

/// A color the core resolved (a literal or a theme token).
pub fn color(a: Arg) -> Option<Hsla> {
    match a {
        Arg::Rgba(v, _) => Some(rgba(v)),
        _ => None,
    }
}

/// `0xRRGGBBAA` to a GPUI color.
pub fn rgba(v: u32) -> Hsla {
    gpui::Rgba {
        r: ((v >> 24) & 0xff) as f32 / 255.,
        g: ((v >> 16) & 0xff) as f32 / 255.,
        b: ((v >> 8) & 0xff) as f32 / 255.,
        a: (v & 0xff) as f32 / 255.,
    }
    .into()
}

/// `#rrggbb[aa]` (a component prop such as a color picker's value), or a
/// theme token's current color.
pub fn parse_color(s: &str, cx: &gpui::App) -> Option<Hsla> {
    let Some(h) = s.strip_prefix('#') else {
        return crate::theme::token(cx, s);
    };
    let v = u32::from_str_radix(h, 16).ok()?;
    match h.len() {
        6 => Some(rgba((v << 8) | 0xff)),
        8 => Some(rgba(v)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every word in W1's generated table applies here (kit words are read
    /// by components).
    #[test]
    fn every_table_word_resolves() {
        let mut missing = Vec::new();
        for e in TABLE {
            if e.kit {
                continue;
            }
            let args: Vec<Arg> = match e.arg {
                ArgKind::None => vec![],
                ArgKind::Length => vec![Arg::Px(4.)],
                ArgKind::Number => vec![Arg::Number(400.)],
                ArgKind::Color => vec![Arg::Rgba(0xff0000ff, "primary")],
                ArgKind::Text => vec![Arg::Text("monospace")],
                ArgKind::Many(_) => vec![Arg::Px(0.), Arg::Px(4.), Arg::Px(12.), Arg::Rgba(0x00000033, "")],
            };
            if apply(StyleRefinement::default(), e.name, &args).is_none() {
                missing.push(e.name);
            }
        }
        assert!(missing.is_empty(), "style words the host can't apply: {missing:?}");
    }

    #[test]
    fn table_is_sorted_for_lookup() {
        assert!(TABLE.windows(2).all(|w| w[0].name < w[1].name));
        assert_eq!(lookup("items-center").map(|e| e.gpui), Some("items_center"));
    }
}
