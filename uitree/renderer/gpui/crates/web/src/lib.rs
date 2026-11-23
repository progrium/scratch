//! uitree_web.wasm: the GPUI renderer in the browser (uitree/web/README.md).
//!
//! The host crate as on the desktop, on gpui_web's single canvas. The core
//! is a separate wasm module (uitcore.wasm) that imports this module's
//! memory, so every pointer uitcore.h passes means the same thing on both
//! sides: uitcore-sys's functions are imports that uitree/web/gpui.js
//! forwards to the core's exports. Two things can't cross that way, and
//! are here: the wake function pointer (an index into this module's
//! table, not the core's) and an allocation the page can make before
//! anything else runs.

#![cfg(target_family = "wasm")]

use std::ffi::c_void;
use wasm_bindgen::prelude::*;

/// Starts the renderer: `argv` is the app, run in h9's Worker when the
/// host calls uit_run_machine.
#[wasm_bindgen]
pub fn start(argv: Vec<String>, title: Option<String>) {
    console_error_panic_hook::set_once();
    let opts = host::Options { argv, title, ..Default::default() };
    host::run(opts);
}

/// Calls UitConfig.wake, which is a function in this module's table.
///
/// # Safety
/// `f` and `ctx` are the UitConfig.wake and wake_ctx the host passed to
/// uit_create.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn uitree_web_wake(f: usize, ctx: *mut c_void) {
    let f: extern "C" fn(*mut c_void) = unsafe { std::mem::transmute(f) };
    f(ctx);
}
