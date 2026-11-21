//! `gpuifs-headless -a unix!/tmp/g.sock`: the tree with no renderer, over 9P.
//!
//! ```text
//! gpuifs-headless [-a addr] [-insecure] [-frames] [-v]
//!     -a addr     unix!path (mode 0600), tcp!host!port (needs -insecure),
//!                 fd!N, or - for stdin/stdout (the default)
//!     -insecure   allow tcp
//!     -frames     draw a frame every 16 ms (default: only on /debug/inject frame)
//!     -v          copy the trace file to stderr
//! ```
//!
//! Exits 0 when the app quits.

use std::io::Write;
use std::sync::Arc;

use ninep::transport::{listen_and_serve, parse_addr, Addr};
use ninep::{FsBackend, HeadlessBackend};

fn usage() -> ! {
    eprintln!("usage: gpuifs-headless [-a addr] [-insecure] [-frames] [-v]");
    std::process::exit(2);
}

fn main() {
    let mut addr = Addr::Stdio;
    let mut insecure = false;
    let mut verbose = false;
    let mut opts = ninep::headless::Options::default();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "-a" => {
                let Some(s) = args.next() else { usage() };
                addr = parse_addr(&s).unwrap_or_else(|e| {
                    eprintln!("gpuifs-headless: {e}");
                    std::process::exit(2)
                });
            }
            "-insecure" | "--insecure" => insecure = true,
            "-v" => verbose = true,
            "-frames" => opts.auto_frames = true,
            _ => usage(),
        }
    }
    if let Addr::Tcp(..) = addr
        && !insecure {
            eprintln!("gpuifs-headless: tcp refused without -insecure: gpuifs does no authentication");
            std::process::exit(2);
        }

    let backend = HeadlessBackend::with_options(tree::Registry::from_catalog(), opts);
    if verbose {
        // `trace` is the whole log so far, oldest lines dropped first: copy
        // what is new since the last look.
        let b = backend.clone();
        std::thread::spawn(move || {
            let path = tree::FsPath::new("trace");
            let mut last: Vec<u8> = Vec::new();
            loop {
                std::thread::sleep(std::time::Duration::from_millis(20));
                let cur = b.snapshot().read(&path).unwrap_or_default().to_vec();
                let new = if cur.starts_with(&last) {
                    &cur[last.len()..]
                } else {
                    // Lines fell off the front: resume after the last line we printed.
                    let tail = last.rsplit(|&c| c == b'\n').nth(1).unwrap_or(&[]);
                    match (!tail.is_empty()).then(|| cur.windows(tail.len()).rposition(|w| w == tail)).flatten() {
                        Some(i) => &cur[(i + tail.len() + 1).min(cur.len())..],
                        None => &cur[..],
                    }
                };
                if !new.is_empty() {
                    let _ = std::io::stderr().write_all(new);
                }
                if b.is_gone() && new.is_empty() {
                    break;
                }
                last = cur;
            }
        });
    }

    let dynb: Arc<dyn FsBackend> = backend.clone();
    let sock = match &addr {
        Addr::Unix(p) => Some(p.clone()),
        _ => None,
    };
    let code = smol::block_on(async move {
        let serve = listen_and_serve(&addr, insecure, dynb);
        let gone = backend.wait_gone();
        futures::pin_mut!(serve, gone);
        match futures::future::select(serve, gone).await {
            futures::future::Either::Left((Ok(()), _)) => 0,
            futures::future::Either::Left((Err(e), _)) => {
                eprintln!("gpuifs-headless: {addr}: {e}");
                1
            }
            futures::future::Either::Right(((), _)) => 0,
        }
    });
    if let Some(p) = sock {
        let _ = std::fs::remove_file(p);
    }
    std::process::exit(code);
}
