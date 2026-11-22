//! W6d: editor, markdown, html, diff, message-list, bubble.
//!
//! DESIGN § Editing and rich content. Multi-line text (`value`, `text`,
//! `old`, `new`, `patch`) is `Bytes`: the bytes are kept as written, with no
//! trailing newline dropped (PLAN question 11).
use crate::*;

const fn p(name: &'static str, kind: PropKind) -> PropSpec {
    PropSpec {
        name,
        kind,
        default: None,
    }
}

const fn pd(name: &'static str, kind: PropKind, default: &'static str) -> PropSpec {
    PropSpec {
        name,
        kind,
        default: Some(default),
    }
}

const fn ev(name: &'static str, kind: EventKind) -> EventSpec {
    EventSpec { name, kind }
}

const fn component(
    name: &'static str,
    props: &'static [PropSpec],
    events: &'static [EventSpec],
) -> TypeSpec {
    TypeSpec {
        name,
        tier: Tier::Component,
        props,
        verbs: &[],
        events,
        slots: Slots::None,
        variants: &[],
        sizable: false,
    }
}

/// Message roles a `bubble` takes (the same words as `message-list` headers).
pub const ROLES: &[&str] = &["user", "assistant", "system", "tool"];

/// The variant words of GPUI Kit's `BubbleVariant`.
pub const BUBBLE_VARIANTS: &[&str] = &[
    "filled",
    "secondary",
    "muted",
    "tinted",
    "outline",
    "ghost",
    "destructive",
];

pub static SPECS: &[TypeSpec] = &[
    // GPUI Kit's code editor. Typing, selection, highlighting and scrolling
    // stay in the host; the client gets coalesced `change` (no text) and
    // `cursor` events and reads `value` when it wants the text.
    //
    // `complete` and `hover` are requests answered through files, sent only
    // when the node's `on` file lists them: the client writes `seq=N` then
    // completion lines to `completions`, or `seq=N` then markdown to `hover`.
    // An answer to anything but the newest request is dropped, and a request
    // nobody answers shows no popup. `save` is the editor's when a client
    // binding named `save` (or, with none, the platform save key) fires in it.
    component(
        "editor",
        &[
            p("value", PropKind::Bytes),
            pd("language", PropKind::Word, "text"),
            pd("line_numbers", PropKind::Bool, "off"),
            pd("soft_wrap", PropKind::Bool, "off"),
            pd("tab_size", PropKind::Number, "4"),
            pd("readonly", PropKind::Bool, "off"),
            p("placeholder", PropKind::Text),
            // `line col len severity message` lines, 1-based.
            p("diagnostics", PropKind::Data(LineFormat::Diagnostics)),
            // `line col line col`, 1-based, anchor then head.
            p("selection", PropKind::Data(LineFormat::Selection)),
            p("completions", PropKind::Data(LineFormat::Completions)),
            p("hover", PropKind::Bytes),
        ],
        &[
            ev("change", EventKind::State),
            ev("cursor", EventKind::State),
            ev("save", EventKind::Action),
            ev("complete", EventKind::Request),
            ev("hover", EventKind::Request),
        ],
    ),
    // Markdown through GPUI Kit's TextView. Links are reported, not opened.
    component(
        "markdown",
        &[
            p("text", PropKind::Bytes),
            pd("selectable", PropKind::Bool, "off"),
        ],
        &[ev("link", EventKind::Action)],
    ),
    // The safe HTML subset TextView renders.
    component(
        "html",
        &[
            p("text", PropKind::Bytes),
            pd("selectable", PropKind::Bool, "off"),
        ],
        &[ev("link", EventKind::Action)],
    ),
    // Either `old` and `new` (the host computes the diff), or a unified
    // `patch`. `path` names the file in the header and picks the language.
    component(
        "diff",
        &[
            p("old", PropKind::Bytes),
            p("new", PropKind::Bytes),
            p("patch", PropKind::Bytes),
            p("path", PropKind::Text),
            pd("layout", PropKind::Enum(&["unified", "split"]), "unified"),
            pd("line_numbers", PropKind::Bool, "on"),
        ],
        &[],
    ),
    // A transcript: `id role [time]` header lines, each followed by a
    // markdown body and a blank line. Virtualized.
    component(
        "message-list",
        &[
            p("items", PropKind::Data(LineFormat::Messages)),
            pd("stick_to_bottom", PropKind::Bool, "on"),
        ],
        &[ev("scrolled_to_top", EventKind::Action)],
    ),
    // One chat bubble: markdown `text`, `user` bubbles at the trailing edge.
    TypeSpec {
        variants: BUBBLE_VARIANTS,
        ..component(
            "bubble",
            &[
                pd("role", PropKind::Enum(ROLES), "assistant"),
                p("text", PropKind::Bytes),
                p("avatar", PropKind::Text),
            ],
            &[],
        )
    },
];
