// A 9P2000 client for `$ui` on the page, for tests and tools: a
// connection to the core of its own (Core.serve), beside the app's. It
// reads and writes the tree's files the way an app does, so a test can
// find a node (its `bounds`), check a value, or drive the app.
//
//	const ui = await probe(core);
//	await ui.read('win/main/row/name/value');
//	await ui.write('win/main/ctl', 'set out text=hi');
//	await ui.bounds('win/main/row/go');   // [x, y, w, h] in window points

const enc = new TextEncoder();
const dec = new TextDecoder();

const T = { version: 100, attach: 104, error: 107, walk: 110, open: 112, read: 116, write: 118, clunk: 120 };

export async function probe(core) {
  let buf = new Uint8Array(0);
  const waiting = new Map();
  let closed = false;
  const ch = core.serve((b) => {
    const n = new Uint8Array(buf.length + b.length);
    n.set(buf);
    n.set(b, buf.length);
    buf = n;
    while (buf.length >= 4) {
      const size = new DataView(buf.buffer, buf.byteOffset).getUint32(0, true);
      if (buf.length < size) break;
      const m = buf.slice(0, size);
      buf = buf.slice(size);
      const dv = new DataView(m.buffer);
      const tag = dv.getUint16(5, true);
      const w = waiting.get(tag);
      waiting.delete(tag);
      w?.(m);
    }
  }, () => { closed = true; });

  let nextTag = 1, nextFid = 1;
  const rpc = (type, body) => new Promise((res, rej) => {
    if (closed) return rej(new Error('9p: closed'));
    const tag = nextTag++ & 0xffff || nextTag++;
    const m = new Uint8Array(7 + body.length);
    const dv = new DataView(m.buffer);
    dv.setUint32(0, m.length, true);
    m[4] = type;
    dv.setUint16(5, tag, true);
    m.set(body, 7);
    waiting.set(tag, (r) => {
      if (r[4] === T.error) {
        const v = new DataView(r.buffer), n = v.getUint16(7, true);
        rej(new Error(dec.decode(r.subarray(9, 9 + n))));
      } else res(r);
    });
    ch.push(m);
  });
  const pack = (...parts) => {
    const bs = parts.map(([k, v]) => {
      if (k === 's') { const s = enc.encode(v); const b = new Uint8Array(2 + s.length); new DataView(b.buffer).setUint16(0, s.length, true); b.set(s, 2); return b; }
      if (k === 'b') return v;
      const n = { 1: 1, 2: 2, 4: 4, 8: 8 }[k];
      const b = new Uint8Array(n), d = new DataView(b.buffer);
      if (n === 1) d.setUint8(0, v); else if (n === 2) d.setUint16(0, v, true); else if (n === 4) d.setUint32(0, v, true); else d.setBigUint64(0, BigInt(v), true);
      return b;
    });
    const out = new Uint8Array(bs.reduce((a, b) => a + b.length, 0));
    let o = 0;
    for (const b of bs) { out.set(b, o); o += b.length; }
    return out;
  };

  const msize = 65536;
  await rpc(T.version, pack([4, msize], ['s', '9P2000']));
  const root = nextFid++;
  await rpc(T.attach, pack([4, root], [4, 0xffffffff], ['s', 'probe'], ['s', '']));

  const walk = async (path) => {
    const names = path.split('/').filter(Boolean);
    const fid = nextFid++;
    const r = await rpc(T.walk, pack([4, root], [4, fid], [2, names.length], ...names.map((n) => ['s', n])));
    const got = new DataView(r.buffer).getUint16(7, true);
    if (got !== names.length) {
      if (got) await rpc(T.clunk, pack([4, fid])).catch(() => {});
      throw new Error(`${path}: not found`);
    }
    return fid;
  };
  const clunk = (fid) => rpc(T.clunk, pack([4, fid])).catch(() => {});

  const ui = {
    /** The file's contents as text. */
    async read(path) {
      const fid = await walk(path);
      try {
        await rpc(T.open, pack([4, fid], [1, 0]));
        const parts = [];
        for (let off = 0; ;) {
          const r = await rpc(T.read, pack([4, fid], [8, off], [4, msize - 24]));
          const n = new DataView(r.buffer).getUint32(7, true);
          if (!n) break;
          parts.push(r.slice(11, 11 + n));
          off += n;
        }
        return dec.decode(parts.length === 1 ? parts[0] : pack(...parts.map((p) => ['b', p])));
      } finally { await clunk(fid); }
    },
    /**
     * Reads `path` as it grows, such as `events`: `on(text)` gets each
     * read until end of file. Returns at once; the reads go on.
     */
    async follow(path, on) {
      const fid = await walk(path);
      await rpc(T.open, pack([4, fid], [1, 0]));
      (async () => {
        try {
          for (let off = 0; ;) {
            const r = await rpc(T.read, pack([4, fid], [8, off], [4, msize - 24]));
            const n = new DataView(r.buffer).getUint32(7, true);
            if (!n) break;
            on(dec.decode(r.slice(11, 11 + n)));
            off += n;
          }
        } catch { /* closed */ } finally { await clunk(fid); }
      })();
    },
    /** One write of `text` (a ctl command, a value). */
    async write(path, text) {
      const fid = await walk(path);
      try {
        await rpc(T.open, pack([4, fid], [1, 1 | 16]));
        const b = enc.encode(text);
        await rpc(T.write, pack([4, fid], [8, 0], [4, b.length], ['b', b]));
      } finally { await clunk(fid); }
    },
    /** Whether `path` exists. */
    async exists(path) {
      try { await clunk(await walk(path)); return true; } catch { return false; }
    },
    /** A node's `bounds`: [x, y, w, h] in window points, or null before its first layout. */
    async bounds(path) {
      const s = (await ui.read(`${path}/bounds`)).trim();
      const v = s.split(/\s+/).map(Number);
      return v.length === 4 && v.every(Number.isFinite) ? v : null;
    },
    close() { ch.close(); },
  };
  return ui;
}
