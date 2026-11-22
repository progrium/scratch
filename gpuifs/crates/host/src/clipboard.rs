//! W7: `clipboard` and `clipboard-files` (DESIGN § Clipboard).
//!
//! The root `clipboard` file is the platform clipboard as text, and
//! `clipboard-files` the paths on it, one per line. A client write reaches
//! the platform through `HostCmd::Clipboard` ([`write`]). The other way, the
//! host polls the platform on its 100 ms tick ([`poll`]) and mirrors a change
//! into the tree, since reads are served from the snapshot on the 9P thread
//! and never reach the main thread.
//!
//! Paths are passed through as they are: a guest path written to
//! `clipboard-files` goes to the platform unchanged, and host paths copied in
//! another app show up as host paths.

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use gpui::{App, ClipboardEntry, ClipboardItem, ExternalPaths};
use tree::{Bytes, Via};

use crate::runtime::Inner;

/// What the host last saw on each side.
#[derive(Default)]
pub(crate) struct State {
    /// The platform clipboard as `(text, files)` file bytes, last polled or written.
    platform: RefCell<Option<(Bytes, Bytes)>>,
    /// The tree's `clipboard` and `clipboard-files` as last pushed to the platform.
    pushed: RefCell<(Bytes, Bytes)>,
}

/// A clipboard item as `(clipboard, clipboard-files)` bytes.
fn files_of(item: &ClipboardItem) -> (Bytes, Bytes) {
    let text = item.text().unwrap_or_default();
    let mut files = String::new();
    for e in &item.entries {
        if let ClipboardEntry::ExternalPaths(p) = e {
            for path in p.paths() {
                files.push_str(&path.to_string_lossy());
                files.push('\n');
            }
        }
    }
    (Bytes::from(text), Bytes::from(files))
}

fn tree_files(inner: &Inner) -> (Bytes, Bytes) {
    let t = inner.tree.borrow();
    (
        t.root_file("clipboard").unwrap_or_default(),
        t.root_file("clipboard-files").unwrap_or_default(),
    )
}

/// The client wrote `clipboard` or `clipboard-files`: put it on the platform.
pub(crate) fn write(inner: &Rc<Inner>, cx: &mut App) {
    let (text, files) = tree_files(inner);
    let (old_text, old_files) = inner.clipboard.pushed.borrow().clone();
    let item = if files != old_files {
        let paths: Vec<PathBuf> = String::from_utf8_lossy(&files)
            .lines()
            .filter(|l| !l.is_empty())
            .map(PathBuf::from)
            .collect();
        ClipboardItem {
            entries: vec![ClipboardEntry::ExternalPaths(ExternalPaths(paths.into()))],
        }
    } else if text != old_text {
        ClipboardItem::new_string(String::from_utf8_lossy(&text).into_owned())
    } else {
        return;
    };
    *inner.clipboard.pushed.borrow_mut() = (text, files);
    cx.write_to_clipboard(item);
    // What the platform holds now, so the next poll doesn't echo it back.
    let now = cx.read_from_clipboard().map(|i| files_of(&i));
    *inner.clipboard.platform.borrow_mut() = now;
}

/// Mirrors a platform clipboard change into the tree.
pub(crate) fn poll(inner: &Rc<Inner>, cx: &mut App) {
    if inner.quitting.get() {
        return;
    }
    let now = cx.read_from_clipboard().map(|i| files_of(&i));
    if *inner.clipboard.platform.borrow() == now {
        return;
    }
    *inner.clipboard.platform.borrow_mut() = now.clone();
    let Some((text, files)) = now else {
        return;
    };
    let (cur_text, cur_files) = tree_files(inner);
    let mut changed = false;
    {
        let mut t = inner.tree.borrow_mut();
        if text != cur_text {
            t.mirror("", "clipboard", text.clone(), Via::User);
            changed = true;
        }
        if files != cur_files {
            t.mirror("", "clipboard-files", files.clone(), Via::User);
            changed = true;
        }
    }
    *inner.clipboard.pushed.borrow_mut() = (text, files);
    if changed {
        inner.publish();
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use gpui::{ClipboardEntry, ClipboardItem, TestAppContext};

    use crate::testing::Harness;

    #[gpui::test]
    fn client_writes_reach_the_platform(cx: &mut TestAppContext) {
        let mut h = Harness::new(cx);
        h.write("clipboard", "copied text\n");
        let item = h.cx.read_from_clipboard().unwrap();
        assert_eq!(item.text().as_deref(), Some("copied text\n"));
        assert_eq!(h.read("clipboard").as_deref(), Some("copied text\n"));
        // The next poll doesn't echo it back as a change.
        h.advance(Duration::from_millis(250));
        assert_eq!(h.read("clipboard").as_deref(), Some("copied text\n"));

        h.write("clipboard-files", "/tmp/a.txt\n/tmp/b.txt\n");
        let item = h.cx.read_from_clipboard().unwrap();
        let paths: Vec<String> = item
            .entries
            .iter()
            .filter_map(|e| match e {
                ClipboardEntry::ExternalPaths(p) => Some(p.paths().to_vec()),
                _ => None,
            })
            .flatten()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        assert_eq!(paths, ["/tmp/a.txt", "/tmp/b.txt"]);
        assert_eq!(
            h.read("clipboard-files").as_deref(),
            Some("/tmp/a.txt\n/tmp/b.txt\n")
        );
    }

    #[gpui::test]
    fn platform_changes_are_mirrored(cx: &mut TestAppContext) {
        let mut h = Harness::new(cx);
        h.write("clipboard", "old");
        h.cx.write_to_clipboard(ClipboardItem::new_string("from another app".into()));
        h.advance(Duration::from_millis(250));
        assert_eq!(h.read("clipboard").as_deref(), Some("from another app"));
        assert_eq!(h.read("clipboard-files").as_deref(), Some(""));
    }
}
