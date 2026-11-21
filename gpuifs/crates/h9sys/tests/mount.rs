//! The `.fd` mount: a tiny 9P2000 server on the host end of a socket pair,
//! serving one file, which the guest reads at /mnt/gpui. Needs what
//! tests/run.rs needs.

use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;

const CONTENT: &[u8] = b"gpuifs 0.1\n";

struct W(Vec<u8>);
impl W {
    fn u8(&mut self, v: u8) -> &mut Self { self.0.push(v); self }
    fn u16(&mut self, v: u16) -> &mut Self { self.0.extend(v.to_le_bytes()); self }
    fn u32(&mut self, v: u32) -> &mut Self { self.0.extend(v.to_le_bytes()); self }
    fn u64(&mut self, v: u64) -> &mut Self { self.0.extend(v.to_le_bytes()); self }
    fn s(&mut self, v: &str) -> &mut Self { self.u16(v.len() as u16); self.0.extend(v.as_bytes()); self }
    fn qid(&mut self, path: u64) -> &mut Self { self.u8(if path == 0 { 0x80 } else { 0 }).u32(0).u64(path) }
}

fn stat(path: u64) -> Vec<u8> {
    let mut b = W(vec![]);
    let (name, mode, len) = if path == 0 { ("/", 0x8000_0000u32 | 0o555, 0) } else { ("version", 0o444, CONTENT.len() as u64) };
    b.u16(0).u32(0).qid(path).u32(mode).u32(0).u32(0).u64(len).s(name).s("glenda").s("glenda").s("");
    let mut out = W(vec![]);
    out.u16(b.0.len() as u16);
    out.0.extend(b.0);
    out.0
}

fn serve(mut s: UnixStream) {
    let mut fids = std::collections::HashMap::<u32, u64>::new();
    loop {
        let mut hdr = [0u8; 4];
        if s.read_exact(&mut hdr).is_err() { return; }
        let size = u32::from_le_bytes(hdr) as usize;
        let mut m = vec![0u8; size - 4];
        if s.read_exact(&mut m).is_err() { return; }
        let (ty, tag) = (m[0], u16::from_le_bytes([m[1], m[2]]));
        let b = &m[3..];
        let u32at = |o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap());
        let mut r = W(vec![]);
        let err = |r: &mut W, e: &str| { r.u8(107).u16(tag).s(e); };
        match ty {
            100 => { r.u8(101).u16(tag).u32(u32at(0)).s("9P2000"); }
            104 => { fids.insert(u32at(0), 0); r.u8(105).u16(tag).qid(0); }
            110 => {
                let (fid, newfid) = (u32at(0), u32at(4));
                let n = u16::from_le_bytes([b[8], b[9]]);
                let mut at = fids[&fid];
                let mut qids = vec![];
                let mut o = 10;
                for _ in 0..n {
                    let l = u16::from_le_bytes([b[o], b[o + 1]]) as usize;
                    let name = std::str::from_utf8(&b[o + 2..o + 2 + l]).unwrap();
                    o += 2 + l;
                    match (at, name) {
                        (0, "version") => at = 1,
                        (_, "..") => at = 0,
                        _ => break,
                    }
                    qids.push(at);
                }
                if n > 0 && qids.is_empty() { err(&mut r, "file does not exist"); }
                else {
                    if qids.len() == n as usize { fids.insert(newfid, at); }
                    r.u8(111).u16(tag).u16(qids.len() as u16);
                    for q in qids { r.qid(q); }
                }
            }
            112 => { r.u8(113).u16(tag).qid(fids[&u32at(0)]).u32(0); }
            116 => {
                let path = fids[&u32at(0)];
                let off = u64::from_le_bytes(b[4..12].try_into().unwrap()) as usize;
                let data = if path == 0 { stat(1) } else { CONTENT.to_vec() };
                let chunk = if off >= data.len() { &[][..] } else { &data[off..] };
                r.u8(117).u16(tag).u32(chunk.len() as u32);
                r.0.extend(chunk);
            }
            120 => { fids.remove(&u32at(0)); r.u8(121).u16(tag); }
            124 => { let st = stat(fids[&u32at(0)]); r.u8(125).u16(tag).u16(st.len() as u16); r.0.extend(st); }
            108 => { r.u8(109).u16(tag); }
            _ => err(&mut r, "permission denied"),
        }
        let mut out = (r.0.len() as u32 + 4).to_le_bytes().to_vec();
        out.extend(r.0);
        if s.write_all(&out).is_err() { return; }
    }
}

#[test]
fn guest_reads_the_tree() {
    if !h9sys::BUILT { return eprintln!("skipped: h9 not built in"); }
    let Ok(root) = std::env::var("H9SYS_TEST_ROOT") else { return eprintln!("skipped: no H9SYS_TEST_ROOT") };
    let (host, guest) = UnixStream::pair().unwrap();
    std::thread::spawn(move || serve(host));
    let (r, w) = std::io::pipe().unwrap();
    let (mut r, w) = (File::from(OwnedFd::from(r)), File::from(OwnedFd::from(w)));
    let cfg = h9sys::Config {
        root,
        cwd: std::env::current_dir().unwrap(),
        dirs: vec![],
        ninep_fd: OwnedFd::from(guest),
        ninep_dst: "/mnt/gpui".into(),
        env: vec!["gpuifs=/mnt/gpui".into()],
        out_fd: w.as_raw_fd(),
        err_fd: w.as_raw_fd(),
        profile: String::new(),
        policy_flags: vec![],
    };
    let mut m = h9sys::Machine::new(cfg).unwrap();
    let st = m.run("rc", &["rc".into(), "-c".into(), "ls $gpuifs; cat $gpuifs/version".into()]).unwrap();
    drop(m);
    drop(w);
    let mut s = String::new();
    r.read_to_string(&mut s).unwrap();
    assert_eq!(st, h9sys::Status::Exited(String::new()), "{s}");
    assert_eq!(s, "/mnt/gpui/version\ngpuifs 0.1\n");
}
