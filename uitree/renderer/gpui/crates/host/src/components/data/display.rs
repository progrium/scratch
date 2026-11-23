//! The small display components: `description-list`, `badge`, `tag`,
//! `avatar`, `avatar-group`, `kbd`, `progress`, `spinner`, `skeleton`,
//! `shimmer`, `empty`, `alert`. All but `alert` are stateless; each draws
//! inside the node's own element, so style words, `on`, `tooltip` and
//! `bounds` work as on any node.

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, Axis, ClickEvent, Entity, InteractiveElement as _,
    IntoElement, Keystroke, ParentElement, StatefulInteractiveElement as _, Styled, Window, div,
    px,
};
use gpui_component::{
    ColorName, IconName, Sizable as _, Size, h_flex,
    alert::{Alert, AlertVariant},
    avatar::{Avatar, AvatarGroup},
    badge::Badge,
    description_list::DescriptionList,
    empty::{Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle},
    kbd::Kbd,
    progress::{Progress, ProgressCircle},
    shimmer::ShimmerText,
    skeleton::Skeleton,
    spinner::Spinner,
    tag::{Tag, TagVariant},
};
use crate::data_lines::DescItem;

use super::{icon, kit_size, lines, no_verbs, number, spec};
use crate::{Component, ComponentRegistry, NodeView, RenderCx};

pub fn register(reg: &mut ComponentRegistry) {
    for ty in [
        "description-list",
        "badge",
        "tag",
        "avatar",
        "avatar-group",
        "kbd",
        "progress",
        "spinner",
        "skeleton",
        "shimmer",
        "empty",
    ] {
        reg.add(Simple { ty });
    }
    reg.add(AlertComp);
}

struct Simple {
    ty: &'static str,
}

impl Component for Simple {
    fn spec(&self) -> &'static crate::Spec {
        spec(self.ty)
    }

    fn verb(
        &self,
        _: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &crate::Ctl,
        _: &mut Window,
        _: &mut App,
    ) -> crate::VerbResult {
        no_verbs(cmd)
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let t = |f: &str| node.text(f).unwrap_or_default();
        match self.ty {
            "description-list" => description_list(rcx, node),
            "badge" => badge(rcx, node),
            "tag" => tag(rcx, node, &t("label")),
            "avatar" => avatar(rcx, node, &t("name"), &t("src")),
            "avatar-group" => avatar_group(rcx, node),
            "kbd" => kbd(rcx, node, &t("key")),
            "progress" => progress(rcx, node),
            "spinner" => {
                let size = kit_size(&rcx.style_of(node));
                let color = rcx.style_of(node).base.text.color;
                let mut s = Spinner::new();
                if let Some(z) = size {
                    s = s.with_size(z);
                }
                if let Some(c) = color {
                    s = s.color(c);
                }
                rcx.element(node)
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(s)
                    .into_any_element()
            }
            "skeleton" => {
                let mut s = Skeleton::new().size_full();
                if node.flag("secondary") {
                    s = s.secondary();
                }
                rcx.element(node).child(s).into_any_element()
            }
            "shimmer" => {
                let text = t("text");
                if text.is_empty() {
                    // No text: a block that shimmers, like a skeleton.
                    rcx.element(node)
                        .child(Skeleton::new().size_full())
                        .into_any_element()
                } else {
                    let id = format!("{}#shimmer", node.path());
                    rcx.element(node)
                        .child(ShimmerText::new(text).id(gpui::ElementId::Name(id.into())))
                        .into_any_element()
                }
            }
            "empty" => empty(rcx, node),
            _ => rcx.element(node).into_any_element(),
        }
    }
}

fn description_list(rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
    let items = lines::<DescItem>(node, "items");
    let mut dl = DescriptionList::new()
        .columns(number(node, "columns", 3.).max(1.) as usize)
        .bordered(node.flag("bordered"))
        .layout(if node.text("labels").as_deref() == Some("top") {
            Axis::Vertical
        } else {
            Axis::Horizontal
        });
    if let Some(w) = node.text("label_width").and_then(|s| s.trim().parse::<f32>().ok()) {
        dl = dl.label_width(px(w));
    }
    if let Some(s) = kit_size(&rcx.style_of(node)) {
        dl = dl.with_size(s);
    }
    for it in items {
        dl = dl.item(it.label, it.value, 1);
    }
    rcx.element(node).child(dl).into_any_element()
}

fn badge(rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
    let kids = rcx.children(node);
    let mut b = Badge::new().children(kids);
    if node.flag("dot") {
        b = b.dot();
    } else if let Some(i) = node.text("icon").filter(|s| !s.trim().is_empty()) {
        b = b.icon(icon(&i));
    } else {
        b = b.count(number(node, "count", 0.).max(0.) as usize);
    }
    b = b.max(number(node, "max", 99.).max(0.) as usize);
    if let Some(s) = kit_size(&rcx.style_of(node)) {
        b = b.with_size(s);
    }
    // The badge is the decorated child's box; the node's style words go on it.
    rcx.element(node).child(b).into_any_element()
}

fn color_name(w: &str) -> Option<ColorName> {
    Some(match w {
        "amber" => ColorName::Amber,
        "black" => ColorName::Black,
        "blue" => ColorName::Blue,
        "cyan" => ColorName::Cyan,
        "emerald" => ColorName::Emerald,
        "fuchsia" => ColorName::Fuchsia,
        "gray" => ColorName::Gray,
        "green" => ColorName::Green,
        "indigo" => ColorName::Indigo,
        "lime" => ColorName::Lime,
        "neutral" => ColorName::Neutral,
        "orange" => ColorName::Orange,
        "pink" => ColorName::Pink,
        "purple" => ColorName::Purple,
        "red" => ColorName::Red,
        "rose" => ColorName::Rose,
        "sky" => ColorName::Sky,
        "teal" => ColorName::Teal,
        "violet" => ColorName::Violet,
        "white" => ColorName::White,
        "yellow" => ColorName::Yellow,
        _ => return None,
    })
}

/// A `tag` with `label` (stamped templates pass their own).
pub(crate) fn tag(rcx: &mut RenderCx, node: &NodeView, label: &str) -> AnyElement {
    let st = rcx.style_of(node);
    let mut variant = TagVariant::Secondary;
    let mut outline = false;
    for v in &st.variants {
        match v.as_str() {
            "primary" => variant = TagVariant::Primary,
            "secondary" => variant = TagVariant::Secondary,
            "danger" => variant = TagVariant::Danger,
            "success" => variant = TagVariant::Success,
            "warning" => variant = TagVariant::Warning,
            "info" => variant = TagVariant::Info,
            "outline" => outline = true,
            w => {
                if let Some(c) = color_name(w) {
                    variant = TagVariant::Color(c);
                }
            }
        }
    }
    let mut t = Tag::new().with_variant(variant);
    if outline {
        t = t.outline();
    }
    if let Some(s) = kit_size(&st) {
        t = t.with_size(s);
    }
    let mut content = h_flex().gap_1().items_center().child(label.to_string());
    if node.flag("closable") {
        let em = node.emitter();
        content = content.child(
            div()
                .id(gpui::ElementId::Name(format!("{}#close", node.path()).into()))
                .cursor_pointer()
                .child(gpui_component::Icon::new(IconName::Close).xsmall())
                .on_click(move |_: &ClickEvent, _, cx| {
                    cx.stop_propagation();
                    em.event("close", &[]);
                }),
        );
    }
    rcx.element(node).child(t.child(content)).into_any_element()
}

fn kit_avatar(node: &NodeView, name: &str, src: &str, size: Option<Size>) -> Avatar {
    let mut a = Avatar::new();
    if !name.is_empty() {
        a = a.name(name.to_string());
    }
    if let Some(asset) = src.strip_prefix('@') {
        if let Some(b) = node.asset(&asset) {
            let img = gpui::Image::from_bytes(guess_format(&b), b.to_vec());
            a = a.src(std::sync::Arc::new(img));
        }
    } else if !src.is_empty() {
        a = a.src(src.to_string());
    }
    if let Some(s) = size {
        a = a.with_size(s);
    }
    a
}

fn guess_format(b: &[u8]) -> gpui::ImageFormat {
    use gpui::ImageFormat::*;
    if b.starts_with(&[0xff, 0xd8]) {
        Jpeg
    } else if b.starts_with(b"GIF8") {
        Gif
    } else if b.len() > 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        Webp
    } else if b.starts_with(b"<svg") || b.starts_with(b"<?xml") {
        Svg
    } else {
        Png
    }
}

/// An `avatar` (stamped templates pass their own `name` and `src`).
pub(crate) fn avatar(rcx: &mut RenderCx, node: &NodeView, name: &str, src: &str) -> AnyElement {
    let size = kit_size(&rcx.style_of(node));
    let a = kit_avatar(node, name, src, size);
    rcx.element(node).child(a).into_any_element()
}

fn avatar_group(rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
    let size = kit_size(&rcx.style_of(node));
    let mut g = AvatarGroup::new();
    if let Some(m) = node.text("max").and_then(|s| s.trim().parse::<f32>().ok()) {
        g = g.limit(m.max(0.) as usize);
    } else {
        g = g.limit(usize::MAX);
    }
    for c in node.children().iter().filter(|c| c.ty() == "avatar") {
        let csize = kit_size(&rcx.style_of(c)).or(size);
        g = g.child(kit_avatar(
            c,
            &c.text("name").unwrap_or_default(),
            &c.text("src").unwrap_or_default(),
            csize,
        ));
    }
    if let Some(s) = size {
        g = g.with_size(s);
    }
    rcx.element(node).child(g).into_any_element()
}

/// A `kbd`: one keystroke, or several separated by spaces (a chord).
pub(crate) fn kbd(rcx: &mut RenderCx, node: &NodeView, key: &str) -> AnyElement {
    let keys: Vec<AnyElement> = key
        .split_whitespace()
        .map(|k| match Keystroke::parse_with_os(k, os()).ok() {
            Some(ks) => Kbd::new(ks).into_any_element(),
            None => div().child(k.to_string()).into_any_element(),
        })
        .collect();
    rcx.element(node)
        .flex()
        .items_center()
        .gap_1()
        .children(keys)
        .into_any_element()
}

fn progress(rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
    let v = node.text("value").unwrap_or_default();
    let v = v.trim();
    let value = v.parse::<f32>().ok().map(|x| x.clamp(0., 100.));
    let st = rcx.style_of(node);
    let color = st.base.text.color;
    let size = kit_size(&st);
    let id = gpui::ElementId::Name(format!("{}#progress", node.path()).into());
    let el: AnyElement = if node.text("variant").as_deref() == Some("circle") {
        let mut p = ProgressCircle::new(id)
            .value(value.unwrap_or(0.))
            .loading(value.is_none());
        if let Some(c) = color {
            p = p.color(c);
        }
        if let Some(s) = size {
            p = p.with_size(s);
        }
        p.into_any_element()
    } else {
        let mut p = Progress::new(id)
            .value(value.unwrap_or(0.))
            .loading(value.is_none());
        if let Some(c) = color {
            p = p.color(c);
        }
        if let Some(s) = size {
            p = p.with_size(s);
        }
        p.into_any_element()
    };
    rcx.element(node).child(el).into_any_element()
}

fn empty(rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
    let kids = rcx.children(node);
    let mut header = EmptyHeader::new();
    if let Some(i) = node.text("icon").filter(|s| !s.trim().is_empty()) {
        header = header.media(EmptyMedia::new().child(icon(&i)));
    }
    if let Some(t) = node.text("title").filter(|s| !s.is_empty()) {
        header = header.title(EmptyTitle::new().child(t));
    }
    if let Some(d) = node.text("description").filter(|s| !s.is_empty()) {
        header = header.description(EmptyDescription::new().child(d));
    }
    let mut e = Empty::new().header(header);
    if !kids.is_empty() {
        e = e.content(EmptyContent::new().children(kids));
    }
    rcx.element(node).child(e).into_any_element()
}

/// `alert`: closing it hides it (uncontrolled) and sends `close`; any
/// write to its files shows it again.
struct AlertComp;

pub(crate) struct AlertState {
    pub(crate) closed: bool,
}

impl Component for AlertComp {
    fn spec(&self) -> &'static crate::Spec {
        spec("alert")
    }

    fn create(&self, _: &NodeView, _: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        Some(cx.new(|_| AlertState { closed: false }).into())
    }

    fn prop_changed(
        &self,
        _: &NodeView,
        state: Option<&AnyEntity>,
        _: &str,
        _: &mut Window,
        cx: &mut App,
    ) {
        if let Some(s) = state.and_then(|s| s.clone().downcast::<AlertState>().ok()) {
            s.update(cx, |s, _| s.closed = false);
        }
    }

    fn verb(
        &self,
        _: &NodeView,
        _: Option<&AnyEntity>,
        cmd: &crate::Ctl,
        _: &mut Window,
        _: &mut App,
    ) -> crate::VerbResult {
        no_verbs(cmd)
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let state: Option<Entity<AlertState>> = rcx.state(node);
        let closed = state.as_ref().is_some_and(|s| s.read(rcx.cx_ref()).closed);
        let st = rcx.style_of(node);
        let word = st
            .variants
            .iter()
            .rev()
            .find(|v| matches!(v.as_str(), "info" | "success" | "warning" | "error"))
            .cloned()
            .or_else(|| node.text("variant"));
        let variant = match word.as_deref() {
            Some("success") => AlertVariant::Success,
            Some("warning") => AlertVariant::Warning,
            Some("error") => AlertVariant::Error,
            _ => AlertVariant::Info,
        };
        let id = gpui::ElementId::Name(format!("{}#alert", node.path()).into());
        let mut a = Alert::new(id, node.text("text").unwrap_or_default())
            .with_variant(variant)
            .visible(!closed);
        if let Some(t) = node.text("title").filter(|s| !s.is_empty()) {
            a = a.title(t);
        }
        if let Some(i) = node.text("icon").filter(|s| !s.trim().is_empty()) {
            a = a.icon(icon(&i));
        }
        if node.flag("banner") {
            a = a.banner();
        }
        if let Some(s) = kit_size(&st) {
            a = a.with_size(s);
        }
        if node.flag("closable") {
            let em = node.emitter();
            a = a.on_close(move |_, window, cx| {
                if let Some(s) = &state {
                    s.update(cx, |s, _| s.closed = true);
                }
                em.event("close", &[]);
                window.refresh();
            });
        }
        let mut el = rcx.element(node);
        if closed {
            el = el.hidden();
        }
        el.child(a).into_any_element()
    }
}

fn os() -> gpui::OperatingSystem {
    if cfg!(target_os = "macos") {
        gpui::OperatingSystem::Mac
    } else if cfg!(target_os = "windows") {
        gpui::OperatingSystem::Windows
    } else {
        gpui::OperatingSystem::Linux
    }
}
