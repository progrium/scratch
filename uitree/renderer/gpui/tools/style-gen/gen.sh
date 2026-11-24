#!/bin/sh
# Regenerates, from gpui and gpui-component at the revs pinned here:
#   uitree/core/types/style-words    name argkind, dashed (the core's checks)
#   uitree/core/types/theme-tokens   name light dark, dashed
#   uitree/core/types/themes         GPUI Kit's themes as palettes (uit_themes)
#   generated/table.rs, theme.rs     the GPUI renderer's dispatch table
#
# After bumping the pins in the renderer's Cargo.toml, bump them here to the
# same values and run this script. It refuses to run if the two disagree.
# Building the generator links GPUI, so it needs GPUI's platform libraries
# (on Linux: libxkbcommon-x11, wayland, fontconfig, freetype headers).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
uitree="$here/../../../.."
ws="$uitree/renderer/gpui/Cargo.toml"

pin() { grep -E "^$1 *=" "$2" | sed -E 's/(, *)?features *= *\[[^]]*\]//' | tr -d ' '; }
for dep in gpui gpui-component; do
	a=$(pin "$dep" "$ws")
	b=$(pin "$dep" "$here/Cargo.toml")
	if [ "$a" != "$b" ]; then
		echo "gen.sh: $dep pin differs from $ws:" >&2
		echo "  renderer: $a" >&2
		echo "  gen:      $b" >&2
		exit 1
	fi
done

cargo run --quiet --manifest-path "$here/Cargo.toml" -- "$uitree/core/types" "$here/generated"
echo "gen.sh: wrote core/types/style-words, theme-tokens, themes, generated/table.rs, generated/theme.rs"
echo "gen.sh: then run renderer/tui/types/gen.sh, which copies them for the terminal host"
