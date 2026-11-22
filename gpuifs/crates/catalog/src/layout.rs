//! W6d: accordion, collapsible, group-box, separator, resizable, grid, dock.
//!
//! DESIGN § Layout. The containers that take typed children say so with
//! `Slots::ChildTypes`: `accordion` takes `accordion-item`s, `resizable`
//! takes `panel`s and `dock` takes `dock-panel`s.
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
    slots: Slots,
) -> TypeSpec {
    TypeSpec {
        name,
        tier: Tier::Component,
        props,
        verbs: &[],
        events,
        slots,
        variants: &[],
        sizable: false,
    }
}

const DIRS: &[&str] = &["h", "v"];

/// Where a `dock-panel` starts out (its place in a restored `layout` wins).
pub const ZONES: &[&str] = &["center", "left", "right", "bottom"];

/// The variant words of GPUI Kit's `GroupBoxVariant`.
pub const GROUP_BOX_VARIANTS: &[&str] = &["normal", "fill", "outline"];

pub static SPECS: &[TypeSpec] = &[
    // `value` is the open items' names, space-separated. The user's clicks
    // change it (uncontrolled) and send `change value=`.
    TypeSpec {
        sizable: true,
        ..component(
            "accordion",
            &[
                pd("multiple", PropKind::Bool, "off"),
                p("value", PropKind::Text),
            ],
            &[ev("change", EventKind::State)],
            Slots::ChildTypes(&["accordion-item"]),
        )
    },
    // One section: `title` in the header, the children are the body.
    component(
        "accordion-item",
        &[
            p("title", PropKind::Text),
            p("icon", PropKind::Word),
            pd("disabled", PropKind::Bool, "off"),
        ],
        &[],
        Slots::Any,
    ),
    // A click on the `trigger` child toggles `open` and shows `content`.
    component(
        "collapsible",
        &[pd("open", PropKind::Bool, "off")],
        &[ev("change", EventKind::State)],
        Slots::Named(&["trigger", "content"]),
    ),
    TypeSpec {
        variants: GROUP_BOX_VARIANTS,
        ..component("group-box", &[p("title", PropKind::Text)], &[], Slots::Any)
    },
    // A rule. `dir=v` is vertical; `label` sits in the middle.
    component(
        "separator",
        &[
            pd("dir", PropKind::Enum(DIRS), "h"),
            p("label", PropKind::Text),
        ],
        &[],
        Slots::None,
    ),
    // Panels side by side (`dir=h`) or stacked. After the user drags a
    // divider, each panel's `size` is mirrored and one `resize sizes=` follows.
    component(
        "resizable",
        &[pd("dir", PropKind::Enum(DIRS), "h")],
        &[ev("resize", EventKind::State)],
        Slots::ChildTypes(&["panel"]),
    ),
    // `size`, `min` and `max` are points along the group's axis. A panel
    // with no `size` takes what is left.
    component(
        "panel",
        &[
            p("size", PropKind::Number),
            p("min", PropKind::Number),
            p("max", PropKind::Number),
        ],
        &[],
        Slots::Any,
    ),
    // A CSS grid. Children take `col_span` and `row_span` style words.
    component(
        "grid",
        &[
            p("cols", PropKind::Number),
            p("rows", PropKind::Number),
            p("gap", PropKind::Number),
        ],
        &[],
        Slots::Any,
    ),
    // GPUI Kit's DockArea. `layout` reads and writes its serialized
    // `DockAreaState` JSON; writing an empty `layout` (or `{}`) resets every panel to
    // its `zone`. Closing a tab sends a `panel-close id=` request (default
    // `close`; answer `keep seq=` to keep it).
    component(
        "dock",
        &[pd("layout", PropKind::Data(LineFormat::Json), "{}")],
        &[
            ev("layout", EventKind::State),
            ev("panel-close", EventKind::Request),
        ],
        Slots::ChildTypes(&["dock-panel"]),
    ),
    // A dock tab; the children are its content. `activate` on its ctl
    // shows it (reopening it if the user closed it).
    TypeSpec {
        verbs: &[VerbSpec {
            name: "activate",
            usage: "activate",
        }],
        ..component(
            "dock-panel",
            &[
                p("title", PropKind::Text),
                p("icon", PropKind::Word),
                pd("zone", PropKind::Enum(ZONES), "center"),
                pd("closable", PropKind::Bool, "off"),
                pd("zoomable", PropKind::Bool, "on"),
            ],
            &[
                ev("activate", EventKind::Action),
                ev("close", EventKind::Action),
            ],
            Slots::Any,
        )
    },
];
