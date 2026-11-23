// The terminal renderer in the browser: uitree-tui.wasm (renderer/tui's
// src/web.zig) drawing into xterm.js. The page owns the event loop: keys
// and the mouse go in through the module's exports, frames come out as
// ANSI text through `tui.write`.

import { instantiate, Core } from './uit-web.js';

const enc = new TextEncoder();
const named = {
  Enter: 'enter', Tab: 'tab', Escape: 'escape', Backspace: 'backspace', ' ': 'space', Delete: 'delete', Insert: 'insert',
  ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down', Home: 'home', End: 'end', PageUp: 'pageup', PageDown: 'pagedown',
};

/** Starts the terminal renderer in `el`; returns { core, term, stats }. */
export async function startTui(el, { wasm = 'uitree-tui.wasm', cols = 60, rows = 14, dark = false, onTitle = () => {}, log = console.error } = {}) {
  const t0 = performance.now();
  const term = new Terminal({ cols, rows, fontSize: 15, cursorBlink: false, allowProposedApi: true, theme: dark ? {} : { background: '#ffffff', foreground: '#000000' } });
  term.open(el);
  const dec = new TextDecoder();
  let x, scheduled = false;
  const stats = { frames: 0, bytes: 0, pumps: 0, pumpMs: 0, loadMs: 0 };
  const pump = () => {
    scheduled = false;
    const a = performance.now();
    x.tui_pump();
    stats.pumps++;
    stats.pumpMs += performance.now() - a;
  };
  const m = await instantiate(await (await fetch(wasm)).arrayBuffer(), {
    log,
    imports: {
      tui: (memory) => ({
        write: (p, n) => { const b = new Uint8Array(memory.buffer, p, n).slice(); stats.frames++; stats.bytes += n; term.write(b); },
        wake: () => { if (!scheduled) { scheduled = true; setTimeout(pump, 0); } },
        title: (p, n) => onTitle(dec.decode(new Uint8Array(memory.buffer, p, n))),
        tip_timer: (gen, ms) => setTimeout(() => x.tui_tip(gen), ms),
        open: (p, n) => { const u = dec.decode(new Uint8Array(memory.buffer, p, n)); if (/^https?:/.test(u)) window.open(u, '_blank', 'noopener'); },
      }),
    },
  });
  x = m.exports;
  const c = x.tui_init(cols, rows, dark ? 1 : 0);
  if (!c) throw new Error('tui_init failed');
  stats.loadMs = performance.now() - t0;
  const core = Core.attach(m, c);

  term.attachCustomKeyEventHandler((e) => {
    if (e.type !== 'keydown') return false;
    if (['Shift', 'Control', 'Alt', 'Meta'].includes(e.key)) return false;
    let name = named[e.key];
    if (!name && /^F\d+$/.test(e.key)) name = e.key.toLowerCase();
    const printable = !name && [...e.key].length === 1;
    if (!name) name = printable ? ((e.ctrlKey || e.altKey) ? e.key.toLowerCase() : e.key) : '';
    if (!name) return false;
    const text = e.key === ' ' && !e.ctrlKey && !e.altKey ? ' ' : printable && !e.ctrlKey && !e.altKey ? e.key : '';
    const nb = enc.encode(name).slice(0, 64), tb = enc.encode(text).slice(0, 64);
    const mem = new Uint8Array(m.memory.buffer);
    mem.set(nb, x.tui_buf());
    mem.set(tb, x.tui_buf2());
    const mods = (e.ctrlKey ? 1 : 0) | (e.altKey ? 2 : 0) | (e.shiftKey ? 4 : 0) | (e.metaKey ? 8 : 0);
    x.tui_key(x.tui_buf(), nb.length, x.tui_buf2(), tb.length, mods);
    e.preventDefault();
    return false;
  });

  // The mouse, in cells.
  const screen = el.querySelector('.xterm-screen');
  const cell = (e) => {
    const r = screen.getBoundingClientRect();
    return [Math.floor(((e.clientX - r.left) / r.width) * term.cols), Math.floor(((e.clientY - r.top) / r.height) * term.rows)];
  };
  let down = false;
  screen.addEventListener('mousedown', (e) => { if (e.button !== 0) return; down = true; x.tui_mouse(...cell(e), 0); e.preventDefault(); });
  window.addEventListener('mouseup', (e) => { if (e.button !== 0 || !down) return; down = false; x.tui_mouse(...cell(e), 1); });
  screen.addEventListener('mousemove', (e) => x.tui_mouse(...cell(e), down ? 3 : 2));
  screen.addEventListener('wheel', (e) => { x.tui_mouse(...cell(e), e.deltaY < 0 ? 4 : 5); e.preventDefault(); }, { passive: false });
  return { core, term, stats, module: m };
}
