//! `gpuifs-headless -a unix!/tmp/g.sock`: the tree with no renderer, over 9P.
//!
//! ```text
//! gpuifs-headless [-a addr] [-insecure] [-v]
//!     -a addr     unix!path (mode 0600), tcp!host!port (needs -insecure),
//!                 fd!N, or - for stdin/stdout (the default)
//!     -insecure   allow tcp
//!     -v          copy the trace file to stderr
//! ```
//!
//! Exits 0 when the app quits.

use std::io::Write;
use std::sync::Arc;

use ninep::transport::{listen_and_serve, parse_addr, Addr};
use ninep::{FsBackend, HeadlessBackend};

fn usage() -> ! {
    eprintln!("usage: gpuifs-headless [-a addr] [-insecure] [-v]");
    std::process::exit(2);
}

fn main() {
    let mut addr = Addr::Stdio;
    let mut insecure = false;
    let mut verbose = false;
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
            _ => usage(),
        }
    }
    if let Addr::Tcp(..) = addr {
        if !insecure {
            eprintln!("gpuifs-headless: tcp refused without -insecure: gpuifs does no authentication");
            std::process::exit(2);
        }
    }

    let backend = HeadlessBackend::new(tree::Registry::from_catalog());
    let dynb: Arc<dyn FsBackend> = backend.clone();

    if verbose {
        // The trace file streams like an events file in the tree; copy it out.
        if let Ok(mut sub) = dynb.subscribe(&tree::FsPath::new("trace")) {
            smol::spawn(async move {
                while let Ok(b) = sub.read(64 * 1024).await {
                    let _ = std::io::stderr().write_all(&b);
                }
            })
            .detach();
        }
    }

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
