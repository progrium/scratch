//! Server tests against an in-memory backend, so the 9P layer and the file
//! semantics are tested without the tree. Headless tests (which need W2's
//! tree) are in `tests_headless`.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use futures::future::BoxFuture;
use futures::StreamExt;
use proto::{Error, ErrorKind};
use tree::{FsPath, Op, SessionId, Stat, StatKind, SubEnd};

use crate::fcall::*;
use crate::server::{serve_conn, Backend, Sub, View, CTL_LIMIT};

// ---- a tiny in-memory tree ----------------------------------------------------

#[derive(Default)]
struct Mem {
    files: BTreeMap<String, (StatKind, Vec<u8>, u32)>,
    ops: Vec<(SessionId, Op)>,
    subs: Vec<futures::channel::mpsc::UnboundedSender<Result<Bytes, SubEnd>>>,
    gone: bool,
}

impl Mem {
    fn add(&mut self, p: &str, k: StatKind, v: &[u8]) {
        self.files.insert(p.to_string(), (k, v.to_vec(), 0));
    }
    fn node(&mut self, p: &str) {
        self.add(p, StatKind::Dir, b"");
        self.add(&format!("{p}/type"), StatKind::Text, b"div");
        self.add(&format!("{p}/text"), StatKind::Text, b"");
        self.add(&format!("{p}/rows"), StatKind::Data, b"");
        self.add(&format!("{p}/append"), StatKind::Data, b"");
        self.add(&format!("{p}/ctl"), StatKind::Ctl, b"new\ndelete\n");
        self.add(&format!("{p}/events"), StatKind::Events, b"");
        self.add(&format!("{p}/id"), StatKind::ReadOnly, p.as_bytes());
    }
}

#[derive(Clone)]
struct MemBackend(Arc<Mutex<Mem>>);

struct MemView(BTreeMap<String, (StatKind, Vec<u8>, u32)>);

fn st(name: &str, e: &(StatKind, Vec<u8>, u32)) -> Stat {
    Stat { name: name.to_string(), kind: e.0, len: e.1.len() as u64, version: e.2 }
}

impl View for MemView {
    fn stat(&self, p: &FsPath) -> Option<Stat> {
        let e = self.0.get(p.as_str())?;
        Some(st(p.as_str().rsplit('/').next().unwrap(), e))
    }
    fn readdir(&self, p: &FsPath) -> Option<Vec<Stat>> {
        let pre = if p.as_str().is_empty() { String::new() } else { format!("{}/", p.as_str()) };
        if !p.as_str().is_empty() && self.0.get(p.as_str())?.0 != StatKind::Dir {
            return None;
        }
        Some(
            self.0
                .iter()
                .filter_map(|(k, v)| {
                    let rest = k.strip_prefix(&pre)?;
                    (!rest.is_empty() && !rest.contains('/')).then(|| st(rest, v))
                })
                .collect(),
        )
    }
    fn read(&self, p: &FsPath) -> Option<Bytes> {
        Some(Bytes::from(self.0.get(p.as_str())?.1.clone()))
    }
}

struct MemSub(futures::channel::mpsc::UnboundedReceiver<Result<Bytes, SubEnd>>);

impl Sub for MemSub {
    fn read(&mut self, max: usize) -> BoxFuture<'_, Result<Bytes, SubEnd>> {
        Box::pin(async move {
            match self.0.next().await {
                Some(Ok(b)) if b.len() > max => Err(SubEnd::ShortRead),
                Some(r) => r,
                None => Err(SubEnd::Eof),
            }
        })
    }
}

impl Backend for MemBackend {
    fn view(&self) -> Arc<dyn View> {
        Arc::new(MemView(self.0.lock().unwrap().files.clone()))
    }
    fn apply(&self, s: SessionId, op: Op) -> BoxFuture<'_, Result<(), Error>> {
        let r = (|| {
            let mut m = self.0.lock().unwrap();
            if m.gone {
                return Err(Error::new(ErrorKind::AppGone, ""));
            }
            m.ops.push((s, op.clone()));
            match op {
                Op::Write { path, data } => {
                    let p = path.as_str().to_string();
                    if p.ends_with("/ctl") || p == "ctl" {
                        let t = String::from_utf8_lossy(&data).to_string();
                        if t.starts_with("bogus") {
                            return Err(Error::new(ErrorKind::UnknownCommand, "bogus"));
                        }
                        if t.trim() == "quit" {
                            m.gone = true;
                            m.subs.clear();
                        }
                        return Ok(());
                    }
                    if data.starts_with(b"bad") {
                        return Err(Error::new(ErrorKind::BadValue, "bad"));
                    }
                    match m.files.get_mut(&p) {
                        Some(e) => {
                            e.1 = data.to_vec();
                            e.2 += 1;
                        }
                        None if p.ends_with("/label") => m.add(&p, StatKind::Text, &data),
                        None => return Err(Error::new(ErrorKind::NotFound, p)),
                    }
                    Ok(())
                }
                Op::Append { path, data } => {
                    let p = path.as_str().to_string();
                    let rows = p.replace("/append", "/rows");
                    let e = m.files.get_mut(&rows).ok_or_else(|| Error::new(ErrorKind::NotFound, p))?;
                    e.1.extend_from_slice(&data);
                    Ok(())
                }
                Op::Mkdir { path } => {
                    let p = path.as_str().to_string();
                    if m.files.contains_key(&p) {
                        return Err(Error::new(ErrorKind::InUse, p));
                    }
                    m.node(&p);
                    Ok(())
                }
                Op::Remove { path } => {
                    let p = path.as_str().to_string();
                    if m.files.remove(&p).is_none() {
                        return Err(Error::new(ErrorKind::NotFound, p));
                    }
                    let pre = format!("{p}/");
                    m.files.retain(|k, _| !k.starts_with(&pre));
                    Ok(())
                }
                Op::SessionClosed => Ok(()),
            }
        })();
        Box::pin(async move { r })
    }
    fn subscribe(&self, _p: &FsPath) -> Result<Box<dyn Sub>, Error> {
        let (tx, rx) = futures::channel::mpsc::unbounded();
        self.0.lock().unwrap().subs.push(tx);
        Ok(Box::new(MemSub(rx)))
    }
    fn new_session(&self) -> SessionId {
        SessionId(7)
    }
    fn is_gone(&self) -> bool {
        self.0.lock().unwrap().gone
    }
}

fn backend() -> MemBackend {
    let mut m = Mem::default();
    m.add("ctl", StatKind::Ctl, b"window\nquit\n");
    m.add("events", StatKind::Events, b"");
    m.add("version", StatKind::ReadOnly, b"gpuifs 0.1\n");
    m.add("windows", StatKind::Dir, b"");
    m.add("windows/main", StatKind::Dir, b"");
    m.node("windows/main/root");
    MemBackend(Arc::new(Mutex::new(m)))
}

impl MemBackend {
    fn push_event(&self, line: &str) {
        let mut m = self.0.lock().unwrap();
        for s in &m.subs {
            let _ = s.unbounded_send(Ok(Bytes::from(line.to_string())));
        }
        m.subs.retain(|s| !s.is_closed());
    }
    fn nsubs(&self) -> usize {
        self.0.lock().unwrap().subs.iter().filter(|s| !s.is_closed()).count()
    }
    fn ops(&self) -> Vec<Op> {
        self.0.lock().unwrap().ops.iter().filter(|(_, o)| *o != Op::SessionClosed).map(|(_, o)| o.clone()).collect()
    }
    fn file(&self, p: &str) -> Vec<u8> {
        self.0.lock().unwrap().files.get(p).map(|e| e.1.clone()).unwrap_or_default()
    }
}

// ---- a test client ------------------------------------------------------------

pub(crate) struct Client {
    pub(crate) s: smol::Async<std::os::unix::net::UnixStream>,
    pub(crate) tag: u16,
}

impl Client {
    pub(crate) async fn send(&mut self, tag: u16, m: &Tmsg) {
        use futures::AsyncWriteExt;
        self.s.write_all(&encode_t(tag, m)).await.unwrap();
    }
    pub(crate) async fn recv(&mut self) -> (u16, Rmsg) {
        use futures::AsyncReadExt;
        let mut h = [0u8; 4];
        self.s.read_exact(&mut h).await.unwrap();
        let n = u32::from_le_bytes(h) as usize;
        let mut b = vec![0u8; n - 4];
        self.s.read_exact(&mut b).await.unwrap();
        decode_r(&b).expect("decodable reply")
    }
    pub(crate) async fn rpc(&mut self, m: Tmsg) -> Rmsg {
        self.tag = self.tag.wrapping_add(1) % 1000;
        let t = self.tag;
        self.send(t, &m).await;
        let (rt, r) = self.recv().await;
        assert_eq!(rt, t);
        r
    }
    pub(crate) async fn ok(&mut self, m: Tmsg) -> Rmsg {
        let r = self.rpc(m.clone()).await;
        if let Rmsg::Error { ename } = &r {
            let d = format!("{m:?}");
            panic!("{}: {ename}", &d[..d.len().min(120)]);
        }
        r
    }
    pub(crate) async fn fail(&mut self, m: Tmsg) -> String {
        match self.rpc(m.clone()).await {
            Rmsg::Error { ename } => ename,
            r => panic!("{m:?}: expected an error, got {r:?}"),
        }
    }
    /// Walks from fid 0 to a new fid.
    pub(crate) async fn walk(&mut self, fid: u32, path: &str) -> Rmsg {
        let names = path.split('/').filter(|s| !s.is_empty()).map(String::from).collect();
        self.rpc(Tmsg::Walk { fid: 0, newfid: fid, names }).await
    }
    pub(crate) async fn open(&mut self, fid: u32, path: &str, mode: u8) {
        if let Rmsg::Error { ename } = self.walk(fid, path).await {
            panic!("walk {path}: {ename}");
        }
        self.ok(Tmsg::Open { fid, mode }).await;
    }
    pub(crate) async fn read_all(&mut self, fid: u32) -> Vec<u8> {
        let mut out = Vec::new();
        loop {
            match self.ok(Tmsg::Read { fid, offset: out.len() as u64, count: 8192 }).await {
                Rmsg::Read { data } if data.is_empty() => return out,
                Rmsg::Read { data } => out.extend(data),
                r => panic!("{r:?}"),
            }
        }
    }
    pub(crate) async fn cat(&mut self, path: &str) -> Vec<u8> {
        self.open(99, path, OREAD).await;
        let b = self.read_all(99).await;
        self.ok(Tmsg::Clunk { fid: 99 }).await;
        b
    }
    pub(crate) async fn ls(&mut self, path: &str) -> Vec<Dir> {
        self.open(98, path, OREAD).await;
        let b = self.read_all(98).await;
        self.ok(Tmsg::Clunk { fid: 98 }).await;
        let mut out = Vec::new();
        let mut r = &b[..];
        while !r.is_empty() {
            let n = u16::from_le_bytes([r[0], r[1]]) as usize + 2;
            out.push(decode_dir(&r[..n]).unwrap());
            r = &r[n..];
        }
        out
    }
}

/// Runs `f` against a fresh server on `b`, after version and attach.
fn with_server<F>(b: MemBackend, f: impl FnOnce(Client) -> F)
where
    F: std::future::Future<Output = ()>,
{
    let (a, c) = std::os::unix::net::UnixStream::pair().unwrap();
    smol::block_on(async move {
        let server = smol::spawn(serve_conn(smol::Async::new(a).unwrap(), Arc::new(b)));
        let mut cl = Client { s: smol::Async::new(c).unwrap(), tag: 0 };
        match cl.ok(Tmsg::Version { msize: 65536 + IOHDRSZ * 2, version: "9P2000".into() }).await {
            Rmsg::Version { version, .. } => assert_eq!(version, "9P2000"),
            r => panic!("{r:?}"),
        }
        cl.ok(Tmsg::Attach { fid: 0, afid: NOFID, uname: "glenda".into(), aname: "".into() }).await;
        f(cl).await;
        drop(server);
    });
}

async fn write_file(cl: &mut Client, fid: u32, path: &str, mode: u8, chunks: &[&[u8]]) -> Rmsg {
    cl.open(fid, path, mode).await;
    let mut off = 0;
    for c in chunks {
        cl.ok(Tmsg::Write { fid, offset: off, data: c.to_vec() }).await;
        off += c.len() as u64;
    }
    cl.rpc(Tmsg::Clunk { fid }).await
}

// ---- tests ----------------------------------------------------------------------

#[test]
fn version_negotiation() {
    let (a, c) = std::os::unix::net::UnixStream::pair().unwrap();
    smol::block_on(async move {
        let _server = smol::spawn(serve_conn(smol::Async::new(a).unwrap(), Arc::new(backend())));
        let mut cl = Client { s: smol::Async::new(c).unwrap(), tag: 0 };
        cl.send(NOTAG, &Tmsg::Version { msize: u32::MAX, version: "9P2000.u".into() }).await;
        assert_eq!(cl.recv().await, (NOTAG, Rmsg::Version { msize: crate::MAX_MSIZE, version: "9P2000".into() }));
        cl.send(NOTAG, &Tmsg::Version { msize: 8192, version: "9P1999".into() }).await;
        assert_eq!(cl.recv().await.1, Rmsg::Version { msize: 8192, version: "unknown".into() });
    });
}

#[test]
fn ls_and_stat() {
    with_server(backend(), |mut cl| async move {
        let names: Vec<String> = cl.ls("/").await.into_iter().map(|d| d.name).collect();
        assert_eq!(names, ["ctl", "events", "version", "windows"]);
        let root = cl.ls("windows/main/root").await;
        let ty = root.iter().find(|d| d.name == "type").unwrap();
        assert_eq!(ty.length, 3);
        assert_eq!(ty.mode, 0o664);
        assert_eq!(ty.uid, "glenda");
        let ev = root.iter().find(|d| d.name == "events").unwrap();
        assert_eq!(ev.mode, 0o444);
        let ap = root.iter().find(|d| d.name == "append").unwrap();
        assert_eq!(ap.mode & DMAPPEND, DMAPPEND);
        assert_eq!(ap.qid.ty, QTAPPEND);

        cl.walk(5, "windows/main/root").await;
        let Rmsg::Stat { stat } = cl.ok(Tmsg::Stat { fid: 5 }).await else { panic!() };
        let d = decode_dir(&stat).unwrap();
        assert_eq!(d.name, "root");
        assert_eq!(d.mode, DMDIR | 0o775);
        assert_eq!(d.qid.ty, QTDIR);

        let Rmsg::Stat { stat } = cl.ok(Tmsg::Stat { fid: 0 }).await else { panic!() };
        assert_eq!(decode_dir(&stat).unwrap().name, "/");

        assert_eq!(cl.cat("version").await, b"gpuifs 0.1\n");
        assert_eq!(cl.cat("windows/main/root/ctl").await, b"new\ndelete\n");
    });
}

#[test]
fn walk_errors() {
    with_server(backend(), |mut cl| async move {
        assert_eq!(cl.walk(5, "nope").await, Rmsg::Error { ename: "not found: nope".into() });
        // A partial walk returns the qids that worked and makes no fid.
        let Rmsg::Walk { qids } = cl.walk(5, "windows/main/zzz").await else { panic!() };
        assert_eq!(qids.len(), 2);
        assert_eq!(cl.fail(Tmsg::Stat { fid: 5 }).await, "unknown fid");
        // Walking through a file stops there.
        let Rmsg::Walk { qids } = cl.walk(5, "ctl/x").await else { panic!() };
        assert_eq!(qids.len(), 1);
        // .. works, and stays at the root.
        let Rmsg::Walk { qids } = cl.walk(6, "windows/../windows/main/..").await else { panic!() };
        assert_eq!(qids.len(), 5);
        cl.ok(Tmsg::Walk { fid: 0, newfid: 7, names: vec!["..".into()] }).await;
        // fid in use
        cl.walk(8, "windows").await;
        assert_eq!(cl.fail(Tmsg::Walk { fid: 0, newfid: 8, names: vec![] }).await, "fid in use");
        // Clone with no names.
        cl.ok(Tmsg::Walk { fid: 8, newfid: 9, names: vec![] }).await;
    });
}

#[test]
fn ctl_applies_each_write() {
    let b = backend();
    let b2 = b.clone();
    with_server(b, |mut cl| async move {
        cl.open(1, "windows/main/root/ctl", OWRITE).await;
        cl.ok(Tmsg::Write { fid: 1, offset: 0, data: b"new text a".to_vec() }).await;
        assert_eq!(b2.ops().len(), 1, "applied before the reply");
        cl.ok(Tmsg::Write { fid: 1, offset: 10, data: b"new text b".to_vec() }).await;
        let e = cl.fail(Tmsg::Write { fid: 1, offset: 20, data: b"bogus".to_vec() }).await;
        assert_eq!(e, "unknown command: bogus");
        cl.ok(Tmsg::Clunk { fid: 1 }).await;
        let ops = b2.ops();
        assert_eq!(ops.len(), 3);
        assert_eq!(
            ops[0],
            Op::Write { path: FsPath::new("windows/main/root/ctl"), data: Bytes::from_static(b"new text a") }
        );

        // One ctl write is at most 64 KiB.
        cl.open(1, "ctl", OWRITE).await;
        let e = cl.fail(Tmsg::Write { fid: 1, offset: 0, data: vec![b'x'; CTL_LIMIT + 1] }).await;
        assert!(e.starts_with("too large"), "{e}");
        cl.ok(Tmsg::Write { fid: 1, offset: 0, data: vec![b' '; CTL_LIMIT] }).await;
    });
}

#[test]
fn text_buffers_until_clunk() {
    let b = backend();
    let b2 = b.clone();
    with_server(b, |mut cl| async move {
        cl.open(1, "windows/main/root/text", OWRITE | OTRUNC).await;
        cl.ok(Tmsg::Write { fid: 1, offset: 0, data: b"hello ".to_vec() }).await;
        cl.ok(Tmsg::Write { fid: 1, offset: 6, data: b"world\n".to_vec() }).await;
        assert!(b2.ops().is_empty(), "nothing applied before clunk");
        cl.ok(Tmsg::Clunk { fid: 1 }).await;
        assert_eq!(
            b2.ops(),
            vec![Op::Write { path: FsPath::new("windows/main/root/text"), data: Bytes::from_static(b"hello world\n") }]
        );
        assert_eq!(cl.cat("windows/main/root/text").await, b"hello world\n");

        // An error at clunk fails the clunk, and the fid is gone anyway.
        let r = write_file(&mut cl, 2, "windows/main/root/text", OWRITE, &[b"bad value"]).await;
        assert_eq!(r, Rmsg::Error { ename: "bad value: bad".into() });
        assert_eq!(cl.fail(Tmsg::Clunk { fid: 2 }).await, "unknown fid");

        // Truncating open with no writes sets the empty value: `echo -n >text`.
        cl.open(3, "windows/main/root/text", OWRITE | OTRUNC).await;
        cl.ok(Tmsg::Clunk { fid: 3 }).await;
        assert_eq!(b2.file("windows/main/root/text"), b"");

        // Open for writing without writing (and without OTRUNC) applies nothing.
        let n = b2.ops().len();
        cl.open(4, "windows/main/root/text", ORDWR).await;
        cl.ok(Tmsg::Clunk { fid: 4 }).await;
        assert_eq!(b2.ops().len(), n);

        // Many 8 KiB writes make one value: `cat big.rs >value`.
        let big: Vec<u8> = (0..100_000u32).map(|i| (i % 251) as u8).collect();
        let chunks: Vec<&[u8]> = big.chunks(8192).collect();
        let n = b2.ops().len();
        write_file(&mut cl, 5, "windows/main/root/rows", OWRITE | OTRUNC, &chunks).await;
        assert_eq!(b2.ops().len(), n + 1);
        assert_eq!(b2.file("windows/main/root/rows"), big);
        assert_eq!(cl.cat("windows/main/root/rows").await, big);
    });
}

#[test]
fn append_applies_per_write() {
    let b = backend();
    let b2 = b.clone();
    with_server(b, |mut cl| async move {
        cl.open(1, "windows/main/root/append", OWRITE).await;
        cl.ok(Tmsg::Write { fid: 1, offset: 0, data: b"a\tb\n".to_vec() }).await;
        cl.ok(Tmsg::Write { fid: 1, offset: 0, data: b"c\td\n".to_vec() }).await;
        assert_eq!(b2.file("windows/main/root/rows"), b"a\tb\nc\td\n");
        cl.ok(Tmsg::Clunk { fid: 1 }).await;
        assert!(matches!(b2.ops().last(), Some(Op::Append { .. })));
        assert_eq!(b2.ops().len(), 2);
    });
}

#[test]
fn readonly_and_events_refuse_writes() {
    with_server(backend(), |mut cl| async move {
        cl.walk(1, "version").await;
        assert_eq!(cl.fail(Tmsg::Open { fid: 1, mode: OWRITE }).await, "permission denied");
        cl.walk(2, "events").await;
        assert_eq!(cl.fail(Tmsg::Open { fid: 2, mode: ORDWR }).await, "permission denied");
        cl.walk(3, "windows").await;
        assert_eq!(cl.fail(Tmsg::Open { fid: 3, mode: OWRITE }).await, "is a directory");
        // Reading without opening.
        cl.walk(4, "ctl").await;
        assert_eq!(cl.fail(Tmsg::Read { fid: 4, offset: 0, count: 10 }).await, "fid not open");
    });
}

#[test]
fn mkdir_and_rm_r() {
    let b = backend();
    let b2 = b.clone();
    with_server(b, |mut cl| async move {
        cl.walk(1, "windows/main/root").await;
        let r = cl.ok(Tmsg::Create { fid: 1, name: "save".into(), perm: DMDIR | 0o777, mode: OREAD }).await;
        let Rmsg::Create { qid, .. } = r else { panic!() };
        assert_eq!(qid.ty, QTDIR);
        assert_eq!(b2.ops(), vec![Op::Mkdir { path: FsPath::new("windows/main/root/save") }]);
        cl.ok(Tmsg::Clunk { fid: 1 }).await;
        assert!(cl.ls("windows/main/root").await.iter().any(|d| d.name == "save"));

        // mkdir of an existing name
        cl.walk(1, "windows/main/root").await;
        let e = cl.fail(Tmsg::Create { fid: 1, name: "save".into(), perm: DMDIR | 0o777, mode: OREAD }).await;
        assert_eq!(e, "in use: windows/main/root/save");

        // rm -r: files first (no-ops), then the directory.
        for f in ["type", "ctl", "text"] {
            cl.walk(2, &format!("windows/main/root/save/{f}")).await;
            cl.ok(Tmsg::Remove { fid: 2 }).await;
        }
        let n = b2.ops().len();
        assert_eq!(n, 2, "the mkdir and the refused mkdir");
        cl.walk(2, "windows/main/root/save").await;
        cl.ok(Tmsg::Remove { fid: 2 }).await;
        assert_eq!(b2.ops().last(), Some(&Op::Remove { path: FsPath::new("windows/main/root/save") }));
        assert!(!cl.ls("windows/main/root").await.iter().any(|d| d.name == "save"));

        // Create of a file not yet listed: written at clunk.
        cl.walk(3, "windows/main/root").await;
        cl.ok(Tmsg::Create { fid: 3, name: "label".into(), perm: 0o664, mode: OWRITE }).await;
        cl.ok(Tmsg::Write { fid: 3, offset: 0, data: b"Save".to_vec() }).await;
        cl.ok(Tmsg::Clunk { fid: 3 }).await;
        assert_eq!(b2.file("windows/main/root/label"), b"Save");
    });
}

#[test]
fn events_block_flush_and_eof() {
    let b = backend();
    let b2 = b.clone();
    with_server(b, |mut cl| async move {
        cl.open(1, "windows/main/root/events", OREAD).await;
        assert_eq!(b2.nsubs(), 1);
        // A blocked read; meanwhile other requests still answer.
        cl.send(500, &Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await;
        assert_eq!(cl.cat("version").await, b"gpuifs 0.1\n");
        b2.push_event("click win=main node=root seq=1\n");
        assert_eq!(cl.recv().await, (500, Rmsg::Read { data: b"click win=main node=root seq=1\n".to_vec() }));

        // Tflush cancels a blocked read: Rflush and no Rread.
        cl.send(501, &Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await;
        cl.send(502, &Tmsg::Flush { oldtag: 501 }).await;
        assert_eq!(cl.recv().await, (502, Rmsg::Flush));
        // The next reply is for a fresh request, so 501 never answered.
        assert_eq!(cl.cat("version").await, b"gpuifs 0.1\n");
        // Flushing an unknown tag still gets Rflush.
        cl.send(503, &Tmsg::Flush { oldtag: 999 }).await;
        assert_eq!(cl.recv().await, (503, Rmsg::Flush));

        // A short buffer gets `short read`.
        b2.push_event("change win=main node=root value=a-long-value seq=2\n");
        let e = cl.fail(Tmsg::Read { fid: 1, offset: 0, count: 10 }).await;
        assert_eq!(e, "short read");

        // Quitting ends the subscription: EOF, then app gone.
        cl.send(504, &Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await;
        cl.open(2, "ctl", OWRITE).await;
        cl.ok(Tmsg::Write { fid: 2, offset: 0, data: b"quit".to_vec() }).await;
        assert_eq!(cl.recv().await, (504, Rmsg::Read { data: vec![] }));
        assert!(matches!(cl.walk(3, "version").await, Rmsg::Walk { .. }), "walks still work");
        assert_eq!(cl.fail(Tmsg::Open { fid: 3, mode: OREAD }).await, "app gone");
        assert_eq!(cl.fail(Tmsg::Write { fid: 2, offset: 0, data: b"x".to_vec() }).await, "app gone");
    });
}

#[test]
fn clunk_drops_subscription() {
    let b = backend();
    let b2 = b.clone();
    with_server(b, |mut cl| async move {
        cl.open(1, "events", OREAD).await;
        cl.open(2, "events", OREAD).await;
        assert_eq!(b2.nsubs(), 2, "each open is its own subscription");
        cl.ok(Tmsg::Clunk { fid: 1 }).await;
        cl.ok(Tmsg::Clunk { fid: 2 }).await;
        b2.push_event("x\n");
        assert_eq!(b2.nsubs(), 0);
    });
}

#[test]
fn session_closed_on_disconnect() {
    let b = backend();
    let b2 = b.clone();
    let (a, c) = std::os::unix::net::UnixStream::pair().unwrap();
    smol::block_on(async move {
        let server = smol::spawn(serve_conn(smol::Async::new(a).unwrap(), Arc::new(b)));
        let mut cl = Client { s: smol::Async::new(c).unwrap(), tag: 0 };
        cl.ok(Tmsg::Version { msize: 8192, version: "9P2000".into() }).await;
        cl.ok(Tmsg::Attach { fid: 0, afid: NOFID, uname: "".into(), aname: "".into() }).await;
        cl.open(1, "events", OREAD).await;
        cl.send(9, &Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await;
        drop(cl);
        server.await.unwrap();
    });
    let ops = b2.0.lock().unwrap().ops.clone();
    assert!(ops.iter().all(|(s, _)| *s == SessionId(7)));
    assert_eq!(ops.last().map(|(_, o)| o.clone()), Some(Op::SessionClosed));
}

#[test]
fn bad_messages_get_errors() {
    let (a, c) = std::os::unix::net::UnixStream::pair().unwrap();
    smol::block_on(async move {
        let _server = smol::spawn(serve_conn(smol::Async::new(a).unwrap(), Arc::new(backend())));
        let mut cl = Client { s: smol::Async::new(c).unwrap(), tag: 0 };
        use futures::AsyncWriteExt;
        // A well-sized message with an unknown type: an error with its tag.
        cl.s.write_all(&[7, 0, 0, 0, 200, 42, 0]).await.unwrap();
        assert_eq!(cl.recv().await, (42, Rmsg::Error { ename: "bad 9P message".into() }));
        assert_eq!(cl.fail(Tmsg::Auth { afid: 1, uname: "".into(), aname: "".into() }).await, "authentication not required");
        assert_eq!(cl.fail(Tmsg::Open { fid: 77, mode: 0 }).await, "unknown fid");
    });
}

/// Random T-messages, well-formed and not, must never panic the server.
#[test]
fn fuzz_random_tmessages() {
    let mut seed: u64 = 0x9e37_79b9_7f4a_7c15;
    let mut rnd = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    for round in 0..40 {
        let b = backend();
        let (a, c) = std::os::unix::net::UnixStream::pair().unwrap();
        let mut msgs: Vec<Vec<u8>> = Vec::new();
        let names = ["windows", "main", "root", "ctl", "text", "events", "..", ".", "x", "append", "rows", ""];
        for _ in 0..300 {
            let fid = (rnd() % 6) as u32;
            let tag = (rnd() % 8) as u16;
            let m = match rnd() % 14 {
                0 => Tmsg::Version { msize: (rnd() % 100_000) as u32, version: "9P2000".into() },
                1 => Tmsg::Attach { fid, afid: NOFID, uname: "u".into(), aname: "".into() },
                2 | 3 => Tmsg::Walk {
                    fid,
                    newfid: (rnd() % 6) as u32,
                    names: (0..rnd() % 4).map(|_| names[(rnd() % names.len() as u64) as usize].to_string()).collect(),
                },
                4 => Tmsg::Open { fid, mode: (rnd() % 256) as u8 },
                5 => Tmsg::Create { fid, name: names[(rnd() % 9) as usize].into(), perm: (rnd() as u32), mode: (rnd() % 4) as u8 },
                // Events reads may block; keep them rarer than other reads.
                6 | 7 => Tmsg::Read { fid, offset: rnd() % 64, count: (rnd() % 9000) as u32 },
                8 => Tmsg::Write { fid, offset: rnd() % 100, data: vec![b'a'; (rnd() % 64) as usize] },
                9 => Tmsg::Clunk { fid },
                10 => Tmsg::Remove { fid },
                11 => Tmsg::Stat { fid },
                12 => Tmsg::Wstat { fid, stat: (0..rnd() % 80).map(|_| rnd() as u8).collect() },
                _ => Tmsg::Flush { oldtag: (rnd() % 8) as u16 },
            };
            let mut bytes = encode_t(tag, &m);
            // Corrupt some of them, keeping the size field honest.
            if rnd() % 5 == 0 && bytes.len() > 5 {
                let i = 4 + (rnd() as usize % (bytes.len() - 4));
                bytes[i] = rnd() as u8;
            }
            if round % 2 == 0 || !matches!(m, Tmsg::Version { .. }) {
                msgs.push(bytes);
            }
        }
        smol::block_on(async move {
            use futures::AsyncWriteExt;
            let server = smol::spawn(serve_conn(smol::Async::new(a).unwrap(), Arc::new(b)));
            let mut s = smol::Async::new(c).unwrap();
            let mut hs = encode_t(NOTAG, &Tmsg::Version { msize: 65536, version: "9P2000".into() });
            hs.extend(encode_t(1, &Tmsg::Attach { fid: 0, afid: NOFID, uname: "u".into(), aname: "".into() }));
            s.write_all(&hs).await.unwrap();
            // Drain replies concurrently so the server never blocks on us.
            let (mut rd, mut wr) = futures::AsyncReadExt::split(s);
            let drain = smol::spawn(async move {
                let mut buf = vec![0u8; 1 << 16];
                while let Ok(n) = futures::AsyncReadExt::read(&mut rd, &mut buf).await {
                    if n == 0 {
                        break;
                    }
                }
            });
            for m in msgs {
                if wr.write_all(&m).await.is_err() {
                    break;
                }
            }
            // Finally a garbage size: the server must drop the connection, not panic.
            let _ = wr.write_all(&[3, 0, 0, 0]).await;
            let _ = wr.close().await;
            drop(wr);
            let r = server.await;
            let _ = r;
            drain.await;
        });
    }
}

#[test]
fn fuzz_random_bytes() {
    let mut seed: u64 = 12345;
    let mut rnd = move || {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (seed >> 33) as u32
    };
    for _ in 0..200 {
        let len = (rnd() % 64) as usize;
        let body: Vec<u8> = (0..len).map(|_| rnd() as u8).collect();
        let _ = decode_t(&body);
        let _ = decode_dir(&body);
        let _ = decode_r(&body);
    }
    // And through the server.
    let (a, c) = std::os::unix::net::UnixStream::pair().unwrap();
    smol::block_on(async move {
        use futures::AsyncWriteExt;
        let server = smol::spawn(serve_conn(smol::Async::new(a).unwrap(), Arc::new(backend())));
        let c2 = c.try_clone().unwrap();
        let s = smol::Async::new(c).unwrap();
        let (mut rd, mut wr) = futures::AsyncReadExt::split(s);
        let drain = smol::spawn(async move {
            let mut buf = vec![0u8; 1 << 16];
            while let Ok(n) = futures::AsyncReadExt::read(&mut rd, &mut buf).await {
                if n == 0 {
                    break;
                }
            }
        });
        for _ in 0..500 {
            let len = 7 + (rnd() % 40) as usize;
            let mut m = (len as u32).to_le_bytes().to_vec();
            m.extend((4..len).map(|_| rnd() as u8));
            if wr.write_all(&m).await.is_err() {
                break;
            }
        }
        let _ = wr.close().await;
        let _ = c2.shutdown(std::net::Shutdown::Write);
        drop(wr);
        let _ = server.await;
        drain.await;
    });
}

#[test]
fn ctl_holds_partial_line_of_a_piece() {
    let b = backend();
    let b2 = b.clone();
    with_server(b, |mut cl| async move {
        let mut piece = Vec::new();
        while piece.len() < 8192 - 20 {
            piece.extend_from_slice(b"new text a\n");
        }
        let full = piece.len();
        piece.resize(8192, b'x'); // the start of a line cut by the 8 KiB split
        cl.open(1, "windows/main/root/ctl", OWRITE).await;
        cl.ok(Tmsg::Write { fid: 1, offset: 0, data: piece.clone() }).await;
        let ops = b2.ops();
        assert_eq!(ops.len(), 1);
        let Op::Write { data, .. } = &ops[0] else { panic!() };
        assert_eq!(data.len(), full, "complete lines only");
        // The next write completes the held line, and holds its own partial tail.
        cl.ok(Tmsg::Write { fid: 1, offset: 8192, data: b"yz\nnew text b".to_vec() }).await;
        let Op::Write { data, .. } = &b2.ops()[1] else { panic!() };
        assert_eq!(data.len(), 8192 - full + 3);
        assert!(data.starts_with(b"xx") && data.ends_with(b"yz\n"));
        // A held line left at clunk applies at clunk.
        assert_eq!(b2.ops().len(), 2);
        cl.ok(Tmsg::Clunk { fid: 1 }).await;
        assert_eq!(b2.ops()[2], Op::Write { path: FsPath::new("windows/main/root/ctl"), data: Bytes::from_static(b"new text b") });
        // A short write with no newline applies at once, as `echo -n` expects.
        cl.open(2, "windows/main/root/ctl", OWRITE).await;
        cl.ok(Tmsg::Write { fid: 2, offset: 0, data: b"new text c".to_vec() }).await;
        assert_eq!(b2.ops().len(), 4);
    });
}

#[test]
fn short_files_apply_per_write() {
    let b = backend();
    let b2 = b.clone();
    {
        let mut m = b2.0.lock().unwrap();
        m.add("windows/main/root/style", StatKind::Text, b"");
    }
    with_server(b, |mut cl| async move {
        cl.open(1, "windows/main/root/style", OWRITE | OTRUNC).await;
        let e = cl.fail(Tmsg::Write { fid: 1, offset: 0, data: b"bad word".to_vec() }).await;
        assert_eq!(e, "bad value: bad", "echo sees the error");
        cl.ok(Tmsg::Write { fid: 1, offset: 0, data: b"p_4".to_vec() }).await;
        assert_eq!(b2.file("windows/main/root/style"), b"p_4");
        let n = b2.ops().len();
        cl.ok(Tmsg::Clunk { fid: 1 }).await;
        assert_eq!(b2.ops().len(), n, "nothing more at clunk");
        // `echo -n >style`: truncating open with no write sets it empty at clunk.
        cl.open(2, "windows/main/root/style", OWRITE | OTRUNC).await;
        cl.ok(Tmsg::Clunk { fid: 2 }).await;
        assert_eq!(b2.file("windows/main/root/style"), b"");
    });
}
