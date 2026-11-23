#!/bin/sh
# finish.sh OUT SW: the last step of zig build web (build.zig). Writes
# OUT/sw.js from SW with its cache name stamped with a hash of OUT, so a
# rebuild starts a new cache (sw.js), then .gz and .br copies of the big
# files for a server that serves them (nginx's gzip_static and
# brotli_static, Caddy's file_server precompressed; README.md, Size).
# Brotli only where the brotli command is installed.
set -eu
out=$1
ver=$(cd "$out" && find . -type f ! -name sw.js ! -name '*.gz' ! -name '*.br' | LC_ALL=C sort | xargs cat | sha256sum | cut -c1-12)
rm -f "$out/sw.js"
sed "s/^const VERSION = 'dev';/const VERSION = '$ver';/" "$2" >"$out/sw.js"
for f in "$out"/h9/h9.wasm "$out"/h9/root.h9a "$out"/gpui/uitree_web_bg.wasm "$out"/*.wasm; do
	[ -f "$f" ] || continue
	gzip -9kf "$f"
	if command -v brotli >/dev/null; then brotli -kf -q 11 "$f"; fi
done
echo "built $out"
