// libghostty-vt's smoke test in a JavaScript host, the same in Node and in
// a browser page (tests/vt-smoke.mjs runs both). vt-smoke.wasm is the
// core (libuitcore.a, with libghostty-vt inside) and tests/vt-smoke.zig
// as a wasm32-wasi reactor, like uitcore.wasm. Its imports are the core's
// platform, cut down to what this needs:
//
// - `h9`: the core's threads, h9's web-host coroutines on JSPI, as
//   web/uit-web.js runs them: a coroutine is a call into h9_coro_entry
//   through WebAssembly.promising, and a park is a Suspending import.
// - `uit`: the app's machine. There is none here; each call fails.
// - `wasi_snapshot_preview1`: stdout and stderr, clocks and randomness.
//
// smoke() starts the test on a coroutine, waits for it, and times
// vt_bench for the parse throughput.

const dec = new TextDecoder();

export async function smoke(bytes, { log = console.log, benchBytes = 16 << 20 } = {}) {
  if (typeof WebAssembly.Suspending !== 'function') throw new Error('no JSPI here (Node 24, or Chrome 137 or later)');
  const mod = await WebAssembly.compile(bytes);
  let x = null;
  const u8 = (p, n) => new Uint8Array(x.memory.buffer, p >>> 0, n >>> 0);
  const dv = () => new DataView(x.memory.buffer);
  const later = (fn) => setTimeout(fn, 0);

  // A coroutine that parks or ends leaves the shadow stack pointer in its
  // own stack: put it back before anything else runs (uit-web.js).
  let sp0 = 0;
  const mainStack = () => { if (x) x.h9_set_sp(sp0); };
  const suspending = (f) => new WebAssembly.Suspending((...a) => {
    const r = f(...a);
    if (r instanceof Promise) mainStack();
    return r;
  });
  const waiters = new Map();
  const permits = new Set();
  let entry = null;
  let failure = null;
  const h9 = {
    park: suspending((id, ms) => {
      if (permits.delete(id)) return 1;
      return new Promise((res) => {
        let t = null;
        if (ms >= 0) t = setTimeout(() => { waiters.delete(id); res(0); }, Number(ms));
        waiters.set(id, () => { if (t !== null) clearTimeout(t); res(1); });
      });
    }),
    unpark: (id) => { const w = waiters.get(id); if (w) { waiters.delete(id); w(); } else permits.add(id); },
    start: (c) => later(() => { entry(c).catch((e) => { failure = e; }).finally(mainStack); mainStack(); }),
    yield: suspending(() => new Promise((res) => later(res))),
    sleep: suspending((ms) => new Promise((res) => setTimeout(res, Number(ms)))),
    panic: (p, n) => { throw new Error(`panic: ${dec.decode(u8(p, n))}`); },
  };

  const ENOSYS = 52;
  const wasi = {
    fd_write: (fd, iovs, n, out) => {
      let s = '', total = 0;
      for (let i = 0; i < n; i++) {
        const p = dv().getUint32(iovs + 8 * i, true), len = dv().getUint32(iovs + 8 * i + 4, true);
        s += dec.decode(u8(p, len));
        total += len;
      }
      if (fd === 1 || fd === 2) log(s.replace(/\n$/, ''));
      dv().setUint32(out, total, true);
      return 0;
    },
    clock_time_get: (_id, _prec, out) => { dv().setBigUint64(out, BigInt(Math.round(performance.now() * 1e6)), true); return 0; },
    clock_res_get: (_id, out) => { dv().setBigUint64(out, 1000n, true); return 0; },
    random_get: (p, n) => { crypto.getRandomValues(u8(p, n)); return 0; },
    args_sizes_get: (a, b) => { dv().setUint32(a, 0, true); dv().setUint32(b, 0, true); return 0; },
    environ_sizes_get: (a, b) => { dv().setUint32(a, 0, true); dv().setUint32(b, 0, true); return 0; },
    args_get: () => 0,
    environ_get: () => 0,
    fd_prestat_get: () => 8, // EBADF: no preopened directories
    proc_exit: (code) => { throw new Error(`proc_exit(${code})`); },
  };

  // Everything else the module imports: `uit` (no machine) and the rest
  // of WASI fail.
  const imports = { h9: {}, uit: {}, wasi_snapshot_preview1: {} };
  for (const { module: m, name, kind } of WebAssembly.Module.imports(mod)) {
    if (kind !== 'function') continue;
    const have = { h9, wasi_snapshot_preview1: wasi }[m]?.[name];
    (imports[m] ??= {})[name] = have ?? (() => (m === 'wasi_snapshot_preview1' ? ENOSYS : -1));
  }
  const inst = await WebAssembly.instantiate(mod, imports);
  x = inst.exports;
  entry = WebAssembly.promising(x.h9_coro_entry);
  sp0 = x.h9_get_sp();
  x._initialize?.();

  if (x.vt_smoke_start() !== 0) throw new Error('vt_smoke_start failed');
  let r;
  for (let i = 0; (r = x.vt_smoke_result()) === -1; i++) {
    if (failure) throw failure;
    if (i > 500) throw new Error('vt-smoke: the coroutine never finished');
    await new Promise((res) => setTimeout(res, 10));
  }
  const buf = x.vt_smoke_buf();
  if (r < -1) throw new Error(`vt-smoke: ${dec.decode(u8(buf, -2 - r))}`);
  const screen = dec.decode(u8(buf, r));

  x.vt_bench(1 << 20); // warm up
  const t0 = performance.now();
  if (x.vt_bench(benchBytes) !== 0) throw new Error('vt_bench failed');
  const ms = performance.now() - t0;
  return { screen, mbps: benchBytes / (1 << 20) / (ms / 1000), wasmBytes: bytes.byteLength };
}
