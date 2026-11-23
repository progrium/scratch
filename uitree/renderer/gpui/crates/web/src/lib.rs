//! uitree_web.wasm: the GPUI renderer in the browser (uitree/web/README.md).
//!
//! The host crate as on the desktop, on gpui_web's single canvas, with
//! the core linked in as it is there (uitcore-sys builds libuitcore.a for
//! wasm32-wasi). The page supplies the core's platform imports
//! (uitree/web/uitcore-imports.js) and runs its coroutines through the
//! exports build.rs adds.

#![cfg(target_family = "wasm")]

use wasm_bindgen::prelude::*;

/// Starts the renderer: `argv` is the app, run in h9's Worker when the
/// host calls uit_run_machine. `assets` is the absolute URL icons are
/// fetched under (`{assets}/assets/icons/NAME.svg`).
#[wasm_bindgen]
pub fn start(argv: Vec<String>, title: Option<String>, assets: String) {
    console_error_panic_hook::set_once();
    let _ = host::WEB_ASSETS.set(assets);
    let opts = host::Options { argv, title, ..Default::default() };
    host::run(opts);
}
