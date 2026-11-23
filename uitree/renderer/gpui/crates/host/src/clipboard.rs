//! The platform clipboard (transfer layer).
//!
//! A client write to `clipboard` reaches the renderer as
//! `UIT_CMD_CLIPBOARD`, with the text in the command's `answer` field, and
//! goes to the platform here. The other direction (the platform clipboard
//! changing under the app) has no ABI call yet: uitreefs mirrored it into
//! the tree on a timer. Until the core takes it, [`poll`] only remembers
//! what the platform holds.

use std::cell::RefCell;
use std::rc::Rc;

use gpui::{App, ClipboardItem};

use crate::runtime::Inner;

#[derive(Default)]
pub(crate) struct State {
    /// The platform clipboard's text, last polled or written.
    platform: RefCell<Option<String>>,
}

/// The client wrote `clipboard`: put it on the platform.
pub(crate) fn write(inner: &Rc<Inner>, text: &str, cx: &mut App) {
    cx.write_to_clipboard(ClipboardItem::new_string(text.to_string()));
    *inner.clipboard.platform.borrow_mut() = Some(text.to_string());
}

/// Notes a platform clipboard change.
pub(crate) fn poll(inner: &Rc<Inner>, cx: &mut App) {
    if inner.quitting.get() {
        return;
    }
    let now = cx.read_from_clipboard().and_then(|i| i.text());
    if *inner.clipboard.platform.borrow() != now {
        *inner.clipboard.platform.borrow_mut() = now;
    }
}
