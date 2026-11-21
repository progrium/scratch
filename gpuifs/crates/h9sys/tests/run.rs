//! Runs real machines. Needs a build with h9 and a 9front root for the
//! host's architecture in `$H9SYS_TEST_ROOT` (hyper9's `zig build isoroot`
//! makes one); skipped otherwise.

use std::fs::File;
use std::io::Read;
use std::os::fd::{AsRawFd, OwnedFd};
use std::time::{Duration, Instant};

fn config(root: &str, out: &File) -> h9sys::Config {
    h9sys::Config {
        root: root.into(),
        cwd: std::env::current_dir().unwrap(),
        dirs: vec![],
        ninep_fd: OwnedFd::from(File::open("/dev/null").unwrap()),
        ninep_dst: String::new(),
        env: vec!["gpuifs=/mnt/gpui".into()],
        out_fd: out.as_raw_fd(),
        err_fd: out.as_raw_fd(),
        profile: "default".into(),
        policy_flags: vec![],
    }
}

fn root() -> Option<String> {
    if !h9sys::BUILT {
        eprintln!("skipped: h9 not built in");
        return None;
    }
    let r = std::env::var("H9SYS_TEST_ROOT").ok();
    if r.is_none() {
        eprintln!("skipped: no H9SYS_TEST_ROOT");
    }
    r
}

fn pipe() -> (File, File) {
    let (r, w) = std::io::pipe().unwrap();
    (File::from(OwnedFd::from(r)), File::from(OwnedFd::from(w)))
}

fn rc(cmd: &str) -> Vec<String> {
    vec!["rc".into(), "-c".into(), cmd.into()]
}

#[test]
fn exits_and_output() {
    let Some(root) = root() else { return };
    let (mut r, w) = pipe();
    let mut m = h9sys::Machine::new(config(&root, &w)).unwrap();
    let st = m.run("rc", &rc("echo $gpuifs; exit")).unwrap();
    assert_eq!(st, h9sys::Status::Exited(String::new()));
    let st = m.run("rc", &rc("exit oops")).unwrap();
    assert_eq!(st, h9sys::Status::Exited("oops".into()));
    drop(m);
    drop(w);
    let mut s = String::new();
    r.read_to_string(&mut s).unwrap();
    assert_eq!(s, "/mnt/gpui\n");
}

#[test]
fn not_found() {
    let Some(root) = root() else { return };
    let (_r, w) = pipe();
    let mut m = h9sys::Machine::new(config(&root, &w)).unwrap();
    let e = m.run("nosuchprog", &["nosuchprog".into()]).unwrap_err();
    assert!(e.contains("nosuchprog"), "{e}");
}

#[test]
fn bad_flag() {
    let Some(root) = root() else { return };
    let (_r, w) = pipe();
    let mut c = config(&root, &w);
    c.policy_flags = vec!["--net".into(), "sideways".into()];
    assert!(h9sys::Machine::new(c).is_err());
    let mut c = config(&root, &w);
    c.policy_flags = vec!["--bogus=1".into()];
    let e = h9sys::Machine::new(c).err().unwrap();
    assert!(e.contains("--bogus"), "{e}");
}

#[test]
fn hangup_ends_a_run() {
    let Some(root) = root() else { return };
    let (_r, w) = pipe();
    let mut m = h9sys::Machine::new(config(&root, &w)).unwrap();
    let sig = m.signals();
    let t = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(500));
        sig.hangup();
    });
    let start = Instant::now();
    // `sleep` is in seconds; the hangup kills it long before.
    let st = m.run("rc", &rc("sleep 60")).unwrap();
    t.join().unwrap();
    assert!(start.elapsed() < Duration::from_secs(10), "{:?}", start.elapsed());
    assert!(matches!(st, h9sys::Status::Killed(_) | h9sys::Status::Exited(_)), "{st:?}");
    assert_ne!(st, h9sys::Status::Exited(String::new()));
}

#[test]
fn hangup_before_run() {
    let Some(root) = root() else { return };
    let (_r, w) = pipe();
    let mut m = h9sys::Machine::new(config(&root, &w)).unwrap();
    m.signals().hangup();
    let st = m.run("rc", &rc("sleep 60")).unwrap();
    assert_eq!(st, h9sys::Status::Killed("hangup".into()));
}
