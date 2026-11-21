//! A `TypeSpec` for every element and component: the data the tree validates
//! writes against. Each group module owns its own `SPECS` slice, so the
//! threads that fill them never edit a shared file:
//!
//! | module      | owner |
//! | ----------- | ----- |
//! | `elements`  | W5b   |
//! | `forms`     | W6a   |
//! | `nav`       | W6b   |
//! | `overlays`  | W6b   |
//! | `data`      | W6c   |
//! | `edit`      | W6d   |
//! | `layout`    | W6d   |
//! | `canvas`    | W7    |

pub mod canvas;
pub mod data;
pub mod edit;
pub mod elements;
pub mod forms;
pub mod layout;
pub mod nav;
pub mod overlays;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    Element,
    Component,
    Overlay,
}

/// Which `proto::lines` format a data file holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineFormat {
    Items,
    Columns,
    Rows,
    TreeItems,
    DescItems,
    RadioItems,
    Menu,
    Keymap,
    CanvasOps,
    Diagnostics,
    Messages,
    Completions,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PropKind {
    Text,
    Word,
    Bool,
    Number,
    Enum(&'static [&'static str]),
    Data(LineFormat),
    Bytes,
    ReadOnly,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PropSpec {
    pub name: &'static str,
    pub kind: PropKind,
    pub default: Option<&'static str>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VerbSpec {
    pub name: &'static str,
    pub usage: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EventKind {
    State,
    Action,
    Request,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EventSpec {
    pub name: &'static str,
    pub kind: EventKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Slots {
    None,
    Any,
    Named(&'static [&'static str]),
    ChildTypes(&'static [&'static str]),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TypeSpec {
    pub name: &'static str,
    pub tier: Tier,
    pub props: &'static [PropSpec],
    pub verbs: &'static [VerbSpec],
    pub events: &'static [EventSpec],
    pub slots: Slots,
    pub variants: &'static [&'static str],
    pub sizable: bool,
}

/// Elements plus every group module.
pub fn all() -> impl Iterator<Item = &'static TypeSpec> {
    [
        elements::SPECS,
        forms::SPECS,
        nav::SPECS,
        overlays::SPECS,
        data::SPECS,
        edit::SPECS,
        layout::SPECS,
        canvas::SPECS,
    ]
    .into_iter()
    .flatten()
}

pub fn get(name: &str) -> Option<&'static TypeSpec> {
    all().find(|t| t.name == name)
}
