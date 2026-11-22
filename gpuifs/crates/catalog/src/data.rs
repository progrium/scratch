//! W6c: the data display group (DESIGN § Data display).
//!
//! `list`, `virtual-list`, `table`, `tree`, `description-list`, `badge`,
//! `tag`, `avatar`, `avatar-group`, `kbd`, `progress`, `spinner`,
//! `skeleton`, `shimmer`, `empty`, `alert`, `chart`.
//!
//! Choices made here where DESIGN.md is silent:
//!
//! - Selection is mirrored to a `value` file: item IDs (space-separated when
//!   `multiple=on`) for `list`, `virtual-list` and `tree`; the row ID, then
//!   the column ID when `selectable=cell`, for `table`. A client write sets
//!   the selection.
//! - `table` keeps the sort the user asked for in `sort` (`col asc|desc`),
//!   which a client may also write to draw the indicator. With `sorted=on`
//!   the host sorts `rows` by it for display; the file itself is untouched.
//! - Column widths after a user resize are mirrored to `widths`
//!   (`col width` lines); the `resize col= width=` event is a state event.
//! - `virtual-list` is `list` for rows of known height: `item_size` (points)
//!   and a `row` template are all it needs, and it skips measuring.
//! - `progress` `value` is a whole number 0 to 100, or empty.
//! - `chart` `data` is TSV with a header row, kept as written. `x` and `y`
//!   name header columns (the first two when unset); `y` may list several
//!   names, and this version draws the first.
//! - `tree` `expanded` names IDs; one not in `items` is kept and ignored
//!   (the catalog can't check one file against another).
use crate::*;

const fn p(name: &'static str, kind: PropKind) -> PropSpec {
    PropSpec {
        name,
        kind,
        default: None,
    }
}

const fn d(name: &'static str, kind: PropKind, default: &'static str) -> PropSpec {
    PropSpec {
        name,
        kind,
        default: Some(default),
    }
}

const fn ev(name: &'static str, kind: EventKind) -> EventSpec {
    EventSpec { name, kind }
}

const fn component(name: &'static str, props: &'static [PropSpec], slots: Slots) -> TypeSpec {
    TypeSpec {
        name,
        tier: Tier::Component,
        props,
        verbs: &[],
        events: &[],
        slots,
        variants: &[],
        sizable: false,
    }
}

use EventKind::{Action, State};
use PropKind::{Bool, Bytes, Data, Enum, Number, Text, Word};

/// `progress` `value`: "0" to "100".
pub static PERCENT: &[&str] = &[
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16",
    "17", "18", "19", "20", "21", "22", "23", "24", "25", "26", "27", "28", "29", "30", "31",
    "32", "33", "34", "35", "36", "37", "38", "39", "40", "41", "42", "43", "44", "45", "46",
    "47", "48", "49", "50", "51", "52", "53", "54", "55", "56", "57", "58", "59", "60", "61",
    "62", "63", "64", "65", "66", "67", "68", "69", "70", "71", "72", "73", "74", "75", "76",
    "77", "78", "79", "80", "81", "82", "83", "84", "85", "86", "87", "88", "89", "90", "91",
    "92", "93", "94", "95", "96", "97", "98", "99", "100",
];

/// GPUI Kit `ColorName`s, which `tag` takes as variant words.
pub static COLOR_NAMES: &[&str] = &[
    "amber", "black", "blue", "cyan", "emerald", "fuchsia", "gray", "green", "indigo", "lime",
    "neutral", "orange", "pink", "purple", "red", "rose", "sky", "teal", "violet", "white",
    "yellow",
];

const TAG_VARIANTS: &[&str] = &[
    "primary", "secondary", "danger", "success", "warning", "info", "outline", "amber", "black",
    "blue", "cyan", "emerald", "fuchsia", "gray", "green", "indigo", "lime", "neutral", "orange",
    "pink", "purple", "red", "rose", "sky", "teal", "violet", "white", "yellow",
];

const ALERT_VARIANTS: &[&str] = &["info", "success", "warning", "error"];

const LIST_PROPS: &[PropSpec] = &[
    p("items", Data(LineFormat::Items)),
    p("fields", Text),
    p("value", Text),
    d("selectable", Bool, "off"),
    d("multiple", Bool, "off"),
    d("searchable", Bool, "off"),
    d("loading", Bool, "off"),
    p("query", Text),
];

const LIST_EVENTS: &[EventSpec] = &[
    ev("select", State),
    ev("open", Action),
    ev("scrolled_to_end", Action),
];

pub static SPECS: &[TypeSpec] = &[
    TypeSpec {
        events: LIST_EVENTS,
        ..component("list", LIST_PROPS, Slots::Named(&["row"]))
    },
    TypeSpec {
        events: LIST_EVENTS,
        ..component(
            "virtual-list",
            &[
                p("items", Data(LineFormat::Items)),
                p("fields", Text),
                p("value", Text),
                d("item_size", Number, "32"),
                d("selectable", Bool, "off"),
                d("multiple", Bool, "off"),
                d("loading", Bool, "off"),
            ],
            Slots::Named(&["row"]),
        )
    },
    TypeSpec {
        events: &[
            ev("select", State),
            ev("sort", Action),
            ev("open", Action),
            ev("resize", State),
            ev("scrolled_to_end", Action),
        ],
        sizable: true,
        ..component(
            "table",
            &[
                p("columns", Data(LineFormat::Columns)),
                p("rows", Data(LineFormat::Rows)),
                p("value", Text),
                p("sort", Text),
                p("widths", Text),
                d("stripe", Bool, "off"),
                d("selectable", Enum(&["row", "cell", "off"]), "row"),
                d("resizable", Bool, "off"),
                d("sortable", Bool, "off"),
                d("sorted", Bool, "off"),
                d("loading", Bool, "off"),
                d("bordered", Bool, "on"),
            ],
            Slots::None,
        )
    },
    TypeSpec {
        events: &[ev("select", State), ev("expand", Action), ev("open", Action)],
        ..component(
            "tree",
            &[
                p("items", Data(LineFormat::TreeItems)),
                p("expanded", Text),
                p("value", Text),
                d("selectable", Bool, "off"),
                d("multiple", Bool, "off"),
            ],
            Slots::None,
        )
    },
    TypeSpec {
        sizable: true,
        ..component(
            "description-list",
            &[
                p("items", Data(LineFormat::DescItems)),
                d("columns", Number, "3"),
                d("bordered", Bool, "off"),
                d("layout", Enum(&["h", "v"]), "h"),
                p("label_width", Number),
            ],
            Slots::None,
        )
    },
    TypeSpec {
        sizable: true,
        ..component(
            "badge",
            &[
                p("count", Number),
                d("dot", Bool, "off"),
                d("max", Number, "99"),
                p("icon", Word),
            ],
            Slots::Any,
        )
    },
    TypeSpec {
        events: &[ev("close", Action)],
        variants: TAG_VARIANTS,
        sizable: true,
        ..component(
            "tag",
            &[p("label", Text), d("closable", Bool, "off")],
            Slots::None,
        )
    },
    TypeSpec {
        sizable: true,
        ..component(
            "avatar",
            &[p("src", Text), p("name", Text)],
            Slots::None,
        )
    },
    TypeSpec {
        sizable: true,
        ..component(
            "avatar-group",
            &[p("max", Number)],
            Slots::ChildTypes(&["avatar"]),
        )
    },
    component("kbd", &[p("key", Word)], Slots::None),
    TypeSpec {
        sizable: true,
        ..component(
            "progress",
            &[
                p("value", Enum(PERCENT)),
                d("variant", Enum(&["bar", "circle"]), "bar"),
            ],
            Slots::None,
        )
    },
    TypeSpec {
        sizable: true,
        ..component("spinner", &[], Slots::None)
    },
    TypeSpec {
        sizable: true,
        ..component("skeleton", &[d("secondary", Bool, "off")], Slots::None)
    },
    TypeSpec {
        sizable: true,
        ..component("shimmer", &[p("text", Text)], Slots::None)
    },
    component(
        "empty",
        &[p("title", Text), p("description", Text), p("icon", Word)],
        Slots::Any,
    ),
    TypeSpec {
        events: &[ev("close", Action)],
        variants: ALERT_VARIANTS,
        sizable: true,
        ..component(
            "alert",
            &[
                p("title", Text),
                p("text", Text),
                d("variant", Enum(&["info", "success", "warning", "error"]), "info"),
                d("closable", Bool, "off"),
                d("banner", Bool, "off"),
                p("icon", Word),
            ],
            Slots::None,
        )
    },
    TypeSpec {
        events: &[ev("select", State)],
        ..component(
            "chart",
            &[
                d("kind", Enum(&["line", "bar", "area", "pie"]), "line"),
                p("data", Bytes),
                p("x", Word),
                p("y", Text),
            ],
            Slots::None,
        )
    },
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_design_row_has_a_spec() {
        for n in [
            "list",
            "virtual-list",
            "table",
            "tree",
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
            "alert",
            "chart",
        ] {
            let s = crate::get(n).unwrap_or_else(|| panic!("{n}"));
            assert_eq!(s.tier, Tier::Component, "{n}");
        }
    }

    #[test]
    fn names_are_unique_and_events_named() {
        let mut seen = std::collections::HashSet::new();
        for s in SPECS {
            assert!(seen.insert(s.name), "{}", s.name);
            for e in s.events {
                assert!(!e.name.is_empty());
            }
            let mut props = std::collections::HashSet::new();
            for p in s.props {
                assert!(props.insert(p.name), "{}/{}", s.name, p.name);
            }
        }
    }

    #[test]
    fn percent_is_0_to_100() {
        assert_eq!(PERCENT.len(), 101);
        for (i, s) in PERCENT.iter().enumerate() {
            assert_eq!(s.parse::<usize>().unwrap(), i);
        }
    }

    #[test]
    fn design_events() {
        let ev = |t: &str, e: &str| {
            crate::get(t)
                .unwrap()
                .events
                .iter()
                .find(|x| x.name == e)
                .map(|x| x.kind)
        };
        assert_eq!(ev("list", "select"), Some(EventKind::State));
        assert_eq!(ev("list", "scrolled_to_end"), Some(EventKind::Action));
        assert_eq!(ev("table", "sort"), Some(EventKind::Action));
        assert_eq!(ev("table", "open"), Some(EventKind::Action));
        assert_eq!(ev("tree", "expand"), Some(EventKind::Action));
        assert_eq!(ev("tag", "close"), Some(EventKind::Action));
        assert_eq!(ev("alert", "close"), Some(EventKind::Action));
        assert_eq!(ev("chart", "select"), Some(EventKind::State));
    }
}
