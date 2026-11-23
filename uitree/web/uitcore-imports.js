// The "uitcore" import module of uitree_web.wasm (renderer/gpui's
// uitcore-sys on wasm): every function of uitcore.h, forwarded to the core
// module (uitcore-shared.wasm), which shares the renderer's memory, so the
// arguments pass through unchanged. gpui.js binds it before the renderer
// starts. Two calls are adjusted on the way:
//
// - uit_create: UitConfig.wake is an index into the renderer's function
//   table, which means nothing to the core. The core gets its own
//   uit_web_wake_fn, and the page calls the renderer's back
//   (uitree_web_wake) when it fires.
// - uit_run_machine: there's no h9 in the core here. The page runs the app
//   in h9's Worker (uit-web.js's runApp) with UitMachineArgs's argv.

let x = null;
let hooks = null;

export function bind(exports, h) {
  x = exports;
  hooks = h;
}

const dv = () => new DataView(hooks.memory.buffer);
const str = (p) => {
  const d = dv(), ptr = d.getUint32(p, true), n = d.getUint32(p + 4, true);
  return n ? new TextDecoder().decode(new Uint8Array(hooks.memory.buffer, ptr, n)) : '';
};

export function uit_create(cfg, out) {
  const d = dv();
  hooks.setWake(d.getUint32(cfg + 32, true));
  d.setUint32(cfg + 32, x.uit_web_wake_fn(), true);
  return x.uit_create(cfg, out);
}

export function uit_run_machine(c, args) {
  const d = dv();
  const argvp = d.getUint32(args + 8, true), argc = d.getUint32(args + 12, true);
  const argv = [];
  for (let i = 0; i < argc; i++) argv.push(str(argvp + 8 * i));
  if (!argv.length) argv.push(str(args));
  return hooks.runMachine(c, argv);
}

export function uit_abi_version(...a) { return x.uit_abi_version(...a); }
export function uit_themes(...a) { return x.uit_themes(...a); }
export function uit_serve_fd(...a) { return x.uit_serve_fd(...a); }
export function uit_listen(...a) { return x.uit_listen(...a); }
export function uit_shutdown(...a) { return x.uit_shutdown(...a); }
export function uit_destroy(...a) { return x.uit_destroy(...a); }
export function uit_last_error(...a) { return x.uit_last_error(...a); }
export function uit_wake_renderer(...a) { return x.uit_wake_renderer(...a); }
export function uit_pump(...a) { return x.uit_pump(...a); }
export function uit_windows(...a) { return x.uit_windows(...a); }
export function uit_window_root(...a) { return x.uit_window_root(...a); }
export function uit_children(...a) { return x.uit_children(...a); }
export function uit_overlays(...a) { return x.uit_overlays(...a); }
export function uit_type(...a) { return x.uit_type(...a); }
export function uit_path(...a) { return x.uit_path(...a); }
export function uit_window_of(...a) { return x.uit_window_of(...a); }
export function uit_prop(...a) { return x.uit_prop(...a); }
export function uit_style(...a) { return x.uit_style(...a); }
export function uit_lines(...a) { return x.uit_lines(...a); }
export function uit_keys(...a) { return x.uit_keys(...a); }
export function uit_menu_bar(...a) { return x.uit_menu_bar(...a); }
export function uit_menu(...a) { return x.uit_menu(...a); }
export function uit_asset(...a) { return x.uit_asset(...a); }
export function uit_theme_dark(...a) { return x.uit_theme_dark(...a); }
export function uit_token(...a) { return x.uit_token(...a); }
export function uit_token_text(...a) { return x.uit_token_text(...a); }
export function uit_emit(...a) { return x.uit_emit(...a); }
export function uit_request(...a) { return x.uit_request(...a); }
export function uit_mirror(...a) { return x.uit_mirror(...a); }
export function uit_bounds(...a) { return x.uit_bounds(...a); }
export function uit_frame_drawn(...a) { return x.uit_frame_drawn(...a); }
export function uit_window_closed(...a) { return x.uit_window_closed(...a); }
export function uit_key(...a) { return x.uit_key(...a); }
export function uit_menu_action(...a) { return x.uit_menu_action(...a); }
export function uit_system_dark(...a) { return x.uit_system_dark(...a); }
export function uit_drag(...a) { return x.uit_drag(...a); }
