// The core's platform in the browser (README.md, "The core's platform").
//
// A module with the uitree core in it (uitcore.wasm alone, uitree-tui.wasm
// with the terminal renderer, uitree_web_bg.wasm with GPUI) imports three
// things from the page, and the page reaches it only through uitcore.h:
//
// - `h9`: hyper9's web-host coroutines, which are the core's threads. Each
//   is a call into the module through WebAssembly.promising, and a park is
//   a Suspending import (JSPI). This is h9-web.js's `run` cut down.
// - `uit`: the app's machine and its connections. uit_run_machine asks for
//   a machine (machine_start), and the page runs the app in h9's own
//   browser host in a Worker (h9-worker.js). The core accepts each `$ui`
//   connection the app makes (machine_accept) and reads and writes it
//   through conn_*: the WebSocket h9 dials, as messages. `wake` is the
//   default UitConfig.wake, for a renderer in JS.
// - `wasi_snapshot_preview1`: a WASI with no files, for wasi-libc.
//
// `platform()` makes the three and binds them to an instance;
// `instantiate` does both for a module the page instantiates itself.

import { parseRoot, putNode, wasiImports } from './h9/wasi-mem.js';

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
 * The core's platform imports (`imports`), unbound. Call `bind(exports,
 * memory)` once the module is instantiated, before anything runs in it.
 * The callbacks can be set or changed later through `config`:
 * `onWake(ctx)` is the default UitConfig.wake (it runs on a coroutine, so
 * it may only schedule work); `log`; `onOutput(fd, bytes)` gets the
 * module's own stdout and stderr; `app` is what machine_start runs
 * (runApp's options: files, onOutput, onExit, base, root).
 */
export function platform({ log = console.error, onWake = () => {}, onOutput = null, args = ['uitree'], env = {}, app = null } = {}) {
  const config = { log, onWake, onOutput, app };
  let x = null;
  let mem = null;
  const memory = { get buffer() { return mem.buffer; } };
  const u8 = (p, n) => new Uint8Array(memory.buffer, p >>> 0, n >>> 0);
  const die = (e) => config.log(`uitree: ${e?.stack ?? e}`);

  // A coroutine that parks or ends leaves the shadow stack pointer (a
  // wasm global every caller shares) in its own stack, which is a heap
  // allocation of 320 KiB. Whatever runs next from the event loop (a
  // renderer's frame, a pump) would run there. So it goes back to the
  // main stack whenever a coroutine stops running; coro.c sets it again
  // when the coroutine resumes.
  let sp0 = 0;
  const mainStack = () => { if (x) x.h9_set_sp(sp0); };
  const suspending = (f) => new WebAssembly.Suspending((...a) => {
    const r = f(...a);
    if (r instanceof Promise) mainStack();
    return r;
  });

  // Coroutines, as h9-web.js: a park is a Promise that unpark resolves;
  // an unpark before the park leaves a permit.
  const waiters = new Map();
  const permits = new Set();
  let entry = null;
  const h9 = {
    park: suspending((id, ms) => {
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
    start: (c) => nextTask(() => {
      entry(c).catch(die).finally(mainStack);
      mainStack();
    }),
    yield: suspending(() => new Promise((res) => nextTask(res))),
    sleep: suspending((ms) => new Promise((res) => setTimeout(res, ms))),
    panic: (p, n) => { throw new Error(`panic: ${dec.decode(u8(p, n))}`); },
  };

  // Connections: each one a `$ui` WebSocket of a machine's.
  const conns = new Map();
  let nextConn = 1;
  const poke = (c) => { const w = c.waiter; c.waiter = null; w?.(); };
  const end = (c) => { if (!c.closed) { c.closed = true; poke(c); } };
  const take = (c, p, n) => {
    let got = 0;
    while (c.q.length && got < n) {
      const b = c.q[0];
      const k = Math.min(n - got, b.length);
      u8(p + got, k).set(b.subarray(0, k));
      got += k;
      if (k === b.length) c.q.shift(); else c.q[0] = b.subarray(k);
    }
    return got;
  };

  // Machines: h9's browser host in a Worker each.
  const machines = new Map();
  let nextMachine = 1;
  // connect()s before any machine: served once one starts.
  let early = [];
  const live = () => [...machines.values()].reverse().find((m) => m.status === null);
  const offer = (m, cid) => {
    m.accepts.push(cid);
    const w = m.acceptWaiter; m.acceptWaiter = null; w?.();
  };
  const finish = (m, status) => {
    if (m.status !== null) return;
    m.status = status;
    for (const c of m.conns.values()) end(c);
    const a = m.acceptWaiter; m.acceptWaiter = null; a?.();
    const w = m.waitWaiter; m.waitWaiter = null; w?.();
  };

  const uit = {
    wake: (ctx) => config.onWake(ctx),

    machine_start: (args) => {
      const app = config.app;
      if (!app) { config.log('uitree: uit_run_machine with no app (runApp sets one)'); return -1; }
      const a = machineArgs(memory, args);
      const id = nextMachine++;
      const m = { id, app, status: null, accepts: [], acceptWaiter: null, waitWaiter: null, conns: new Map(), w: null };
      machines.set(id, m);
      m.w = startWorker(app, a, {
        open: (wid) => {
          const cid = nextConn++;
          conns.set(cid, {
            q: [], closed: false, waiter: null,
            send: (b) => m.w.postMessage({ type: 'uit-data', id: wid, data: b.buffer }, [b.buffer]),
            hangup: () => m.w.postMessage({ type: 'uit-close', id: wid }),
          });
          m.conns.set(wid, conns.get(cid));
          m.w.postMessage({ type: 'uit-opened', id: wid });
          offer(m, cid);
        },
        data: (wid, b) => { const c = m.conns.get(wid); if (c && !c.closed) { c.q.push(b); poke(c); } },
        close: (wid) => { const c = m.conns.get(wid); m.conns.delete(wid); if (c) end(c); },
        exit: (code, msg) => {
          finish(m, code === 0 ? '' : (msg ?? `exit ${code}`));
          app.onExit?.(code, msg);
        },
      });
      for (const cid of early) offer(m, cid);
      early = [];
      return id;
    },
    machine_accept: suspending((id) => {
      const m = machines.get(id);
      if (!m) return -1;
      const next = () => (m.accepts.length ? m.accepts.shift() : 0);
      if (m.accepts.length || m.status !== null) return next();
      return new Promise((res) => { m.acceptWaiter = () => res(next()); });
    }),
    machine_wait: suspending((id, p, n) => {
      const m = machines.get(id);
      if (!m) return -1;
      const put = () => {
        const b = enc.encode(m.status).subarray(0, n);
        u8(p, b.length).set(b);
        machines.delete(id);
        return b.length;
      };
      if (m.status !== null) return put();
      return new Promise((res) => { m.waitWaiter = () => res(put()); });
    }),
    // A hangup (uit_shutdown, often because the app quit): the app's $ui
    // connections end, as a hangup note would end its reads, and it gets
    // a moment to exit with its own status before the Worker is stopped.
    machine_hangup: (id) => {
      const m = machines.get(id);
      if (!m || m.status !== null || m.hungUp) return;
      m.hungUp = true;
      for (const [wid, c] of m.conns) { if (!c.closed) { end(c); c.hangup(); } m.conns.delete(wid); }
      setTimeout(() => {
        if (m.status !== null) return;
        m.w.terminate();
        finish(m, 'hangup');
        m.app.onExit?.(-1, 'hangup');
      }, 2000);
    },

    conn_read: suspending((id, p, n) => {
      const c = conns.get(id);
      if (!c) return -1;
      if (c.q.length) return take(c, p, n);
      if (c.closed) return 0;
      return new Promise((res) => { c.waiter = () => res(c.q.length ? take(c, p, n) : 0); });
    }),
    conn_write: (id, p, n) => {
      const c = conns.get(id);
      if (!c || c.closed) return -1;
      c.send(u8(p, n).slice());
      return 0;
    },
    conn_hangup: (id) => {
      const c = conns.get(id);
      if (!c || c.closed) return;
      end(c);
      c.hangup();
    },
    conn_release: (id) => {
      const c = conns.get(id);
      if (!c) return;
      if (!c.closed) { end(c); c.hangup(); }
      conns.delete(id);
    },
  };

  const write = (fd, data) => (config.onOutput ? config.onOutput(fd, data) : config.log(dec.decode(data)));
  const root = parseRoot(enc.encode('h9root1\n'));
  const wasi = wasiImports({ memory, root, args, env, write });
  wasi.proc_exit = (code) => { throw new Error(`exit ${code}`); };

  return {
    config,
    memory,
    /**
     * Puts a file in the core's own WASI file system (not the app's
     * machine): what the core opens by path, such as a drop's `file=`
     * host paths (uit_drag). `path` is absolute; directories are made.
     */
    putFile(path, bytes, mode = 0o644) {
      putNode(root, path, 0o100000 | mode, typeof bytes === 'string' ? enc.encode(bytes) : bytes);
    },
    /**
     * A `$ui` connection of the page's own, beside the app's (tests,
     * probe.js): the core accepts it as one of the machine's, so it is
     * served once the app's machine runs. `send(bytes)` gets the core's
     * replies; returns { push(bytes), close() }.
     */
    connect(send, onClose = () => {}) {
      const cid = nextConn++;
      const c = { q: [], closed: false, waiter: null, send, hangup: onClose };
      conns.set(cid, c);
      const m = live();
      if (m) offer(m, cid); else early.push(cid);
      return {
        id: cid,
        push: (b) => { if (!c.closed) { c.q.push(b); poke(c); } },
        close: () => end(c),
      };
    },
    imports: { h9, uit, wasi_snapshot_preview1: wasi },
    /** Binds the imports to the instance: its exports and its memory. */
    bind(exports, m = exports.memory) {
      x = exports;
      mem = m;
      entry = WebAssembly.promising(x.h9_coro_entry);
      sp0 = x.h9_get_sp();
    },
  };
}

/** uitcore.h's UitMachineArgs at `p`, as wasm32 lays it out. */
function machineArgs(memory, p) {
  const dv = new DataView(memory.buffer);
  const str = (q) => {
    const ptr = dv.getUint32(q, true), n = dv.getUint32(q + 4, true);
    return n ? dec.decode(new Uint8Array(memory.buffer, ptr, n)) : '';
  };
  const list = (q) => {
    const ptr = dv.getUint32(q, true), n = dv.getUint32(q + 4, true);
    return Array.from({ length: n }, (_, i) => str(ptr + 8 * i));
  };
  const prog = str(p);
  const argv = list(p + 8);
  return {
    prog, argv: argv.length ? argv : [prog], root: str(p + 16), cwd: str(p + 24),
    dirs: list(p + 32), env: list(p + 40), flags: list(p + 48),
  };
}

/** Runs the app in h9's browser host, in a Worker of its own (h9-worker.js). */
function startWorker(app, a, on) {
  const { base = new URL('./', import.meta.url), root = 'h9/root.h9a', files = {}, onOutput = () => {} } = app;
  const w = new Worker(new URL('h9-worker.js', base), { type: 'module' });
  w.onmessage = ({ data: m }) => {
    switch (m.type) {
      case 'uit-open': on.open(m.id); break;
      case 'uit-data': on.data(m.id, new Uint8Array(m.data)); break;
      case 'uit-close': on.close(m.id); break;
      case 'output': onOutput(m.fd, m.data); break;
      case 'exit': on.exit(m.code); break;
      case 'error': on.exit(-1, m.message); break;
    }
  };
  w.onerror = (e) => on.exit(-1, e.message);
  for (const [path, text] of Object.entries(files)) {
    const data = typeof text === 'string' ? enc.encode(text) : text.slice();
    w.postMessage({ type: 'put', path, data: data.buffer, mode: 0o755 }, [data.buffer]);
  }
  const env = { ui: '/mnt/ui' };
  for (const l of a.env) { const i = l.indexOf('='); if (i > 0) env[l.slice(0, i)] = l.slice(i + 1); }
  w.postMessage({
    type: 'start',
    argv: a.argv,
    env,
    mounts: [
      { kind: 'archive', src: String(new URL(root, base)), dst: '', opts: '' },
      { kind: 'url', src: 'ws://uitree.invalid/ui', dst: '/mnt/ui', opts: '' },
    ],
  });
  return w;
}

/**
 * Instantiates a module with the core in it. `imports` adds import
 * modules (a renderer's own, such as the terminal's: an object, or a
 * function of the memory). The rest are platform()'s options.
 */
export async function instantiate(bytes, { imports = {}, ...opts } = {}) {
  if (!haveJSPI) throw new Error('this browser lacks JavaScript Promise Integration (Chrome 137 or later)');
  const mod = bytes instanceof WebAssembly.Module ? bytes : await WebAssembly.compile(bytes);
  const p = platform(opts);
  const all = { ...p.imports };
  for (const [k, v] of Object.entries(imports)) all[k] = { ...(all[k] ?? {}), ...(typeof v === 'function' ? v(p.memory) : v) };
  const inst = await WebAssembly.instantiate(mod, all);
  p.bind(inst.exports);
  inst.exports._initialize?.();
  return {
    instance: inst,
    exports: inst.exports,
    memory: p.memory,
    platform: p,
    /** A coroutine running export `name(...args)`, which may park. */
    spawn: (name, ...args) => WebAssembly.promising(inst.exports[name])(...args),
  };
}

/** Memory helpers over a core module's exports (libc's malloc and free). */
export class Mem {
  constructor(m) { this.m = m; this.x = m.exports; }
  get u8() { return new Uint8Array(this.m.memory.buffer); }
  get dv() { return new DataView(this.m.memory.buffer); }
  alloc(n) { const p = this.x.malloc(Math.max(n, 1)); if (!p) throw new Error('out of memory'); this.u8.fill(0, p, p + n); return p; }
  free(p) { this.x.free(p); }
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
 * One core (uit_create), for a renderer in JS: its wake is the platform's
 * (`onWake`), and it is pumped (pump) when that fires.
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
    // wake (32) and wake_ctx (36) stay NULL: the platform's wake.
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

  /** uit_run_machine with `argv` and `env` (NAME=value lines). */
  runMachine(argv, env = []) {
    const mem = this.mem;
    const strs = (l) => {
      const p = mem.alloc(8 * l.length);
      l.forEach((s, i) => { const [q, n] = mem.bytes(s); mem.dv.setUint32(p + 8 * i, q, true); mem.dv.setUint32(p + 8 * i + 4, n, true); });
      return p;
    };
    const a = mem.alloc(64);
    const [prog, plen] = mem.bytes(argv[0]);
    mem.dv.setUint32(a, prog, true);
    mem.dv.setUint32(a + 4, plen, true);
    mem.dv.setUint32(a + 8, strs(argv), true);
    mem.dv.setUint32(a + 12, argv.length, true);
    mem.dv.setUint32(a + 40, strs(env), true);
    mem.dv.setUint32(a + 44, env.length, true);
    mem.dv.setInt32(a + 56, -1, true);
    mem.dv.setInt32(a + 60, -1, true);
    // The page reads the args before uit_run_machine returns; a few bytes
    // per app aren't worth tracking to free.
    return this.m.exports.uit_run_machine(this.c, a);
  }

  /** A `$ui` connection of the page's own (platform's connect). */
  serve(send, onClose) { return this.m.platform.connect(send, onClose); }

  pump() { return this.m.exports.uit_pump(this.c, this.changes); }
  lastError() { const p = this.mem.alloc(8); this.m.exports.uit_last_error(p, this.c); const s = this.mem.uitstr(p); this.mem.free(p); return s; }
}

/**
 * Runs an app in h9's browser host, in a Worker of its own, with `$ui` at
 * /mnt/ui served by `core` (uit_run_machine). `files` are put in the root
 * ({ path: text or bytes }), `argv` is h9's.
 */
export function runApp(core, { argv, env = [], ...app }) {
  core.m.platform.config.app = app;
  const r = core.runMachine(argv, env);
  if (r !== 0) throw new Error(`uit_run_machine: ${r} ${core.lastError()}`);
}
