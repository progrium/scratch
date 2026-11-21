//! 9P2000 messages: types, decoding and encoding. Decoding never panics on
//! bad input; it returns `None` for anything malformed.

pub const NOTAG: u16 = 0xFFFF;
pub const NOFID: u32 = 0xFFFF_FFFF;

/// Bytes of header in an `Rread`/`Twrite` before the data (size, type, tag, fid/count...).
pub const IOHDRSZ: u32 = 24;

pub const QTDIR: u8 = 0x80;
pub const QTAPPEND: u8 = 0x40;
pub const QTFILE: u8 = 0x00;

pub const DMDIR: u32 = 0x8000_0000;
pub const DMAPPEND: u32 = 0x4000_0000;

pub const OREAD: u8 = 0;
pub const OWRITE: u8 = 1;
pub const ORDWR: u8 = 2;
pub const OEXEC: u8 = 3;
pub const OTRUNC: u8 = 0x10;
pub const ORCLOSE: u8 = 0x40;

/// Plan 9's maximum walk elements per Twalk.
pub const MAXWELEM: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Qid {
    pub ty: u8,
    pub version: u32,
    pub path: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Dir {
    pub ty: u16,
    pub dev: u32,
    pub qid: Qid,
    pub mode: u32,
    pub atime: u32,
    pub mtime: u32,
    pub length: u64,
    pub name: String,
    pub uid: String,
    pub gid: String,
    pub muid: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Tmsg {
    Version { msize: u32, version: String },
    Auth { afid: u32, uname: String, aname: String },
    Attach { fid: u32, afid: u32, uname: String, aname: String },
    Flush { oldtag: u16 },
    Walk { fid: u32, newfid: u32, names: Vec<String> },
    Open { fid: u32, mode: u8 },
    Create { fid: u32, name: String, perm: u32, mode: u8 },
    Read { fid: u32, offset: u64, count: u32 },
    Write { fid: u32, offset: u64, data: Vec<u8> },
    Clunk { fid: u32 },
    Remove { fid: u32 },
    Stat { fid: u32 },
    Wstat { fid: u32, stat: Vec<u8> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rmsg {
    Version { msize: u32, version: String },
    Error { ename: String },
    Attach { qid: Qid },
    Flush,
    Walk { qids: Vec<Qid> },
    Open { qid: Qid, iounit: u32 },
    Create { qid: Qid, iounit: u32 },
    Read { data: Vec<u8> },
    Write { count: u32 },
    Clunk,
    Remove,
    Stat { stat: Vec<u8> },
    Wstat,
}

// Message type numbers.
const TVERSION: u8 = 100;
const TAUTH: u8 = 102;
const TATTACH: u8 = 104;
const TERROR: u8 = 106; // illegal
const TFLUSH: u8 = 108;
const TWALK: u8 = 110;
const TOPEN: u8 = 112;
const TCREATE: u8 = 114;
const TREAD: u8 = 116;
const TWRITE: u8 = 118;
const TCLUNK: u8 = 120;
const TREMOVE: u8 = 122;
const TSTAT: u8 = 124;
const TWSTAT: u8 = 126;

struct Rd<'a> {
    b: &'a [u8],
}

impl<'a> Rd<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        if self.b.len() < n {
            return None;
        }
        let (h, t) = self.b.split_at(n);
        self.b = t;
        Some(h)
    }
    fn u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }
    fn u16(&mut self) -> Option<u16> {
        Some(u16::from_le_bytes(self.take(2)?.try_into().ok()?))
    }
    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }
    fn u64(&mut self) -> Option<u64> {
        Some(u64::from_le_bytes(self.take(8)?.try_into().ok()?))
    }
    fn str(&mut self) -> Option<String> {
        let n = self.u16()? as usize;
        String::from_utf8(self.take(n)?.to_vec()).ok()
    }
    fn qid(&mut self) -> Option<Qid> {
        Some(Qid { ty: self.u8()?, version: self.u32()?, path: self.u64()? })
    }
}

/// Decodes one T-message body (everything after the 4-byte size).
/// Returns the tag and the message, or `None` if it is malformed.
pub fn decode_t(body: &[u8]) -> Option<(u16, Tmsg)> {
    let mut r = Rd { b: body };
    let ty = r.u8()?;
    let tag = r.u16()?;
    let m = match ty {
        TVERSION => Tmsg::Version { msize: r.u32()?, version: r.str()? },
        TAUTH => Tmsg::Auth { afid: r.u32()?, uname: r.str()?, aname: r.str()? },
        TATTACH => Tmsg::Attach { fid: r.u32()?, afid: r.u32()?, uname: r.str()?, aname: r.str()? },
        TFLUSH => Tmsg::Flush { oldtag: r.u16()? },
        TWALK => {
            let fid = r.u32()?;
            let newfid = r.u32()?;
            let n = r.u16()? as usize;
            if n > MAXWELEM {
                return None;
            }
            let mut names = Vec::with_capacity(n);
            for _ in 0..n {
                names.push(r.str()?);
            }
            Tmsg::Walk { fid, newfid, names }
        }
        TOPEN => Tmsg::Open { fid: r.u32()?, mode: r.u8()? },
        TCREATE => Tmsg::Create { fid: r.u32()?, name: r.str()?, perm: r.u32()?, mode: r.u8()? },
        TREAD => Tmsg::Read { fid: r.u32()?, offset: r.u64()?, count: r.u32()? },
        TWRITE => {
            let fid = r.u32()?;
            let offset = r.u64()?;
            let n = r.u32()? as usize;
            Tmsg::Write { fid, offset, data: r.take(n)?.to_vec() }
        }
        TCLUNK => Tmsg::Clunk { fid: r.u32()? },
        TREMOVE => Tmsg::Remove { fid: r.u32()? },
        TSTAT => Tmsg::Stat { fid: r.u32()? },
        TWSTAT => {
            let fid = r.u32()?;
            let n = r.u16()? as usize;
            Tmsg::Wstat { fid, stat: r.take(n)?.to_vec() }
        }
        _ => {
            let _ = TERROR;
            return None;
        }
    };
    if !r.b.is_empty() {
        return None;
    }
    Some((tag, m))
}

/// Just the type and tag of a body, for replying to a message we can't decode.
pub fn peek_tag(body: &[u8]) -> Option<u16> {
    if body.len() < 3 {
        return None;
    }
    Some(u16::from_le_bytes([body[1], body[2]]))
}

#[derive(Default)]
pub struct Wr {
    pub b: Vec<u8>,
}

impl Wr {
    pub fn u8(&mut self, v: u8) {
        self.b.push(v);
    }
    pub fn u16(&mut self, v: u16) {
        self.b.extend_from_slice(&v.to_le_bytes());
    }
    pub fn u32(&mut self, v: u32) {
        self.b.extend_from_slice(&v.to_le_bytes());
    }
    pub fn u64(&mut self, v: u64) {
        self.b.extend_from_slice(&v.to_le_bytes());
    }
    pub fn str(&mut self, s: &str) {
        // 9P strings are at most 65535 bytes; truncate on a char boundary.
        let mut n = s.len().min(u16::MAX as usize);
        while !s.is_char_boundary(n) {
            n -= 1;
        }
        self.u16(n as u16);
        self.b.extend_from_slice(&s.as_bytes()[..n]);
    }
    pub fn qid(&mut self, q: &Qid) {
        self.u8(q.ty);
        self.u32(q.version);
        self.u64(q.path);
    }
}

/// Encodes a whole R-message, size prefix included.
pub fn encode_r(tag: u16, m: &Rmsg) -> Vec<u8> {
    let mut w = Wr::default();
    w.u32(0);
    let ty = match m {
        Rmsg::Version { .. } => TVERSION + 1,
        Rmsg::Error { .. } => TERROR + 1,
        Rmsg::Attach { .. } => TATTACH + 1,
        Rmsg::Flush => TFLUSH + 1,
        Rmsg::Walk { .. } => TWALK + 1,
        Rmsg::Open { .. } => TOPEN + 1,
        Rmsg::Create { .. } => TCREATE + 1,
        Rmsg::Read { .. } => TREAD + 1,
        Rmsg::Write { .. } => TWRITE + 1,
        Rmsg::Clunk => TCLUNK + 1,
        Rmsg::Remove => TREMOVE + 1,
        Rmsg::Stat { .. } => TSTAT + 1,
        Rmsg::Wstat => TWSTAT + 1,
    };
    w.u8(ty);
    w.u16(tag);
    match m {
        Rmsg::Version { msize, version } => {
            w.u32(*msize);
            w.str(version);
        }
        Rmsg::Error { ename } => w.str(ename),
        Rmsg::Attach { qid } => w.qid(qid),
        Rmsg::Walk { qids } => {
            w.u16(qids.len() as u16);
            for q in qids {
                w.qid(q);
            }
        }
        Rmsg::Open { qid, iounit } | Rmsg::Create { qid, iounit } => {
            w.qid(qid);
            w.u32(*iounit);
        }
        Rmsg::Read { data } => {
            w.u32(data.len() as u32);
            w.b.extend_from_slice(data);
        }
        Rmsg::Write { count } => w.u32(*count),
        Rmsg::Stat { stat } => {
            w.u16(stat.len() as u16);
            w.b.extend_from_slice(stat);
        }
        Rmsg::Flush | Rmsg::Clunk | Rmsg::Remove | Rmsg::Wstat => {}
    }
    let n = w.b.len() as u32;
    w.b[..4].copy_from_slice(&n.to_le_bytes());
    w.b
}

/// A machine-independent directory entry, with its own size prefix.
pub fn encode_dir(d: &Dir) -> Vec<u8> {
    let mut w = Wr::default();
    w.u16(0);
    w.u16(d.ty);
    w.u32(d.dev);
    w.qid(&d.qid);
    w.u32(d.mode);
    w.u32(d.atime);
    w.u32(d.mtime);
    w.u64(d.length);
    w.str(&d.name);
    w.str(&d.uid);
    w.str(&d.gid);
    w.str(&d.muid);
    let n = (w.b.len() - 2) as u16;
    w.b[..2].copy_from_slice(&n.to_le_bytes());
    w.b
}

/// Decodes one directory entry (with its size prefix).
pub fn decode_dir(b: &[u8]) -> Option<Dir> {
    let mut r = Rd { b };
    let n = r.u16()? as usize;
    let mut r = Rd { b: r.take(n)? };
    let d = Dir {
        ty: r.u16()?,
        dev: r.u32()?,
        qid: r.qid()?,
        mode: r.u32()?,
        atime: r.u32()?,
        mtime: r.u32()?,
        length: r.u64()?,
        name: r.str()?,
        uid: r.str()?,
        gid: r.str()?,
        muid: r.str()?,
    };
    Some(d)
}

// ---- encoding T-messages and decoding R-messages, for tests and clients ----

pub fn encode_t(tag: u16, m: &Tmsg) -> Vec<u8> {
    let mut w = Wr::default();
    w.u32(0);
    let ty = match m {
        Tmsg::Version { .. } => TVERSION,
        Tmsg::Auth { .. } => TAUTH,
        Tmsg::Attach { .. } => TATTACH,
        Tmsg::Flush { .. } => TFLUSH,
        Tmsg::Walk { .. } => TWALK,
        Tmsg::Open { .. } => TOPEN,
        Tmsg::Create { .. } => TCREATE,
        Tmsg::Read { .. } => TREAD,
        Tmsg::Write { .. } => TWRITE,
        Tmsg::Clunk { .. } => TCLUNK,
        Tmsg::Remove { .. } => TREMOVE,
        Tmsg::Stat { .. } => TSTAT,
        Tmsg::Wstat { .. } => TWSTAT,
    };
    w.u8(ty);
    w.u16(tag);
    match m {
        Tmsg::Version { msize, version } => {
            w.u32(*msize);
            w.str(version);
        }
        Tmsg::Auth { afid, uname, aname } => {
            w.u32(*afid);
            w.str(uname);
            w.str(aname);
        }
        Tmsg::Attach { fid, afid, uname, aname } => {
            w.u32(*fid);
            w.u32(*afid);
            w.str(uname);
            w.str(aname);
        }
        Tmsg::Flush { oldtag } => w.u16(*oldtag),
        Tmsg::Walk { fid, newfid, names } => {
            w.u32(*fid);
            w.u32(*newfid);
            w.u16(names.len() as u16);
            for n in names {
                w.str(n);
            }
        }
        Tmsg::Open { fid, mode } => {
            w.u32(*fid);
            w.u8(*mode);
        }
        Tmsg::Create { fid, name, perm, mode } => {
            w.u32(*fid);
            w.str(name);
            w.u32(*perm);
            w.u8(*mode);
        }
        Tmsg::Read { fid, offset, count } => {
            w.u32(*fid);
            w.u64(*offset);
            w.u32(*count);
        }
        Tmsg::Write { fid, offset, data } => {
            w.u32(*fid);
            w.u64(*offset);
            w.u32(data.len() as u32);
            w.b.extend_from_slice(data);
        }
        Tmsg::Clunk { fid } | Tmsg::Remove { fid } | Tmsg::Stat { fid } => w.u32(*fid),
        Tmsg::Wstat { fid, stat } => {
            w.u32(*fid);
            w.u16(stat.len() as u16);
            w.b.extend_from_slice(stat);
        }
    }
    let n = w.b.len() as u32;
    w.b[..4].copy_from_slice(&n.to_le_bytes());
    w.b
}

pub fn decode_r(body: &[u8]) -> Option<(u16, Rmsg)> {
    let mut r = Rd { b: body };
    let ty = r.u8()?;
    let tag = r.u16()?;
    let m = match ty.wrapping_sub(1) {
        TVERSION => Rmsg::Version { msize: r.u32()?, version: r.str()? },
        TERROR => Rmsg::Error { ename: r.str()? },
        TATTACH => Rmsg::Attach { qid: r.qid()? },
        TFLUSH => Rmsg::Flush,
        TWALK => {
            let n = r.u16()? as usize;
            let mut qids = Vec::new();
            for _ in 0..n {
                qids.push(r.qid()?);
            }
            Rmsg::Walk { qids }
        }
        TOPEN => Rmsg::Open { qid: r.qid()?, iounit: r.u32()? },
        TCREATE => Rmsg::Create { qid: r.qid()?, iounit: r.u32()? },
        TREAD => {
            let n = r.u32()? as usize;
            Rmsg::Read { data: r.take(n)?.to_vec() }
        }
        TWRITE => Rmsg::Write { count: r.u32()? },
        TCLUNK => Rmsg::Clunk,
        TREMOVE => Rmsg::Remove,
        TSTAT => {
            let n = r.u16()? as usize;
            Rmsg::Stat { stat: r.take(n)?.to_vec() }
        }
        TWSTAT => Rmsg::Wstat,
        _ => return None,
    };
    Some((tag, m))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn t_roundtrip() {
        let msgs = vec![
            Tmsg::Version { msize: 8216, version: "9P2000".into() },
            Tmsg::Attach { fid: 0, afid: NOFID, uname: "glenda".into(), aname: "".into() },
            Tmsg::Walk { fid: 0, newfid: 1, names: vec!["windows".into(), "main".into()] },
            Tmsg::Open { fid: 1, mode: OREAD },
            Tmsg::Create { fid: 1, name: "x".into(), perm: DMDIR | 0o755, mode: OREAD },
            Tmsg::Read { fid: 1, offset: 7, count: 8192 },
            Tmsg::Write { fid: 1, offset: 0, data: b"hello".to_vec() },
            Tmsg::Clunk { fid: 1 },
            Tmsg::Flush { oldtag: 3 },
        ];
        for (i, m) in msgs.into_iter().enumerate() {
            let b = encode_t(i as u16, &m);
            assert_eq!(u32::from_le_bytes(b[..4].try_into().unwrap()) as usize, b.len());
            assert_eq!(decode_t(&b[4..]), Some((i as u16, m)));
        }
    }

    #[test]
    fn dir_roundtrip() {
        let d = Dir {
            qid: Qid { ty: QTDIR, version: 3, path: 99 },
            mode: DMDIR | 0o775,
            length: 0,
            name: "root".into(),
            uid: "u".into(),
            gid: "g".into(),
            muid: "m".into(),
            ..Default::default()
        };
        assert_eq!(decode_dir(&encode_dir(&d)), Some(d));
    }

    #[test]
    fn malformed_is_none() {
        assert_eq!(decode_t(&[]), None);
        assert_eq!(decode_t(&[TWRITE, 0, 0, 1, 0, 0, 0]), None);
        assert_eq!(decode_t(&[TWALK, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0xff, 0xff]), None);
        assert_eq!(decode_t(&[250, 0, 0]), None);
    }
}
