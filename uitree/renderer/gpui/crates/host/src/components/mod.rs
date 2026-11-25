//! Component groups. Each group owns its directory and its `register`; this
//! file is already wired and nobody needs to edit it.
pub mod data;
pub mod edit;
pub mod forms;
pub mod layout;
pub mod nav;
pub mod overlays;
pub mod terminal;
pub mod web;

use crate::ComponentRegistry;

pub fn register(reg: &mut ComponentRegistry) {
    forms::register(reg);
    nav::register(reg);
    overlays::register(reg);
    data::register(reg);
    edit::register(reg);
    layout::register(reg);
    web::register(reg);
    terminal::register(reg);
}
