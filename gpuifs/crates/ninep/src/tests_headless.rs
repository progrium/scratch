//! End to end: the 9P server over the real tree in `HeadlessBackend`.

use std::sync::Arc;

use crate::fcall::*;
use crate::headless::Options;
use crate::server::{serve_conn, Adapt};
use crate::tests::Client;
use crate::{FsBackend, HeadlessBackend};

// The catalog fills in as the component threads land; these tests bring
// their own few types.
use catalog::{EventKind, EventSpec, PropKind, PropSpec, Slots, Tier, TypeSpec};

const fn spec(name: &'static str, props: &'static [PropSpec]) -> TypeSpec {
    TypeSpec { name, tier: Tier::Element, props, verbs: &[], events: &[], slots: Slots::Any, variants: &[], sizable: false }
}
const fn p(name: &'static str, kind: PropKind) -> PropSpec {
    PropSpec { name, kind, default: None }
}
static DIV: TypeSpec = spec("div", &[]);
static TEXT: TypeSpec = TypeSpec { slots: Slots::None, ..spec("text", &[p("text", PropKind::Text)]) };
static BUTTON: TypeSpec = TypeSpec {
    tier: Tier::Component,
    events: &[EventSpec { name: "click", kind: EventKind::Action }],
    ..spec("button", &[p("label", PropKind::Text)])
};

fn registry() -> tree::Registry {
    let mut r = tree::Registry::from_catalog();
    for t in [&DIV, &TEXT, &BUTTON] {
        if r.get(t.name).is_none() {
            r.insert(t);
        }
    }
    r
}

fn with_headless<F>(opts: Options, f: impl FnOnce(Client, Arc<HeadlessBackend>) -> F)
where
    F: std::future::Future<Output = ()>,
{
    let hb = HeadlessBackend::with_options(registry(), opts);
    let b: Arc<dyn FsBackend> = hb.clone();
    let (a, c) = std::os::unix::net::UnixStream::pair().unwrap();
    smol::block_on(async move {
        let _server = smol::spawn(serve_conn(smol::Async::new(a).unwrap(), Arc::new(Adapt(b))));
        let mut cl = Client { s: smol::Async::new(c).unwrap(), tag: 0 };
        cl.ok(Tmsg::Version { msize: 8192 + IOHDRSZ, version: "9P2000".into() }).await;
        cl.ok(Tmsg::Attach { fid: 0, afid: NOFID, uname: "glenda".into(), aname: "".into() }).await;
        f(cl, hb).await;
    });
}

/// `echo -n data >path`: one write, then clunk; the clunk's result.
async fn put(cl: &mut Client, path: &str, data: &str) -> Result<(), String> {
    cl.open(50, path, OWRITE | OTRUNC).await;
    let w = cl.rpc(Tmsg::Write { fid: 50, offset: 0, data: data.as_bytes().to_vec() }).await;
    let c = cl.rpc(Tmsg::Clunk { fid: 50 }).await;
    match (w, c) {
        (Rmsg::Error { ename }, _) | (_, Rmsg::Error { ename }) => Err(ename),
        _ => Ok(()),
    }
}

async fn text(cl: &mut Client, path: &str) -> String {
    String::from_utf8(cl.cat(path).await).unwrap()
}

#[test]
fn hello_tree() {
    with_headless(Options::default(), |mut cl, _| async move {
        let v = text(&mut cl, "version").await;
        assert!(v.starts_with("gpuifs"), "{v}");
        let names: Vec<String> = cl.ls("/").await.into_iter().map(|d| d.name).collect();
        for n in ["ctl", "events", "trace", "windows", "debug"] {
            assert!(names.iter().any(|x| x == n), "{n} in {names:?}");
        }

        put(&mut cl, "ctl", "window main title=Hello").await.unwrap();
        assert!(cl.ls("windows").await.iter().any(|d| d.name == "main"));
        put(&mut cl, "windows/main/root/style", "v_flex p_4 gap_2").await.unwrap();

        // mkdir, then type and text.
        cl.walk(1, "windows/main/root").await;
        cl.ok(Tmsg::Create { fid: 1, name: "hi".into(), perm: DMDIR | 0o777, mode: OREAD }).await;
        cl.ok(Tmsg::Clunk { fid: 1 }).await;
        put(&mut cl, "windows/main/root/hi/type", "text").await.unwrap();
        put(&mut cl, "windows/main/root/hi/text", "Hello\n").await.unwrap();
        assert_eq!(text(&mut cl, "windows/main/root/hi/text").await, "Hello");

        // new on a ctl
        put(&mut cl, "windows/main/root/ctl", "new button ok label=OK").await.unwrap();
        let tree = text(&mut cl, "windows/main/root/tree").await;
        assert!(tree.contains("text hi"), "{tree}");
        assert!(tree.contains("button ok"), "{tree}");

        // Errors reach the writer of a per-write file and of a ctl.
        let e = put(&mut cl, "windows/main/root/hi/style", "flexx").await.unwrap_err();
        assert!(e.starts_with("unknown style word"), "{e}");
        let e = put(&mut cl, "windows/main/root/ctl", "frobnicate").await.unwrap_err();
        assert!(e.starts_with("unknown command"), "{e}");

        // rm -r: the node's files first, then the node.
        for f in cl.ls("windows/main/root/hi").await {
            cl.walk(2, &format!("windows/main/root/hi/{}", f.name)).await;
            if f.mode & DMDIR == 0 {
                cl.ok(Tmsg::Remove { fid: 2 }).await;
            } else {
                cl.ok(Tmsg::Clunk { fid: 2 }).await;
            }
        }
        cl.walk(2, "windows/main/root/hi").await;
        cl.ok(Tmsg::Remove { fid: 2 }).await;
        assert!(!cl.ls("windows/main/root").await.iter().any(|d| d.name == "hi"));
    });
}

#[test]
fn type_fixed_after_frame() {
    with_headless(Options::default(), |mut cl, _| async move {
        put(&mut cl, "ctl", "window main").await.unwrap();
        put(&mut cl, "windows/main/root/ctl", "new div a").await.unwrap();
        // No frame yet: type is writable.
        put(&mut cl, "windows/main/root/a/type", "text").await.unwrap();
        put(&mut cl, "debug/inject", "frame win=main").await.unwrap();
        let e = put(&mut cl, "windows/main/root/a/type", "div").await.unwrap_err();
        assert!(e.starts_with("type is fixed"), "{e}");
    });
}

#[test]
fn events_inject_and_quit() {
    with_headless(Options::default(), |mut cl, hb| async move {
        put(&mut cl, "ctl", "window main").await.unwrap();
        put(&mut cl, "windows/main/root/ctl", "new button ok label=OK tag=save").await.unwrap();
        cl.open(1, "windows/main/events", OREAD).await;
        let Rmsg::Read { data } = cl.ok(Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await else { panic!() };
        let first = String::from_utf8(data).unwrap();
        assert!(first.starts_with("resync seq="), "{first}");

        put(&mut cl, "debug/inject", "event click win=main node=root/ok").await.unwrap();
        let Rmsg::Read { data } = cl.ok(Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await else { panic!() };
        let line = String::from_utf8(data).unwrap();
        assert!(line.starts_with("click "), "{line}");
        assert!(line.contains("node=root/ok") && line.contains("tag=save"), "{line}");

        // A blocked read, then quit: EOF, then app gone. Replies come in any order.
        cl.open(2, "ctl", OWRITE).await;
        cl.send(700, &Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await;
        cl.send(701, &Tmsg::Write { fid: 2, offset: 0, data: b"quit".to_vec() }).await;
        let (mut eof, mut wrote) = (false, false);
        while !(eof && wrote) {
            match cl.recv().await {
                (701, Rmsg::Write { .. }) => wrote = true,
                (700, Rmsg::Read { data }) if data.is_empty() => eof = true,
                // Lines before the EOF (a `gone`, say) are fine.
                (700, Rmsg::Read { .. }) => cl.send(700, &Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await,
                r => panic!("{r:?}"),
            }
        }
        hb.wait_gone().await;
        cl.walk(3, "version").await;
        assert_eq!(cl.fail(Tmsg::Open { fid: 3, mode: OREAD }).await, "app gone");
        assert!(hb.log().iter().any(|l| l == "quit"), "{:?}", hb.log());
    });
}

#[test]
fn window_close_request() {
    with_headless(Options::default(), |mut cl, hb| async move {
        put(&mut cl, "ctl", "window main").await.unwrap();
        put(&mut cl, "ctl", "window other").await.unwrap();
        // No events file open: the default (close) applies at once.
        put(&mut cl, "windows/other/ctl", "close").await.unwrap();
        assert!(!cl.ls("windows").await.iter().any(|d| d.name == "other"), "{:?}", hb.log());

        // With a reader, the client answers `keep seq=N`.
        cl.open(1, "events", OREAD).await;
        cl.ok(Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await; // resync
        put(&mut cl, "windows/main/ctl", "close").await.unwrap();
        let Rmsg::Read { data } = cl.ok(Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await else { panic!() };
        let line = String::from_utf8(data).unwrap();
        assert!(line.starts_with("close win=main"), "{line}");
        let seq = line.trim().rsplit("seq=").next().unwrap().to_string();
        put(&mut cl, "windows/main/ctl", &format!("keep seq={seq}")).await.unwrap();
        // Skip past the 5 s timeout: kept, so still there.
        put(&mut cl, "debug/inject", "tick 6").await.unwrap();
        assert!(cl.ls("windows").await.iter().any(|d| d.name == "main"));
        // A late answer is not found.
        let e = put(&mut cl, "windows/main/ctl", &format!("close seq={seq}")).await.unwrap_err();
        assert!(e.starts_with("not found"), "{e}");
    });
}

#[test]
fn ctl_long_write_in_pieces() {
    with_headless(Options::default(), |mut cl, _| async move {
        put(&mut cl, "ctl", "window main").await.unwrap();
        // 600 `new` lines, about 14 KiB, written in 8 KiB pieces as cat does.
        let mut cmds = String::new();
        for i in 0..600 {
            cmds.push_str(&format!("new text t{i:04} text=line\n"));
        }
        cl.open(1, "windows/main/root/ctl", OWRITE).await;
        let mut off = 0u64;
        for piece in cmds.as_bytes().chunks(8192) {
            cl.ok(Tmsg::Write { fid: 1, offset: off, data: piece.to_vec() }).await;
            off += piece.len() as u64;
        }
        cl.ok(Tmsg::Clunk { fid: 1 }).await;
        let n = cl.ls("windows/main/root").await.iter().filter(|d| d.name.starts_with('t') && d.mode & DMDIR != 0).count();
        assert_eq!(n, 600);
    });
}

#[test]
fn text_value_across_many_writes() {
    with_headless(Options::default(), |mut cl, _| async move {
        put(&mut cl, "ctl", "window main").await.unwrap();
        put(&mut cl, "windows/main/root/ctl", "new text big").await.unwrap();
        let body: String = (0..5000).map(|i| format!("line {i}\n")).collect();
        cl.open(1, "windows/main/root/big/text", OWRITE | OTRUNC).await;
        let mut off = 0u64;
        for piece in body.as_bytes().chunks(8192) {
            cl.ok(Tmsg::Write { fid: 1, offset: off, data: piece.to_vec() }).await;
            off += piece.len() as u64;
        }
        cl.ok(Tmsg::Clunk { fid: 1 }).await;
        let got = text(&mut cl, "windows/main/root/big/text").await;
        assert_eq!(got.len() + 1, body.len(), "one trailing newline dropped");
    });
}

#[test]
fn debug_inject_errors() {
    with_headless(Options::default(), |mut cl, _| async move {
        let e = put(&mut cl, "debug/inject", "explode").await.unwrap_err();
        assert!(e.starts_with("unknown command"), "{e}");
        let e = put(&mut cl, "debug/inject", "bounds win=main value='1 2 3'").await.unwrap_err();
        assert!(e.starts_with("bad value"), "{e}");
        let e = put(&mut cl, "debug/inject", "event click node=root/x").await.unwrap_err();
        assert!(e.starts_with("bad syntax"), "{e}");
        assert!(text(&mut cl, "debug/inject").await.contains("tick SECONDS"));
        put(&mut cl, "debug/inject", "drag n=3 type=text data=hello").await.unwrap();
        assert_eq!(text(&mut cl, "drags/3/data").await, "hello");
    });
}

#[test]
fn read_after_quit_is_eof_and_walks_still_work() {
    with_headless(Options::default(), |mut cl, _| async move {
        put(&mut cl, "ctl", "window main").await.unwrap();
        cl.open(1, "events", OREAD).await;
        put(&mut cl, "ctl", "quit").await.unwrap();
        // Whatever was queued (resync, gone), then EOF.
        let mut n = 0;
        loop {
            let Rmsg::Read { data } = cl.ok(Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await else { panic!() };
            if data.is_empty() {
                break;
            }
            n += 1;
            assert!(n < 5, "no EOF");
        }
        // Walks succeed, so the kernel doesn't fall back to create; open and create fail.
        assert!(matches!(cl.walk(2, "ctl").await, Rmsg::Walk { .. }));
        assert_eq!(cl.fail(Tmsg::Open { fid: 2, mode: OWRITE | OTRUNC }).await, "app gone");
        cl.walk(3, "windows").await;
        let e = cl.fail(Tmsg::Create { fid: 3, name: "x".into(), perm: 0o664, mode: OWRITE }).await;
        assert_eq!(e, "app gone");
        assert_eq!(cl.fail(Tmsg::Stat { fid: 3 }).await, "app gone");
        assert!(matches!(cl.walk(4, "nope").await, Rmsg::Error { .. }));
    });
}

#[test]
fn injected_quit_waits_for_a_reader() {
    with_headless(Options::default(), |mut cl, hb| async move {
        put(&mut cl, "ctl", "window main").await.unwrap();
        // After the fake clock has moved on, a new request still gets its 5 s.
        put(&mut cl, "debug/inject", "tick 5").await.unwrap();
        cl.open(1, "events", OREAD).await;
        cl.ok(Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await; // resync
        put(&mut cl, "debug/inject", "event quit via=menu").await.unwrap();
        put(&mut cl, "debug/inject", "tick 1").await.unwrap();
        assert!(!hb.is_gone(), "{:?}", hb.log());
        let Rmsg::Read { data } = cl.ok(Tmsg::Read { fid: 1, offset: 0, count: 8192 }).await else { panic!() };
        let s = String::from_utf8(data).unwrap();
        assert!(s.contains("quit "), "{s}");
        let seq = s.trim().rsplit("seq=").next().unwrap().to_string();
        put(&mut cl, "ctl", &format!("keep seq={seq}")).await.unwrap();
        put(&mut cl, "debug/inject", "tick 6").await.unwrap();
        assert!(!hb.is_gone(), "{:?}", hb.log());
    });
}

#[test]
fn rm_menu_file() {
    with_headless(Options::default(), |mut cl, _| async move {
        cl.walk(2, "menus").await;
        cl.ok(Tmsg::Create { fid: 2, name: "Help".into(), perm: 0o664, mode: OWRITE }).await;
        cl.ok(Tmsg::Write { fid: 2, offset: 0, data: b"item about label=About\n".to_vec() }).await;
        cl.ok(Tmsg::Clunk { fid: 2 }).await;
        assert!(cl.ls("menus").await.iter().any(|d| d.name == "Help"));
        cl.walk(2, "menus/Help").await;
        cl.ok(Tmsg::Remove { fid: 2 }).await;
        assert!(!cl.ls("menus").await.iter().any(|d| d.name == "Help"));
    });
}
