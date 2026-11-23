#!/bin/sh
# Builds the browser demo into web/dist (README.md). Needs Zig 0.16,
# wasm-opt (binaryen) and, for root.h9a, a 386 root in third_party/hyper9
# (see README.md).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
uit=$here/..
h9=$uit/third_party/hyper9
out=$here/dist
opt=${OPTIMIZE:-ReleaseSmall}
mkdir -p "$out/h9" "$out/apps"
# h9's browser host, unchanged.
[ "${H9:-1}" = 1 ] && (cd "$h9" && zig build web -Doptimize=ReleaseFast)
cp "$h9"/zig-out/web/h9-web.js "$h9"/zig-out/web/worker.js \
   "$h9"/zig-out/web/wasi-mem.js "$h9"/zig-out/web/statictree.js "$out/h9/"
# h9.wasm without its DWARF, which is 12.9 of its 17.5 MB (the code is
# the same; README.md, Size).
wasm-opt --all-features --strip-debug --strip-producers "$h9"/zig-out/web/h9.wasm -o "$out/h9/h9.wasm"
# The root: only what the examples run (root.list), from h9's 386 root
# tree; h9's own browser root adds rio, acme and their font.
(cd "$h9" && zig run -OReleaseSafe tools/webroot.zig -- .local/9front/root386 "$here/root.list" "$out/h9/root.h9a")
# The core alone as a wasm reactor (core-test.html).
(cd "$uit/core" && zig build -Dtarget=wasm32-wasi -Doptimize="$opt" --prefix "$out/zig")
cp "$out/zig/web/uitcore.wasm" "$out/"
# The terminal renderer, with the core linked in.
(cd "$uit/renderer/tui" && zig build -Dtarget=wasm32-wasi -Dh9=false -Doptimize="$opt" --prefix "$out/zig")
cp "$out/zig/web/uitree-tui.wasm" "$out/"
# The GPUI renderer (renderer/gpui's crates/web) through wasm-bindgen,
# with the core linked in (uitcore-sys builds it for wasm32-wasi).
# gpui-kit turns on gpui_web's multithreaded feature, whose wasm_thread
# needs nightly: RUSTC_BOOTSTRAP stands in for it (gpui_web runs
# single-threaded here; GPUI Kit's own story-web pins a nightly).
if [ "${GPUI:-1}" = 1 ]; then
	tgt=${CARGO_TARGET_DIR:-$uit/renderer/gpui/target}
	(cd "$uit/renderer/gpui" && UITCORE_OPTIMIZE="$opt" RUSTC_BOOTSTRAP=1 RUSTFLAGS='--cfg getrandom_backend="wasm_js"' \
		cargo build -p uitree-web --target wasm32-unknown-unknown --profile web --target-dir "$tgt")
	wasm-bindgen "$tgt/wasm32-unknown-unknown/web/uitree_web.wasm" --out-dir "$out/gpui" --target web --no-typescript --remove-name-section
	# GPUI Kit's icons: on wasm its assets are fetched one by one when
	# drawn, from assets/icons/NAME.svg beside the page.
	kit=$(cd "$uit/renderer/gpui" && cargo metadata --format-version 1 --locked |
		python3 -c 'import json,sys; print(next(p["manifest_path"] for p in json.load(sys.stdin)["packages"] if p["name"] == "gpui-kit-assets"))')
	rm -rf "$out/assets/icons"
	mkdir -p "$out/assets"
	cp -R "$(dirname "$kit")/assets/icons" "$out/assets/icons"
fi
cp "$here"/*.js "$here"/*.html "$out/"
# The examples (apps.js): each in apps/NAME/ with what it reads.
ex=$uit/tests/conformance/examples
rm -rf "$out/apps"
for a in counter hello confirm signin settings files; do
	mkdir -p "$out/apps/$a"
	cp "$ex/rc/$a.rc" "$ex/rc/lib.rc" "$out/apps/$a/"
done
mkdir -p "$out/apps/csvview" "$out/apps/tour"
cp "$ex/awk/csvview.awk" "$ex/awk/planets.csv" "$out/apps/csvview/"
cp "$here/tour/tour.rc" "$here/tour/notes.md" "$here/tour/pic.png" "$ex/rc/lib.rc" "$out/apps/tour/"
# The service worker's cache name, from what's in dist/ (sw.js).
ver=$(cd "$out" && find . -type f ! -name sw.js ! -name '*.gz' ! -name '*.br' | LC_ALL=C sort | xargs cat | sha256sum | cut -c1-12)
sed "s/^const VERSION = 'dev';/const VERSION = '$ver';/" "$here/sw.js" >"$out/sw.js"
# Precompressed copies of the big files, for a server that serves them
# (nginx's gzip_static and brotli_static, Caddy's file_server precompressed):
# README.md, Size. Brotli only where the brotli command is installed.
for f in "$out"/h9/h9.wasm "$out"/h9/root.h9a "$out"/gpui/uitree_web_bg.wasm "$out"/*.wasm; do
	[ -f "$f" ] || continue
	gzip -9kf "$f"
	if command -v brotli >/dev/null; then brotli -kf -q 11 "$f"; fi
done
echo "built $out"
