// h9's browser-host Worker (h9/worker.js, unchanged) with one addition: a
// WebSocket for `ws://uitree.invalid/...`, the app's `$ui` mount, that is
// a channel to the core on the page instead of a network connection.
// uit-web.js's runApp is the page's side.
//
// Worker to page: { type: 'uit-open', id }, { type: 'uit-data', id, data }
// and { type: 'uit-close', id }. Page to Worker: { type: 'uit-opened', id },
// { type: 'uit-data', id, data } and { type: 'uit-close', id }.

import './h9/worker.js';

const Real = self.WebSocket;
const socks = new Map();
let next = 1;

class CoreSocket {
  constructor(url) {
    this.url = url;
    this.protocol = '9p';
    this.binaryType = 'arraybuffer';
    this.readyState = 0;
    this.id = next++;
    this.onopen = this.onmessage = this.onclose = this.onerror = null;
    socks.set(this.id, this);
    self.postMessage({ type: 'uit-open', id: this.id });
  }
  send(b) {
    if (this.readyState !== 1) return;
    const u = b instanceof Uint8Array ? b.slice() : new Uint8Array(b).slice();
    self.postMessage({ type: 'uit-data', id: this.id, data: u.buffer }, [u.buffer]);
  }
  close() {
    if (this.readyState >= 2) return;
    this.readyState = 3;
    self.postMessage({ type: 'uit-close', id: this.id });
    this.onclose?.({ wasClean: true, code: 1000, reason: '' });
  }
}

self.WebSocket = function WebSocket(url, protocols) {
  if (String(url).startsWith('ws://uitree.invalid/')) return new CoreSocket(url);
  return new Real(url, protocols);
};

self.addEventListener('message', ({ data: m }) => {
  const s = socks.get(m.id);
  if (!s) return;
  switch (m.type) {
    case 'uit-opened': s.readyState = 1; s.onopen?.({}); break;
    case 'uit-data': s.onmessage?.({ data: m.data }); break;
    case 'uit-close':
      if (s.readyState < 3) { s.readyState = 3; s.onclose?.({ wasClean: true, code: 1000, reason: '' }); }
      socks.delete(m.id);
      break;
  }
});

