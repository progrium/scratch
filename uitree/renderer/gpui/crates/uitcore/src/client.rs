//! A small blocking 9P2000 client over a unix socket, for tests: enough to
//! write `ctl` and prop files and read `events` the way an app in h9 does.

use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;

pub struct Client {
    c: UnixStream,
    next_fid: u32,
}

const TVERSION: u8 = 100;
const TATTACH: u8 = 104;
const TWALK: u8 = 110;
const TOPEN: u8 = 112;
const TCREATE: u8 = 114;
const TREAD: u8 = 116;
const TWRITE: u8 = 118;
const TCLUNK: u8 = 120;
const RERROR: u8 = 107;

fn st(s: &str) -> Vec<u8> {
    let mut v = (s.len() as u16).to_le_bytes().to_vec();
    v.extend_from_slice(s.as_bytes());
    v
}

fn err(t: String) -> io::Error {
    io::Error::other(t)
}

/// An open file on the server.
pub struct File {
    fid: u32,
    offset: u64,
}

impl Client {
    /// Connects to a dial string from `uit_listen` (`unix!PATH`) and attaches.
    pub fn connect(dial: &str) -> io::Result<Client> {
        let path = dial.strip_prefix("unix!").unwrap_or(dial);
        let mut c = Client { c: UnixStream::connect(path)?, next_fid: 1 };
        let mut v = 65536u32.to_le_bytes().to_vec();
        v.extend(st("9P2000"));
        c.rpc(TVERSION, 0xffff, &v)?;
        let mut a = 0u32.to_le_bytes().to_vec();
        a.extend_from_slice(&u32::MAX.to_le_bytes());
        a.extend(st("test"));
        a.extend(st(""));
        c.rpc(TATTACH, 1, &a)?;
        Ok(c)
    }

    fn rpc(&mut self, t: u8, tag: u16, body: &[u8]) -> io::Result<Vec<u8>> {
        let mut m = Vec::with_capacity(7 + body.len());
        m.extend_from_slice(&((7 + body.len()) as u32).to_le_bytes());
        m.push(t);
        m.extend_from_slice(&tag.to_le_bytes());
        m.extend_from_slice(body);
        self.c.write_all(&m)?;
        let mut sz = [0u8; 4];
        self.c.read_exact(&mut sz)?;
        let mut rest = vec![0u8; u32::from_le_bytes(sz) as usize - 4];
        self.c.read_exact(&mut rest)?;
        if rest[0] == RERROR {
            let n = u16::from_le_bytes([rest[3], rest[4]]) as usize;
            return Err(err(String::from_utf8_lossy(&rest[5..5 + n]).into_owned()));
        }
        Ok(rest[3..].to_vec())
    }

    fn walk(&mut self, path: &str) -> io::Result<u32> {
        let fid = {
            self.next_fid += 1;
            self.next_fid
        };
        let names: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
        let mut b = 0u32.to_le_bytes().to_vec();
        b.extend_from_slice(&fid.to_le_bytes());
        b.extend_from_slice(&(names.len() as u16).to_le_bytes());
        for n in &names {
            b.extend(st(n));
        }
        let r = self.rpc(TWALK, 2, &b)?;
        let got = u16::from_le_bytes([r[0], r[1]]) as usize;
        if got != names.len() {
            if got > 0 || names.is_empty() {
                let _ = self.rpc(TCLUNK, 2, &fid.to_le_bytes());
            }
            return Err(err(format!("{path}: not found")));
        }
        Ok(fid)
    }

    /// Opens a file: mode 0 read, 1 write, 2 read and write.
    pub fn open(&mut self, path: &str, mode: u8) -> io::Result<File> {
        let fid = self.walk(path)?;
        let mut o = fid.to_le_bytes().to_vec();
        o.push(mode);
        if let Err(e) = self.rpc(TOPEN, 3, &o) {
            let _ = self.rpc(TCLUNK, 3, &fid.to_le_bytes());
            return Err(e);
        }
        Ok(File { fid, offset: 0 })
    }

    /// Creates a file in a directory and opens it for writing.
    pub fn create(&mut self, dir: &str, name: &str) -> io::Result<File> {
        let fid = self.walk(dir)?;
        let mut b = fid.to_le_bytes().to_vec();
        b.extend(st(name));
        b.extend_from_slice(&0o644u32.to_le_bytes());
        b.push(1);
        self.rpc(TCREATE, 3, &b)?;
        Ok(File { fid, offset: 0 })
    }

    /// One read at the file's offset; empty at the end.
    pub fn read(&mut self, f: &mut File, n: u32) -> io::Result<Vec<u8>> {
        let mut r = f.fid.to_le_bytes().to_vec();
        r.extend_from_slice(&f.offset.to_le_bytes());
        r.extend_from_slice(&n.to_le_bytes());
        let rr = self.rpc(TREAD, 4, &r)?;
        let k = u32::from_le_bytes([rr[0], rr[1], rr[2], rr[3]]) as usize;
        f.offset += k as u64;
        Ok(rr[4..4 + k].to_vec())
    }

    pub fn write(&mut self, f: &mut File, data: &[u8]) -> io::Result<()> {
        let mut wb = f.fid.to_le_bytes().to_vec();
        wb.extend_from_slice(&f.offset.to_le_bytes());
        wb.extend_from_slice(&(data.len() as u32).to_le_bytes());
        wb.extend_from_slice(data);
        self.rpc(TWRITE, 5, &wb)?;
        f.offset += data.len() as u64;
        Ok(())
    }

    /// Clunks the file. For `ctl` and prop files this is when the write
    /// applies, and its error comes back here.
    pub fn close(&mut self, f: File) -> io::Result<()> {
        self.rpc(TCLUNK, 6, &f.fid.to_le_bytes()).map(|_| ())
    }

    /// Writes a whole file (open, write, clunk): what `echo x > file` does.
    pub fn put(&mut self, path: &str, data: &str) -> io::Result<()> {
        let mut f = self.open(path, 1)?;
        let r = self.write(&mut f, data.as_bytes());
        let c = self.close(f);
        r.and(c)
    }

    /// Reads a whole file.
    pub fn get(&mut self, path: &str) -> io::Result<String> {
        let mut f = self.open(path, 0)?;
        let mut out = Vec::new();
        loop {
            let b = self.read(&mut f, 8192)?;
            if b.is_empty() {
                break;
            }
            out.extend(b);
        }
        self.close(f)?;
        Ok(String::from_utf8_lossy(&out).into_owned())
    }
}
