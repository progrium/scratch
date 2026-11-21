//! The event bus: one queue per open `events` file.
//!
//! A subscription's target is `""` (the app), `windows/<w>` (a window) or a
//! node's full path. Every event goes to the app's subscriptions, its
//! window's, and its node's. State events coalesce: a new one replaces a
//! queued one with the same name about the same node and moves to the back.
//! Action events (and requests) are never dropped; past 4,096 queued, the
//! reader gets `lost n=N` instead.

use std::collections::{HashSet, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use bytes::Bytes;
use catalog::EventKind;

use crate::{FsPath, SubEnd};

/// Queued action events per subscription before `lost`.
pub const ACTION_CAP: usize = 4096;

#[derive(Debug)]
enum Entry {
    Line {
        text: Arc<str>,
        name: Arc<str>,
        key: Arc<str>,
        kind: EventKind,
    },
    Lost(u64),
    Gone,
}

impl Entry {
    fn len(&self) -> usize {
        match self {
            Entry::Line { text, .. } => text.len(),
            Entry::Lost(n) => format!("lost n={n}\n").len(),
            Entry::Gone => "gone\n".len(),
        }
    }
    fn write_to(&self, out: &mut Vec<u8>) {
        match self {
            Entry::Line { text, .. } => out.extend_from_slice(text.as_bytes()),
            Entry::Lost(n) => out.extend_from_slice(format!("lost n={n}\n").as_bytes()),
            Entry::Gone => out.extend_from_slice(b"gone\n"),
        }
    }
}

#[derive(Debug, Default)]
struct Queue {
    entries: VecDeque<Entry>,
    /// Action lines currently queued.
    actions: usize,
    /// No more entries will arrive; EOF once `entries` drains.
    ended: bool,
    waker: Option<Waker>,
}

#[derive(Debug)]
struct SubShared {
    target: String,
    q: Mutex<Queue>,
    /// Set when the `Subscription` is dropped (the file was clunked).
    closed: std::sync::atomic::AtomicBool,
}

impl SubShared {
    fn is_closed(&self) -> bool {
        self.closed.load(std::sync::atomic::Ordering::Acquire)
    }

    fn push(&self, e: Entry) {
        let mut q = self.q.lock().unwrap();
        if q.ended {
            return;
        }
        match &e {
            Entry::Line {
                name,
                key,
                kind: EventKind::State,
                ..
            } => {
                if let Some(i) = q.entries.iter().position(|x| {
                    matches!(x, Entry::Line { name: n, key: k, kind: EventKind::State, .. }
                        if n == name && k == key)
                }) {
                    q.entries.remove(i);
                }
                q.entries.push_back(e);
            }
            Entry::Line { .. } => {
                if q.actions >= ACTION_CAP {
                    match q.entries.back_mut() {
                        Some(Entry::Lost(n)) => *n += 1,
                        _ => q.entries.push_back(Entry::Lost(1)),
                    }
                } else {
                    q.actions += 1;
                    q.entries.push_back(e);
                }
            }
            Entry::Lost(_) => q.entries.push_back(e),
            Entry::Gone => {
                q.entries.push_back(e);
                q.ended = true;
            }
        }
        if let Some(w) = q.waker.take() {
            w.wake();
        }
    }

    fn end(&self) {
        let mut q = self.q.lock().unwrap();
        q.ended = true;
        if let Some(w) = q.waker.take() {
            w.wake();
        }
    }
}

#[derive(Debug, Default)]
struct Inner {
    /// The last seq handed out.
    seq: u64,
    subs: Vec<Arc<SubShared>>,
    /// Targets that exist: `""`, window dirs and node paths.
    live: HashSet<String>,
    gone: bool,
}

/// Subscriptions per app, window and node. Thread-safe, and cheap to clone:
/// clones share one bus, so the 9P thread can keep its own handle.
#[derive(Debug, Clone)]
pub struct EventBus {
    inner: Arc<Mutex<Inner>>,
}

impl Default for EventBus {
    fn default() -> Self {
        let mut inner = Inner::default();
        inner.live.insert(String::new());
        EventBus {
            inner: Arc::new(Mutex::new(inner)),
        }
    }
}

/// `events` -> `""`, `windows/w/events` -> `windows/w`, `<node>/events` -> `<node>`.
fn target_of(events_file: &str) -> Option<&str> {
    if events_file == "events" {
        return Some("");
    }
    events_file.strip_suffix("/events")
}

impl EventBus {
    /// One subscription per open of an `events` file. The first line is
    /// `resync seq=N`, N being the last seq handed out.
    pub fn subscribe(&self, events_file: &FsPath) -> Result<Subscription, proto::Error> {
        let mut inner = self.inner.lock().unwrap();
        if inner.gone {
            return Err(proto::Error::new(proto::ErrorKind::AppGone, ""));
        }
        let target = target_of(events_file.as_str())
            .filter(|t| inner.live.contains(*t))
            .ok_or_else(|| proto::Error::new(proto::ErrorKind::NotFound, events_file.as_str()))?
            .to_string();
        let shared = Arc::new(SubShared {
            target,
            q: Mutex::new(Queue::default()),
            closed: Default::default(),
        });
        let resync = format!("resync seq={}\n", inner.seq);
        shared.q.lock().unwrap().entries.push_back(Entry::Line {
            text: resync.into(),
            name: "resync".into(),
            key: "".into(),
            kind: EventKind::Action,
        });
        inner.subs.retain(|s| !s.is_closed());
        inner.subs.push(shared.clone());
        Ok(Subscription { shared })
    }

    /// The last seq handed out.
    pub fn last_seq(&self) -> u64 {
        self.inner.lock().unwrap().seq
    }

    /// Whether an open `events` file would see an event about `node_key`
    /// (a node path, a window dir, or `""`) in window `win`.
    pub fn has_reader(&self, win: Option<&str>, node_key: &str) -> bool {
        let inner = self.inner.lock().unwrap();
        let wdir = win.map(|w| format!("windows/{w}"));
        inner.subs.iter().any(|s| {
            !s.is_closed()
                && (s.target.is_empty()
                    || Some(&s.target) == wdir.as_ref()
                    || (!node_key.is_empty() && s.target == node_key))
        })
    }

    pub(crate) fn next_seq(&self) -> u64 {
        let mut inner = self.inner.lock().unwrap();
        inner.seq += 1;
        inner.seq
    }

    /// Queues one already-formatted line (with its seq) for every reader of
    /// the app, `win`, and `key`.
    pub(crate) fn deliver(
        &self,
        win: Option<&str>,
        key: &str,
        name: &str,
        kind: EventKind,
        line: String,
    ) {
        let mut inner = self.inner.lock().unwrap();
        if inner.gone {
            return;
        }
        inner.subs.retain(|s| !s.is_closed());
        let wdir = win.map(|w| format!("windows/{w}"));
        let text: Arc<str> = line.into();
        let name: Arc<str> = name.into();
        let key_a: Arc<str> = key.into();
        for s in &inner.subs {
            if s.target.is_empty()
                || Some(&s.target) == wdir.as_ref()
                || (!key.is_empty() && s.target == key)
            {
                s.push(Entry::Line {
                    text: text.clone(),
                    name: name.clone(),
                    key: key_a.clone(),
                    kind,
                });
            }
        }
    }

    pub(crate) fn add_live(&self, target: &str) {
        self.inner.lock().unwrap().live.insert(target.to_string());
    }

    /// The target went away: its readers get `gone`, then EOF.
    pub(crate) fn remove_live(&self, target: &str) {
        let mut inner = self.inner.lock().unwrap();
        inner.live.remove(target);
        for s in inner.subs.iter().filter(|s| s.target == target) {
            s.push(Entry::Gone);
        }
        inner.subs.retain(|s| s.target != target && !s.is_closed());
    }

    /// The app quit: every reader gets EOF, and new subscriptions fail.
    pub(crate) fn shut_down(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.gone = true;
        for s in inner.subs.drain(..) {
            s.end();
        }
    }
}

/// One open `events` file. `Send`.
#[derive(Debug)]
pub struct Subscription {
    shared: Arc<SubShared>,
}

impl Drop for Subscription {
    fn drop(&mut self) {
        self.shared
            .closed
            .store(true, std::sync::atomic::Ordering::Release);
    }
}

impl Subscription {
    /// Whole lines only, at most `max` bytes. Blocks until a line is ready.
    /// Dropping the future (a 9P `Tflush`) loses nothing.
    pub async fn read(&mut self, max: usize) -> Result<Bytes, SubEnd> {
        ReadFut {
            shared: &self.shared,
            max,
        }
        .await
    }

    /// The same as `read`, without waiting: `None` when nothing is queued.
    pub fn try_read(&mut self, max: usize) -> Option<Result<Bytes, SubEnd>> {
        let mut q = self.shared.q.lock().unwrap();
        take(&mut q, max)
    }
}

fn take(q: &mut Queue, max: usize) -> Option<Result<Bytes, SubEnd>> {
    let Some(first) = q.entries.front() else {
        return if q.ended {
            Some(Err(SubEnd::Eof))
        } else {
            None
        };
    };
    if first.len() > max {
        return Some(Err(SubEnd::ShortRead));
    }
    let mut out = Vec::new();
    while let Some(e) = q.entries.front() {
        if out.len() + e.len() > max {
            break;
        }
        let e = q.entries.pop_front().unwrap();
        if matches!(e, Entry::Line { kind, .. } if kind != EventKind::State) {
            q.actions = q.actions.saturating_sub(1);
        }
        e.write_to(&mut out);
    }
    Some(Ok(Bytes::from(out)))
}

struct ReadFut<'a> {
    shared: &'a Arc<SubShared>,
    max: usize,
}

impl Future for ReadFut<'_> {
    type Output = Result<Bytes, SubEnd>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut q = self.shared.q.lock().unwrap();
        match take(&mut q, self.max) {
            Some(r) => Poll::Ready(r),
            None => {
                q.waker = Some(cx.waker().clone());
                Poll::Pending
            }
        }
    }
}
