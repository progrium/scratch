#!/bin/sh
# Regenerates crates/style/src/table.rs and theme.rs from gpui and
# gpui-component at the revs pinned in this directory's Cargo.toml.
#
# After bumping the pins in the workspace Cargo.toml, bump them here to the same
# values and run this script. It refuses to run if the two disagree.
# Building the generator links GPUI, so it needs GPUI's platform libraries
# (on Linux: libxkbcommon-x11, wayland, fontconfig, freetype headers).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ws="$here/../../.."

pin() { grep -E "^$1 *=" "$2" | sed -E 's/(, *)?features *= *\[[^]]*\]//' | tr -d ' '; }
for dep in gpui gpui-component; do
	a=$(pin "$dep" "$ws/Cargo.toml")
	b=$(pin "$dep" "$here/Cargo.toml")
	if [ "$a" != "$b" ]; then
		echo "gen.sh: $dep pin differs from the workspace:" >&2
		echo "  workspace: $a" >&2
		echo "  gen:       $b" >&2
		exit 1
	fi
done

cargo run --quiet --manifest-path "$here/Cargo.toml" -- "$ws/crates/style/src"
echo "gen.sh: wrote crates/style/src/table.rs and theme.rs"
