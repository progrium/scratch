// Drives the examples in headless Chromium on both renderers and checks
// that each feature they use works (README.md § Tests):
//
//	node test/run.mjs [--base URL] [--only APP,...] [--renderer gpui|tui] [--shots DIR]
//
// Serve dist/ first (python3 -m http.server -d dist 8765). Each case
// finds nodes through $ui (probe.js: a node's bounds file), acts with the
// real mouse and keyboard, and checks the tree or the app's own output.
import { createRequire } from 'node:module';
const { chromium } = createRequire(import.meta.url)('playwright');
import { cases } from './cases.mjs';

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const base = arg('--base', 'http://localhost:8765/');
const only = arg('--only', '')?.split(',').filter(Boolean);
const renderers = arg('--renderer', 'gpui,tui').split(',');
const shots = arg('--shots', '');
const route = arg('--xterm', ''); // a directory with xterm's package, for offline runs

const browser = await chromium.launch({ args: ['--enable-unsafe-swiftshader', '--use-angle=swiftshader', '--disable-webgpu'] });
let failed = 0, passed = 0;
for (const r of renderers) {
  for (const c of cases) {
    if (only.length && !only.includes(c.app)) continue;
    if (c.renderers && !c.renderers.includes(r)) continue;
    const page = await browser.newPage({ viewport: { width: c.width ?? 1000, height: c.height ?? 640 } });
    if (route) {
      const fs = await import('node:fs');
      await page.route('https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/**', (rt) => {
        const f = `${route}/${new URL(rt.request().url()).pathname.split('@5.5.0/')[1]}`;
        rt.fulfill({ body: fs.readFileSync(f), contentType: f.endsWith('.css') ? 'text/css' : 'application/javascript' });
      });
    }
    const log = [];
    page.on('console', (m) => log.push(m.text()));
    page.on('pageerror', (e) => log.push(`pageerror: ${e.message}`));
    const name = `${r} ${c.app}: ${c.name}`;
    try {
      await page.goto(new URL(`${r}.html?app=${c.app}`, base).href);
      const t = await harness(page, r, log);
      await c.run(t);
      console.log(`ok   ${name}`);
      passed++;
    } catch (e) {
      console.log(`FAIL ${name}: ${e.message}`);
      if (r === 'tui') console.log((await page.evaluate(() => { const tm = window.tui?.term; if (!tm) return ''; const b = tm.buffer.active; let s = ''; for (let i = 0; i < tm.rows; i++) s += b.getLine(i).translateToString(true).trimEnd() + '\n'; return s; }).catch(() => '')).replace(/\n+$/, '').split('\n').map((l) => `     > ${l}`).join('\n'));
      console.log(`     active: ${await page.evaluate(() => document.activeElement?.className).catch(() => '?')}`);
      for (const l of log.filter((l) => process.env.DEBUG || !/GL Driver|No available adapters|no usable hypervisor/.test(l)).slice(-30)) console.log(`     | ${l.slice(0, 300)}`);
      failed++;
    }
    if (shots) await page.screenshot({ path: `${shots}/${r}-${c.app}-${c.name.replace(/\W+/g, '-')}.png` });
    await page.close();
  }
}
await browser.close();
console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);

/** What a case gets: the page, the renderer, and helpers that work on both. */
async function harness(page, renderer, log) {
  await page.waitForFunction(() => window.probe, null, { timeout: 30000 });
  await page.evaluate(async () => { window.ui = await window.probe(); });
  const ui = {
    read: (p) => page.evaluate((p) => window.ui.read(p), p),
    write: (p, s) => page.evaluate(([p, s]) => window.ui.write(p, s), [p, s]),
    exists: (p) => page.evaluate((p) => window.ui.exists(p), p),
    bounds: (p) => page.evaluate((p) => window.ui.bounds(p), p),
  };
  // Window points to page pixels.
  const toPage = async ([x, y]) => {
    if (renderer === 'gpui') return [x, y];
    const box = await page.locator('.xterm-screen').boundingBox();
    const [cols, rows] = await page.evaluate(() => [window.tui.term.cols, window.tui.term.rows]);
    const cw = box.width / cols, ch = box.height / rows;
    // A cell is 8 by 16 points, and row 0 is the title (renderer/tui ui.zig's bounds).
    return [box.x + (Math.floor(x / 8) + 0.5) * cw, box.y + (Math.floor(y / 16) + 1 + 0.5) * ch];
  };
  const t = {
    page, renderer, ui, log,
    wait: (ms) => page.waitForTimeout(ms),
    /** Waits until fn() is truthy (fn may be async), up to ms. */
    async until(what, fn, ms = 15000) {
      const end = Date.now() + ms;
      let last;
      for (;;) {
        try { last = await fn(); if (last) return last; } catch (e) { last = e.message; }
        if (Date.now() > end) throw new Error(`timed out waiting for ${what} (last: ${JSON.stringify(last)})`);
        await page.waitForTimeout(150);
      }
    },
    /**
     * Waits for `path` to be laid out and then a moment more, for the
     * app to finish its setup and open its events (an event before that
     * is lost, README.md).
     */
    async ready(path, settle = 1500) { await t.node(path); await page.waitForTimeout(settle); },
    /** Waits for the node at path (in the main window unless it starts with win/) to be laid out. */
    async node(path) {
      const p = path.startsWith('win/') ? path : `win/main/${path}`;
      return t.until(`${p} laid out`, async () => { const b = await ui.bounds(p); return b && b[2] > 0 && b[3] > 0 ? b : null; });
    },
    /** Clicks the middle of a node (or at fx, fy of its box). */
    async click(path, { fx = 0.5, fy = 0.5, button = 'left', count = 1 } = {}) {
      const [x, y, w, h] = await t.node(path);
      const [px, py] = await toPage([x + w * fx, y + h * fy]);
      await page.mouse.click(px, py, { button, clickCount: count });
    },
    async hover(path) {
      const [x, y, w, h] = await t.node(path);
      const [px, py] = await toPage([x + w / 2, y + h / 2]);
      await page.mouse.move(px, py);
    },
    type: (s) => page.keyboard.type(s, { delay: 20 }),
    press: (k) => page.keyboard.press(k),
    /** The app's standard output and error so far. */
    output: () => page.evaluate(() => window.appLog.join('')),
    /** The terminal's text (terminal renderer only). */
    screen: () => page.evaluate(() => { const tm = window.tui.term, b = tm.buffer.active; let s = ''; for (let i = 0; i < tm.rows; i++) s += b.getLine(i).translateToString(true) + '\n'; return s; }),
    /**
     * Does act() until check() holds: the app may not be reading its
     * events yet when its tree first appears (README.md), so a first
     * click can go unheard.
     */
    async retry(what, act, check, { tries = 6, ms = 1500 } = {}) {
      for (let i = 0; i < tries; i++) {
        await act();
        try { return await t.until(what, check, ms); } catch (e) { if (i === tries - 1) throw e; }
      }
    },
    async eq(what, got, want) { if (got !== want) throw new Error(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); },
  };
  return t;
}
