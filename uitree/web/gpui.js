// The GPUI renderer in the browser: uitree_web.wasm (renderer/gpui's
// crates/web, gpui_web on one canvas, built by wasm-bindgen), with the
// core linked in as on the desktop. The page supplies the core's platform
// (uitcore-imports.js, through gpui.html's import map) and binds it to the
// instance before the renderer starts; the renderer calls uit_run_machine
// itself, and the platform runs the app in h9's Worker.

import init, { start, drop_files } from './gpui/uitree_web.js';
import { core } from './uitcore-imports.js';

/**
 * Starts the GPUI renderer on the page's canvas with the app `argv` (h9's)
 * and its `files` ({ path: text }, put in h9's root). `onCore(core)` gets
 * a Core-shaped handle on the renderer's core: `serve(send, onClose)`
 * opens a `$ui` connection of the page's own (probe.js). `gfx` is the
 * graphics backend: 'webgl' (null, the default), 'webgpu' or 'auto'.
 */
export async function startGpui({ argv, title, gfx = null, files = {}, log = console.error, onOutput = () => {}, onExit = () => {}, onCore = () => {} }) {
  const t = { start: performance.now() };
  core.config.log = log;
  core.config.app = { files, onOutput, onExit };
  const wasm = await init({ module_or_path: new URL('gpui/uitree_web_bg.wasm', import.meta.url) });
  t.renderer = performance.now();
  core.bind(wasm, wasm.memory);
  start(argv, title ?? null, new URL('.', import.meta.url).href.replace(/\/$/, ''), gfx);
  t.started = performance.now();
  onCore({ serve: (send, onClose) => core.connect(send, onClose) });
  dropFiles(core);
  return { timings: t, memory: wasm.memory, core };
}

/**
 * File drops: gpui_web makes none, since the browser gives `File`s and not
 * paths. So each drop's files go in the core's own file system, as
 * /drop/N/NAME, and the renderer gets those paths as a platform drop
 * would bring them; the core opens them by path for `uit_drag`'s `file=`.
 */
function dropFiles(core) {
  let n = 0;
  const canvas = () => document.querySelector('canvas');
  document.addEventListener('dragover', (e) => e.preventDefault());
  document.addEventListener('drop', async (e) => {
    e.preventDefault();
    const files = [...(e.dataTransfer?.files ?? [])];
    if (!files.length) return;
    const dir = `/drop/${++n}`;
    const paths = await Promise.all(files.map(async (f) => {
      const p = `${dir}/${f.name.replaceAll('/', '_')}`;
      core.putFile(p, new Uint8Array(await f.arrayBuffer()));
      return p;
    }));
    const r = canvas()?.getBoundingClientRect() ?? { left: 0, top: 0 };
    drop_files(paths, e.clientX - r.left, e.clientY - r.top);
  });
}
