//! W5b: the element tier (`div`, `text`, `styled-text`, `img`, `svg`, `icon`, `scroll`, `spacer`).

use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;

use gpui::{
    AnyElement, App, FontStyle, FontWeight, HighlightStyle, Image, ImageFormat, ImageSource,
    IntoElement, ParentElement, StatefulInteractiveElement, StrikethroughStyle, Styled,
    StyledText, UnderlineStyle, Window, img, px, svg,
};
use gpui_component::{ElementExt as _, Icon, Sizable as _, Size};

use crate::{Component, ComponentRegistry, NodeView, RenderCx};

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(Div);
    reg.add(Text);
    reg.add(StyledTextEl);
    reg.add(Img);
    reg.add(Svg);
    reg.add(IconEl);
    reg.add(Scroll);
    reg.add(Spacer);
}

fn spec(name: &str) -> &'static crate::Spec {
    crate::spec::must(name)
}

fn no_verbs(cmd: &crate::Ctl) -> crate::VerbResult {
    Err(crate::Unhandled)
}

macro_rules! element_common {
    ($name:literal) => {
        fn spec(&self) -> &'static crate::Spec {
            spec($name)
        }
        fn verb(
            &self,
            _: &NodeView,
            _: Option<&gpui::AnyEntity>,
            cmd: &crate::Ctl,
            _: &mut Window,
            _: &mut App,
        ) -> crate::VerbResult {
            no_verbs(cmd)
        }
    };
}

struct Div;
impl Component for Div {
    element_common!("div");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let kids = rcx.children(node);
        rcx.element(node).children(kids).into_any_element()
    }
}

struct Text;
impl Component for Text {
    element_common!("text");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let text = node.text("text").unwrap_or_default();
        let mut el = rcx.element(node);
        if node.flag("truncate") {
            el = el.overflow_hidden().text_ellipsis().whitespace_nowrap();
        }
        el.child(text).into_any_element()
    }
}

/// A `runs` line's style words to a text highlight.
fn highlight(words: &[&str], rcx: &RenderCx) -> HighlightStyle {
    let mut h = HighlightStyle::default();
    for w in words {
        let (name, arg) = w.split_once('=').unwrap_or((w, ""));
        let color = || {
            crate::styling::parse_color(arg, rcx.cx_ref())
        };
        match name {
            "text_color" | "color" => h.color = color(),
            "bg" | "text_bg" => h.background_color = color(),
            "font_bold" => h.font_weight = Some(FontWeight::BOLD),
            "font_semibold" => h.font_weight = Some(FontWeight::SEMIBOLD),
            "font_medium" => h.font_weight = Some(FontWeight::MEDIUM),
            "font_weight" => h.font_weight = arg.parse().ok().map(FontWeight),
            "italic" => h.font_style = Some(FontStyle::Italic),
            "underline" => {
                h.underline = Some(UnderlineStyle {
                    thickness: px(1.),
                    ..Default::default()
                })
            }
            "line_through" => {
                h.strikethrough = Some(StrikethroughStyle {
                    thickness: px(1.),
                    ..Default::default()
                })
            }
            "opacity" | "fade_out" => h.fade_out = arg.parse::<f32>().ok().map(|o| 1. - o),
            _ => {}
        }
    }
    h
}

struct StyledTextEl;
impl Component for StyledTextEl {
    element_common!("styled-text");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let text = node.text("text").unwrap_or_default();
        let runs = node.text("runs").unwrap_or_default();
        let mut hl = Vec::new();
        for line in runs.lines() {
            let mut it = line.split_whitespace();
            let (Some(s), Some(l)) = (it.next(), it.next()) else {
                continue;
            };
            let (Ok(start), Ok(len)) = (s.parse::<usize>(), l.parse::<usize>()) else {
                continue;
            };
            let end = (start + len).min(text.len());
            if start >= end || !text.is_char_boundary(start) || !text.is_char_boundary(end) {
                continue;
            }
            let words: Vec<&str> = it.collect();
            hl.push((start..end, highlight(&words, rcx)));
        }
        hl.sort_by_key(|(r, _)| r.start);
        // Highlights must not overlap.
        let mut last = 0;
        hl.retain(|(r, _)| {
            let ok = r.start >= last;
            if ok {
                last = r.end;
            }
            ok
        });
        let st = StyledText::new(text).with_highlights(hl);
        rcx.element(node).child(st).into_any_element()
    }
}

/// Guesses an image format from its first bytes.
fn image_format(b: &[u8]) -> ImageFormat {
    if b.starts_with(b"\x89PNG") {
        ImageFormat::Png
    } else if b.starts_with(&[0xff, 0xd8]) {
        ImageFormat::Jpeg
    } else if b.starts_with(b"GIF8") {
        ImageFormat::Gif
    } else if b.len() > 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        ImageFormat::Webp
    } else if b.starts_with(b"BM") {
        ImageFormat::Bmp
    } else if b.starts_with(b"<svg") || b.starts_with(b"<?xml") {
        ImageFormat::Svg
    } else {
        ImageFormat::Png
    }
}

/// Bytes of `@name` from the root `assets/` directory.
fn asset(node: &NodeView, name: &str) -> Option<Vec<u8>> {
    node.asset(&name).map(|b| b.to_vec())
}

struct Img;
impl Component for Img {
    element_common!("img");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let data = node.prop("data").filter(|d| !d.is_empty());
        let src = node.text("src").unwrap_or_default();
        let source: Option<ImageSource> = if let Some(d) = data {
            Some(Arc::new(Image::from_bytes(image_format(&d), d.to_vec())).into())
        } else if let Some(name) = src.strip_prefix('@') {
            asset(node, name).map(|b| Arc::new(Image::from_bytes(image_format(&b), b)).into())
        } else if !src.is_empty() {
            Some(src.into())
        } else {
            None
        };
        let el = rcx.element(node);
        match source {
            Some(s) => el.child(img(s).size_full()).into_any_element(),
            None => el.into_any_element(),
        }
    }
}

struct Svg;
impl Component for Svg {
    element_common!("svg");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let src = node.text("src").unwrap_or_default();
        let color = rcx.style_of(node).base.text.color;
        let el = rcx.element(node);
        let icon = if let Some(name) = src.strip_prefix('@') {
            asset(node, name).map(|b| Icon::default().data(&b).size_full().into_any_element())
        } else if !src.is_empty() {
            let mut s = svg().external_path(src).size_full();
            if let Some(c) = color {
                s = s.text_color(c);
            }
            Some(s.into_any_element())
        } else {
            None
        };
        el.children(icon).into_any_element()
    }
}

struct IconEl;
impl Component for IconEl {
    element_common!("icon");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let name = node.text("name").unwrap_or_default();
        let st = rcx.style_of(node);
        let mut icon = Icon::default().path(format!("icons/{}.svg", name.trim()));
        if let Some(s) = &st.size {
            icon = icon.with_size(match s.as_str() {
                "xs" => Size::XSmall,
                "sm" => Size::Small,
                "lg" => Size::Large,
                _ => Size::Medium,
            });
        }
        if let Some(c) = st.base.text.color {
            icon = icon.text_color(c);
        }
        rcx.element(node)
            .flex()
            .items_center()
            .justify_center()
            .child(icon)
            .into_any_element()
    }
}

thread_local! {
    /// The scroll origin last mirrored per node, so only changes are written.
    static ORIGINS: RefCell<HashMap<String, (f32, f32)>> = RefCell::new(HashMap::new());
}

struct Scroll;
impl Component for Scroll {
    element_common!("scroll");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let st = rcx.style_of(node);
        let handle = rcx.scroll_handle(node);
        let kids = rcx.children(node);
        let mut el = rcx.element(node).track_scroll(&handle);
        if st.base.overflow.x.is_none() && st.base.overflow.y.is_none() {
            el = el.overflow_y_scroll();
        }
        let em = node.emitter();
        let path = node.path().to_string();
        el.children(kids)
            .on_prepaint(move |_, _, _| {
                let o = handle.offset();
                let now = (-f32::from(o.x), -f32::from(o.y));
                let changed = ORIGINS.with(|m| {
                    let mut m = m.borrow_mut();
                    let ch = m.get(&path) != Some(&now);
                    if ch {
                        m.insert(path.clone(), now);
                    }
                    ch
                });
                if changed {
                    em.mirror("origin", format!("{} {}", now.0, now.1).into_bytes());
                }
            })
            .into_any_element()
    }
}

struct Spacer;
impl Component for Spacer {
    element_common!("spacer");
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        rcx.element(node).flex_1().into_any_element()
    }
}
