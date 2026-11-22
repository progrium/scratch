//! W6d: the `edit` group. See `catalog::edit` for the specs.
//!
//! - `editor` ([`editor`]): GPUI Kit's code editor in an [`EditorNode`]
//!   entity that mirrors `value` and `selection`, sends `change`, `cursor`
//!   and `save`, and turns completion and hover lookups into `complete` and
//!   `hover` requests answered through the `completions` and `hover` files.
//! - `markdown`, `html`, `bubble`, `message-list` ([`rich`]): GPUI Kit's
//!   `TextView`, `Bubble`, `Message` and `MessageScroller`.
//! - `diff` ([`diff`]): GPUI Kit's `Diff`, from a patch or from `old`/`new`.
#[allow(unused_imports)]
use crate::*;

pub mod diff;
pub mod editor;
pub mod rich;

pub use editor::EditorNode;

pub fn register(reg: &mut ComponentRegistry) {
    reg.add(editor::EditorComponent);
    reg.add(rich::Markdown);
    reg.add(rich::Html);
    reg.add(rich::BubbleComponent);
    reg.add(rich::MessageList);
    reg.add(diff::DiffComponent);
}

/// A spec from this group by name.
pub(crate) fn spec(name: &str) -> &'static catalog::TypeSpec {
    catalog::edit::SPECS
        .iter()
        .find(|s| s.name == name)
        .unwrap_or_else(|| panic!("no edit spec {name}"))
}

/// The answer for a verb a component doesn't take (the tree has already
/// checked the verb against the spec, so this is for request answers).
pub(crate) fn no_verb(cmd: &proto::Command) -> Result<(), proto::Error> {
    if cmd.props.iter().any(|(k, _)| k == "seq") {
        return Ok(());
    }
    Err(proto::Error::new(
        proto::ErrorKind::UnknownCommand,
        cmd.verb.clone(),
    ))
}

/// A node's state entity as `T`.
pub(crate) fn entity<T: 'static>(state: Option<&gpui::AnyEntity>) -> Option<gpui::Entity<T>> {
    state.and_then(|s| s.clone().downcast::<T>().ok())
}

/// A prop as text, keeping every byte (multi-line files keep their newlines).
pub(crate) fn raw_text(node: &NodeView, file: &str) -> String {
    node.prop(file)
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default()
}

/// A prop as a number.
pub(crate) fn number(node: &NodeView, file: &str) -> Option<f32> {
    node.text(file).and_then(|s| s.trim().parse().ok())
}

#[cfg(test)]
mod tests;
