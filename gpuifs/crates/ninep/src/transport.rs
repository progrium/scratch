//! Transports: `unix!path` (mode 0600), `tcp!host!port` (only with
//! `insecure`), stdin/stdout (`-`), and `fd!N`, an already-connected socket
//! (the host end of h9's socket pair). These run on `smol`; the GPUI host can
//! use them or call [`crate::serve`] on its own streams.

use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

use futures::io::{AsyncRead, AsyncWrite};

use crate::FsBackend;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Addr {
    /// `unix!path`
    Unix(std::path::PathBuf),
    /// `tcp!host!port`; host `*` listens on every address.
    Tcp(String, u16),
    /// `-`: one connection on stdin and stdout.
    Stdio,
    /// `fd!N`: one connection on an inherited, connected stream socket.
    Fd(i32),
}

impl std::fmt::Display for Addr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Addr::Unix(p) => write!(f, "unix!{}", p.display()),
            Addr::Tcp(h, p) => write!(f, "tcp!{h}!{p}"),
            Addr::Stdio => f.write_str("-"),
            Addr::Fd(n) => write!(f, "fd!{n}"),
        }
    }
}

/// Parses a Plan 9 dial string.
pub fn parse_addr(s: &str) -> Result<Addr, String> {
    if s == "-" || s == "stdio" {
        return Ok(Addr::Stdio);
    }
    let parts: Vec<&str> = s.split('!').collect();
    match parts.as_slice() {
        ["unix", p] if !p.is_empty() => Ok(Addr::Unix(p.into())),
        ["tcp", h, port] | ["net", h, port] => {
            let port: u16 = port.parse().map_err(|_| format!("bad port in {s}"))?;
            Ok(Addr::Tcp(h.to_string(), port))
        }
        ["fd", n] => n.parse().map(Addr::Fd).map_err(|_| format!("bad fd in {s}")),
        _ => Err(format!("bad address {s}: want unix!path, tcp!host!port, fd!N or -")),
    }
}

/// Serves `addr` until it fails (listeners) or the one connection ends
/// (stdio, fd). Each accepted connection is its own 9P session, served on
/// its own smol task.
pub async fn listen_and_serve(addr: &Addr, insecure: bool, b: Arc<dyn FsBackend>) -> io::Result<()> {
    match addr {
        Addr::Stdio => {
            let io = Duplex { r: smol::Unblock::new(io::stdin()), w: smol::Unblock::new(io::stdout()) };
            crate::serve(io, b).await
        }
        #[cfg(unix)]
        Addr::Fd(n) => {
            use std::os::fd::FromRawFd;
            // SAFETY: the caller hands us ownership of an open socket fd.
            let s = unsafe { std::os::unix::net::UnixStream::from_raw_fd(*n) };
            serve_unix_stream(s, b).await
        }
        #[cfg(unix)]
        Addr::Unix(p) => {
            let l = bind_unix(p)?;
            loop {
                let (s, _) = l.accept().await?;
                let b = b.clone();
                smol::spawn(async move {
                    let _ = crate::serve(s, b).await;
                })
                .detach();
            }
        }
        Addr::Tcp(h, port) => {
            if !insecure {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "tcp listening refused without -insecure: gpuifs does no authentication",
                ));
            }
            let host = if h == "*" { "0.0.0.0" } else { h.as_str() };
            let l = smol::net::TcpListener::bind((host, *port)).await?;
            loop {
                let (s, _) = l.accept().await?;
                let _ = s.set_nodelay(true);
                let b = b.clone();
                smol::spawn(async move {
                    let _ = crate::serve(s, b).await;
                })
                .detach();
            }
        }
        #[cfg(not(unix))]
        _ => Err(io::Error::new(io::ErrorKind::Unsupported, "address not supported on this platform")),
    }
}

/// Binds a Unix socket with mode 0600, replacing a stale socket file.
#[cfg(unix)]
pub fn bind_unix(p: &std::path::Path) -> io::Result<smol::net::unix::UnixListener> {
    use std::os::unix::fs::{FileTypeExt, PermissionsExt};
    if let Ok(md) = std::fs::symlink_metadata(p)
        && md.file_type().is_socket() && std::os::unix::net::UnixStream::connect(p).is_err() {
            std::fs::remove_file(p)?;
        }
    let l = std::os::unix::net::UnixListener::bind(p)?;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o600))?;
    l.set_nonblocking(true)?;
    smol::net::unix::UnixListener::try_from(l)
}

/// Serves one connection on a connected Unix stream, for example the host
/// end of `UnixStream::pair()` whose other end goes to the h9 machine.
#[cfg(unix)]
pub async fn serve_unix_stream(s: std::os::unix::net::UnixStream, b: Arc<dyn FsBackend>) -> io::Result<()> {
    s.set_nonblocking(true)?;
    let s = smol::Async::new(s)?;
    crate::serve(s, b).await
}

/// A reader and a writer joined into one stream.
pub struct Duplex<R, W> {
    pub r: R,
    pub w: W,
}

impl<R: AsyncRead + Unpin, W: Unpin> AsyncRead for Duplex<R, W> {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut [u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.r).poll_read(cx, buf)
    }
}

impl<R: Unpin, W: AsyncWrite + Unpin> AsyncWrite for Duplex<R, W> {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.w).poll_write(cx, buf)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.w).poll_flush(cx)
    }
    fn poll_close(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.w).poll_close(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addrs() {
        assert_eq!(parse_addr("unix!/tmp/g.sock"), Ok(Addr::Unix("/tmp/g.sock".into())));
        assert_eq!(parse_addr("tcp!localhost!5640"), Ok(Addr::Tcp("localhost".into(), 5640)));
        assert_eq!(parse_addr("-"), Ok(Addr::Stdio));
        assert_eq!(parse_addr("fd!3"), Ok(Addr::Fd(3)));
        assert!(parse_addr("tcp!x").is_err());
        assert!(parse_addr("/tmp/x").is_err());
    }
}
