//! W4: wire host (or headless), 9P server and h9 machine; map the client's
//! exit string to an exit code.
//!
//! The pieces (DESIGN § Running a client in h9):
//!
//! - a backend: the GPUI host's, or `HeadlessBackend` with `--headless`,
//!   wrapped in [`Guard`], which makes every access after the app quits
//!   fail with `app gone`;
//! - a 9P server on one end of a socket pair, whose other end the machine
//!   mounts on `/mnt/gpui`, and one more per connection to `-a addr`;
//! - the machine, on its own thread, running `cmd`.
//!
//! When the client exits, gpuifs exits with 0 for an empty exit string and
//! 1 otherwise, unless `-k`. When the app quits, the machine gets a hangup
//! and has 2 seconds before h9 tears it down.

use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ninep::FsBackend;
use proto::{Error, ErrorKind};

use crate::cli::{Addr, Args};

/// Where the machine mounts the tree.
pub const MOUNT: &str = "/mnt/gpui";
/// How long the machine has after a hangup before h9 tears it down, plus
/// slack for the teardown itself.
const TEARDOWN: Duration = Duration::from_millis(2500);

/// Returns the process exit code.
pub fn run(args: Args) -> i32 {
    if args.headless {
        return headless(args);
    }
    gui(args)
}

/// What every part of the lifecycle shares.
pub struct App {
    gone: AtomicBool,
    signals: Mutex<h9sys::Signals>,
    quit_tx: Mutex<Option<mpsc::Sender<Event>>>,
}

/// What the main thread waits for.
enum Event {
    /// The client's run ended.
    Client(Result<h9sys::Status, String>),
    /// The app quit (headless: `quit` on the root ctl).
    Quit,
}

impl App {
    fn new(tx: mpsc::Sender<Event>) -> Arc<App> {
        Arc::new(App {
            gone: AtomicBool::new(false),
            signals: Mutex::new(h9sys::Signals::none()),
            quit_tx: Mutex::new(Some(tx)),
        })
    }

    pub fn is_gone(&self) -> bool {
        self.gone.load(Ordering::Acquire)
    }

    /// The app quit: later access fails with `app gone`, and the client
    /// gets a hangup. Idempotent.
    pub fn quit(&self) {
        if self.gone.swap(true, Ordering::AcqRel) {
            return;
        }
        self.signals.lock().unwrap().hangup();
        if let Some(tx) = self.quit_tx.lock().unwrap().take() {
            let _ = tx.send(Event::Quit);
        }
    }
}

/// The backend every 9P connection sees: the real one until the app quits,
/// `app gone` after.
pub struct Guard {
    inner: Arc<dyn FsBackend>,
    app: Arc<App>,
    /// Headless only: a `quit` on the root ctl quits the app here, since no
    /// host is there to do it.
    watch_quit: bool,
}

impl Guard {
    pub fn new(inner: Arc<dyn FsBackend>, app: Arc<App>, watch_quit: bool) -> Arc<dyn FsBackend> {
        Arc::new(Guard { inner, app, watch_quit })
    }
}

fn gone() -> Error {
    Error::new(ErrorKind::AppGone, "")
}

/// Whether a write to the root `ctl` holds a `quit` verb. `quit seq=N`
/// answers a request rather than asking, as `close seq=N` does.
fn is_quit(op: &tree::Op) -> bool {
    let tree::Op::Write { path, data } = op else { return false };
    if path.as_str().trim_matches('/') != "ctl" {
        return false;
    }
    proto::parse_ctl(data).is_ok_and(|cmds| cmds.iter().any(|c| c.verb == "quit" && c.prop("seq").is_none()))
}

#[async_trait::async_trait]
impl FsBackend for Guard {
    fn snapshot(&self) -> Arc<tree::Snapshot> {
        self.inner.snapshot()
    }
    async fn apply(&self, s: tree::SessionId, op: tree::Op) -> Result<(), Error> {
        let closing = matches!(op, tree::Op::SessionClosed);
        if self.app.is_gone() && !closing {
            return Err(gone());
        }
        let quit = self.watch_quit && is_quit(&op);
        self.inner.apply(s, op).await?;
        if quit {
            self.app.quit();
        }
        Ok(())
    }
    fn subscribe(&self, events_file: &tree::FsPath) -> Result<tree::Subscription, Error> {
        if self.app.is_gone() {
            return Err(gone());
        }
        self.inner.subscribe(events_file)
    }
    fn new_session(&self) -> tree::SessionId {
        self.inner.new_session()
    }
}

/// The exit code for how the client's run ended, saying why on stderr
/// when it isn't a plain success.
pub fn exit_code(r: &Result<h9sys::Status, String>) -> i32 {
    match r {
        Ok(h9sys::Status::Exited(s)) if s.is_empty() => 0,
        Ok(h9sys::Status::Exited(s)) => {
            eprintln!("gpuifs: client exited: {s}");
            1
        }
        Ok(h9sys::Status::Killed(note)) => {
            eprintln!("gpuifs: client killed: {note}");
            1
        }
        Err(e) => {
            eprintln!("gpuifs: {e}");
            1
        }
    }
}

/// Serves one connection on its own thread until it closes.
fn serve_stream(stream: UnixStream, backend: Arc<dyn FsBackend>) {
    std::thread::Builder::new()
        .name("gpuifs-9p".into())
        .spawn(move || {
            let io = match smol::Async::new(stream) {
                Ok(io) => io,
                Err(e) => return eprintln!("gpuifs: 9p: {e}"),
            };
            if let Err(e) = smol::block_on(ninep::serve(io, backend)) {
                eprintln!("gpuifs: 9p: {e}");
            }
        })
        .expect("spawning the 9P thread");
}

/// `-a addr`: accepts connections on a thread, each served on its own.
/// Returns the unix socket's path, to remove at exit.
fn listen(addr: &str, backend: Arc<dyn FsBackend>) -> Result<Option<PathBuf>, String> {
    match Addr::parse(addr)? {
        Addr::Unix(path) => {
            use std::os::unix::fs::PermissionsExt;
            let p = PathBuf::from(&path);
            // A socket left by a gpuifs that's gone; a live one is in use.
            if p.exists() {
                if UnixStream::connect(&p).is_ok() {
                    return Err(format!("{path}: in use"));
                }
                let _ = std::fs::remove_file(&p);
            }
            let l = std::os::unix::net::UnixListener::bind(&p).map_err(|e| format!("{path}: {e}"))?;
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600)).map_err(|e| format!("{path}: {e}"))?;
            std::thread::Builder::new()
                .name("gpuifs-listen".into())
                .spawn(move || {
                    for c in l.incoming() {
                        match c {
                            Ok(s) => serve_stream(s, backend.clone()),
                            Err(e) => eprintln!("gpuifs: accept: {e}"),
                        }
                    }
                })
                .map_err(|e| e.to_string())?;
            Ok(Some(p))
        }
        Addr::Tcp(host, port) => {
            let l = std::net::TcpListener::bind((host.as_str(), port)).map_err(|e| format!("tcp!{host}!{port}: {e}"))?;
            std::thread::Builder::new()
                .name("gpuifs-listen".into())
                .spawn(move || {
                    for c in l.incoming() {
                        let s = match c {
                            Ok(s) => s,
                            Err(e) => {
                                eprintln!("gpuifs: accept: {e}");
                                continue;
                            }
                        };
                        let _ = s.set_nodelay(true);
                        let b = backend.clone();
                        std::thread::spawn(move || {
                            let io = match smol::Async::new(s) {
                                Ok(io) => io,
                                Err(e) => return eprintln!("gpuifs: 9p: {e}"),
                            };
                            if let Err(e) = smol::block_on(ninep::serve(io, b)) {
                                eprintln!("gpuifs: 9p: {e}");
                            }
                        });
                    }
                })
                .map_err(|e| e.to_string())?;
            Ok(None)
        }
    }
}

/// The machine's config for `args`, with `guest` as its end of the pair.
fn machine_config(args: &Args, guest: OwnedFd) -> Result<h9sys::Config, String> {
    let cwd = std::env::current_dir().and_then(std::fs::canonicalize).map_err(|e| format!("cwd: {e}"))?;
    let mut env = vec![format!("gpuifs={MOUNT}")];
    env.extend(args.env.iter().cloned());
    Ok(h9sys::Config {
        root: args.root.clone().unwrap_or_else(|| "builtin".into()),
        cwd,
        dirs: args.dirs.clone(),
        ninep_fd: guest,
        ninep_dst: MOUNT.into(),
        env,
        out_fd: std::io::stdout().as_raw_fd(),
        err_fd: std::io::stderr().as_raw_fd(),
        profile: String::new(),
        policy_flags: args.policy_flags.clone(),
    })
}

/// Starts the client: a socket pair served by `backend`, and the machine on
/// its own thread. The run's result goes to `tx`. Fails before anything
/// runs if the machine can't be configured.
fn start_client(args: &Args, backend: Arc<dyn FsBackend>, app: &Arc<App>, tx: mpsc::Sender<Event>) -> Result<(), String> {
    let (host_end, guest_end) = UnixStream::pair().map_err(|e| format!("socketpair: {e}"))?;
    let cfg = machine_config(args, OwnedFd::from(guest_end))?;
    serve_stream(host_end, backend);
    let (prog, argv) = (args.cmd[0].clone(), args.cmd.clone());
    // The machine is !Send: it's made, run and dropped on its thread, and
    // only its signals come back.
    let (sig_tx, sig_rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("gpuifs-h9".into())
        .spawn(move || {
            let mut m = match h9sys::Machine::new(cfg) {
                Ok(m) => m,
                Err(e) => {
                    let _ = sig_tx.send(Err(e));
                    return;
                }
            };
            let _ = sig_tx.send(Ok(m.signals()));
            let r = m.run(&prog, &argv);
            drop(m);
            let _ = tx.send(Event::Client(r));
        })
        .map_err(|e| e.to_string())?;
    let signals = sig_rx.recv().map_err(|_| "h9 thread died".to_string())??;
    *app.signals.lock().unwrap() = signals;
    // A quit that came while the machine was being made.
    if app.is_gone() {
        app.signals.lock().unwrap().hangup();
    }
    Ok(())
}

/// `--headless`: the tree with no window, its trace on stderr.
fn headless(args: Args) -> i32 {
    let (tx, rx) = mpsc::channel();
    let app = App::new(tx.clone());
    let inner: Arc<dyn FsBackend> = ninep::HeadlessBackend::new(tree::Registry::from_catalog());
    let backend = Guard::new(inner, app.clone(), true);
    let trace_stop = trace_to_stderr(&backend);

    let sock = match args.addr.as_deref().map(|a| listen(a, backend.clone())).transpose() {
        Ok(s) => s.flatten(),
        Err(e) => {
            eprintln!("gpuifs: -a {e}");
            return 1;
        }
    };
    let cleanup = || {
        if let Some(p) = &sock {
            let _ = std::fs::remove_file(p);
        }
    };
    if !args.cmd.is_empty() {
        if let Err(e) = start_client(&args, backend.clone(), &app, tx.clone()) {
            eprintln!("gpuifs: {e}");
            cleanup();
            return 1;
        }
    }
    drop(tx);

    let code = loop {
        match rx.recv() {
            Ok(Event::Client(r)) => {
                if app.is_gone() {
                    // The client's end after the app quit is the app's
                    // doing, not a failure.
                    break 0;
                }
                let code = exit_code(&r);
                if !args.keep {
                    break code;
                }
            }
            Ok(Event::Quit) => {
                // Wait for the client's hangup and h9's teardown.
                if !args.cmd.is_empty() {
                    let _ = rx.recv_timeout(TEARDOWN);
                }
                break 0;
            }
            // -a with no client and no quit yet: the senders live in App.
            Err(_) => break 0,
        }
    };
    if let Some(stop) = trace_stop {
        stop();
    }
    cleanup();
    code
}

/// Copies the root `trace` file to stderr on a thread. The returned
/// function drains what is already queued and stops it.
fn trace_to_stderr(backend: &Arc<dyn FsBackend>) -> Option<Box<dyn FnOnce()>> {
    use std::io::Write;
    let mut sub = backend.subscribe(&tree::FsPath::new("trace")).ok()?;
    let stop = Arc::new(AtomicBool::new(false));
    let (done_tx, done_rx) = mpsc::channel::<()>();
    let s = stop.clone();
    std::thread::Builder::new()
        .name("gpuifs-trace".into())
        .spawn(move || {
            smol::block_on(async {
                loop {
                    let read = sub.read(64 << 10);
                    // Once stopping, take only what's already there.
                    let timeout = async {
                        loop {
                            smol::Timer::after(Duration::from_millis(50)).await;
                            if s.load(Ordering::Acquire) {
                                return Err(tree::SubEnd::Eof);
                            }
                        }
                    };
                    match smol::future::or(read, timeout).await {
                        Ok(b) => {
                            let _ = std::io::stderr().write_all(&b);
                        }
                        Err(_) => break,
                    }
                }
            });
            let _ = done_tx.send(());
        })
        .ok()?;
    Some(Box::new(move || {
        stop.store(true, Ordering::Release);
        let _ = done_rx.recv_timeout(Duration::from_millis(500));
    }))
}

/// The GPUI app: `host::run` owns the main thread until the app quits.
#[cfg(feature = "gui")]
fn gui(args: Args) -> i32 {
    let (tx, rx) = mpsc::channel();
    let app = App::new(tx.clone());
    let opts = host::HostOptions { title: args.title.clone(), keep: args.keep };
    let sock: Arc<Mutex<Option<PathBuf>>> = Arc::default();
    let started = {
        let (app, args, sock) = (app.clone(), args.clone(), sock.clone());
        move |inner: Arc<dyn FsBackend>| {
            // The host quits the app itself; the guard only shuts the door
            // once it has.
            let backend = Guard::new(inner, app.clone(), false);
            if let Some(a) = &args.addr {
                match listen(a, backend.clone()) {
                    Ok(p) => *sock.lock().unwrap() = p,
                    Err(e) => {
                        eprintln!("gpuifs: -a {e}");
                        std::process::exit(1);
                    }
                }
            }
            if args.cmd.is_empty() {
                return;
            }
            if let Err(e) = start_client(&args, backend, &app, tx) {
                eprintln!("gpuifs: {e}");
                std::process::exit(1);
            }
            // The client's exit ends the app unless -k. host::run has no
            // way to be told to quit, so this exits the process from here.
            let keep = args.keep;
            let (app, sock) = (app.clone(), sock.clone());
            std::thread::spawn(move || {
                if let Ok(Event::Client(r)) = rx.recv() {
                    if app.is_gone() {
                        return;
                    }
                    let code = exit_code(&r);
                    if !keep {
                        if let Some(p) = sock.lock().unwrap().as_ref() {
                            let _ = std::fs::remove_file(p);
                        }
                        std::process::exit(code);
                    }
                }
            });
        }
    };
    host::run(opts, started);
    // The app quit: the client gets a hangup and its 2 seconds.
    app.quit();
    std::thread::sleep(Duration::from_millis(100));
    if let Some(p) = sock.lock().unwrap().as_ref() {
        let _ = std::fs::remove_file(p);
    }
    0
}

#[cfg(not(feature = "gui"))]
fn gui(_args: Args) -> i32 {
    eprintln!("gpuifs: built without the GPUI host (feature gui); use --headless");
    2
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;

    fn write(path: &str, data: &str) -> tree::Op {
        tree::Op::Write { path: tree::FsPath::new(path), data: Bytes::from(data.to_string()) }
    }

    #[test]
    fn quit_detection() {
        assert!(is_quit(&write("ctl", "quit\n")));
        assert!(is_quit(&write("/ctl", "theme dark\nquit\n")));
        assert!(!is_quit(&write("ctl", "quit seq=4\n")));
        assert!(!is_quit(&write("windows/main/ctl", "quit\n")));
        assert!(!is_quit(&write("ctl", "window main\n")));
        assert!(!is_quit(&tree::Op::Mkdir { path: tree::FsPath::new("ctl") }));
    }

    #[test]
    fn exit_codes() {
        assert_eq!(exit_code(&Ok(h9sys::Status::Exited(String::new()))), 0);
        assert_eq!(exit_code(&Ok(h9sys::Status::Exited("rc: oops".into()))), 1);
        assert_eq!(exit_code(&Ok(h9sys::Status::Killed("h9: timeout".into()))), 1);
        assert_eq!(exit_code(&Err("rc: not found".into())), 1);
    }

    #[test]
    fn app_quit_once() {
        let (tx, rx) = mpsc::channel();
        let app = App::new(tx);
        assert!(!app.is_gone());
        app.quit();
        app.quit();
        assert!(app.is_gone());
        assert!(matches!(rx.recv(), Ok(Event::Quit)));
        assert!(rx.recv().is_err());
    }
}
