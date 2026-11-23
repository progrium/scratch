//! `markdown`, `html`, `bubble` and `message-list`.
//!
//! Links in rendered text are reported as `link href=` events and never
//! opened by the host: the client decides.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gpui::{
    AnyElement, AnyEntity, App, AppContext as _, Context, ElementId, Entity, IntoElement,
    ParentElement as _, SharedString, Styled as _, Window, div, px,
};
use gpui_component::avatar::Avatar;
use gpui_component::bubble::{Bubble, BubbleVariant};
use gpui_component::message::{Message, MessageAlignment, MessageContent, MessageHeader};
use gpui_component::message_scroller::{MessageScroller, MessageScrollerState};
use gpui_component::text::TextView;
use gpui_component::{ActiveTheme as _, h_flex};

use super::{entity, no_verb, raw_text, spec};
use crate::{Component, Emitter, NodeView, RenderCx};

/// A TextView whose links send `link href=` on `em`'s node.
fn text_view(id: impl Into<ElementId>, text: String, html: bool, em: Emitter) -> TextView {
    let v = if html {
        TextView::html(id, text)
    } else {
        TextView::markdown(id, text)
    };
    v.on_link_click(move |href: &SharedString, _, _, _| {
        em.event("link", &[("href", href.as_ref())]);
    })
}

macro_rules! no_verbs {
    () => {
        fn verb(
            &self,
            _: &NodeView,
            _: Option<&AnyEntity>,
            cmd: &crate::Ctl,
            _: &mut Window,
            _: &mut App,
        ) -> crate::VerbResult {
            no_verb(cmd)
        }
    };
}

fn render_text(rcx: &mut RenderCx, node: &NodeView, html: bool) -> AnyElement {
    let text = raw_text(node, "text");
    let view = text_view(
        ElementId::Name(format!("{}#text", node.path()).into()),
        text,
        html,
        node.emitter(),
    )
    .selectable(node.flag("selectable"))
    .w_full();
    rcx.element(node).child(view).into_any_element()
}

pub struct Markdown;
impl Component for Markdown {
    fn spec(&self) -> &'static crate::Spec {
        spec("markdown")
    }
    no_verbs!();
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        render_text(rcx, node, false)
    }
}

pub struct Html;
impl Component for Html {
    fn spec(&self) -> &'static crate::Spec {
        spec("html")
    }
    no_verbs!();
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        render_text(rcx, node, true)
    }
}

fn bubble_variant(words: &[String], role: &str) -> BubbleVariant {
    for w in words {
        let v = match w.as_str() {
            "filled" => BubbleVariant::Filled,
            "secondary" => BubbleVariant::Secondary,
            "muted" => BubbleVariant::Muted,
            "tinted" => BubbleVariant::Tinted,
            "outline" => BubbleVariant::Outline,
            "ghost" => BubbleVariant::Ghost,
            "destructive" => BubbleVariant::Destructive,
            _ => continue,
        };
        return v;
    }
    // A chat's own messages are filled; replies sit on a quieter surface.
    if role == "user" {
        BubbleVariant::Filled
    } else {
        BubbleVariant::Secondary
    }
}

fn alignment(role: &str) -> MessageAlignment {
    if role == "user" {
        MessageAlignment::End
    } else {
        MessageAlignment::Start
    }
}

/// `avatar`: `@asset`, a path or URL, or else a name to take initials from.
fn avatar(node: &NodeView, a: &str) -> Avatar {
    if let Some(name) = a.strip_prefix('@') {
        if let Some(b) = node.asset(&name) {
            let img = gpui::Image::from_bytes(gpui::ImageFormat::Png, b.to_vec());
            return Avatar::new().src(std::sync::Arc::new(img));
        }
        return Avatar::new().name(name.to_string());
    }
    if a.contains('/') || a.contains('.') {
        return Avatar::new().src(a.to_string());
    }
    Avatar::new().name(a.to_string())
}

pub struct BubbleComponent;
impl Component for BubbleComponent {
    fn spec(&self) -> &'static crate::Spec {
        spec("bubble")
    }
    no_verbs!();
    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let role = node.text("role").unwrap_or_else(|| "assistant".into());
        let st = rcx.style_of(node);
        let text = raw_text(node, "text");
        let body = text_view(
            ElementId::Name(format!("{}#text", node.path()).into()),
            text,
            false,
            node.emitter(),
        )
        .selectable(true);
        let bubble = Bubble::new()
            .alignment(alignment(&role))
            .with_variant(bubble_variant(&st.variants, &role))
            .child(body);
        let av = node.text("avatar").filter(|a| !a.trim().is_empty());
        let inner = match av {
            Some(a) => Message::new()
                .alignment(alignment(&role))
                .avatar(avatar(node, a.trim()))
                .content(MessageContent::new().bubble(bubble))
                .into_any_element(),
            None => bubble.into_any_element(),
        };
        rcx.element_from(node, div().flex().flex_col().w_full())
            .child(inner)
            .into_any_element()
    }
}

// ---------------------------------------------------------------------------
// message-list

/// The host-side state of one `message-list`.
pub struct MessageListNode {
    scroller: Entity<MessageScrollerState>,
    msgs: Rc<RefCell<Vec<crate::data_lines::Message>>>,
    /// Whether the list was scrolled to its top at the last frame.
    at_top: Rc<Cell<bool>>,
}

impl MessageListNode {
    fn new(node: &NodeView, cx: &mut Context<Self>) -> Self {
        let msgs = parse(node);
        let n = msgs.len();
        let scroller = cx.new(|cx| MessageScrollerState::new(n, cx));
        if !node.flag("stick_to_bottom") {
            scroller.update(cx, |s, cx| {
                s.scroll_to_item(0, cx);
            });
        }
        MessageListNode {
            scroller,
            msgs: Rc::new(RefCell::new(msgs)),
            at_top: Rc::new(Cell::new(true)),
        }
    }

    /// New `items`: append when the old messages are a prefix of the new
    /// ones (a streamed reply grows its last message), else start over.
    fn update(&mut self, node: &NodeView, cx: &mut Context<Self>) {
        let new = parse(node);
        let old = self.msgs.borrow().clone();
        let stick = node.flag("stick_to_bottom");
        let same_ids = old.len() <= new.len()
            && old
                .iter()
                .zip(&new)
                .all(|(a, b)| a.id == b.id && a.role == b.role);
        self.scroller.update(cx, |s, cx| {
            if same_ids && !old.is_empty() {
                // Remeasure messages whose body changed, then append the rest.
                let changed: Vec<usize> = old
                    .iter()
                    .zip(&new)
                    .enumerate()
                    .filter(|(_, (a, b))| a != b)
                    .map(|(i, _)| i)
                    .collect();
                for i in changed {
                    s.remeasure_items(i..i + 1, cx);
                }
                let extra = new.len() - old.len();
                if extra > 0 {
                    s.append(extra, cx);
                }
                if stick {
                    s.scroll_to_end(cx);
                }
            } else {
                s.reset(new.len(), cx);
                if !stick && !new.is_empty() {
                    s.scroll_to_item(0, cx);
                }
            }
        });
        *self.msgs.borrow_mut() = new;
    }
}

fn parse(node: &NodeView) -> Vec<crate::data_lines::Message> {
    crate::data_lines::parse_messages(&raw_text(node, "items")).unwrap_or_default()
}

fn message_row(path: &str, m: &crate::data_lines::Message, em: &Emitter, cx: &App) -> AnyElement {
    let al = alignment(&m.role);
    let body = text_view(
        ElementId::Name(format!("{path}#msg-{}", m.id).into()),
        m.body.clone(),
        false,
        em.clone(),
    )
    .selectable(true);
    let variant = if m.role == "user" {
        BubbleVariant::Filled
    } else {
        BubbleVariant::Ghost
    };
    let mut header = h_flex()
        .gap_2()
        .text_xs()
        .text_color(cx.theme().muted_foreground);
    if m.role != "user" {
        header = header.child(m.role.clone());
    }
    if !m.time.is_empty() {
        header = header.child(m.time.clone());
    }
    Message::new()
        .id(ElementId::Name(format!("{path}#row-{}", m.id).into()))
        .alignment(al)
        .header(MessageHeader::new().child(header))
        .content(
            MessageContent::new().bubble(
                Bubble::new()
                    .alignment(al)
                    .with_variant(variant)
                    .child(body),
            ),
        )
        .into_any_element()
}

pub struct MessageList;
impl Component for MessageList {
    fn spec(&self) -> &'static crate::Spec {
        spec("message-list")
    }
    no_verbs!();

    fn create(&self, node: &NodeView, _: &mut Window, cx: &mut App) -> Option<AnyEntity> {
        Some(cx.new(|cx| MessageListNode::new(node, cx)).into_any())
    }

    fn prop_changed(
        &self,
        node: &NodeView,
        state: Option<&AnyEntity>,
        prop: &str,
        _: &mut Window,
        cx: &mut App,
    ) {
        if let Some(e) = entity::<MessageListNode>(state) {
            match prop {
                "items" => e.update(cx, |me, cx| me.update(node, cx)),
                "stick_to_bottom" if node.flag("stick_to_bottom") => {
                    let s = e.read(cx).scroller.clone();
                    s.update(cx, |s, cx| s.scroll_to_end(cx));
                }
                _ => {}
            }
        }
    }

    fn render(&self, rcx: &mut RenderCx, node: &NodeView) -> AnyElement {
        let Some(e) = rcx.state::<MessageListNode>(node) else {
            return rcx.element(node).into_any_element();
        };
        let (scroller, msgs, at_top) = {
            let me = e.read(rcx.cx_ref());
            (me.scroller.clone(), me.msgs.clone(), me.at_top.clone())
        };
        // `scrolled_to_top` once each time the user reaches the top.
        let top = {
            let s = scroller.read(rcx.cx_ref());
            let t = s.logical_scroll_top();
            s.item_count() > 0 && t.item_ix == 0 && t.offset_in_item <= px(0.)
        };
        if top && !at_top.get() {
            node.emitter().event("scrolled_to_top", &[]);
        }
        at_top.set(top);

        let path = node.path().to_string();
        let em = node.emitter();
        let list = MessageScroller::new(
            ElementId::Name(format!("{path}#list").into()),
            scroller,
            move |ix, _, cx| {
                let m = msgs.borrow().get(ix).cloned();
                match m {
                    Some(m) => message_row(&path, &m, &em, cx),
                    None => div().into_any_element(),
                }
            },
        )
        .size_full();
        rcx.element_from(node, div().flex().flex_col().min_h_0())
            .child(list)
            .into_any_element()
    }
}
