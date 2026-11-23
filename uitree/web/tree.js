// Reads a core's committed tree from JS, through uitcore.h's exports, for
// checks and the demo's inspector. On wasm32 a UitStr argument is passed
// as a pointer to it, and a UitStr result through a pointer the caller
// passes first.

export class Tree {
  constructor(core) {
    this.core = core;
    this.mem = core.mem;
    this.x = core.m.exports;
    this.c = core.c;
    this.tmp = this.mem.alloc(64);
  }
  /** A UitStr argument: [ptr to UitStr, free]. */
  arg(s) {
    const [p, n] = this.mem.bytes(s);
    const u = this.mem.alloc(8);
    this.mem.dv.setUint32(u, p, true);
    this.mem.dv.setUint32(u + 4, n, true);
    return [u, () => { this.mem.free(p, n); this.mem.free(u, 8); }];
  }
  ret(fn, ...args) {
    fn(this.tmp, ...args);
    return this.mem.uitstr(this.tmp);
  }
  windows() {
    const n = this.x.uit_windows(this.c, this.tmp);
    const p = this.mem.dv.getUint32(this.tmp, true);
    const out = [];
    for (let i = 0; i < n; i++) out.push(this.mem.uitstr(p + 8 * i));
    return out;
  }
  root(win) {
    const [u, f] = this.arg(win);
    try { return this.x.uit_window_root(this.c, u); } finally { f(); }
  }
  children(n) {
    const k = this.x.uit_children(this.c, n, this.tmp);
    const p = this.mem.dv.getUint32(this.tmp, true);
    const out = [];
    for (let i = 0; i < k; i++) out.push(this.mem.dv.getUint32(p + 4 * i, true));
    return out;
  }
  type(n) { return this.ret(this.x.uit_type, this.c, n); }
  path(n) { return this.ret(this.x.uit_path, this.c, n); }
  prop(n, file) {
    const [u, f] = this.arg(file);
    try {
      const r = this.x.uit_prop(this.c, n, u, this.tmp + 16);
      return r === 1 ? this.mem.uitstr(this.tmp + 16) : null;
    } finally { f(); }
  }
  find(win, path) {
    const walk = (n) => {
      if (this.path(n) === path) return n;
      for (const c of this.children(n)) { const r = walk(c); if (r) return r; }
      return 0;
    };
    return walk(this.root(win));
  }
  emit(path, name, win = 'main') {
    const n = this.find(win, path);
    if (!n) throw new Error(`no node ${path}`);
    const [u, f] = this.arg(name);
    try { return this.x.uit_emit(this.c, n, u, 0, 0); } finally { f(); }
  }
  dump() {
    const lines = [];
    const walk = (n, d) => {
      const t = this.prop(n, 'text');
      lines.push(`${'  '.repeat(d)}${this.path(n)} ${this.type(n)}${t !== null ? ` text=${JSON.stringify(t)}` : ''}`);
      for (const c of this.children(n)) walk(c, d + 1);
    };
    for (const w of this.windows()) {
      lines.push(`window ${w}`);
      const r = this.root(w);
      if (r) walk(r, 1);
    }
    return lines.join('\n');
  }
}
