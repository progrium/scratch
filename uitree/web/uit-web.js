// The page's host for the uitree core in the browser (README.md).
//
// The core is a wasm32-wasi module (uitcore.wasm, or a renderer that links
// it, such as uitree-tui.wasm) whose threads are hyper9's web-host
// coroutines: each one is a call into the module through
// WebAssembly.promising, and a park is a Suspending import (JSPI). This
// file is h9-web.js's `run` cut down to what the core needs: coroutines,
// a WASI shim with no files, and the page's 9P channels.
//
// The app runs in h9's own Worker (h9-worker.js). Its `$ui` mount is a
// WebSocket, which h9-worker.js turns into messages; `Core.serve` hands
// each one to the core as a channel (uit_web_serve).

import { parseRoot, wasiImports } from './h9/wasi-mem.js';

export const haveJSPI = typeof WebAssembly.Suspending === 'function' && typeof WebAssembly.promising === 'function';

const nextTask = (() => {
  const ch = new MessageChannel();
  const q = [];
  ch.port1.onmessage = () => q.shift()();
  return (fn) => { q.push(fn); ch.port2.postMessage(0); };
})();

const enc = new TextEncoder();
const dec = new TextDecoder();

/**
 * Instantiates a core module. `imports` adds import modules (a renderer's
 * own, such as the terminal's). `onWake` is UitConfig.wake: it runs on a
 * coroutine, so it may only schedule work. `onOutput(fd, bytes)` gets
 * the module's stdout and stderr.
 */
export async function instantiate(bytes, { imports = {}, onWake = () => {}, onOutput, log = console.error, args = ['uitree'], env = {}, memory: shared = null } = {}) {
  if (!haveJSPI) throw new Error('this browser lacks JavaScript Promise Integration (Chrome 137 or later)');
  const mod = bytes instanceof WebAssembly.Module ? bytes : await WebAssembly.compile(bytes);
  let inst;
  // `shared`: a memory to import (uitcore-shared.wasm, in another module's memory).
  const memory = shared ?? { get buffer() { return inst.exports.memory.buffer; } };
  const u8 = (p, n) => new Uint8Array(memory.buffer, p >>> 0, n >>> 0);

  // Coroutines, as h9-web.js: a park is a Promise that unpark resolves;
  // an unpark before the park leaves a permit.
  const waiters = new Map();
  const permits = new Set();
  let entry;
  const die = (e) => log(`uitree: ${e?.stack ?? e}`);
  const h9 = {
    park: new WebAssembly.Suspending((id, ms) => {
      if (permits.delete(id)) return 1;
      return new Promise((res) => {
        let t = null;
        if (ms >= 0) t = setTimeout(() => { waiters.delete(id); res(0); }, ms);
        waiters.set(id, () => { if (t !== null) clearTimeout(t); res(1); });
      });
    }),
    unpark: (id) => {
      const w = waiters.get(id);
      if (w) { waiters.delete(id); w(); } else permits.add(id);
    },
    start: (c) => nextTask(() => entry(c).catch(die)),
    yield: new WebAssembly.Suspending(() => new Promise((res) => nextTask(res))),
    sleep: new WebAssembly.Suspending((ms) => new Promise((res) => setTimeout(res, ms))),
    panic: (p, n) => { throw new Error(`panic: ${dec.decode(u8(p, n))}`); },
  };

  // The 9P channels: one per connection the page serves.
  const chans = new Map();
  const poke = (c) => { const w = c.waiter; c.waiter = null; w?.(); };
  const uit = {
    chan_recv: new WebAssembly.Suspending(async (id, p, n) => {
      const c = chans.get(id);
      if (!c) return -1;
      while (!c.q.length && !c.closed) await new Promise((res) => { c.waiter = res; });
      if (!c.q.length) return 0;
      let got = 0;
      while (c.q.length && got < n) {
        const b = c.q[0];
        const take = Math.min(n - got, b.length);
        u8(p + got, take).set(b.subarray(0, take));
        got += take;
        if (take === b.length) c.q.shift(); else c.q[0] = b.subarray(take);
      }
      return got;
    }),
    chan_send: (id, p, n) => {
      const c = chans.get(id);
      if (!c || c.closed) return -1;
      c.send(u8(p, n).slice());
      return n;
    },
    chan_close: (id) => {
      const c = chans.get(id);
      if (!c || c.closed) return;
      c.closed = true;
      poke(c);
      c.onClose?.();
    },
    wake: (ctx) => onWake(ctx),
  };

  const write = (fd, data) => (onOutput ? onOutput(fd, data) : log(dec.decode(data)));
  const wasi = wasiImports({ memory, root: parseRoot(enc.encode('h9root1\n')), args, env, write });
  wasi.proc_exit = (code) => { throw new Error(`exit ${code}`); };
  const all = { wasi_snapshot_preview1: wasi, h9, uit, ...(shared ? { env: { memory: shared } } : {}) };
  for (const [k, v] of Object.entries(imports)) all[k] = { ...(all[k] ?? {}), ...(typeof v === 'function' ? v(memory) : v) };
  inst = await WebAssembly.instantiate(mod, all);
  entry = WebAssembly.promising(inst.exports.h9_coro_entry);
  inst.exports._initialize?.();

  return {
    instance: inst,
    exports: inst.exports,
    memory,
    /** A coroutine running export `name(...args)`, which may park. */
    spawn: (name, ...args) => WebAssembly.promising(inst.exports[name])(...args),
    /** A new channel: `send(bytes)` carries the core's replies. */
    channel(send, onClose) {
      const id = chans.size ? Math.max(...chans.keys()) + 1 : 1;
      const c = { q: [], closed: false, waiter: null, send, onClose };
      chans.set(id, c);
      return {
        id,
        push: (b) => { if (!c.closed) { c.q.push(b); poke(c); } },
        close: () => { if (!c.closed) { c.closed = true; poke(c); } },
      };
    },
  };
}

/** Memory helpers over a core module's exports. */
export class Mem {
  constructor(m) { this.m = m; this.x = m.exports; }
  get u8() { return new Uint8Array(this.m.memory.buffer); }
  get dv() { return new DataView(this.m.memory.buffer); }
  alloc(n) { const p = this.x.uit_web_alloc(n); if (!p) throw new Error('out of memory'); return p; }
  free(p, n) { this.x.uit_web_free(p, n); }
  /** Copies `s` (a string or bytes) in; returns [ptr, len]. */
  bytes(s) {
    const b = typeof s === 'string' ? enc.encode(s) : s;
    const p = this.alloc(b.length);
    this.u8.set(b, p);
    return [p, b.length];
  }
  str(p, n) { return n ? dec.decode(this.u8.subarray(p >>> 0, (p >>> 0) + (n >>> 0))) : ''; }
  /** A UitStr at `p`. */
  uitstr(p) { const dv = this.dv; return this.str(dv.getUint32(p, true), dv.getUint32(p + 4, true)); }
}

/**
 * One core (uit_create) with the page's wake, serving `$ui` to apps in
 * h9 Workers. A renderer pumps it (pump) when `onWake` fires.
 */
export class Core {
  constructor(m, { types = '', styleWords = '', themeTokens = '', dark = false } = {}) {
    this.m = m;
    this.mem = new Mem(m);
    const x = m.exports, mem = this.mem;
    const cfg = mem.alloc(40);
    const put = (off, s) => {
      const [p, n] = s ? mem.bytes(s) : [0, 0];
      mem.dv.setUint32(cfg + off, p, true);
      mem.dv.setUint32(cfg + off + 4, n, true);
    };
    mem.dv.setUint32(cfg, x.uit_abi_version(), true);
    put(4, types);
    put(12, styleWords);
    put(20, themeTokens);
    mem.dv.setUint32(cfg + 28, dark ? 1 : 0, true);
    mem.dv.setUint32(cfg + 32, x.uit_web_wake_fn(), true);
    mem.dv.setUint32(cfg + 36, 0, true);
    const out = mem.alloc(4);
    const r = x.uit_create(cfg, out);
    if (r !== 0) throw new Error(`uit_create: ${r}`);
    this.c = mem.dv.getUint32(out, true);
    this.changes = mem.alloc(128);
  }

  /** A core someone else made (a renderer's own uit_create): `c` is its UitCore*. */
  static attach(m, c) {
    const k = Object.create(Core.prototype);
    k.m = m;
    k.mem = new Mem(m);
    k.c = c;
    k.changes = k.mem.alloc(128);
    return k;
  }

  /** Serves one connection: a channel whose bytes come from `port`. */
  serve(send, onClose) {
    const ch = this.m.channel(send, onClose);
    const r = this.m.exports.uit_web_serve(this.c, ch.id);
    if (r !== 0) throw new Error(`uit_web_serve: ${r}`);
    return ch;
  }

  pump() { return this.m.exports.uit_pump(this.c, this.changes); }
  lastError() { const p = this.mem.alloc(8); this.m.exports.uit_last_error(p, this.c); const s = this.mem.uitstr(p); this.mem.free(p, 8); return s; }
}

/**
 * Runs an app in h9's browser host, in a Worker of its own
 * (h9-worker.js), with `$ui` at /mnt/ui served by `core`.
 * `files` are put in the root ({ path: text or bytes }), `argv` is h9's.
 */
export function runApp(core, { base = new URL('./', import.meta.url), root = 'h9/root.h9a', files = {}, argv, cwd = '/', onOutput = () => {}, onExit = () => {} }) {
  const w = new Worker(new URL('h9-worker.js', base), { type: 'module' });
  const conns = new Map();
  w.onmessage = ({ data: m }) => {
    switch (m.type) {
      case 'uit-open': {
        const ch = core.serve(
          (b) => w.postMessage({ type: 'uit-data', id: m.id, data: b.buffer }, [b.buffer]),
          () => w.postMessage({ type: 'uit-close', id: m.id }),
        );
        conns.set(m.id, ch);
        w.postMessage({ type: 'uit-opened', id: m.id });
        break;
      }
      case 'uit-data': conns.get(m.id)?.push(new Uint8Array(m.data)); break;
      case 'uit-close': conns.get(m.id)?.close(); conns.delete(m.id); break;
      case 'output': onOutput(m.fd, m.data); break;
      case 'exit': onExit(m.code); break;
      case 'error': onExit(-1, m.message); break;
    }
  };
  w.onerror = (e) => onExit(-1, e.message);
  for (const [path, text] of Object.entries(files)) {
    const data = typeof text === 'string' ? enc.encode(text) : text.slice();
    w.postMessage({ type: 'put', path, data: data.buffer, mode: 0o755 }, [data.buffer]);
  }
  w.postMessage({
    type: 'start',
    argv,
    env: { ui: '/mnt/ui' },
    mounts: [
      { kind: 'archive', src: String(new URL(root, base)), dst: '', opts: '' },
      { kind: 'url', src: 'ws://uitree.invalid/ui', dst: '/mnt/ui', opts: '' },
    ],
  });
  return w;
}
