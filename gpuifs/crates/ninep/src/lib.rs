//! A 9P2000 server over an `FsBackend`, plus the headless backend.
//! Runtime-agnostic (`futures` io traits). Owned by W3.
#![allow(unused_variables, dead_code)]

use std::io;
use std::sync::Arc;

use futures::io::{AsyncRead, AsyncWrite};

mod headless;
pub use headless::HeadlessBackend;

#[async_trait::async_trait]
pub trait FsBackend: Send + Sync + 'static {
    fn snapshot(&self) -> Arc<tree::Snapshot>;
    /// Waits for the op's ack.
    async fn apply(&self, s: tree::SessionId, op: tree::Op) -> Result<(), proto::Error>;
    fn subscribe(&self, events_file: &tree::FsPath) -> Result<tree::Subscription, proto::Error>;
    fn new_session(&self) -> tree::SessionId;
}

/// Serves one 9P2000 connection until it closes.
pub async fn serve<T: AsyncRead + AsyncWrite + Unpin>(io: T, b: Arc<dyn FsBackend>) -> io::Result<()> {
    todo!("W3")
}
