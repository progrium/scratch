// The GPUI renderer in the browser: uitree_web.wasm (renderer/gpui's
// crates/web, gpui_web on one canvas, built by wasm-bindgen), with the
// core linked in as on the desktop. The page supplies the core's platform
// (uitcore-imports.js, through gpui.html's import map) and binds it to the
// instance before the renderer starts; the renderer calls uit_run_machine
// itself, and the platform runs the app in h9's Worker.

import init, { start } from './gpui/uitree_web.js';
import { core } from './uitcore-imports.js';

/**
 * Starts the GPUI renderer on the page's canvas with the app `argv` (h9's)
 * and its `files` ({ path: text }, put in h9's root).
 */
export async function startGpui({ argv, title, files = {}, log = console.error, onOutput = () => {}, onExit = () => {} }) {
  const t = { start: performance.now() };
  core.config.log = log;
  core.config.app = { files, onOutput, onExit };
  const wasm = await init({ module_or_path: new URL('gpui/uitree_web_bg.wasm', import.meta.url) });
  t.renderer = performance.now();
  core.bind(wasm, wasm.memory);
  start(argv, title ?? null, new URL('.', import.meta.url).href.replace(/\/$/, ''));
  t.started = performance.now();
  return { timings: t, memory: wasm.memory, core };
}
