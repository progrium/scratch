//! W5b: div text styled-text img svg icon scroll spacer.
//!
//! The element tier is GPUI itself. These types have no events of their own:
//! a node sends what its `on` file lists (`click hover mouse_down mouse_up
//! scroll key focus blur move`), which the tree accepts on any node.
use crate::*;

const fn p(name: &'static str, kind: PropKind) -> PropSpec {
    PropSpec { name, kind, default: None }
}

/// `flags` on text elements: `selectable`, `truncate`, or both.
const TEXT_FLAGS: PropKind = PropKind::Enum(&[
    "selectable",
    "truncate",
    "selectable truncate",
    "truncate selectable",
]);

const fn element(name: &'static str, props: &'static [PropSpec], slots: Slots) -> TypeSpec {
    TypeSpec {
        name,
        tier: Tier::Element,
        props,
        verbs: &[],
        events: &[],
        slots,
        variants: &[],
        sizable: false,
    }
}

pub static SPECS: &[TypeSpec] = &[
    // The universal box.
    element("div", &[], Slots::Any),
    // A styled run of text. `flags` takes `selectable` and `truncate`.
    element(
        "text",
        &[p("text", PropKind::Text), p("flags", TEXT_FLAGS)],
        Slots::None,
    ),
    // Text plus `start len style...` highlight lines in `runs`.
    element(
        "styled-text",
        &[
            p("text", PropKind::Text),
            p("runs", PropKind::Bytes),
            p("flags", TEXT_FLAGS),
        ],
        Slots::None,
    ),
    // `src` is `@asset`, a host path or an https URL; `data` takes raw image bytes.
    element(
        "img",
        &[p("src", PropKind::Text), p("data", PropKind::Bytes)],
        Slots::None,
    ),
    // An icon or vector file, tinted by `text_color`.
    element("svg", &[p("src", PropKind::Text)], Slots::None),
    // A GPUI Kit icon by name (`search`, `chevron-down`).
    TypeSpec {
        sizable: true,
        ..element("icon", &[p("name", PropKind::Word)], Slots::None)
    },
    // A scrolling div; `origin` reads and writes `x y` (two numbers).
    element("scroll", &[p("origin", PropKind::Number)], Slots::Any),
    // `flex_1`, for pushing siblings apart.
    element("spacer", &[], Slots::None),
];
