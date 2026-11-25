// Runs vt-smoke.wasm (`zig build smoke -Dtarget=wasm32-wasi`) in Node and
// in headless Chromium, through vt-smoke.js in both:
//
//	node tests/vt-smoke.mjs [zig-out/web/vt-smoke.wasm] [--node-only]
//
// Needs Node 24 (JSPI) and, for the browser half, Playwright with its
// Chromium, as web/test/run.mjs does.
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { smoke } from './vt-smoke.js';

const args = process.argv.slice(2);
const wasmPath = args.find((a) => !a.startsWith('--')) ?? new URL('../zig-out/web/vt-smoke.wasm', import.meta.url).pathname;
const bytes = await readFile(wasmPath);
let failed = false;
const report = (where, r) => {
  console.log(`ok   ${where}: libghostty-vt in the core's wasm (${(r.wasmBytes / 1024).toFixed(0)} KiB), parse ${r.mbps.toFixed(1)} MB/s`);
  console.log(r.screen.replace(/\n+$/, '').split('\n').map((l) => `     > ${l}`).join('\n'));
};

try {
  report('node', await smoke(bytes, { log: (s) => console.log(`     | ${s}`) }));
} catch (e) {
  console.log(`FAIL node: ${e.stack ?? e}`);
  failed = true;
}

if (!args.includes('--node-only')) {
  const js = await readFile(new URL('./vt-smoke.js', import.meta.url));
  const page = `<!doctype html><meta charset="utf-8"><title>vt-smoke</title><pre id="out">running</pre>
<script type="module">
import { smoke } from './vt-smoke.js';
const out = document.getElementById('out');
try {
  const r = await smoke(await (await fetch('vt-smoke.wasm')).arrayBuffer(), { log: (s) => console.log(s) });
  window.result = r;
  out.textContent = r.screen;
} catch (e) { window.result = { error: String(e.stack ?? e) }; out.textContent = String(e); }
</script>`;
  const files = { '/': ['text/html', page], '/vt-smoke.js': ['text/javascript', js], '/vt-smoke.wasm': ['application/wasm', bytes] };
  const server = createServer((req, res) => {
    const f = files[new URL(req.url, 'http://x').pathname];
    if (!f) { res.writeHead(404).end(); return; }
    res.writeHead(200, { 'content-type': f[0] }).end(f[1]);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { chromium } = createRequire(import.meta.url)('playwright');
  const browser = await chromium.launch();
  try {
    const p = await browser.newPage();
    const log = [];
    p.on('console', (m) => log.push(m.text()));
    p.on('pageerror', (e) => log.push(`pageerror: ${e.message}`));
    await p.goto(`http://127.0.0.1:${server.address().port}/`);
    await p.waitForFunction(() => window.result, null, { timeout: 60000 });
    const r = await p.evaluate(() => window.result);
    if (r.error) throw new Error(r.error);
    report(`chromium ${browser.version()}`, r);
  } catch (e) {
    console.log(`FAIL chromium: ${e.stack ?? e}`);
    failed = true;
  } finally {
    await browser.close();
    server.close();
  }
}
process.exit(failed ? 1 : 0);
