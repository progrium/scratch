//! W6b: dialog, alert-dialog, sheet, popover, hover-card, context-menu.
//!
//! DESIGN § Overlays. Every overlay lives in `windows/<w>/overlays/` and
//! takes `open` and `close` on its `ctl` (the tree adds both verbs to every
//! `Tier::Overlay` type). Choices the design leaves open:
//!
//! - `open` is a read-only file the host mirrors (`on` or `off`).
//! - A `dialog` or `sheet` child named `footer` is its footer slot; every
//!   other child is its body.
//! - `close` requests (`dialog`, `sheet`) come from Esc, the close button and
//!   a click on the overlay; `close seq=N` hides it, `keep seq=N` doesn't.
//!   A `close` written to `ctl` with no `seq=` hides it at once.
//! - `alert-dialog` Esc and an overlay click send `cancel` (GAPS 27).
//! - `anchor` is window-relative (`root/more`). With `trigger=click` a
//!   click on the anchor toggles a popover; `trigger=hover` opens it while
//!   the pointer is over the anchor. A `context-menu` opens on a right click
//!   on its anchor, at the pointer.
use crate::*;

const fn p(name: &'static str, kind: PropKind) -> PropSpec {
    PropSpec { name, kind, default: None }
}

const fn pd(name: &'static str, kind: PropKind, default: &'static str) -> PropSpec {
    PropSpec { name, kind, default: Some(default) }
}

const fn ev(name: &'static str, kind: EventKind) -> EventSpec {
    EventSpec { name, kind }
}

const fn overlay(
    name: &'static str,
    props: &'static [PropSpec],
    events: &'static [EventSpec],
    slots: Slots,
) -> TypeSpec {
    TypeSpec {
        name,
        tier: Tier::Overlay,
        props,
        verbs: &[],
        events,
        slots,
        variants: &[],
        sizable: false,
    }
}

const OPEN: PropSpec = pd("open", PropKind::ReadOnly, "off");

pub const PLACEMENTS: &[&str] = &[
    "top-start",
    "top",
    "top-end",
    "bottom-start",
    "bottom",
    "bottom-end",
    "left-start",
    "left",
    "left-end",
    "right-start",
    "right",
    "right-end",
];

pub static SPECS: &[TypeSpec] = &[
    overlay(
        "dialog",
        &[
            p("title", PropKind::Text),
            p("description", PropKind::Text),
            p("width", PropKind::Number),
            // Unset means on. No spec default, so a document keeps the
            // words the client wrote.
            p("modal", PropKind::Bool),
            p("overlay_closable", PropKind::Bool),
            p("keyboard", PropKind::Bool),
            OPEN,
        ],
        &[ev("open", EventKind::Action), ev("close", EventKind::Request)],
        Slots::Any,
    ),
    overlay(
        "alert-dialog",
        &[
            p("title", PropKind::Text),
            p("description", PropKind::Text),
            pd("confirm", PropKind::Text, "OK"),
            p("cancel", PropKind::Text),
            pd("variant", PropKind::Enum(&["default", "danger"]), "default"),
            p("width", PropKind::Number),
            OPEN,
        ],
        &[
            ev("confirm", EventKind::Action),
            ev("cancel", EventKind::Action),
        ],
        Slots::Any,
    ),
    overlay(
        "sheet",
        &[
            pd("side", PropKind::Enum(&["left", "right", "top", "bottom"]), "right"),
            pd("size", PropKind::Number, "350"),
            p("title", PropKind::Text),
            p("overlay_closable", PropKind::Bool),
            OPEN,
        ],
        &[ev("close", EventKind::Request)],
        Slots::Any,
    ),
    overlay(
        "popover",
        &[
            p("anchor", PropKind::NodePath),
            pd("placement", PropKind::Enum(PLACEMENTS), "bottom-start"),
            pd("trigger", PropKind::Enum(&["click", "hover"]), "click"),
            OPEN,
        ],
        &[ev("open", EventKind::Action), ev("close", EventKind::Action)],
        Slots::Any,
    ),
    overlay(
        "hover-card",
        &[
            p("anchor", PropKind::NodePath),
            pd("placement", PropKind::Enum(PLACEMENTS), "bottom-start"),
            pd("open_delay", PropKind::Number, "600"),
            pd("close_delay", PropKind::Number, "300"),
            OPEN,
        ],
        &[],
        Slots::Any,
    ),
    overlay(
        "context-menu",
        &[
            p("anchor", PropKind::NodePath),
            p("menu", PropKind::Data(LineFormat::Menu)),
            OPEN,
        ],
        &[ev("action", EventKind::Action)],
        Slots::None,
    ),
];
