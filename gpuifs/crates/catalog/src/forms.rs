//! W6a: button ... field (DESIGN § Buttons and form controls).
//!
//! Rules every valued control here follows:
//!
//! - **Uncontrolled by default.** The host changes `value` itself and sends
//!   `change`. With `controlled=on` the host sends `change value=...` and
//!   leaves `value` alone until the client writes it.
//! - `disabled` on any control greys it out and stops its events.
//! - An `input`'s `change` carries no text; the client reads `value`.
//!   With `flags=secret` the trace redacts `value` writes.
use crate::*;

const fn p(name: &'static str, kind: PropKind) -> PropSpec {
    PropSpec { name, kind, default: None }
}
const fn d(name: &'static str, kind: PropKind, default: &'static str) -> PropSpec {
    PropSpec { name, kind, default: Some(default) }
}
const fn ev(name: &'static str, kind: EventKind) -> EventSpec {
    EventSpec { name, kind }
}

const ON_OFF: PropKind = PropKind::Enum(&["on", "off"]);
const DIR: PropKind = PropKind::Enum(&["h", "v"]);

const CHANGE: EventSpec = ev("change", EventKind::State);
const COMMIT: EventSpec = ev("commit", EventKind::Action);
const CLICK: EventSpec = ev("click", EventKind::Action);
const SUBMIT: EventSpec = ev("submit", EventKind::Action);
const FOCUS: EventSpec = ev("focus", EventKind::State);
const BLUR: EventSpec = ev("blur", EventKind::State);

/// GPUI Kit `ButtonVariant`s plus the `outline` modifier.
pub const BUTTON_VARIANTS: &[&str] = &[
    "primary",
    "secondary",
    "danger",
    "info",
    "success",
    "warning",
    "ghost",
    "link",
    "outline",
];
/// GPUI Kit `ToggleVariant`s.
pub const TOGGLE_VARIANTS: &[&str] = &["ghost", "outline"];

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
        sizable: true,
    }
}

const INPUT_PROPS: &[PropSpec] = &[
    p("value", PropKind::Text),
    p("placeholder", PropKind::Text),
    p("mask", PropKind::Text),
    p("max_len", PropKind::Number),
    // `secret` `cleanable` `readonly`
    p("flags", PropKind::Text),
    p("disabled", PropKind::Bool),
    p("controlled", PropKind::Bool),
];
const INPUT_EVENTS: &[EventSpec] = &[CHANGE, SUBMIT, FOCUS, BLUR];

const DATE_PROPS: &[PropSpec] = &[
    // An ISO date `2026-11-21`, or `start end` with `range=on`.
    p("value", PropKind::Text),
    p("range", PropKind::Bool),
    p("min", PropKind::Text),
    p("max", PropKind::Text),
    // `on` for GPUI Kit's default presets.
    p("presets", PropKind::Text),
    p("placeholder", PropKind::Text),
    p("disabled", PropKind::Bool),
    p("controlled", PropKind::Bool),
];

pub static SPECS: &[TypeSpec] = &[
    // Children are the button's content, after its icon and label.
    TypeSpec {
        variants: BUTTON_VARIANTS,
        slots: Slots::Any,
        ..component(
            "button",
            &[
                p("label", PropKind::Text),
                p("icon", PropKind::Word),
                p("loading", PropKind::Bool),
                p("disabled", PropKind::Bool),
                p("selected", PropKind::Bool),
            ],
            &[CLICK],
        )
    },
    // Children are buttons; `value` is the selected children's names.
    TypeSpec {
        variants: BUTTON_VARIANTS,
        slots: Slots::ChildTypes(&["button"]),
        ..component(
            "button-group",
            &[
                p("multiple", PropKind::Bool),
                p("value", PropKind::Text),
                d("dir", DIR, "h"),
                p("disabled", PropKind::Bool),
                p("controlled", PropKind::Bool),
            ],
            &[CHANGE],
        )
    },
    // `menu` is item lines in the menus grammar (§ Actions, keymaps and menus).
    TypeSpec {
        variants: BUTTON_VARIANTS,
        ..component(
            "dropdown-button",
            &[
                p("label", PropKind::Text),
                p("icon", PropKind::Word),
                p("menu", PropKind::Data(LineFormat::Menu)),
                p("disabled", PropKind::Bool),
            ],
            &[CLICK, ev("action", EventKind::Action)],
        )
    },
    component(
        "checkbox",
        &[
            p("label", PropKind::Text),
            d("value", PropKind::Enum(&["on", "off", "mixed"]), "off"),
            p("disabled", PropKind::Bool),
            p("controlled", PropKind::Bool),
        ],
        &[CHANGE],
    ),
    component(
        "radio-group",
        &[
            p("items", PropKind::Data(LineFormat::RadioItems)),
            p("value", PropKind::Word),
            d("dir", DIR, "v"),
            p("disabled", PropKind::Bool),
            p("controlled", PropKind::Bool),
        ],
        &[CHANGE],
    ),
    component(
        "switch",
        &[
            p("label", PropKind::Text),
            d("value", ON_OFF, "off"),
            p("disabled", PropKind::Bool),
            p("controlled", PropKind::Bool),
        ],
        &[CHANGE],
    ),
    // A pressed/unpressed button (GPUI Kit `Toggle`).
    TypeSpec {
        variants: TOGGLE_VARIANTS,
        ..component(
            "toggle",
            &[
                p("label", PropKind::Text),
                p("icon", PropKind::Word),
                d("value", ON_OFF, "off"),
                p("disabled", PropKind::Bool),
                p("controlled", PropKind::Bool),
            ],
            &[CHANGE],
        )
    },
    // `value` is one number, or `lo hi` for a range.
    TypeSpec {
        sizable: false,
        ..component(
            "slider",
            &[
                d("min", PropKind::Number, "0"),
                d("max", PropKind::Number, "100"),
                d("step", PropKind::Number, "1"),
                d("value", PropKind::Number, "0"),
                d("dir", DIR, "h"),
                p("disabled", PropKind::Bool),
                p("controlled", PropKind::Bool),
            ],
            &[CHANGE, COMMIT],
        )
    },
    TypeSpec {
        slots: Slots::Named(&["prefix", "suffix"]),
        ..component("input", INPUT_PROPS, INPUT_EVENTS)
    },
    // `auto_grow=min,max` in rows.
    component(
        "textarea",
        &[
            // Multi-line: kept as written, trailing newline and all.
            p("value", PropKind::Bytes),
            p("placeholder", PropKind::Text),
            p("max_len", PropKind::Number),
            p("flags", PropKind::Text),
            p("rows", PropKind::Number),
            p("auto_grow", PropKind::Number),
            p("disabled", PropKind::Bool),
            p("controlled", PropKind::Bool),
        ],
        INPUT_EVENTS,
    ),
    TypeSpec {
        slots: Slots::Named(&["prefix", "suffix"]),
        ..component(
            "number-input",
            &[
                p("value", PropKind::Number),
                p("min", PropKind::Number),
                p("max", PropKind::Number),
                d("step", PropKind::Number, "1"),
                p("placeholder", PropKind::Text),
                p("disabled", PropKind::Bool),
                p("controlled", PropKind::Bool),
            ],
            &[CHANGE, SUBMIT, FOCUS, BLUR],
        )
    },
    component(
        "otp-input",
        &[
            d("length", PropKind::Number, "6"),
            p("value", PropKind::Text),
            p("flags", PropKind::Text),
            p("disabled", PropKind::Bool),
            p("controlled", PropKind::Bool),
        ],
        &[CHANGE, ev("complete", EventKind::Action)],
    ),
    // `items` lines: `id<TAB>label[<TAB>icon=..][<TAB>disabled]`, `# group`, `-`.
    component(
        "select",
        &[
            p("items", PropKind::Data(LineFormat::Items)),
            p("value", PropKind::Word),
            p("placeholder", PropKind::Text),
            p("searchable", PropKind::Bool),
            p("disabled", PropKind::Bool),
            p("controlled", PropKind::Bool),
        ],
        &[CHANGE],
    ),
    // `value` is item ids, space-separated with `multiple=on`; `query` is
    // what the user typed, for clients that filter `items` themselves.
    component(
        "combobox",
        &[
            p("items", PropKind::Data(LineFormat::Items)),
            p("value", PropKind::Text),
            p("multiple", PropKind::Bool),
            p("placeholder", PropKind::Text),
            p("query", PropKind::ReadOnly),
            p("disabled", PropKind::Bool),
            p("controlled", PropKind::Bool),
        ],
        &[CHANGE, ev("query", EventKind::State)],
    ),
    component("date-picker", DATE_PROPS, &[CHANGE]),
    TypeSpec {
        sizable: false,
        ..component("calendar", DATE_PROPS, &[CHANGE])
    },
    // `value` is `#rrggbbaa`; `swatches` is colors, blank-separated.
    component(
        "color-picker",
        &[
            p("value", PropKind::Text),
            p("swatches", PropKind::Text),
            p("disabled", PropKind::Bool),
            p("controlled", PropKind::Bool),
        ],
        &[CHANGE, COMMIT],
    ),
    component(
        "rating",
        &[
            d("max", PropKind::Number, "5"),
            d("value", PropKind::Number, "0"),
            p("disabled", PropKind::Bool),
            p("controlled", PropKind::Bool),
        ],
        &[CHANGE],
    ),
    // Children are `field`s. `submit` comes from enter in any of its inputs.
    // `layout` is `v` when unset (no default, so `tree` prints what was written).
    TypeSpec {
        slots: Slots::ChildTypes(&["field"]),
        ..component(
            "form",
            &[p("layout", DIR), p("label_width", PropKind::Number)],
            &[SUBMIT],
        )
    },
    // A label, description and error around one control child.
    TypeSpec {
        slots: Slots::Any,
        sizable: false,
        ..component(
            "field",
            &[
                p("label", PropKind::Text),
                p("description", PropKind::Text),
                p("error", PropKind::Text),
                p("required", PropKind::Bool),
            ],
            &[],
        )
    },
];
