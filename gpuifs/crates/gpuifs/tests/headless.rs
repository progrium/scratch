//! `gpuifs --headless` with real h9 machines running rc clients. Needs a
//! build with h9 and a 9front root for the host's architecture in
//! `$H9SYS_TEST_ROOT` (hyper9's `zig build isoroot` makes one); skipped
//! otherwise.

use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{Duration, Instant};

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

/// Runs `script` as `gpuifs --headless --root ROOT [flags] rc t.rc` in a
/// fresh directory.
fn run(root: &str, flags: &[&str], script: &str) -> (Output, Duration) {
    let dir = std::env::temp_dir().join(format!("gpuifs-test-{}-{:x}", std::process::id(), rand()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("t.rc"), script).unwrap();
    let start = Instant::now();
    let out = Command::new(env!("CARGO_BIN_EXE_gpuifs"))
        .current_dir(&dir)
        .arg("--headless")
        .args(["--root", root])
        .args(flags)
        .args(["rc", "t.rc"])
        .output()
        .unwrap();
    let took = start.elapsed();
    let _ = std::fs::remove_dir_all(&dir);
    (out, took)
}

fn rand() -> u64 {
    use std::hash::{BuildHasher, RandomState};
    RandomState::new().hash_one(PathBuf::new())
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

#[test]
fn client_sees_the_tree_and_its_exit_status_comes_back() {
    let Some(root) = root() else { return };
    let (out, _) = run(&root, &[], "cat $gpuifs/version | sed 1q\necho 'window main title=Hi' >$gpuifs/ctl\nls $gpuifs/windows\n");
    assert!(out.status.success(), "{out:?}");
    assert_eq!(text(&out.stdout), "gpuifs 0.1\n/mnt/gpui/windows/main\n");
    // The trace goes to stderr.
    assert!(text(&out.stderr).contains("ctl path=ctl cmd='window main title=Hi'"), "{}", text(&out.stderr));

    let (out, _) = run(&root, &[], "exit oops\n");
    assert_eq!(out.status.code(), Some(1));
    assert!(text(&out.stderr).contains("client exited: oops"), "{}", text(&out.stderr));
}

#[test]
fn failed_writes_are_reported() {
    let Some(root) = root() else { return };
    // Whether rc sees the error too depends on the file (at write or at
    // clunk); the trace says it either way.
    let (out, _) = run(&root, &[], "echo 'window main' >$gpuifs/ctl\necho flexx >$gpuifs/windows/main/root/style\n");
    assert!(text(&out.stderr).contains("error path=windows/main/root/style err='unknown style word"), "{}", text(&out.stderr));
}

#[test]
fn quit_hangs_up_a_client_that_stays() {
    let Some(root) = root() else { return };
    // After quit, access fails (not fatal for cat), then sleep until the
    // hangup ends it: the app quit, so gpuifs exits 0.
    let script = "echo 'window main' >$gpuifs/ctl\necho quit >$gpuifs/ctl\ncat $gpuifs/version\nsleep 60\n";
    let (out, took) = run(&root, &[], script);
    assert_eq!(out.status.code(), Some(0), "{out:?}");
    assert!(took < Duration::from_secs(10), "{took:?}");
    assert!(out.stdout.is_empty(), "{out:?}");
}

#[test]
fn a_client_that_exits_after_quit_gives_its_status() {
    let Some(root) = root() else { return };
    let (out, took) = run(&root, &[], "echo quit >$gpuifs/ctl\nexit failed\n");
    assert_eq!(out.status.code(), Some(1), "{out:?}");
    assert!(took < Duration::from_secs(10), "{took:?}");
}

#[test]
fn h9_flags_pass_through() {
    let Some(root) = root() else { return };
    let (out, took) = run(&root, &["--timeout", "1s"], "sleep 30\n");
    assert_eq!(out.status.code(), Some(1), "{out:?}");
    assert!(took < Duration::from_secs(10), "{took:?}");
    assert!(text(&out.stderr).contains("h9: timeout"), "{}", text(&out.stderr));
}

#[test]
fn missing_command() {
    let Some(root) = root() else { return };
    let out = Command::new(env!("CARGO_BIN_EXE_gpuifs"))
        .args(["--headless", "--root", &root, "nosuchcmd"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert!(text(&out.stderr).contains("nosuchcmd"), "{}", text(&out.stderr));
}
