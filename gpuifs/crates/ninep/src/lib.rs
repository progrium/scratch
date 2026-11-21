//! A 9P2000 server over an `FsBackend`, plus the headless backend.
//! Runtime-agnostic (`futures` io traits). Owned by W3.
//!
//! - [`serve`] serves one connection on any `AsyncRead + AsyncWrite`. The host
//!   runs it on GPUI's background executor; headless runs it on `smol`.
//! - [`transport`] has the listeners: `unix!path` (mode 0600), `tcp!host!port`
//!   (only with `insecure`), stdin/stdout, and a socket-pair fd for h9.
//! - [`HeadlessBackend`] is the tree with no renderer, on its own thread.
//!
//! File semantics are documented in `server.rs` and PLAN.md § W3.

use std::io;
use std::sync::Arc;

use bytes::Bytes;
use futures::io::{AsyncRead, AsyncWrite};

pub mod fcall;
mod headless;
mod server;
pub mod transport;

#[cfg(test)]
mod tests;

pub use headless::HeadlessBackend;
pub use server::{CTL_LIMIT, DATA_LIMIT, MAX_MSIZE, PIXELS_LIMIT, TEXT_LIMIT};

#[async_trait::async_trait]
pub trait FsBackend: Send + Sync + 'static {
    fn snapshot(&self) -> Arc<tree::Snapshot>;
    /// Waits for the op's ack.
    async fn apply(&self, s: tree::SessionId, op: tree::Op) -> Result<(), proto::Error>;
    fn subscribe(&self, events_file: &tree::FsPath) -> Result<tree::Subscription, proto::Error>;
    fn new_session(&self) -> tree::SessionId;

    // Additive, with defaults: files a backend serves outside the tree (the
    // headless `/debug/inject`), and whether the app has quit. Writes to an
    // extra file arrive through `apply` like any other.

    /// Stat of a path outside the tree, if this backend serves it.
    fn extra_stat(&self, _p: &tree::FsPath) -> Option<tree::Stat> {
        None
    }
    /// Entries added to a directory listing (for example `debug` in `/`).
    fn extra_readdir(&self, _p: &tree::FsPath) -> Vec<tree::Stat> {
        Vec::new()
    }
    /// Contents of a file outside the tree.
    fn extra_read(&self, _p: &tree::FsPath) -> Option<Bytes> {
        None
    }
    /// After the app quits, every access but an `events` read fails with `app gone`.
    fn is_gone(&self) -> bool {
        false
    }
}

/// Serves one 9P2000 connection until it closes. Ends the backend session
/// (`Op::SessionClosed`) on the way out, so open batches abort.
pub async fn serve<T: AsyncRead + AsyncWrite + Unpin>(io: T, b: Arc<dyn FsBackend>) -> io::Result<()> {
    server::serve_conn(io, Arc::new(server::Adapt(b))).await
}
