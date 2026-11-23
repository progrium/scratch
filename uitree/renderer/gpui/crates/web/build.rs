//! The core's coroutine exports, for the page (uitree/web/uit-web.js):
//! h9_coro_entry starts a coroutine through WebAssembly.promising, and
//! h9_get_sp and h9_set_sp let it put the shadow stack pointer back on the
//! main stack whenever a coroutine parks. They're defined in the core's
//! libh9coro.a, which uitcore-sys links, and a cdylib exports only Rust's.

fn main() {
    if std::env::var("CARGO_CFG_TARGET_FAMILY").as_deref() == Ok("wasm") {
        for name in ["h9_coro_entry", "h9_get_sp", "h9_set_sp"] {
            println!("cargo:rustc-link-arg=--export={name}");
        }
    }
}
