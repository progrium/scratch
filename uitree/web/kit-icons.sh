#!/bin/sh
# kit-icons.sh OUT: copies GPUI Kit's icons (gpui-kit-assets, at the
# version Cargo.lock pins) into OUT. Run in renderer/gpui (build.zig).
set -eu
kit=$(cargo metadata --format-version 1 --locked |
	python3 -c 'import json,sys; print(next(p["manifest_path"] for p in json.load(sys.stdin)["packages"] if p["name"] == "gpui-kit-assets"))')
mkdir -p "$1"
cp -R "$(dirname "$kit")/assets/icons/." "$1/"
