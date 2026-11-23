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
cp "$out/zig/web/uitcore.wasm" "$out/"
# The terminal renderer, with the core linked in.
(cd "$uit/renderer/tui" && zig build -Dtarget=wasm32-wasi -Dh9=false -Doptimize="$opt" --prefix "$out/zig")
cp "$out/zig/web/uitree-tui.wasm" "$out/"
cp "$here"/*.js "$here"/*.html "$out/"
cp "$uit"/renderer/tui/examples/counter.rc "$uit"/renderer/tui/examples/lib.rc "$out/apps/"
echo "built $out"
