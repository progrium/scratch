// The demo's service worker (cache.js registers it): every same-origin GET
// is answered from a cache once fetched, so h9.wasm, root.h9a, the GPUI
// module and the rest download once, not per page or per iframe. zig build web
// stamps VERSION with a hash of zig-out/, so a rebuild starts a new cache and
// drops the old one; until then nothing is fetched twice.
const VERSION = 'dev';
const CACHE = `uitree-${VERSION}`;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k.startsWith('uitree-') && k !== CACHE) await caches.delete(k);
  await self.clients.claim();
})()));

self.addEventListener('fetch', (e) => {
  const r = e.request;
  // A dev build (VERSION unstamped) always goes to the network.
  if (VERSION === 'dev' || r.method !== 'GET' || new URL(r.url).origin !== location.origin) return;
  e.respondWith((async () => {
    const c = await caches.open(CACHE);
    const hit = await c.match(r, { ignoreSearch: false });
    if (hit) return hit;
    const res = await fetch(r);
    if (res.ok && res.type === 'basic') await c.put(r, res.clone());
    return res;
  })());
});
