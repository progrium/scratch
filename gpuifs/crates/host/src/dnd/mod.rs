//! W7: drag and drop (DESIGN § Drag and drop).
//!
//! **Receiving.** A node with a non-empty `drop` file accepts drags whose
//! type it lists (`files`, `text`, `uri`, or a client word such as `note`);
//! an empty `drop` with `drop` in `on` accepts any type. While an accepted
//! drag hovers, the node's `hover:` and `drop-over:` style words apply in
//! GPUI with no round trip. A drop allocates a drag number `n` (or keeps
//! the one an in-app drag already has), fills `/drags/<n>/data` and opens a
//! `drop` request whose default is `refuse`:
//!
//! ```text
//! drop win=main node=root/notes tag=pick type=files drag=7 pt=40,212 seq=301
//! ```
//!
//! `pt=` is node-relative. Platform drops arrive as GPUI `ExternalPaths`:
//! the host serves each dropped file read-only at
//! `/drags/<n>/files/<name>` ([`Served`]) and `data` lists those guest paths
//! (PLAN § Design questions 12). The answer (`accept`/`refuse seq=`) or the
//! default ends the drag; the tree removes `/drags/<n>`, and the host stops
//! serving its files.
//!
//! **Starting a drag.** A node with `drag` in `on` and a `drag-type` file
//! starts a GPUI drag when pressed and moved. The host makes `/drags/<n>`
//! (an empty `data`) and sends `dragstart node=... drag=n`; the client
//! fills `data` while the drag runs. When it ends the source gets
//! `dragend drag=n result=dropped|cancelled target=<node>`: `dropped` once a
//! target accepted it, `cancelled` if it was refused or let go anywhere
//! else (then with no `target=`).
//!
//! Drags out of the window to the platform are not offered in v1.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use gpui::{
    AppContext as _, Context, ExternalPaths, InteractiveElement, IntoElement, ParentElement,
    Pixels, Point, Refineable as _, Render, SharedString, StatefulInteractiveElement, Styled,
    Window, div, px,
};
use tree::{Answer, Bytes, EventKind, EventMsg, FsPath, Stat, StatKind, Via};

use crate::runtime::{Inner, Msg, Pending, Tx};
use crate::{NodeView, ParsedStyle};

/// Where the guest sees the tree; `data` names dropped files under it.
pub const MOUNT: &str = "/mnt/gpui";

static NEXT_DRAG: AtomicU64 = AtomicU64::new(1);

/// A fresh drag number for the host's own drags.
fn next_drag() -> u64 {
    NEXT_DRAG.fetch_add(1, Ordering::Relaxed)
}

/// The value GPUI carries during an in-app drag.
pub struct DragValue {
    /// Set when the drag starts (in the drag's view constructor).
    n: Cell<u64>,
    /// The source's `drag-type`.
    ty: String,
    /// Full path of the source node.
    source: String,
}

/// What `dnd` listeners send to the main thread.
pub(crate) enum DndMsg {
    /// A drag began on `source`.
    Start { source: String, n: u64 },
    /// A drag landed on `target`: an in-app drag `n`, or platform `files`.
    Drop {
        target: String,
        n: u64,
        ty: String,
        pos: Point<Pixels>,
        files: Option<Vec<PathBuf>>,
    },
    /// The drag's view went away (it was dropped somewhere or let go).
    Released { n: u64 },
}

struct Active {
    source: Option<String>,
    /// The target's window-relative path once it landed on one.
    target: Option<String>,
}

/// Main-thread drag state.
#[derive(Default)]
pub(crate) struct State {
    active: RefCell<HashMap<u64, Active>>,
    pub served: Arc<Served>,
}

/// Dropped platform files, served read-only under `drags/<n>/files/`.
/// Shared with the 9P thread through `HostBackend::extra_*`.
#[derive(Default)]
pub struct Served {
    drags: Mutex<BTreeMap<u64, Vec<ServedFile>>>,
}

struct ServedFile {
    name: String,
    host: PathBuf,
    data: Option<Bytes>,
}

impl Served {
    /// Serves `paths` (regular files only) for drag `n`; returns their names.
    fn add(&self, n: u64, paths: &[PathBuf]) -> Vec<String> {
        let mut files: Vec<ServedFile> = Vec::new();
        for p in paths {
            if !p.is_file() {
                continue;
            }
            let base = p
                .file_name()
                .map(|s| s.to_string_lossy().into_owned())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "file".into());
            let mut name = base.clone();
            let mut i = 1;
            while files.iter().any(|f| f.name == name) {
                i += 1;
                name = format!("{i}-{base}");
            }
            files.push(ServedFile {
                name,
                host: p.clone(),
                data: None,
            });
        }
        let names = files.iter().map(|f| f.name.clone()).collect();
        self.drags.lock().unwrap().insert(n, files);
        names
    }

    fn remove(&self, n: u64) {
        self.drags.lock().unwrap().remove(&n);
    }

    /// Drags with files being served.
    pub fn drags(&self) -> Vec<u64> {
        self.drags.lock().unwrap().keys().copied().collect()
    }

    /// `(n, rest)` for `drags/<n>/files[/rest]`.
    fn split(p: &FsPath) -> Option<(u64, Option<&str>)> {
        let rest = p.as_str().strip_prefix("drags/")?;
        let (n, rest) = rest.split_once('/')?;
        let n = n.parse().ok()?;
        match rest {
            "files" => Some((n, None)),
            _ => Some((n, Some(rest.strip_prefix("files/")?))),
        }
    }

    pub fn stat(&self, p: &FsPath) -> Option<Stat> {
        let (n, name) = Self::split(p)?;
        let g = self.drags.lock().unwrap();
        let files = g.get(&n)?;
        match name {
            None => Some(Stat {
                name: "files".into(),
                kind: StatKind::Dir,
                len: 0,
                version: 0,
            }),
            Some(name) => {
                let f = files.iter().find(|f| f.name == name)?;
                let len = match &f.data {
                    Some(d) => d.len() as u64,
                    None => std::fs::metadata(&f.host).map(|m| m.len()).unwrap_or(0),
                };
                Some(Stat {
                    name: f.name.clone(),
                    kind: StatKind::ReadOnly,
                    len,
                    version: 0,
                })
            }
        }
    }

    pub fn readdir(&self, p: &FsPath) -> Vec<Stat> {
        let s = p.as_str();
        if let Some(n) = s
            .strip_prefix("drags/")
            .filter(|r| !r.contains('/'))
            .and_then(|n| n.parse::<u64>().ok())
        {
            return self
                .stat(&FsPath::new(format!("drags/{n}/files")))
                .into_iter()
                .collect();
        }
        match Self::split(p) {
            Some((n, None)) => {
                let names: Vec<String> = self
                    .drags
                    .lock()
                    .unwrap()
                    .get(&n)
                    .map(|fs| fs.iter().map(|f| f.name.clone()).collect())
                    .unwrap_or_default();
                names
                    .into_iter()
                    .filter_map(|name| self.stat(&FsPath::new(format!("drags/{n}/files/{name}"))))
                    .collect()
            }
            _ => Vec::new(),
        }
    }

    /// The file's bytes, read from the host once and kept while the drag lives.
    pub fn read(&self, p: &FsPath) -> Option<Bytes> {
        let (n, Some(name)) = Self::split(p)? else {
            return None;
        };
        let mut g = self.drags.lock().unwrap();
        let f = g.get_mut(&n)?.iter_mut().find(|f| f.name == name)?;
        if f.data.is_none() {
            f.data = Some(Bytes::from(std::fs::read(&f.host).ok()?));
        }
        f.data.clone()
    }
}

/// The words of a node's `drop` file.
fn accepts(node: &NodeView) -> Vec<String> {
    node.text("drop")
        .unwrap_or_default()
        .split_whitespace()
        .map(str::to_string)
        .collect()
}

fn accepted(list: &[String], any: bool, ty: &str) -> bool {
    any || list.iter().any(|w| w == ty)
}

/// Adds drop-target and drag-source behaviour to a node's element.
pub(crate) fn attach(
    node: &NodeView,
    st: &ParsedStyle,
    on: &[String],
    mut el: gpui::Stateful<gpui::Div>,
) -> gpui::Stateful<gpui::Div> {
    let tx = node.host.tx.clone();
    let list = accepts(node);
    let any = list.is_empty() && on.iter().any(|w| w == "drop");
    if !list.is_empty() || any {
        let list = Rc::new(list);
        // Style while an accepted drag hovers: hover:, then drop-over:.
        let mut over = st.hover.clone().unwrap_or_default();
        if let Some(d) = &st.drop_over {
            over.refine(d);
        }
        let over = Rc::new(over);
        {
            let list = list.clone();
            el = el.can_drop(move |v, _, _| {
                if let Some(d) = v.downcast_ref::<DragValue>() {
                    accepted(&list, any, &d.ty)
                } else if v.downcast_ref::<ExternalPaths>().is_some() {
                    accepted(&list, any, "files")
                } else {
                    false
                }
            });
        }
        let o = over.clone();
        el = el.drag_over::<DragValue>(move |mut s, _, _, _| {
            s.refine(&o);
            s
        });
        let o = over.clone();
        el = el.drag_over::<ExternalPaths>(move |mut s, _, _, _| {
            s.refine(&o);
            s
        });
        let target = node.path().to_string();
        {
            let (tx, target) = (tx.clone(), target.clone());
            el = el.on_drop::<DragValue>(move |d, window, _| {
                send(
                    &tx,
                    DndMsg::Drop {
                        target: target.clone(),
                        n: d.n.get(),
                        ty: d.ty.clone(),
                        pos: window.mouse_position(),
                        files: None,
                    },
                );
            });
        }
        {
            let (tx, target) = (tx.clone(), target.clone());
            el = el.on_drop::<ExternalPaths>(move |p, window, _| {
                send(
                    &tx,
                    DndMsg::Drop {
                        target: target.clone(),
                        n: next_drag(),
                        ty: "files".into(),
                        pos: window.mouse_position(),
                        files: Some(p.paths().to_vec()),
                    },
                );
            });
        }
    }

    let ty = node
        .text("drag-type")
        .map(|t| t.trim().to_string())
        .unwrap_or_default();
    if on.iter().any(|w| w == "drag") && !ty.is_empty() {
        let label: SharedString = node
            .text("label")
            .or_else(|| node.text("text"))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| ty.clone())
            .into();
        let value = DragValue {
            n: Cell::new(0),
            ty,
            source: node.path().to_string(),
        };
        el = el.on_drag(value, move |v, _offset, _window, cx| {
            let n = next_drag();
            v.n.set(n);
            send(
                &tx,
                DndMsg::Start {
                    source: v.source.clone(),
                    n,
                },
            );
            let label = label.clone();
            let view = cx.new(|_| DragPreview { label });
            let tx = tx.clone();
            cx.observe_release(&view, move |_, _| send(&tx, DndMsg::Released { n }))
                .detach();
            view
        });
    }
    el
}

fn send(tx: &Tx, m: DndMsg) {
    let _ = tx.unbounded_send(Msg::Dnd(m));
}

/// What follows the pointer during an in-app drag.
struct DragPreview {
    label: SharedString,
}

impl Render for DragPreview {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let bg = crate::theme::token(cx, "secondary").unwrap_or_default();
        let fg = crate::theme::token(cx, "secondary_foreground").unwrap_or_default();
        let border = crate::theme::token(cx, "border").unwrap_or_default();
        div()
            .px(px(8.))
            .py(px(4.))
            .rounded(px(6.))
            .border_1()
            .border_color(border)
            .bg(bg)
            .text_color(fg)
            .text_sm()
            .opacity(0.9)
            .child(self.label.clone())
    }
}

fn num(v: f32) -> String {
    if v.fract() == 0.0 {
        format!("{}", v as i64)
    } else {
        format!("{v:.1}")
    }
}

fn rel(path: &str) -> String {
    path.strip_prefix("windows/")
        .and_then(|p| p.split_once('/'))
        .map(|(_, r)| r.to_string())
        .unwrap_or_else(|| path.to_string())
}

fn emit(inner: &Inner, node: &str, name: &str, attrs: Vec<(String, String)>) {
    inner.tree.borrow_mut().emit(EventMsg {
        kind: EventKind::Action,
        name: name.into(),
        win: None,
        node: Some(node.to_string()),
        attrs,
        via: Via::User,
    });
}

/// Applies a `dnd` message on the main thread (inside `runtime::process`).
pub(crate) fn process(inner: &Rc<Inner>, m: DndMsg) {
    match m {
        DndMsg::Start { source, n } => {
            // The directory exists before `dragstart`, so the client can
            // write `data` as soon as it hears of the drag.
            inner
                .tree
                .borrow_mut()
                .mirror(&format!("drags/{n}"), "data", Bytes::new(), Via::User);
            inner.dnd.active.borrow_mut().insert(
                n,
                Active {
                    source: Some(source.clone()),
                    target: None,
                },
            );
            emit(
                inner,
                &source,
                "dragstart",
                vec![("drag".into(), n.to_string())],
            );
        }
        DndMsg::Drop {
            target,
            n,
            ty,
            pos,
            files,
        } => {
            if let Some(files) = &files {
                let names = inner.dnd.served.add(n, files);
                let mut data = String::new();
                for name in names {
                    data.push_str(&format!("{MOUNT}/drags/{n}/files/{name}\n"));
                }
                inner.tree.borrow_mut().mirror(
                    &format!("drags/{n}"),
                    "data",
                    Bytes::from(data),
                    Via::User,
                );
            } else if inner.tree.borrow().drag_data(n).is_none() {
                // A drag the host no longer knows: nothing to drop.
                return;
            }
            {
                let mut a = inner.dnd.active.borrow_mut();
                let e = a.entry(n).or_insert(Active {
                    source: None,
                    target: None,
                });
                e.target = Some(rel(&target));
            }
            let b = inner
                .tree
                .borrow()
                .snapshot()
                .read(&FsPath::new(format!("{target}/bounds")));
            let origin: Vec<f32> = b
                .map(|b| {
                    String::from_utf8_lossy(&b)
                        .split_whitespace()
                        .filter_map(|x| x.parse().ok())
                        .collect()
                })
                .unwrap_or_default();
            let (ox, oy) = match origin[..] {
                [x, y, ..] => (x, y),
                _ => (0., 0.),
            };
            let pt = format!(
                "{},{}",
                num(f32::from(pos.x) - ox),
                num(f32::from(pos.y) - oy)
            );
            let ev = EventMsg {
                kind: EventKind::Request,
                name: "drop".into(),
                win: None,
                node: Some(target),
                attrs: vec![
                    ("type".into(), ty),
                    ("drag".into(), n.to_string()),
                    ("pt".into(), pt),
                ],
                via: Via::User,
            };
            let seq = inner.tree.borrow_mut().open_request(
                ev,
                Answer::verb("refuse"),
                tree::REQUEST_TIMEOUT,
            );
            inner.pending.borrow_mut().insert(seq, Pending::Drop(n));
        }
        DndMsg::Released { n } => {
            let landed = inner
                .dnd
                .active
                .borrow()
                .get(&n)
                .is_some_and(|a| a.target.is_some());
            if landed {
                return; // the drop request ends it
            }
            if let Some(a) = inner.dnd.active.borrow_mut().remove(&n) {
                inner.tree.borrow_mut().drag_done(n);
                if let Some(src) = a.source {
                    emit(
                        inner,
                        &src,
                        "dragend",
                        vec![
                            ("drag".into(), n.to_string()),
                            ("result".into(), "cancelled".into()),
                        ],
                    );
                }
            }
        }
    }
}

/// The client answered drag `n`'s drop request (or its default applied).
pub(crate) fn answered(inner: &Rc<Inner>, n: u64, answer: &Answer) {
    inner.dnd.served.remove(n);
    inner.tree.borrow_mut().drag_done(n);
    let Some(a) = inner.dnd.active.borrow_mut().remove(&n) else {
        return;
    };
    let Some(src) = a.source else {
        return;
    };
    let ok = answer.0.verb == "accept";
    let mut attrs = vec![
        ("drag".to_string(), n.to_string()),
        (
            "result".to_string(),
            if ok { "dropped" } else { "cancelled" }.to_string(),
        ),
    ];
    if ok && let Some(t) = a.target {
        attrs.push(("target".into(), t));
    }
    emit(inner, &src, "dragend", attrs);
}

#[cfg(test)]
mod render_tests;
