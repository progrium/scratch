// Registers sw.js, which keeps everything the demo fetches in a cache
// (sw.js). A page that the worker doesn't control yet, such as the first
// visit, loads as before; the next page or iframe is served from the cache.
if (typeof navigator !== 'undefined' && navigator.serviceWorker && location.protocol !== 'file:') {
  navigator.serviceWorker.register(new URL('sw.js', import.meta.url)).catch((e) => console.warn('sw.js:', e));
}
