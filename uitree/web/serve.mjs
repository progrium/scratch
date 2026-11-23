#!/usr/bin/env node
// A static server for zig-out/ that serves zig build web's precompressed copies:
// FILE.br or FILE.gz when the browser accepts it, as a CDN or nginx's
// brotli_static would, so the transfer sizes match a real deployment.
//
//	node serve.mjs [dir] [port]     (default zig-out, 8000; LOG=1 logs each
//	                                 file served and its bytes)
import { createServer } from 'node:http';
import { stat, readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const dir = process.argv[2] ?? new URL('zig-out', import.meta.url).pathname;
const port = Number(process.argv[3] ?? 8000);
const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.wasm': 'application/wasm', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json',
  '.css': 'text/css', '.rc': 'text/plain; charset=utf-8', '.md': 'text/plain; charset=utf-8',
};
const isFile = async (p) => (await stat(p).catch(() => null))?.isFile() ?? false;

createServer(async (req, res) => {
  let p = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (p.endsWith('/')) p += 'index.html';
  const f = join(dir, p);
  if (!f.startsWith(dir) || !(await isFile(f))) { res.writeHead(404).end(); return; }
  const accept = String(req.headers['accept-encoding'] ?? '');
  const head = { 'content-type': types[extname(f)] ?? 'application/octet-stream', vary: 'accept-encoding', 'cache-control': 'no-cache' };
  let body = f;
  for (const [enc, ext] of [['br', '.br'], ['gzip', '.gz']]) {
    if (accept.includes(enc) && (await isFile(f + ext))) { body = f + ext; head['content-encoding'] = enc; break; }
  }
  const data = await readFile(body);
  if (process.env.LOG) console.log(`${p} ${head['content-encoding'] ?? '-'} ${data.length}`);
  res.writeHead(200, head).end(data);
}).listen(port, () => console.log(`http://localhost:${port}/ serving ${dir}`));
