#!/bin/sh
# Copies the descriptors of the types uitree-tui draws from core/types/
# (interface I6), with style-words and theme-tokens (I7), and writes
# types.zig, which embeds them. Run from this directory after W1 changes
# a descriptor or after adding a type to TYPES (and drawing it).
set -e
TYPES="div text styled-text img svg icon scroll spacer
button checkbox radio-group switch select input textarea number-input slider form field
link tabs tab empty separator badge kbd progress spinner alert dialog"
src=../../../core/types
for t in $TYPES; do mkdir -p "$t"; cp "$src/$t/spec" "$t/spec"; done
cp "$src/style-words" "$src/theme-tokens" .
{
	echo '//! The descriptors of the types uitree-tui draws, copied from'
	echo '//! core/types/ (interface I6), and the style words and theme tokens it'
	echo '//! registers (I7). Written by gen.sh; do not edit.'
	echo
	echo 'pub const names = [_][]const u8{'
	for t in $TYPES; do echo "    \"$t\","; done
	echo '};'
	echo
	echo 'pub const descriptors = ""'
	for t in $TYPES; do echo "    ++ @embedFile(\"$t/spec\")"; done
	echo ';'
	echo
	echo 'pub const style_words = @embedFile("style-words");'
	echo 'pub const theme_tokens = @embedFile("theme-tokens");'
} >types.zig
zig fmt types.zig >/dev/null 2>&1 || true
