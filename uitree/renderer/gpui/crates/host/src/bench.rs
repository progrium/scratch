//! `uitree --bench N`: the spike's FFI cost measurement.
//!
//! A 9P client on a thread of our own writes one `ctl` that builds an
//! N-node tree (rows of styled texts) through the core's socket, exactly as
//! an app would. Then:
//!
//! 1. a pure ABI walk, with no GPUI: every node's children, type, style
//!    words with their arguments, and the `text`, `on` and `tag` props, as
//!    a frame reads them; repeated and averaged;
//! 2. real frames: the window is redrawn 120 times on GPUI's timer, and
//!    each render records its time in ABI reads and its total build time.
//!
//! It prints both and exits.

use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
// The core serves 9P over unix sockets only (no Windows transport yet), so
// on Windows `listen` fails before the bench dials; this keeps it compiling.
#[cfg(not(unix))]
use std::net::TcpStream as UnixStream;
use std::rc::Rc;
use std::time::{Duration, Instant};

use gpui::{App, AsyncApp};
use uitcore::{Core, Node};

use crate::runtime::Inner as Host;

fn msg(t: u8, tag: u16, body: &[u8]) -> Vec<u8> {
    let mut m = Vec::with_capacity(7 + body.len());
    m.extend_from_slice(&((7 + body.len()) as u32).to_le_bytes());
    m.push(t);
    m.extend_from_slice(&tag.to_le_bytes());
    m.extend_from_slice(body);
    m
}

fn st(s: &str) -> Vec<u8> {
    let mut v = (s.len() as u16).to_le_bytes().to_vec();
    v.extend_from_slice(s.as_bytes());
    v
}

fn rpc(c: &mut UnixStream, m: Vec<u8>) -> Result<Vec<u8>, String> {
    c.write_all(&m).map_err(|e| e.to_string())?;
    let mut sz = [0u8; 4];
    c.read_exact(&mut sz).map_err(|e| e.to_string())?;
    let mut rest = vec![0u8; u32::from_le_bytes(sz) as usize - 4];
    c.read_exact(&mut rest).map_err(|e| e.to_string())?;
    if rest[0] == 107 {
        return Err(String::from_utf8_lossy(&rest[5..]).into_owned());
    }
    Ok(rest)
}

/// Writes `text` to `win/main/ctl` over 9P, as one file (applied at clunk).
pub fn write_ctl(path: &str, text: &str) -> Result<(), String> {
    let mut c = UnixStream::connect(path).map_err(|e| e.to_string())?;
    let mut v = 65536u32.to_le_bytes().to_vec();
    v.extend(st("9P2000"));
    rpc(&mut c, msg(100, 0xffff, &v))?;
    let mut a = 1u32.to_le_bytes().to_vec();
    a.extend_from_slice(&u32::MAX.to_le_bytes());
    a.extend(st("bench"));
    a.extend(st(""));
    rpc(&mut c, msg(104, 1, &a))?;
    let mut w = 1u32.to_le_bytes().to_vec();
    w.extend_from_slice(&2u32.to_le_bytes());
    w.extend_from_slice(&3u16.to_le_bytes());
    for n in ["win", "main", "ctl"] {
        w.extend(st(n));
    }
    rpc(&mut c, msg(110, 2, &w))?;
    let mut o = 2u32.to_le_bytes().to_vec();
    o.push(1);
    rpc(&mut c, msg(112, 3, &o))?;
    for (i, chunk) in text.as_bytes().chunks(32 << 10).enumerate() {
        let mut b = 2u32.to_le_bytes().to_vec();
        b.extend_from_slice(&((i * (32 << 10)) as u64).to_le_bytes());
        b.extend_from_slice(&(chunk.len() as u32).to_le_bytes());
        b.extend_from_slice(chunk);
        rpc(&mut c, msg(118, 4, &b))?;
    }
    rpc(&mut c, msg(120, 5, &2u32.to_le_bytes()))?;
    Ok(())
}

/// The `ctl` text for an N-node tree under the window root.
pub fn tree_ctl(n: usize) -> String {
    let per_row = 49;
    let rows = n.div_ceil(per_row + 1);
    let mut s = String::from("set . title=Bench size=1000,700 : v-flex size-full gap=1 p=4 bg=background\n");
    let mut made = 0;
    for r in 0..rows {
        if made >= n {
            break;
        }
        s.push_str(&format!("new div r{r} tag=row{r} : h-flex gap=2 flex-wrap\n"));
        made += 1;
        for c in 0..per_row {
            if made >= n {
                break;
            }
            s.push_str(&format!("new text r{r}/c{c} text={} on=click : text-xs px=1 rounded=2 border-1 border-color=border hover:bg=accent\n", r * per_row + c));
            made += 1;
        }
    }
    s
}

/// One frame's reads through the ABI, with nothing built. Returns calls made.
pub fn walk(core: &Core, n: Node) -> usize {
    let mut calls = 3;
    std::hint::black_box(core.type_of(n));
    for w in core.style(n) {
        std::hint::black_box(w.name);
        for a in w.args() {
            std::hint::black_box(a);
        }
    }
    for p in ["text", "on", "tag"] {
        std::hint::black_box(core.prop(n, p));
        calls += 1;
    }
    for &k in core.children(n) {
        calls += walk(core, k);
    }
    calls
}

fn count(core: &Core, n: Node) -> usize {
    1 + core.children(n).iter().map(|&k| count(core, k)).sum::<usize>()
}

pub(crate) fn start(host: &Rc<Host>, n: usize, cx: &mut App) {
    let dial = match host.core.borrow_mut().listen() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("bench: listen: {e}");
            return cx.quit();
        }
    };
    let path = dial.trim_start_matches("unix!").to_string();
    let text = tree_ctl(n);
    let t_write = Instant::now();
    // One ctl write per 48 KiB of lines, under 0.2's write limit.
    let writer = std::thread::spawn(move || {
        let mut chunk = String::new();
        for line in text.lines() {
            if chunk.len() + line.len() + 1 > 48 << 10 {
                write_ctl(&path, &chunk)?;
                chunk.clear();
            }
            chunk.push_str(line);
            chunk.push('\n');
        }
        write_ctl(&path, &chunk)
    });
    let h = host.clone();
    cx.spawn(async move |cx: &mut AsyncApp| {
        // The pump loop applies the write; wait for the writer's ack.
        while !writer.is_finished() {
            cx.background_executor().timer(Duration::from_millis(5)).await;
        }
        let built = t_write.elapsed();
        if let Err(e) = writer.join().unwrap() {
            eprintln!("bench: ctl: {e}");
            let _ = cx.update(|cx| cx.quit());
            return;
        }
        // 1. The pure ABI walk.
        let (nodes, calls, per_walk) = {
            let core = h.core.borrow();
            let root = core.window_root("main");
            let nodes = count(&core, root);
            let mut calls = 0;
            for _ in 0..20 {
                calls = walk(&core, root);
            }
            let reps = 200;
            let t = Instant::now();
            for _ in 0..reps {
                walk(&core, root);
            }
            (nodes, calls, t.elapsed() / reps)
        };
        println!("bench: {nodes} nodes built by one 9P ctl write in {:.1} ms", built.as_secs_f64() * 1e3);
        println!(
            "bench: ABI walk (type, style+args, 3 props, children per node): {:.3} ms/frame, {calls} calls, {:.1} ns/call",
            per_walk.as_secs_f64() * 1e3,
            per_walk.as_nanos() as f64 / calls as f64
        );
        // 2. Real frames.
        let _ = cx.update(|cx| crate::window::open(&h, "main", cx));
        h.frames.borrow_mut().clear();
        for _ in 0..120 {
            cx.background_executor().timer(Duration::from_millis(16)).await;
            let _ = cx.update(|cx| {
                // A frame from scratch: forget what the renderer cached.
                if std::env::var_os("UITREE_BENCH_COLD").is_some() {
                    h.cache.borrow_mut().clear();
                }
                crate::runtime::notify_window(&h, "main", cx)
            });
        }
        cx.background_executor().timer(Duration::from_millis(200)).await;
        let mut f = h.frames.borrow().clone();
        f.sort_by_key(|x| x.1);
        if f.is_empty() {
            println!("bench: no frames rendered");
        } else {
            let med = f[f.len() / 2];
            let p90 = f[f.len() * 9 / 10];
            println!(
                "bench: {} frames; whole element build (reads, cached styles, elements): median {:.3} ms, p90 {:.3} ms",
                f.len(),
                med.1.as_secs_f64() * 1e3,
                p90.1.as_secs_f64() * 1e3
            );
        }
        let _ = cx.update(|cx| cx.quit());
    })
    .detach();
}
