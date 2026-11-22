//! A `gpui::TestAppContext` harness: build a tree with ops, render it,
//! simulate input, read files and events back. W6 and W7 reuse it.
//!
//! ```ignore
//! #[gpui::test]
//! fn click_sends_click(cx: &mut gpui::TestAppContext) {
//!     let mut h = Harness::new(cx);
//!     h.ctl("", "window main");
//!     h.ctl("windows/main/root", "new div card tag=open:42");
//!     h.write("windows/main/root/card/on", "click");
//!     let mut ev = h.subscribe("events");
//!     h.click("windows/main/root/card");
//!     assert!(h.events(&mut ev).iter().any(|l| l.starts_with("click ")));
//! }
//! ```

use std::rc::Rc;

use gpui::{AnyWindowHandle, Modifiers, TestAppContext, VisualTestContext, point, px};
use tree::{FsPath, Op, SessionId, SubEnd, Subscription};

use crate::runtime::{self, Inner};
use crate::{HostOptions, NodeView};

pub struct Harness {
    pub cx: TestAppContext,
    inner: Rc<Inner>,
    session: SessionId,
}

impl Harness {
    /// Initializes GPUI Kit and the host in a test app. No windows yet.
    pub fn new(cx: &mut TestAppContext) -> Self {
        let inner = cx.update(|cx| {
            gpui_component::init(cx);
            let (inner, _backend) = runtime::install(
                HostOptions {
                    title: Some("test".into()),
                    keep: true,
                },
                cx,
            );
            inner
        });
        Harness {
            cx: cx.clone(),
            inner,
            session: SessionId(1),
        }
    }

    /// Applies an op as the 9P server would, then lets GPUI settle.
    pub fn op(&mut self, op: Op) -> Result<(), proto::Error> {
        let inner = self.inner.clone();
        let s = self.session;
        let r = self.cx.update(|cx| runtime::apply_now(&inner, s, op, cx));
        self.settle();
        r
    }

    /// Writes a file (`ctl`: one write; text and data files: the whole value).
    pub fn try_write(&mut self, path: &str, data: &str) -> Result<(), proto::Error> {
        self.op(Op::Write {
            path: FsPath::new(path),
            data: data.as_bytes().to_vec().into(),
        })
    }

    /// As `try_write`, panicking on an error.
    #[track_caller]
    pub fn write(&mut self, path: &str, data: &str) {
        if let Err(e) = self.try_write(path, data) {
            panic!("write {path}: {e}");
        }
    }

    /// One `ctl` write on a directory (`""` for the root `ctl`).
    #[track_caller]
    pub fn ctl(&mut self, dir: &str, line: &str) {
        let p = if dir.is_empty() {
            "ctl".to_string()
        } else {
            format!("{dir}/ctl")
        };
        self.write(&p, line);
    }

    pub fn mkdir(&mut self, path: &str) -> Result<(), proto::Error> {
        self.op(Op::Mkdir {
            path: FsPath::new(path),
        })
    }

    pub fn remove(&mut self, path: &str) -> Result<(), proto::Error> {
        self.op(Op::Remove {
            path: FsPath::new(path),
        })
    }

    /// Reads a file from the published snapshot.
    pub fn read(&self, path: &str) -> Option<String> {
        let snap = self.inner.snapshot.lock().unwrap().clone();
        snap.read(&FsPath::new(path))
            .map(|b| String::from_utf8_lossy(&b).into_owned())
    }

    /// Opens an `events` file.
    pub fn subscribe(&self, events_file: &str) -> Subscription {
        self.inner
            .tree
            .borrow()
            .bus()
            .subscribe(&FsPath::new(events_file))
            .expect("subscribe")
    }

    /// Every line queued on a subscription (without its trailing newline).
    pub fn events(&mut self, sub: &mut Subscription) -> Vec<String> {
        self.settle();
        let mut out = Vec::new();
        while let Some(r) = sub.try_read(64 * 1024) {
            match r {
                Ok(b) => out.extend(
                    String::from_utf8_lossy(&b)
                        .lines()
                        .map(str::to_string),
                ),
                Err(SubEnd::Eof) => {
                    out.push("<eof>".into());
                    break;
                }
                Err(SubEnd::ShortRead) => break,
            }
        }
        out
    }

    /// A window's GPUI handle.
    pub fn window(&self, win: &str) -> AnyWindowHandle {
        self.inner
            .windows
            .borrow()
            .get(win)
            .map(|w| w.handle)
            .unwrap_or_else(|| panic!("no window {win}"))
    }

    pub fn has_window(&self, win: &str) -> bool {
        self.inner.windows.borrow().contains_key(win)
    }

    /// A `VisualTestContext` for simulating input into a window.
    pub fn visual(&self, win: &str) -> VisualTestContext {
        VisualTestContext::from_window(self.window(win), &self.cx)
    }

    /// Runs pending work, then draws every open window.
    pub fn settle(&mut self) {
        self.cx.run_until_parked();
        let wins: Vec<AnyWindowHandle> = self.inner.windows.borrow().values().map(|w| w.handle).collect();
        for w in wins {
            let _ = self.cx.update(|cx| w.update(cx, |_, window, _| window.refresh()));
        }
        self.cx.run_until_parked();
    }

    /// A node as the renderer sees it.
    pub fn node(&self, path: &str) -> NodeView {
        self.inner
            .node_view(path)
            .unwrap_or_else(|| panic!("no node {path}"))
    }

    /// `x y w h` from the node's `bounds` file.
    pub fn bounds(&self, path: &str) -> [f32; 4] {
        let s = self.read(&format!("{path}/bounds")).unwrap_or_default();
        let v: Vec<f32> = s.split_whitespace().filter_map(|x| x.parse().ok()).collect();
        match v[..] {
            [x, y, w, h] => [x, y, w, h],
            _ => panic!("{path}/bounds: {s:?}"),
        }
    }

    /// Clicks the middle of a node (full path).
    pub fn click(&mut self, path: &str) {
        let [x, y, w, h] = self.bounds(path);
        let win = path.split('/').nth(1).unwrap_or("main").to_string();
        let mut v = self.visual(&win);
        let p = point(px(x + w / 2.), px(y + h / 2.));
        v.simulate_mouse_move(p, None, Modifiers::none());
        v.simulate_click(p, Modifiers::none());
        self.settle();
    }

    /// Moves the mouse to the middle of a node (full path).
    pub fn hover(&mut self, path: &str) {
        let [x, y, w, h] = self.bounds(path);
        let win = path.split('/').nth(1).unwrap_or("main").to_string();
        let mut v = self.visual(&win);
        v.simulate_mouse_move(point(px(x + w / 2.), px(y + h / 2.)), None, Modifiers::none());
        self.settle();
    }

    /// Types keystrokes (`cmd-s`, `a b c`) into a window.
    pub fn keys(&mut self, win: &str, keys: &str) {
        let mut v = self.visual(win);
        v.simulate_keystrokes(keys);
        self.settle();
    }

    /// The host's main-thread state, for tests inside the crate.
    #[allow(dead_code)]
    pub(crate) fn inner(&self) -> &Rc<Inner> {
        &self.inner
    }

    /// Lets the host's 100 ms tick run (request timeouts, clipboard polling).
    pub fn advance(&mut self, d: std::time::Duration) {
        self.cx.executor().advance_clock(d);
        self.settle();
    }

    /// Whether the app has quit (`app gone`).
    pub fn quit_called(&self) -> bool {
        self.inner.quitting.get()
    }
}
