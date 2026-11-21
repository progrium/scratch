//! One 9P2000 connection: fids, the request loop, `Tflush`, and the file
//! semantics PLAN.md § W3 fixes:
//!
//! - `ctl` files apply each write on arrival; the reply waits for the ack.
//!   A write that doesn't end in a newline and fills a whole 8 KiB piece (as
//!   `cat cmds >ctl` and the kernel's iounit split make) keeps its last
//!   partial line until the next write or the clunk, so long command files
//!   aren't cut mid-line.
//! - Text and data files buffer writes from open to clunk and apply the whole
//!   value at clunk. An error at clunk fails the clunk. A file named `append`
//!   applies each write as `Op::Append`.
//! - Short files apply per write, so `echo` sees their errors: `style`,
//!   `order`, `tag`, `on`, `type`, ... (see `PER_WRITE`), anything under
//!   `theme/` or `menus/`, and any prop whose `catalog` kind is a word, bool,
//!   number or enum. Each write is the whole value.
//! - `events` files: each open is a subscription; reads block until whole
//!   lines are ready; `Tflush` cancels a blocked read.
//! - `Tcreate` with `DMDIR` is `mkdir`; `Tremove` on a directory removes the
//!   node. Removing a node's own files is a no-op, so `rm -r` works bottom-up.
//!
//! The loop is runtime-agnostic: it polls every in-flight request from the one
//! future `serve` returns, and never spawns.

use std::collections::HashMap;
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use futures::future::{AbortHandle, Abortable, BoxFuture};
use futures::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use futures::stream::{FuturesUnordered, StreamExt};
use proto::{Error, ErrorKind};
use tree::{FsPath, Op, SessionId, Stat, StatKind, SubEnd};

use crate::fcall::*;

/// The largest msize we offer: room for one 64 KiB `ctl` write plus header,
/// and big enough that `cat big.rs >value` takes few round trips.
pub const MAX_MSIZE: u32 = 1024 * 1024 + IOHDRSZ;

/// One `ctl` write.
pub const CTL_LIMIT: usize = 64 * 1024;
/// A text property file.
pub const TEXT_LIMIT: usize = 16 * 1024 * 1024;
/// A data file.
pub const DATA_LIMIT: usize = 64 * 1024 * 1024;
/// An image or `pixels` write.
pub const PIXELS_LIMIT: usize = 16 * 1024 * 1024;

/// A `ctl` write at least this long with no final newline is taken to be a
/// piece of a longer write (cat's buffer, the kernel's iounit split).
const CTL_PIECE: usize = 8192;

/// Files that apply per write whatever their node type.
pub const PER_WRITE: &[&str] = &[
    "style", "order", "tag", "on", "type", "flags", "drop", "drag-type", "context", "keymap", "focus",
    "page", "expanded", "origin", "selection", "controlled", "sorted", "state", "mode",
];

// ---------------------------------------------------------------------------
// What the server needs from a backend. `FsBackend` is adapted to this; tests
// implement it directly so the server is testable without the tree.

pub(crate) trait View: Send + Sync {
    fn stat(&self, p: &FsPath) -> Option<Stat>;
    fn readdir(&self, p: &FsPath) -> Option<Vec<Stat>>;
    fn read(&self, p: &FsPath) -> Option<Bytes>;
}

impl View for tree::Snapshot {
    fn stat(&self, p: &FsPath) -> Option<Stat> {
        tree::Snapshot::stat(self, p)
    }
    fn readdir(&self, p: &FsPath) -> Option<Vec<Stat>> {
        tree::Snapshot::readdir(self, p)
    }
    fn read(&self, p: &FsPath) -> Option<Bytes> {
        tree::Snapshot::read(self, p)
    }
}

pub(crate) trait Sub: Send {
    fn read(&mut self, max: usize) -> BoxFuture<'_, Result<Bytes, SubEnd>>;
}

impl Sub for tree::Subscription {
    fn read(&mut self, max: usize) -> BoxFuture<'_, Result<Bytes, SubEnd>> {
        Box::pin(tree::Subscription::read(self, max))
    }
}

pub(crate) trait Backend: Send + Sync + 'static {
    fn view(&self) -> Arc<dyn View>;
    fn apply(&self, s: SessionId, op: Op) -> BoxFuture<'_, Result<(), Error>>;
    fn subscribe(&self, p: &FsPath) -> Result<Box<dyn Sub>, Error>;
    fn new_session(&self) -> SessionId;
    fn extra_stat(&self, _p: &FsPath) -> Option<Stat> {
        None
    }
    fn extra_readdir(&self, _p: &FsPath) -> Vec<Stat> {
        Vec::new()
    }
    fn extra_read(&self, _p: &FsPath) -> Option<Bytes> {
        None
    }
    fn is_gone(&self) -> bool {
        false
    }
}

pub(crate) struct Adapt(pub Arc<dyn crate::FsBackend>);

impl Backend for Adapt {
    fn view(&self) -> Arc<dyn View> {
        self.0.snapshot()
    }
    fn apply(&self, s: SessionId, op: Op) -> BoxFuture<'_, Result<(), Error>> {
        self.0.apply(s, op)
    }
    fn subscribe(&self, p: &FsPath) -> Result<Box<dyn Sub>, Error> {
        Ok(Box::new(self.0.subscribe(p)?))
    }
    fn new_session(&self) -> SessionId {
        self.0.new_session()
    }
    fn extra_stat(&self, p: &FsPath) -> Option<Stat> {
        self.0.extra_stat(p)
    }
    fn extra_readdir(&self, p: &FsPath) -> Vec<Stat> {
        self.0.extra_readdir(p)
    }
    fn extra_read(&self, p: &FsPath) -> Option<Bytes> {
        self.0.extra_read(p)
    }
    fn is_gone(&self) -> bool {
        self.0.is_gone()
    }
}

// ---------------------------------------------------------------------------

type SubCell = Arc<futures::lock::Mutex<Box<dyn Sub>>>;

enum Opened {
    Dir { entries: Vec<Vec<u8>>, next_off: u64, next_idx: usize },
    /// `wbuf` is the value so far (text/data), or a held partial line (`ctl`).
    /// `per_write` files apply each write; `dirty` is a truncating open not yet written.
    File { cache: Option<Bytes>, wbuf: Vec<u8>, dirty: bool, per_write: bool },
    Events { sub: SubCell },
}

struct Fid {
    path: FsPath,
    qid: Qid,
    kind: StatKind,
    mode: Option<u8>,
    opened: Option<Opened>,
}

struct Conn {
    b: Arc<dyn Backend>,
    sid: SessionId,
    uname: Mutex<String>,
    fids: Mutex<HashMap<u32, Fid>>,
    msize: AtomicU32,
}

fn err(e: impl std::fmt::Display) -> Rmsg {
    Rmsg::Error { ename: e.to_string() }
}

fn perr(kind: ErrorKind, detail: impl Into<String>) -> Rmsg {
    err(Error::new(kind, detail))
}

fn gone() -> Rmsg {
    perr(ErrorKind::AppGone, "")
}

/// FNV-1a over the path: a stable qid.path for as long as the path exists.
fn qid_path(p: &FsPath) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in p.as_str().bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn base(p: &FsPath) -> &str {
    let s = p.as_str();
    match s.rfind('/') {
        Some(i) => &s[i + 1..],
        None => s,
    }
}

fn parent(p: &FsPath) -> FsPath {
    let s = p.as_str();
    match s.rfind('/') {
        Some(i) => FsPath::new(&s[..i]),
        None => FsPath::new(""),
    }
}

fn join(p: &FsPath, name: &str) -> FsPath {
    if p.as_str().is_empty() {
        FsPath::new(name)
    } else {
        FsPath::new(format!("{}/{}", p.as_str(), name))
    }
}

fn is_append(p: &FsPath) -> bool {
    base(p) == "append"
}

fn make_qid(p: &FsPath, st: &Stat) -> Qid {
    let ty = match st.kind {
        StatKind::Dir => QTDIR,
        _ if is_append(p) => QTAPPEND,
        _ => QTFILE,
    };
    Qid { ty, version: st.version, path: qid_path(p) }
}

fn mode_bits(p: &FsPath, kind: StatKind) -> u32 {
    match kind {
        StatKind::Dir => DMDIR | 0o775,
        StatKind::Events | StatKind::ReadOnly => 0o444,
        _ if is_append(p) => DMAPPEND | 0o664,
        StatKind::Ctl | StatKind::Text | StatKind::Data => 0o664,
    }
}

fn write_limit(p: &FsPath, kind: StatKind) -> usize {
    match kind {
        StatKind::Ctl => CTL_LIMIT,
        _ if base(p) == "pixels" => PIXELS_LIMIT,
        StatKind::Text => TEXT_LIMIT,
        _ => DATA_LIMIT,
    }
}

impl Conn {
    fn stat(&self, p: &FsPath) -> Option<Stat> {
        self.b.view().stat(p).or_else(|| self.b.extra_stat(p))
    }

    fn dir_entry(&self, p: &FsPath, st: &Stat) -> Dir {
        let uname = self.uname.lock().unwrap().clone();
        let name = if p.as_str().is_empty() { "/".to_string() } else { base(p).to_string() };
        Dir {
            ty: 0,
            dev: 0,
            qid: make_qid(p, st),
            mode: mode_bits(p, st.kind),
            atime: 0,
            mtime: 0,
            length: if st.kind == StatKind::Dir { 0 } else { st.len },
            name,
            uid: uname.clone(),
            gid: uname.clone(),
            muid: uname,
        }
    }

    fn iounit(&self) -> u32 {
        self.msize.load(Ordering::Relaxed).saturating_sub(IOHDRSZ)
    }

    /// Whether a text or data file applies each write (see the module doc).
    fn per_write(&self, p: &FsPath) -> bool {
        let name = base(p);
        if is_append(p) || PER_WRITE.contains(&name) {
            return true;
        }
        let s = p.as_str();
        if s.starts_with("theme/") || s.starts_with("menus/") || s == "keymap" {
            return true;
        }
        let node = parent(p);
        let Some(ty) = self.b.view().read(&join(&node, "type")) else { return false };
        let ty = String::from_utf8_lossy(&ty);
        let ty = ty.trim();
        let Some(spec) = catalog::all().find(|t| t.name == ty) else { return false };
        let Some(prop) = spec.props.iter().find(|pr| pr.name == name) else { return false };
        matches!(
            prop.kind,
            catalog::PropKind::Word | catalog::PropKind::Bool | catalog::PropKind::Number | catalog::PropKind::Enum(_)
        )
    }

    async fn handle(&self, m: Tmsg) -> Rmsg {
        match m {
            // Version and Flush are handled in the loop.
            Tmsg::Version { .. } | Tmsg::Flush { .. } => err("unexpected message"),
            Tmsg::Auth { .. } => err("authentication not required"),
            Tmsg::Attach { fid, afid: _, uname, aname: _ } => self.attach(fid, uname),
            Tmsg::Walk { fid, newfid, names } => self.walk(fid, newfid, names),
            Tmsg::Open { fid, mode } => self.open(fid, mode),
            Tmsg::Create { fid, name, perm, mode } => self.create(fid, name, perm, mode).await,
            Tmsg::Read { fid, offset, count } => self.read(fid, offset, count).await,
            Tmsg::Write { fid, offset, data } => self.write(fid, offset, data).await,
            Tmsg::Clunk { fid } => self.clunk(fid).await,
            Tmsg::Remove { fid } => self.remove(fid).await,
            Tmsg::Stat { fid } => self.fstat(fid),
            Tmsg::Wstat { fid, stat } => self.wstat(fid, stat),
        }
    }

    fn attach(&self, fid: u32, uname: String) -> Rmsg {
        if self.b.is_gone() {
            return gone();
        }
        let mut fids = self.fids.lock().unwrap();
        if fids.contains_key(&fid) {
            return err("fid in use");
        }
        *self.uname.lock().unwrap() = if uname.is_empty() { "gpuifs".into() } else { uname };
        let root = FsPath::new("");
        let st = self.b.view().stat(&root).unwrap_or(Stat {
            name: "/".into(),
            kind: StatKind::Dir,
            len: 0,
            version: 0,
        });
        let qid = make_qid(&root, &Stat { kind: StatKind::Dir, ..st });
        fids.insert(fid, Fid { path: root, qid, kind: StatKind::Dir, mode: None, opened: None });
        Rmsg::Attach { qid }
    }

    fn walk(&self, fid: u32, newfid: u32, names: Vec<String>) -> Rmsg {
        if self.b.is_gone() {
            return gone();
        }
        let mut fids = self.fids.lock().unwrap();
        let Some(f) = fids.get(&fid) else { return err("unknown fid") };
        if f.opened.is_some() {
            return err("fid is open");
        }
        if newfid != fid && fids.contains_key(&newfid) {
            return err("fid in use");
        }
        let (mut path, mut qid, mut kind) = (f.path.clone(), f.qid, f.kind);
        let mut qids = Vec::with_capacity(names.len());
        for name in &names {
            if kind != StatKind::Dir {
                break;
            }
            let next = match name.as_str() {
                "." => path.clone(),
                ".." => parent(&path),
                n if n.is_empty() || n.contains('/') => break,
                n => join(&path, n),
            };
            let st = if next.as_str().is_empty() {
                Some(Stat { name: "/".into(), kind: StatKind::Dir, len: 0, version: 0 })
            } else {
                self.stat(&next)
            };
            let Some(st) = st else { break };
            qid = make_qid(&next, &st);
            kind = st.kind;
            path = next;
            qids.push(qid);
        }
        if qids.len() < names.len() {
            if qids.is_empty() {
                let missing = names.first().map(|s| s.as_str()).unwrap_or("");
                return perr(ErrorKind::NotFound, missing);
            }
            return Rmsg::Walk { qids };
        }
        fids.insert(newfid, Fid { path, qid, kind, mode: None, opened: None });
        Rmsg::Walk { qids }
    }

    fn open(&self, fid: u32, mode: u8) -> Rmsg {
        if self.b.is_gone() {
            return gone();
        }
        let (path, kind) = {
            let fids = self.fids.lock().unwrap();
            let Some(f) = fids.get(&fid) else { return err("unknown fid") };
            if f.opened.is_some() {
                return err("fid already open");
            }
            (f.path.clone(), f.kind)
        };
        let rw = mode & 3;
        let writes = rw == OWRITE || rw == ORDWR;
        let opened = match kind {
            StatKind::Dir => {
                if writes || mode & OTRUNC != 0 {
                    return err("is a directory");
                }
                Opened::Dir { entries: Vec::new(), next_off: 0, next_idx: 0 }
            }
            StatKind::Events => {
                if writes {
                    return err("permission denied");
                }
                match self.b.subscribe(&path) {
                    Ok(sub) => Opened::Events { sub: Arc::new(futures::lock::Mutex::new(sub)) },
                    Err(e) => return err(e),
                }
            }
            StatKind::ReadOnly => {
                if writes {
                    return err("permission denied");
                }
                Opened::File { cache: None, wbuf: Vec::new(), dirty: false, per_write: false }
            }
            StatKind::Ctl | StatKind::Text | StatKind::Data => {
                let trunc = mode & OTRUNC != 0 && writes && kind != StatKind::Ctl && !is_append(&path);
                let per_write = kind != StatKind::Ctl && self.per_write(&path);
                Opened::File { cache: None, wbuf: Vec::new(), dirty: trunc, per_write }
            }
        };
        let mut fids = self.fids.lock().unwrap();
        let Some(f) = fids.get_mut(&fid) else { return err("unknown fid") };
        f.mode = Some(mode);
        f.opened = Some(opened);
        Rmsg::Open { qid: f.qid, iounit: self.iounit() }
    }

    async fn create(&self, fid: u32, name: String, perm: u32, mode: u8) -> Rmsg {
        if self.b.is_gone() {
            return gone();
        }
        if name.is_empty() || name == "." || name == ".." || name.contains('/') {
            return perr(ErrorKind::BadValue, format!("bad name {name}"));
        }
        let dir = {
            let fids = self.fids.lock().unwrap();
            let Some(f) = fids.get(&fid) else { return err("unknown fid") };
            if f.opened.is_some() {
                return err("fid is open");
            }
            if f.kind != StatKind::Dir {
                return err("not a directory");
            }
            f.path.clone()
        };
        let path = join(&dir, &name);
        let rw = mode & 3;
        let (qid, kind, opened) = if perm & DMDIR != 0 {
            if let Err(e) = self.b.apply(self.sid, Op::Mkdir { path: path.clone() }).await {
                return err(e);
            }
            let st = self.stat(&path).unwrap_or(Stat {
                name: name.clone(),
                kind: StatKind::Dir,
                len: 0,
                version: 0,
            });
            let st = Stat { kind: StatKind::Dir, ..st };
            (make_qid(&path, &st), StatKind::Dir, Opened::Dir { entries: Vec::new(), next_off: 0, next_idx: 0 })
        } else {
            // A file that may not be listed yet (an unset prop). Its value is
            // written at clunk, where the tree validates it.
            let st = self.stat(&path).unwrap_or_else(|| Stat {
                name: name.clone(),
                kind: if name == "ctl" { StatKind::Ctl } else { StatKind::Data },
                len: 0,
                version: 0,
            });
            match st.kind {
                StatKind::Dir => return err("is a directory"),
                StatKind::Events | StatKind::ReadOnly => return err("permission denied"),
                _ => {}
            }
            let dirty = st.kind != StatKind::Ctl && !is_append(&path);
            let per_write = st.kind != StatKind::Ctl && self.per_write(&path);
            (make_qid(&path, &st), st.kind, Opened::File { cache: None, wbuf: Vec::new(), dirty, per_write })
        };
        let _ = rw;
        let mut fids = self.fids.lock().unwrap();
        let Some(f) = fids.get_mut(&fid) else { return err("unknown fid") };
        *f = Fid { path, qid, kind, mode: Some(mode), opened: Some(opened) };
        Rmsg::Create { qid, iounit: self.iounit() }
    }

    async fn read(&self, fid: u32, offset: u64, count: u32) -> Rmsg {
        let count = count.min(self.iounit()) as usize;
        enum Plan {
            Done(Rmsg),
            Events(SubCell),
        }
        let plan = {
            let mut fids = self.fids.lock().unwrap();
            let Some(f) = fids.get_mut(&fid) else { return err("unknown fid") };
            let Some(mode) = f.mode else { return err("fid not open") };
            if mode & 3 == OWRITE {
                return err("permission denied");
            }
            let path = f.path.clone();
            match f.opened.as_mut() {
                None => return err("fid not open"),
                Some(Opened::Events { sub }) => Plan::Events(sub.clone()),
                Some(_) if self.b.is_gone() => Plan::Done(gone()),
                Some(Opened::Dir { entries, next_off, next_idx }) => {
                    if offset == 0 {
                        *entries = self.list(&path);
                        *next_off = 0;
                        *next_idx = 0;
                    } else if offset != *next_off {
                        return err("bad offset in directory read");
                    }
                    let mut out = Vec::new();
                    while *next_idx < entries.len() {
                        let e = &entries[*next_idx];
                        if out.len() + e.len() > count {
                            break;
                        }
                        out.extend_from_slice(e);
                        *next_idx += 1;
                    }
                    if out.is_empty() && *next_idx < entries.len() {
                        return perr(ErrorKind::ShortRead, "");
                    }
                    *next_off += out.len() as u64;
                    Plan::Done(Rmsg::Read { data: out })
                }
                Some(Opened::File { cache, .. }) => {
                    if offset == 0 || cache.is_none() {
                        let v = self.b.view().read(&path).or_else(|| self.b.extra_read(&path));
                        *cache = Some(v.unwrap_or_default());
                    }
                    let data = cache.as_ref().unwrap();
                    let start = (offset.min(data.len() as u64)) as usize;
                    let end = (start + count).min(data.len());
                    Plan::Done(Rmsg::Read { data: data[start..end].to_vec() })
                }
            }
        };
        match plan {
            Plan::Done(r) => r,
            Plan::Events(sub) => {
                let mut sub = sub.lock().await;
                match sub.read(count).await {
                    Ok(b) => Rmsg::Read { data: b.to_vec() },
                    Err(SubEnd::Eof) => Rmsg::Read { data: Vec::new() },
                    Err(SubEnd::ShortRead) => perr(ErrorKind::ShortRead, ""),
                }
            }
        }
    }

    fn list(&self, path: &FsPath) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let view = self.b.view();
        let mut stats = view.readdir(path).unwrap_or_default();
        stats.extend(self.b.extra_readdir(path));
        for st in stats {
            if st.name.is_empty() || !seen.insert(st.name.clone()) {
                continue;
            }
            let p = join(path, &st.name);
            out.push(encode_dir(&self.dir_entry(&p, &st)));
        }
        out
    }

    async fn write(&self, fid: u32, offset: u64, data: Vec<u8>) -> Rmsg {
        if self.b.is_gone() {
            return gone();
        }
        let n = data.len() as u32;
        let piece = data.len() >= CTL_PIECE || data.len() as u32 == self.iounit();
        let (path, op) = {
            let mut fids = self.fids.lock().unwrap();
            let Some(f) = fids.get_mut(&fid) else { return err("unknown fid") };
            let Some(mode) = f.mode else { return err("fid not open") };
            if mode & 3 == OREAD || mode & 3 == OEXEC {
                return err("permission denied");
            }
            let path = f.path.clone();
            let kind = f.kind;
            let Some(Opened::File { wbuf, dirty, cache, per_write }) = f.opened.as_mut() else {
                return err("permission denied");
            };
            *cache = None;
            match kind {
                StatKind::Ctl => {
                    let held = !wbuf.is_empty();
                    let mut buf = std::mem::take(wbuf);
                    buf.extend_from_slice(&data);
                    if !buf.ends_with(b"\n") && (held || piece) {
                        // Keep the partial last line for the next write or the clunk.
                        let cut = buf.iter().rposition(|&c| c == b'\n').map(|i| i + 1).unwrap_or(0);
                        let tail = buf.split_off(cut);
                        if tail.len() > CTL_LIMIT {
                            return perr(ErrorKind::TooLarge, format!("ctl line over {} bytes", CTL_LIMIT));
                        }
                        *wbuf = tail;
                        if buf.is_empty() {
                            return Rmsg::Write { count: n };
                        }
                    }
                    if buf.len() > CTL_LIMIT {
                        return perr(ErrorKind::TooLarge, format!("ctl write over {} bytes", CTL_LIMIT));
                    }
                    (path.clone(), Op::Write { path, data: Bytes::from(buf) })
                }
                StatKind::Text | StatKind::Data => {
                    let limit = write_limit(&path, kind);
                    if is_append(&path) {
                        if data.len() > limit {
                            return perr(ErrorKind::TooLarge, format!("append over {limit} bytes"));
                        }
                        (path.clone(), Op::Append { path, data: Bytes::from(data) })
                    } else if *per_write {
                        // Each write is the whole value.
                        if data.len() > limit {
                            return perr(ErrorKind::TooLarge, format!("{} over {} bytes", base(&path), limit));
                        }
                        *dirty = false;
                        (path.clone(), Op::Write { path, data: Bytes::from(data) })
                    } else {
                        let end = offset.saturating_add(data.len() as u64);
                        if end > limit as u64 {
                            return perr(ErrorKind::TooLarge, format!("{} over {} bytes", base(&path), limit));
                        }
                        let (off, end) = (offset as usize, end as usize);
                        if wbuf.len() < end {
                            wbuf.resize(end, 0);
                        }
                        wbuf[off..end].copy_from_slice(&data);
                        *dirty = true;
                        return Rmsg::Write { count: n };
                    }
                }
                _ => return err("permission denied"),
            }
        };
        let _ = path;
        match self.b.apply(self.sid, op).await {
            Ok(()) => Rmsg::Write { count: n },
            Err(e) => err(e),
        }
    }

    async fn clunk(&self, fid: u32) -> Rmsg {
        let Some(f) = self.fids.lock().unwrap().remove(&fid) else { return err("unknown fid") };
        let rclose = f.mode.map(|m| m & ORCLOSE != 0).unwrap_or(false);
        let mut result = Rmsg::Clunk;
        let pending = match f.opened {
            // A held partial ctl line, or a buffered (or truncated, unwritten) value.
            Some(Opened::File { wbuf, .. }) if f.kind == StatKind::Ctl && !wbuf.is_empty() => Some(wbuf),
            Some(Opened::File { wbuf, dirty: true, .. }) if f.kind != StatKind::Ctl => Some(wbuf),
            _ => None,
        };
        if let Some(wbuf) = pending {
            if self.b.is_gone() {
                return gone();
            }
            let op = Op::Write { path: f.path.clone(), data: Bytes::from(wbuf) };
            if let Err(e) = self.b.apply(self.sid, op).await {
                result = err(e);
            }
        }
        if rclose && f.kind == StatKind::Dir
            && let Err(e) = self.b.apply(self.sid, Op::Remove { path: f.path }).await {
                result = err(e);
            }
        result
    }

    async fn remove(&self, fid: u32) -> Rmsg {
        let Some(f) = self.fids.lock().unwrap().remove(&fid) else { return err("unknown fid") };
        if self.b.is_gone() {
            return gone();
        }
        if f.path.as_str().is_empty() {
            return err("permission denied");
        }
        if f.kind != StatKind::Dir {
            // A node's files go with the node; `rm -r` removes them first.
            return Rmsg::Remove;
        }
        match self.b.apply(self.sid, Op::Remove { path: f.path }).await {
            Ok(()) => Rmsg::Remove,
            Err(e) => err(e),
        }
    }

    fn fstat(&self, fid: u32) -> Rmsg {
        if self.b.is_gone() {
            return gone();
        }
        let (path, kind, qid) = {
            let fids = self.fids.lock().unwrap();
            let Some(f) = fids.get(&fid) else { return err("unknown fid") };
            (f.path.clone(), f.kind, f.qid)
        };
        let st = if path.as_str().is_empty() {
            Some(Stat { name: "/".into(), kind: StatKind::Dir, len: 0, version: qid.version })
        } else {
            self.stat(&path)
        };
        let st = match st {
            Some(st) => st,
            // Created but not yet written: report it empty.
            None => Stat { name: base(&path).into(), kind, len: 0, version: qid.version },
        };
        Rmsg::Stat { stat: encode_dir(&self.dir_entry(&path, &st)) }
    }

    fn wstat(&self, fid: u32, stat: Vec<u8>) -> Rmsg {
        if self.b.is_gone() {
            return gone();
        }
        let Some(d) = decode_dir(&stat) else { return perr(ErrorKind::BadSyntax, "stat") };
        let mut fids = self.fids.lock().unwrap();
        let Some(f) = fids.get_mut(&fid) else { return err("unknown fid") };
        if !d.name.is_empty() && d.name != base(&f.path) {
            return err("permission denied: rename");
        }
        // Truncation through wstat (length 0) on an open text file.
        if d.length == 0 && f.kind != StatKind::Dir
            && let Some(Opened::File { wbuf, dirty, .. }) = f.opened.as_mut()
                && f.kind != StatKind::Ctl {
                    wbuf.clear();
                    *dirty = true;
                }
        // Mode, times, owner: accepted and ignored.
        Rmsg::Wstat
    }
}

type Inflight<'a> = Pin<Box<dyn Future<Output = Result<(u16, Rmsg), futures::future::Aborted>> + Send + 'a>>;

pub(crate) async fn serve_conn<T>(io: T, b: Arc<dyn Backend>) -> io::Result<()>
where
    T: AsyncRead + AsyncWrite + Unpin,
{
    let sid = b.new_session();
    let conn = Conn {
        b: b.clone(),
        sid,
        uname: Mutex::new("gpuifs".into()),
        fids: Mutex::new(HashMap::new()),
        msize: AtomicU32::new(MAX_MSIZE),
    };
    let (mut rd, mut wr) = io.split();
    let (tx, mut rx) = futures::channel::mpsc::unbounded::<Vec<u8>>();
    let msize = &conn.msize;

    let reader = async move {
        let mut hdr = [0u8; 4];
        loop {
            if let Err(e) = rd.read_exact(&mut hdr).await {
                return if e.kind() == io::ErrorKind::UnexpectedEof { Ok(()) } else { Err(e) };
            }
            let size = u32::from_le_bytes(hdr);
            if size < 7 || size > msize.load(Ordering::Relaxed).max(8192 + IOHDRSZ) {
                return Err(io::Error::new(io::ErrorKind::InvalidData, format!("bad 9P message size {size}")));
            }
            let mut body = vec![0u8; size as usize - 4];
            rd.read_exact(&mut body).await?;
            if tx.unbounded_send(body).is_err() {
                return Ok(());
            }
        }
    };

    let conn_ref = &conn;
    let main = async move {
        let mut inflight: FuturesUnordered<Inflight<'_>> = FuturesUnordered::new();
        let mut aborts: HashMap<u16, AbortHandle> = HashMap::new();
        loop {
            futures::select! {
                body = rx.next() => {
                    let Some(body) = body else { break };
                    let Some((tag, m)) = decode_t(&body) else {
                        match peek_tag(&body) {
                            Some(tag) => {
                                wr.write_all(&encode_r(tag, &err("bad 9P message"))).await?;
                                wr.flush().await?;
                                continue;
                            }
                            None => return Err(io::Error::new(io::ErrorKind::InvalidData, "bad 9P message")),
                        }
                    };
                    match m {
                        Tmsg::Version { msize, version } => {
                            for (_, h) in aborts.drain() {
                                h.abort();
                            }
                            inflight.clear();
                            conn_ref.fids.lock().unwrap().clear();
                            let _ = conn_ref.b.apply(conn_ref.sid, Op::SessionClosed).await;
                            let ms = msize.clamp(256, MAX_MSIZE);
                            conn_ref.msize.store(ms, Ordering::Relaxed);
                            let v = if version.starts_with("9P2000") { "9P2000" } else { "unknown" };
                            wr.write_all(&encode_r(tag, &Rmsg::Version { msize: ms, version: v.into() })).await?;
                        }
                        Tmsg::Flush { oldtag } => {
                            if let Some(h) = aborts.remove(&oldtag) {
                                h.abort();
                            }
                            wr.write_all(&encode_r(tag, &Rmsg::Flush)).await?;
                        }
                        m => {
                            let (h, reg) = AbortHandle::new_pair();
                            if let Some(old) = aborts.insert(tag, h) {
                                // A reused in-flight tag is a client bug; the old one loses.
                                old.abort();
                            }
                            let fut = async move { (tag, conn_ref.handle(m).await) };
                            inflight.push(Box::pin(Abortable::new(fut, reg)));
                            continue;
                        }
                    }
                    wr.flush().await?;
                }
                done = inflight.select_next_some() => {
                    if let Ok((tag, r)) = done {
                        aborts.remove(&tag);
                        wr.write_all(&encode_r(tag, &r)).await?;
                        wr.flush().await?;
                    }
                }
                complete => break,
            }
        }
        io::Result::Ok(())
    };

    let res = {
        let reader = std::pin::pin!(reader);
        let main = std::pin::pin!(main);
        match futures::future::select(reader, main).await {
            futures::future::Either::Left((r, main)) => {
                // The reader hit EOF or an error: finish the queued requests
                // we already read (their replies may fail to send), then stop.
                let _ = main.await;
                r
            }
            futures::future::Either::Right((r, _)) => r,
        }
    };
    conn.fids.lock().unwrap().clear();
    let _ = b.apply(sid, Op::SessionClosed).await;
    res
}
