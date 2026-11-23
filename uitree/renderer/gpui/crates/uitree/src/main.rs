//! uitree: the GPUI renderer's binary. Everything but drawing is the core
//! (libuitcore, Zig); this only parses its flags and
//! hands control to GPUI.
//!
//!     uitree [-k] [-t title] [--root DIR] [--bench N] prog [args...]
//!
//! The app runs in h9 with $ui mounted at /mnt/ui. `--root` is h9's
//! (default $H9ROOT, else the built-in root). `--bench N` builds an
//! N-node tree instead of running an app, measures the per-frame cost of
//! reading it through the ABI, prints it and exits. `-k` keeps the
//! window open after the program exits.

fn main() {
    let mut args = std::env::args().skip(1);
    let mut opts = host::Options::default();
    let mut rest = Vec::new();
    while let Some(a) = args.next() {
        match a.as_str() {
            "-t" => opts.title = args.next(),
            "-k" => opts.keep = true,
            "--root" => opts.root = args.next(),
            "--bench" => opts.bench = args.next().and_then(|n| n.parse().ok()),
            "-h" | "--help" => {
                eprintln!("usage: uitree [-k] [-t title] [--root DIR] [--bench N] prog [args...]");
                std::process::exit(2);
            }
            _ => {
                rest.push(a);
                rest.extend(args.by_ref());
            }
        }
    }
    if rest.is_empty() && opts.bench.is_none() {
        eprintln!("usage: uitree [-k] [-t title] [--root DIR] [--bench N] prog [args...]");
        std::process::exit(2);
    }
    opts.root = opts.root.or_else(|| std::env::var("H9ROOT").ok().filter(|r| !r.is_empty()));
    opts.argv = rest;
    std::process::exit(host::run(opts));
}
