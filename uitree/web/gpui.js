// The GPUI renderer in the browser: uitree_web.wasm (renderer/gpui's
// crates/web, gpui_web on one canvas, built by wasm-bindgen) and the core
// (uitcore-shared.wasm) in one memory.
//
// The core imports the renderer's memory and keeps its data, stack and
// heap above `base` (core/build.zig's web-base), so a pointer means the
// same thing in both modules and uitcore-sys's functions can be the
// core's exports, forwarded by uitcore-imports.js. The order matters:
// the renderer first, then the memory grown past the core's heap base,
// then the core and its first malloc (wasi-libc's malloc claims all the
// memory there is above its heap base on first use), and only then the
// renderer's own start, whose allocations grow the memory past that.

import init, { start } from './gpui/uitree_web.js';
import { instantiate, Core, runApp } from './uit-web.js';
import { bind } from './uitcore-imports.js';

const base = 256 << 20;
const page = 65536;

/**
 * Starts the GPUI renderer on the page's canvas with the app `argv` (h9's)
 * and its `files` ({ path: text }, put in h9's root). `onCore(core)` gets
 * the renderer's core (uit-web.js's Core) once the app starts.
 */
export async function startGpui({ argv, title, files = {}, log = console.error, onOutput = () => {}, onExit = () => {}, onCore = () => {} }) {
  const t = { start: performance.now() };
  const [wasm, coreBytes] = await Promise.all([
    init({ module_or_path: new URL('gpui/uitree_web_bg.wasm', import.meta.url) }),
    fetch(new URL('uitcore-shared.wasm', import.meta.url)).then((r) => r.arrayBuffer()),
  ]);
  const appFiles = files;
  t.renderer = performance.now();
  const memory = wasm.memory;
  if (memory.buffer.byteLength > base) throw new Error(`the renderer's memory is ${memory.buffer.byteLength} bytes, past the core's base`);
  const coreMod = await WebAssembly.compile(coreBytes);
  const need = memoryMin(new Uint8Array(coreBytes));
  const want = need + (16 << 20) / page;
  memory.grow(want - memory.buffer.byteLength / page);
  let rustWake = 0;
  let scheduled = false;
  const m = await instantiate(coreMod, {
    memory,
    log,
    onWake: (ctx) => {
      if (scheduled) return;
      scheduled = true;
      setTimeout(() => { scheduled = false; wasm.uitree_web_wake(rustWake, ctx); }, 0);
    },
  });
  m.exports.uit_web_alloc(1);
  t.core = performance.now();
  bind(m.exports, {
    memory,
    setWake: (f) => { rustWake = f; },
    runMachine: (c, args) => {
      const core = Core.attach(m, c);
      runApp(core, { argv: args, files: appFiles, onOutput, onExit });
      onCore(core);
      t.app = performance.now();
      return 0;
    },
  });
  start(argv, title ?? null, new URL('.', import.meta.url).href.replace(/\/$/, ''));
  t.started = performance.now();
  return { timings: t, memory, core: m };
}

/** The minimum, in pages, of the memory a module imports (its heap base). */
function memoryMin(b) {
  let p = 8;
  const u = () => { let r = 0, s = 0, x; do { x = b[p++]; r += (x & 0x7f) * 2 ** s; s += 7; } while (x & 0x80); return r; };
  while (p < b.length) {
    const id = b[p++], len = u(), end = p + len;
    if (id === 2) {
      for (let n = u(); n > 0; n--) {
        let l = u(); p += l;
        l = u(); p += l;
        const kind = b[p++];
        if (kind === 0) u();
        else if (kind === 1) { p++; const f = u(); u(); if (f & 1) u(); }
        else if (kind === 2) { const f = u(); const min = u(); if (f & 1) u(); return min; }
        else if (kind === 3) p += 2;
        else if (kind === 4) { p++; u(); }
      }
    }
    p = end;
  }
  throw new Error('the core imports no memory');
}
