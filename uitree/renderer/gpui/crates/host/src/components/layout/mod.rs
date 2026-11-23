//! W6d: the `layout` group. See `catalog::layout` for the specs.
//!
//! - `accordion`/`accordion-item`, `collapsible`, `group-box`, `separator`
//!   and `grid` ([`basic`]): render from their files; the user's clicks
//!   mirror the file and send `change`.
//! - `resizable`/`panel` ([`resizable`]): GPUI Kit's resizable panel group.
//! - `dock`/`dock-panel` ([`dock`]): GPUI Kit's `DockArea`, with the layout
//!   readable and writable as JSON.
#[allow(unused_imports)]
use crate::*;

pub mod basic;
pub mod dock;
pub mod resizable;

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(basic::AccordionComponent);
    reg.add(basic::AccordionItemComponent);
    reg.add(basic::CollapsibleComponent);
    reg.add(basic::GroupBoxComponent);
    reg.add(basic::SeparatorComponent);
    reg.add(basic::GridComponent);
    reg.add(resizable::ResizableComponent);
    reg.add(resizable::PanelComponent);
    reg.add(dock::DockComponent);
    reg.add(dock::DockPanelComponent);
}

/// A spec from this group by name.
pub(crate) fn spec(name: &str) -> &'static crate::Spec {
    crate::spec::must(name)
}

pub(crate) use super::edit::{entity, no_verb, number};

// uitreefs-spelled render tests: not built until they are ported to 0.2
// as the core serves what they need (README § Tests).
#[cfg(any())]
mod tests;
