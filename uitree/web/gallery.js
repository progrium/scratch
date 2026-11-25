// The component gallery's driver: turns a story (stories.js) into writes
// on the window, through a $ui connection of the page's own (probe.js).
// index.html uses it, and so do the browser tests (test/cases.mjs).

import { stories } from './stories.js';

const W = 'win/main';
/** The path of section i's box, from the window. */
const box = (i) => `s/v/s${i}/b`;

/** The types a piece of a document or an over/ctl script makes. */
function typesIn(ui = '', over = '') {
  const t = new Set();
  for (const l of ui.split('\n')) { const w = l.trim().split(/\s+/)[0]; if (w) t.add(w); }
  for (const l of over.split('\n')) { const m = /^new\s+(\S+)/.exec(l.trim()); if (m) t.add(m[1]); }
  return t;
}

/** Every type a story uses, in its sections and overlays. */
export function storyTypes(s) {
  const t = typesIn('', s.over);
  for (const sec of s.sections) for (const x of typesIn(sec.ui)) t.add(x);
  return [...t];
}

/**
 * The types each renderer draws. The core accepts every type in its
 * catalog whatever the renderer ($ui/types lists them all: a renderer's
 * own list is only checked against it, abi.zig's create), and a type the
 * renderer doesn't draw is an empty box. So the list is here: the
 * terminal renderer's is renderer/tui/types/types.zig's `names` (the
 * gallery test checks they agree); GPUI draws every type.
 */
export const drawn = {
  tui: new Set(['div', 'text', 'styled-text', 'img', 'svg', 'icon', 'scroll', 'spacer', 'button', 'checkbox', 'radio-group',
    'switch', 'select', 'input', 'textarea', 'number-input', 'slider', 'form', 'field', 'link', 'tabs', 'tab', 'empty',
    'separator', 'badge', 'kbd', 'progress', 'spinner', 'alert', 'dialog', 'grid', 'toolbar', 'button-group', 'toggle',
    'status-bar', 'title-bar', 'table', 'list', 'tree', 'canvas', 'chart', 'description-list', 'sidebar', 'sidebar-group',
    'sidebar-item', 'group-box', 'avatar', 'editor', 'markdown', 'sheet', 'alert-dialog', 'resizable', 'panel', 'dock',
    'dock-panel', 'message-list', 'collapsible', 'accordion', 'accordion-item', 'breadcrumb', 'dropdown-button', 'tag',
    'web', 'terminal']),
  gpui: { has: () => true },
};

/** The stories' types that `renderer` (gpui or tui) draws and the core has ($ui/types). */
export async function catalog(ui, renderer) {
  const all = new Set(['div', 'text', 'icon']);
  for (const s of stories) for (const t of storyTypes(s)) all.add(t);
  const has = new Set();
  await Promise.all([...all].map(async (t) => { if (drawn[renderer].has(t) && await ui.exists(`types/${t}`)) has.add(t); }));
  return has;
}

const q = (s) => `'${s.replaceAll("'", "''")}'`;
const indent = (text, n) => text.replace(/^\n/, '').split('\n').map((l) => (l.trim() ? ' '.repeat(n) + l : l)).join('\n');

/**
 * The story as writes: { doc, files: [[path, text]], bytes: [[path,
 * url]], ctl: [[path, cmd]], over, missing }. A section with a type the
 * renderer lacks becomes a note naming it, and so does a story's overlay
 * script; `missing` lists them all.
 */
export function plan(s, has) {
  const missing = new Set();
  const lines = [
    'div root  : v-flex size-full bg=background',
    '  scroll s  : flex-1 overflow-y-scroll',
    '    div v  : v-flex gap=20 p=20',
  ];
  const files = [], bytes = [], ctl = [];
  s.sections.forEach((sec, i) => {
    const lack = [...typesIn(sec.ui)].filter((t) => !has.has(t));
    const body = sec.full ? 'v-flex gap=12' : sec.col ? 'v-flex items-start gap=12' : 'h-flex flex-wrap items-center gap=12';
    lines.push(`      div s${i}  : v-flex gap=8`);
    lines.push(`        text h  text=${q(sec.label)}  : text-xs font-semibold text-color=muted-foreground`);
    lines.push(`        div b  : ${body}`);
    if (lack.length) {
      lack.forEach((t) => missing.add(t));
      lines.push(`          text n  text=${q(`Not drawn by this renderer yet: ${lack.join(', ')}`)}  : text-sm italic text-color=muted-foreground`);
      return;
    }
    lines.push(indent(sec.ui, 10));
    for (const [p, v] of Object.entries(sec.files ?? {})) files.push([`${box(i)}/${p}`, v]);
    for (const [p, v] of Object.entries(sec.bytes ?? {})) bytes.push([`${box(i)}/${p}`, v]);
    for (const [p, v] of Object.entries(sec.ctl ?? {})) ctl.push([`${box(i)}/${p}/ctl`, v]);
  });
  let over = '';
  if (s.over) {
    const lack = [...typesIn('', s.over)].filter((t) => !has.has(t));
    if (lack.length) lack.forEach((t) => missing.add(t));
    else over = s.over.replace(/\$(\d+)\//g, (_, i) => `${box(i)}/`);
  }
  if (over) for (const [p, v] of Object.entries(s.overFiles ?? {})) files.push([`over/${p}`, v]);
  return { doc: lines.join('\n') + '\n', files, bytes, ctl, over, missing: [...missing] };
}

/** The names of the overlays an over/ctl script makes. */
const overlayNames = (over) => [...over.matchAll(/^new\s+\S+\s+([^/\s]+)\s/gm)].map((m) => m[1]);

/**
 * Shows story `s` in the window: removes the last story's overlays,
 * writes the tree, its data files and bytes, then its overlays. Returns
 * the plan, with `errors` for any write the core refused.
 */
export async function show(ui, s, has, { base = location.href, last = null } = {}) {
  const p = plan(s, has);
  p.errors = [];
  const tryWrite = async (path, data) => {
    try { await ui.write(path, data); } catch (e) { p.errors.push(`${path}: ${e.message}`); }
  };
  for (const n of last?.overlays ?? []) await ui.write(`${W}/over/ctl`, `delete ${n}`).catch(() => {});
  for (const [name, url] of Object.entries(s.assets ?? {})) {
    const b = new Uint8Array(await (await fetch(new URL(url, base))).arrayBuffer());
    if (await ui.exists(`asset/${name}`)) await tryWrite(`asset/${name}`, b);
    else await ui.create('asset', name, b).catch((e) => p.errors.push(`asset/${name}: ${e.message}`));
  }
  await tryWrite(`${W}/tree`, p.doc);
  for (const [path, v] of p.files.filter(([f]) => !f.startsWith('over/'))) await tryWrite(`${W}/${path}`, v);
  for (const [path, url] of p.bytes) await tryWrite(`${W}/${path}`, new Uint8Array(await (await fetch(new URL(url, base))).arrayBuffer()));
  for (const [path, v] of p.ctl) await tryWrite(`${W}/${path}`, v);
  p.overlays = [];
  if (p.over) {
    await tryWrite(`${W}/over/ctl`, p.over);
    p.overlays = overlayNames(p.over);
    for (const [path, v] of p.files.filter(([f]) => f.startsWith('over/'))) await tryWrite(`${W}/${path}`, v);
  }
  return p;
}

/**
 * Acts on one event line from the app (gallery.rc prints them): a click
 * on a button tagged open:NAME, close:NAME or toast:TYPE.
 */
export async function react(ui, line) {
  const [name, key] = line.trim().split(/\s+/);
  if (name !== 'click' || !key) return;
  const [verb, arg] = key.split(':');
  if (verb === 'open' || verb === 'close') await ui.write(`${W}/over/${arg}/ctl`, verb).catch(() => {});
  else if (verb === 'toast') await ui.write(`${W}/ctl`, `notify ${q(`This is ${arg}`)} type=${arg}`).catch(() => {});
}
