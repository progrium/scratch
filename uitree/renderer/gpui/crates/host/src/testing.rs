//! A `gpui::TestAppContext` harness that drives the real core over 9P, as
//! a client would: writes go to `$ui` through a 9P connection on another
//! thread while this (the owner) thread pumps, so a write returns once the
//! core has applied it and the renderer has drawn the result.
//!
//! ```ignore
//! #[gpui::test]
//! fn click_sends_click(cx: &mut gpui::TestAppContext) {
//!     let mut h = Harness::new(cx);
//!     h.ctl("win/main", "set . size=400,300\nnew div card tag=open on=click : w=100 h=40");
//!     let mut ev = h.subscribe("events");
//!     h.click("win/main/card");
//!     assert!(h.events(&mut ev).iter().any(|l| l.starts_with("click card open ")));
//! }
//! ```
//!
//! Paths are `$ui`-relative, in the 0.2 spelling (`win/main/f/ok`).

use std::rc::Rc;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use gpui::{AnyWindowHandle, Modifiers, TestAppContext, VisualTestContext, point, px};
use uitcore::client::Client;

use crate::runtime::{self, Inner};
use crate::{NodeView, Options};

/// How long a 9P call may wait for the owner thread before a test fails.
const TIMEOUT: Duration = Duration::from_secs(10);

pub struct Harness {
    pub cx: TestAppContext,
    inner: Rc<Inner>,
    dial: String,
}

/// An open `events` file, read on its own thread.
pub struct Subscription {
    rx: mpsc::Receiver<Option<String>>,
}

impl Harness {
    /// Starts GPUI Kit, the host and its core in a test app, listening on a
    /// private socket. The hidden `main` window exists, as for a client.
    pub fn new(cx: &mut TestAppContext) -> Self {
        let inner = cx.update(|cx| {
            gpui_component::init(cx);
            runtime::install_with(Options { title: Some("test".into()), keep: true, ..Default::default() }, Some(Box::new(|| {})), cx).expect("install")
        });
        let dial = inner.core.borrow_mut().listen().expect("listen");
        Harness { cx: cx.clone(), inner, dial }
    }

    /// Runs `f` on a 9P connection on another thread, pumping here until
    /// it returns.
    fn call<T: Send + 'static>(&mut self, f: impl FnOnce(&mut Client) -> std::io::Result<T> + Send + 'static) -> std::io::Result<T> {
        let dial = self.dial.clone();
        let t = thread::spawn(move || f(&mut Client::connect(&dial)?));
        let start = Instant::now();
        while !t.is_finished() {
            self.pump();
            assert!(start.elapsed() < TIMEOUT, "9P call timed out");
            thread::sleep(Duration::from_millis(1));
        }
        let r = t.join().expect("9P thread");
        self.settle();
        r
    }

    fn pump(&mut self) {
        let inner = self.inner.clone();
        self.cx.update(|cx| runtime::pump(&inner, cx));
        self.cx.run_until_parked();
    }

    /// Writes a whole file (open, write, clunk); the core's error, if any.
    pub fn try_write(&mut self, path: &str, data: &str) -> Result<(), String> {
        let (p, d) = (path.to_string(), data.to_string());
        self.call(move |c| c.put(&p, &d)).map_err(|e| e.to_string())
    }

    /// As `try_write`, panicking on an error.
    #[track_caller]
    pub fn write(&mut self, path: &str, data: &str) {
        if let Err(e) = self.try_write(path, data) {
            panic!("write {path}: {e}");
        }
    }

    /// One `ctl` write on a directory (`""` for the app `ctl`).
    #[track_caller]
    pub fn ctl(&mut self, dir: &str, line: &str) {
        let p = if dir.is_empty() { "ctl".to_string() } else { format!("{dir}/ctl") };
        self.write(&p, line);
    }

    /// Reads a file, without its trailing newline.
    pub fn read(&mut self, path: &str) -> Option<String> {
        let p = path.to_string();
        self.call(move |c| c.get(&p)).ok().map(|s| s.strip_suffix('\n').map(str::to_string).unwrap_or(s))
    }

    /// Opens an `events` file. Lines arrive as the core sends them.
    pub fn subscribe(&mut self, events_file: &str) -> Subscription {
        let (tx, rx) = mpsc::channel();
        let (dial, p) = (self.dial.clone(), events_file.to_string());
        let (otx, orx) = mpsc::channel();
        thread::spawn(move || {
            let mut c = match Client::connect(&dial) {
                Ok(c) => c,
                Err(e) => return otx.send(Err(e.to_string())).unwrap_or(()),
            };
            let mut f = match c.open(&p, 0) {
                Ok(f) => f,
                Err(e) => return otx.send(Err(e.to_string())).unwrap_or(()),
            };
            let _ = otx.send(Ok(()));
            let mut buf = String::new();
            loop {
                match c.read(&mut f, 65536) {
                    Ok(b) if !b.is_empty() => {
                        buf.push_str(&String::from_utf8_lossy(&b));
                        while let Some(i) = buf.find('\n') {
                            let line: String = buf.drain(..=i).collect();
                            if tx.send(Some(line.trim_end_matches('\n').to_string())).is_err() {
                                return;
                            }
                        }
                    }
                    _ => {
                        let _ = tx.send(None);
                        return;
                    }
                }
            }
        });
        orx.recv_timeout(TIMEOUT).expect("subscribe").unwrap_or_else(|e| panic!("open {events_file}: {e}"));
        Subscription { rx }
    }

    /// Every line sent on a subscription so far; `<eof>` at end of file.
    pub fn events(&mut self, sub: &mut Subscription) -> Vec<String> {
        // Input queued by listeners reaches the core on the next turn, and
        // its lines reach the reader thread shortly after.
        let mut out = Vec::new();
        let mut quiet = 0;
        while quiet < 5 {
            self.settle();
            let mut got = false;
            while let Ok(l) = sub.rx.recv_timeout(Duration::from_millis(5)) {
                got = true;
                match l {
                    Some(l) => out.push(l),
                    None => {
                        out.push("<eof>".into());
                        return out;
                    }
                }
            }
            quiet = if got { 0 } else { quiet + 1 };
        }
        out
    }

    /// A window's GPUI handle.
    pub fn window(&self, win: &str) -> AnyWindowHandle {
        self.inner.windows.borrow().get(win).map(|w| w.handle).unwrap_or_else(|| panic!("no window {win}"))
    }

    pub fn has_window(&self, win: &str) -> bool {
        self.inner.windows.borrow().contains_key(win)
    }

    /// A `VisualTestContext` for simulating input into a window.
    pub fn visual(&self, win: &str) -> VisualTestContext {
        VisualTestContext::from_window(self.window(win), &self.cx)
    }

    /// Pumps, runs pending work, then draws every open window.
    pub fn settle(&mut self) {
        self.pump();
        let wins: Vec<AnyWindowHandle> = self.inner.windows.borrow().values().map(|w| w.handle).collect();
        for w in wins {
            let _ = self.cx.update(|cx| w.update(cx, |_, window, _| window.refresh()));
        }
        self.cx.run_until_parked();
        self.pump();
    }

    /// `win/main/x` to the renderer's `main/x`.
    fn host_path(path: &str) -> &str {
        path.strip_prefix("win/").unwrap_or(path)
    }

    /// A node as the renderer sees it.
    pub fn node(&self, path: &str) -> NodeView {
        self.inner.node_at(Self::host_path(path)).unwrap_or_else(|| panic!("no node {path}"))
    }

    /// `x y w h` from the last layout, as the renderer reported it.
    pub fn bounds(&self, path: &str) -> [f32; 4] {
        let n = self.node(path).node();
        self.inner.bounds.borrow().get(&n).copied().unwrap_or_else(|| panic!("{path}: no bounds"))
    }

    fn window_of(path: &str) -> String {
        Self::host_path(path).split('/').next().unwrap_or("main").to_string()
    }

    /// Clicks the middle of a node.
    pub fn click(&mut self, path: &str) {
        let [x, y, w, h] = self.bounds(path);
        let mut v = self.visual(&Self::window_of(path));
        let p = point(px(x + w / 2.), px(y + h / 2.));
        v.simulate_mouse_move(p, None, Modifiers::none());
        v.simulate_click(p, Modifiers::none());
        self.settle();
    }

    /// Moves the mouse to the middle of a node.
    pub fn hover(&mut self, path: &str) {
        let [x, y, w, h] = self.bounds(path);
        let mut v = self.visual(&Self::window_of(path));
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

    /// Lets timers run (clipboard polling).
    pub fn advance(&mut self, d: Duration) {
        self.cx.executor().advance_clock(d);
        self.settle();
    }

    /// Whether the app has quit.
    pub fn quit_called(&self) -> bool {
        self.inner.quitting.get()
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.inner.core.borrow().shutdown();
    }
}
