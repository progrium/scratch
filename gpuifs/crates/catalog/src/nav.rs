//! W6b: tabs, tab, sidebar, sidebar-group, sidebar-item, breadcrumb,
//! pagination, stepper, title-bar, toolbar, status-bar, link.
//!
//! DESIGN § Navigation. Choices the design leaves open:
//!
//! - `tabs` `value` must name one of its tabs once it has any (`not found`
//!   otherwise); with no `value` the first tab in `order` is selected.
//! - `tab` `close` is a request answered on the tab's `ctl` (`close seq=N`
//!   removes the tab, `keep seq=N` leaves it); the default is `close`.
//! - `pagination` `total` counts items, so the page count is
//!   `ceil(total / per_page)`; `page` counts from 1.
//! - `sidebar` `collapse value=on|off` follows `collapsed`, which the host
//!   mirrors when the user toggles it.
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

const DIR: PropKind = PropKind::Enum(&["h", "v"]);

pub static SPECS: &[TypeSpec] = &[
    // GPUI Kit's TabBar and its tabs' panels. The selected tab's children
    // are drawn below the bar.
    TypeSpec {
        variants: &["underline", "pill", "outline", "segmented", "folder"],
        sizable: true,
        ..component(
            "tabs",
            &[p("value", PropKind::Child)],
            &[ev("change", EventKind::State)],
            Slots::ChildTypes(&["tab"]),
        )
    },
    component(
        "tab",
        &[
            p("label", PropKind::Text),
            p("icon", PropKind::Word),
            p("closable", PropKind::Bool),
            p("disabled", PropKind::Bool),
        ],
        &[ev("close", EventKind::Request)],
        Slots::Any,
    ),
    component(
        "sidebar",
        &[
            p("collapsed", PropKind::Bool),
            pd("side", PropKind::Enum(&["left", "right"]), "left"),
            pd("collapsible", PropKind::Enum(&["icon", "off"]), "icon"),
        ],
        &[ev("collapse", EventKind::State)],
        Slots::NamedAnd(&["header", "footer"], &["sidebar-group"]),
    ),
    component(
        "sidebar-group",
        &[p("label", PropKind::Text)],
        &[],
        Slots::ChildTypes(&["sidebar-item"]),
    ),
    component(
        "sidebar-item",
        &[
            p("label", PropKind::Text),
            p("icon", PropKind::Word),
            p("active", PropKind::Bool),
            p("badge", PropKind::Text),
            p("disabled", PropKind::Bool),
        ],
        &[ev("click", EventKind::Action)],
        Slots::ChildTypes(&["sidebar-item"]),
    ),
    component(
        "breadcrumb",
        &[p("items", PropKind::Data(LineFormat::Items))],
        &[ev("click", EventKind::Action)],
        Slots::None,
    ),
    TypeSpec {
        sizable: true,
        ..component(
            "pagination",
            &[
                pd("page", PropKind::Number, "1"),
                pd("total", PropKind::Number, "0"),
                pd("per_page", PropKind::Number, "10"),
                p("disabled", PropKind::Bool),
            ],
            &[ev("change", EventKind::State)],
            Slots::None,
        )
    },
    TypeSpec {
        sizable: true,
        ..component(
            "stepper",
            &[
                p("items", PropKind::Data(LineFormat::Items)),
                p("value", PropKind::Word),
                pd("dir", DIR, "h"),
                p("disabled", PropKind::Bool),
            ],
            &[ev("change", EventKind::State)],
            Slots::None,
        )
    },
    // Writing a title-bar makes the window draw its own title bar
    // (`titlebar=custom` on the window). Window controls send `action`.
    component(
        "title-bar",
        &[p("title", PropKind::Text)],
        &[ev("action", EventKind::Action)],
        Slots::Any,
    ),
    TypeSpec {
        sizable: true,
        ..component("toolbar", &[p("disabled", PropKind::Bool)], &[], Slots::Any)
    },
    component(
        "status-bar",
        &[],
        &[],
        Slots::Named(&["left", "center", "right"]),
    ),
    component(
        "link",
        &[
            p("label", PropKind::Text),
            p("href", PropKind::Text),
            p("disabled", PropKind::Bool),
        ],
        &[ev("click", EventKind::Action)],
        Slots::None,
    ),
];
