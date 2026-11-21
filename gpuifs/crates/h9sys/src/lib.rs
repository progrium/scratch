//! h9 embedding: the Zig C-ABI shim of DESIGN § Embedding h9 (`zig/shim.zig`,
//! built by `build.rs`) and a safe wrapper. Owned by W4.
//!
//! Without Zig or a hyper9 checkout at build time the crate builds as a stub
//! (`cfg(h9sys_stub)`), and [`Machine::new`] fails with [`NOT_BUILT`].

use std::ffi::{CString, c_char, c_int};
use std::marker::PhantomData;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

pub struct Config {
    /// `builtin`, or an absolute host path to a 9front tree.
    pub root: String,
    pub cwd: PathBuf,
    /// Extra `--dir` mounts, `SRC:DST[:OPTS]`.
    pub dirs: Vec<String>,
    /// The guest end of the socket pair.
    pub ninep_fd: OwnedFd,
    /// `/mnt/gpui`.
    pub ninep_dst: String,
    /// `name=value`, with `gpuifs=/mnt/gpui`.
    pub env: Vec<String>,
    pub out_fd: RawFd,
    pub err_fd: RawFd,
    pub profile: String,
    pub policy_flags: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Status {
    /// The client's `exits` string (empty for success).
    Exited(String),
    /// A kill note such as `h9: timeout`.
    Killed(String),
}

/// Why `Machine::new` fails in a build without h9.
pub const NOT_BUILT: &str = "h9 is not built into this gpuifs (no Zig or hyper9 checkout at build time)";

/// Whether this build links h9.
pub const BUILT: bool = !cfg!(h9sys_stub);

/// The h9 sandbox flags the shim takes (as `--name value` or `--name=value`).
/// The first group takes a value, the second doesn't.
pub const POLICY_FLAGS: &[&str] = &[
    "--profile", "--sandbox", "--readable", "--writable", "--read-deny", "--write", "--net",
    "--net-allow", "--memory", "--timeout", "--pids", "--cpus", "--backend", "--arch",
];
pub const POLICY_SWITCHES: &[&str] = &["--host-fs", "--no-guest-tools"];

mod ffi {
    use super::*;

    #[repr(C)]
    pub struct H9Config {
        pub root: *const c_char,
        pub cwd: *const c_char,
        pub dirs: *const *const c_char,
        pub ninep_fd: c_int,
        pub ninep_dst: *const c_char,
        pub env: *const *const c_char,
        pub out_fd: c_int,
        pub err_fd: c_int,
        pub profile: *const c_char,
        pub policy_flags: *const *const c_char,
    }

    #[repr(C)]
    pub struct H9Machine {
        _p: [u8; 0],
    }

    #[cfg(not(h9sys_stub))]
    unsafe extern "C" {
        pub fn h9_new(cfg: *const H9Config, m: *mut *mut H9Machine, err: *mut c_char, errlen: usize) -> c_int;
        pub fn h9_run(
            m: *mut H9Machine,
            prog: *const c_char,
            argv: *const *const c_char,
            status: *mut c_char,
            statuslen: usize,
        ) -> c_int;
        pub fn h9_hangup(m: *mut H9Machine);
        pub fn h9_stop(m: *mut H9Machine);
        pub fn h9_free(m: *mut H9Machine);
    }

    // The stub: nothing is ever created, so only `h9_new` is reached.
    #[cfg(h9sys_stub)]
    pub unsafe fn h9_new(_: *const H9Config, _: *mut *mut H9Machine, _: *mut c_char, _: usize) -> c_int {
        -1
    }
    #[cfg(h9sys_stub)]
    pub unsafe fn h9_run(_: *mut H9Machine, _: *const c_char, _: *const *const c_char, _: *mut c_char, _: usize) -> c_int {
        -1
    }
    #[cfg(h9sys_stub)]
    pub unsafe fn h9_hangup(_: *mut H9Machine) {}
    #[cfg(h9sys_stub)]
    pub unsafe fn h9_stop(_: *mut H9Machine) {}
    #[cfg(h9sys_stub)]
    pub unsafe fn h9_free(_: *mut H9Machine) {}
}

/// A NULL-terminated array of C strings that owns its strings.
struct CStrs {
    _owned: Vec<CString>,
    ptrs: Vec<*const c_char>,
}

impl CStrs {
    fn new<S: AsRef<str>>(items: &[S]) -> Result<Self, String> {
        let owned = items.iter().map(|s| cstr(s.as_ref())).collect::<Result<Vec<_>, _>>()?;
        let mut ptrs: Vec<*const c_char> = owned.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        Ok(CStrs { _owned: owned, ptrs })
    }
    fn as_ptr(&self) -> *const *const c_char {
        self.ptrs.as_ptr()
    }
}

fn cstr(s: &str) -> Result<CString, String> {
    CString::new(s).map_err(|_| format!("NUL byte in {s:?}"))
}

fn from_buf(buf: &[u8]) -> String {
    let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

/// The machine pointer, shared with `Signals`: freed under the lock, so a
/// signal never reaches a freed machine.
struct Shared {
    ptr: Mutex<*mut ffi::H9Machine>,
}

// The shim's hangup and stop only set atomic flags; they're safe from any
// thread, and the mutex keeps them from racing `h9_free`.
unsafe impl Send for Shared {}
unsafe impl Sync for Shared {}

/// `!Send` while running; lives on its own `std::thread`.
pub struct Machine {
    shared: Arc<Shared>,
    /// Kept open for the machine's life: the shim mounts it on every run.
    _ninep: OwnedFd,
    _not_send: PhantomData<*mut ()>,
}

impl Machine {
    pub fn new(c: Config) -> Result<Self, String> {
        if !BUILT {
            return Err(NOT_BUILT.into());
        }
        let root = cstr(&c.root)?;
        let cwd = cstr(c.cwd.to_str().ok_or("cwd is not UTF-8")?)?;
        let dirs = CStrs::new(&c.dirs)?;
        let dst = cstr(&c.ninep_dst)?;
        let env = CStrs::new(&c.env)?;
        let profile = cstr(&c.profile)?;
        let flags = CStrs::new(&c.policy_flags)?;
        let cfg = ffi::H9Config {
            root: root.as_ptr(),
            cwd: cwd.as_ptr(),
            dirs: dirs.as_ptr(),
            ninep_fd: c.ninep_fd.as_raw_fd(),
            ninep_dst: dst.as_ptr(),
            env: env.as_ptr(),
            out_fd: c.out_fd,
            err_fd: c.err_fd,
            profile: profile.as_ptr(),
            policy_flags: flags.as_ptr(),
        };
        let mut m: *mut ffi::H9Machine = std::ptr::null_mut();
        let mut err = [0u8; 512];
        // SAFETY: every pointer in cfg outlives the call; the shim copies
        // what it keeps.
        let rc = unsafe { ffi::h9_new(&cfg, &mut m, err.as_mut_ptr().cast(), err.len()) };
        if rc != 0 || m.is_null() {
            let why = from_buf(&err);
            return Err(if why.is_empty() { "h9: cannot configure machine".into() } else { why });
        }
        Ok(Machine {
            shared: Arc::new(Shared { ptr: Mutex::new(m) }),
            _ninep: c.ninep_fd,
            _not_send: PhantomData,
        })
    }

    /// Blocks until the client exits.
    pub fn run(&mut self, prog: &str, argv: &[String]) -> Result<Status, String> {
        let p = cstr(prog)?;
        let argv = CStrs::new(argv)?;
        let m = *self.shared.ptr.lock().unwrap();
        let mut status = vec![0u8; 4096];
        // SAFETY: m is live until Drop, which can't run during this call.
        let rc = unsafe { ffi::h9_run(m, p.as_ptr(), argv.as_ptr(), status.as_mut_ptr().cast(), status.len()) };
        let text = from_buf(&status);
        match rc {
            0 => Ok(Status::Exited(text)),
            1 => Ok(Status::Killed(text)),
            _ => Err(text),
        }
    }

    pub fn signals(&self) -> Signals {
        Signals { shared: Some(self.shared.clone()) }
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        let mut p = self.shared.ptr.lock().unwrap();
        if !p.is_null() {
            // SAFETY: created by h9_new, freed once.
            unsafe { ffi::h9_free(*p) };
            *p = std::ptr::null_mut();
        }
    }
}

/// `Send + Clone`; callable from any thread. Calls after the machine is
/// dropped do nothing.
#[derive(Clone, Default)]
pub struct Signals {
    shared: Option<Arc<Shared>>,
}

impl Signals {
    /// A handle connected to no machine, whose calls do nothing.
    pub fn none() -> Self {
        Signals { shared: None }
    }
    /// `hangup` to every process; h9 tears the machine down after 2 s.
    pub fn hangup(&self) {
        self.with(|m| unsafe { ffi::h9_hangup(m) });
    }
    /// Tears the machine down now.
    pub fn stop(&self) {
        self.with(|m| unsafe { ffi::h9_stop(m) });
    }
    fn with(&self, f: impl FnOnce(*mut ffi::H9Machine)) {
        if let Some(s) = &self.shared {
            let p = s.ptr.lock().unwrap();
            if !p.is_null() {
                f(*p);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signals_are_send_clone<T: Send + Sync + Clone>() {}

    #[test]
    fn signals_traits() {
        signals_are_send_clone::<Signals>();
        Signals::none().hangup();
        Signals::none().stop();
    }

    #[test]
    fn cstrs_terminated() {
        let a = CStrs::new(&["a", "bc"]).unwrap();
        assert_eq!(a.ptrs.len(), 3);
        assert!(a.ptrs[2].is_null());
        assert!(CStrs::new(&["a\0b"]).is_err());
    }
}
