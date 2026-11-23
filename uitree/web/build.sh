#!/bin/sh
# Builds the browser demo into web/dist (README.md). Needs Zig 0.16 and,
# for root.h9a, a 386 root in third_party/hyper9 (see README.md).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
uit=$here/..
h9=$uit/third_party/hyper9
out=$here/dist
opt=${OPTIMIZE:-ReleaseSmall}
mkdir -p "$out/h9" "$out/apps"
# h9's browser host, unchanged.
(cd "$h9" && zig build web -Doptimize=ReleaseFast)
cp "$h9"/zig-out/web/h9.wasm "$h9"/zig-out/web/h9-web.js "$h9"/zig-out/web/worker.js \
   "$h9"/zig-out/web/wasi-mem.js "$h9"/zig-out/web/statictree.js "$h9"/zig-out/web/root.h9a "$out/h9/"
# The core as a wasm reactor.
(cd "$uit/core" && zig build -Dtarget=wasm32-wasi -Doptimize="$opt" --prefix "$out/zig")
cp "$out/zig/web/uitcore.wasm" "$out/zig/web/uitcore-shared.wasm" "$out/"
# The terminal renderer, with the core linked in.
(cd "$uit/renderer/tui" && zig build -Dtarget=wasm32-wasi -Dh9=false -Doptimize="$opt" --prefix "$out/zig")
cp "$out/zig/web/uitree-tui.wasm" "$out/"
# The GPUI renderer (renderer/gpui's crates/web) through wasm-bindgen.
# gpui-kit turns on gpui_web's multithreaded feature, whose wasm_thread
# needs nightly: RUSTC_BOOTSTRAP stands in for it (gpui_web runs
# single-threaded here; GPUI Kit's own story-web pins a nightly).
if [ "${GPUI:-1}" = 1 ]; then
	tgt=${CARGO_TARGET_DIR:-$uit/renderer/gpui/target}
	(cd "$uit/renderer/gpui" && RUSTC_BOOTSTRAP=1 RUSTFLAGS='--cfg getrandom_backend="wasm_js"' \
		cargo build -p uitree-web --target wasm32-unknown-unknown --release --target-dir "$tgt")
	wasm-bindgen "$tgt/wasm32-unknown-unknown/release/uitree_web.wasm" --out-dir "$out/gpui" --target web --no-typescript --remove-name-section
fi
cp "$here"/*.js "$here"/*.html "$out/"
cp "$uit"/renderer/tui/examples/counter.rc "$uit"/renderer/tui/examples/lib.rc "$out/apps/"
echo "built $out"
