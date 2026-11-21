//! h9 embedding: the Zig C-ABI shim of DESIGN § Embedding h9 (`shim.zig`,
//! built by `build.rs`) and a safe wrapper. Owned by W4.
#![allow(unused_variables, dead_code)]

use std::marker::PhantomData;
use std::os::fd::{OwnedFd, RawFd};
use std::path::PathBuf;

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

/// `!Send` while running; lives on its own `std::thread`.
pub struct Machine {
    _not_send: PhantomData<*mut ()>,
}

impl Machine {
    pub fn new(c: Config) -> Result<Self, String> {
        todo!("W4")
    }
    /// Blocks until the client exits.
    pub fn run(&mut self, prog: &str, argv: &[String]) -> Result<Status, String> {
        todo!("W4")
    }
    pub fn signals(&self) -> Signals {
        todo!("W4")
    }
}

/// `Send + Clone`; callable from any thread.
#[derive(Clone)]
pub struct Signals {}

impl Signals {
    pub fn hangup(&self) {
        todo!("W4")
    }
    pub fn stop(&self) {
        todo!("W4")
    }
}
