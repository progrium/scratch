#!/bin/sh
# plan.sh: run by h9build in the builder root. Railpack reads the source at
# $H9BUILD_SRC (/h9build/src/NAME) and writes its build plan to plan.json in
# the cwd, and this script reads the plan into plain text that h9build's host
# side, which has no jq, acts on:
#
#   steps.txt        INDEX LAYER NAME: the layer each step builds in
#   keys.txt         LAYER KEY: a hash of each layer's steps and the files they read
#   shared.txt       KEY COPIES: the key the runtime layer is shared under across apps,
#                    and whether its steps copy files from the source (copies or none)
#   deploy.txt       LAYER PATH [EXCLUDE...]: what the run takes from each layer
#   apt-build.txt    Debian packages the plan installs to build
#   apt-runtime.txt  Debian packages the plan installs to run
#
# The layers, in order: runtime (the packages:* steps: mise's runtimes),
# deps (install*), and app (the rest, the build). A step never builds in a
# layer below an earlier step's, so a plan that goes back to an install step
# after its build builds it in the app layer.
#
# Railpack resolves versions with the mise it pins, which it keeps in
# /tmp/railpack/mise and downloads if it isn't there. h9build keeps that
# binary in its tools between runs, so put it back first, and save it after.
set -eu
W=/mnt/term/cwd
P=$W/plan.json
mkdir -p /tmp/railpack/mise "$W/cache/mise-bin"
for m in /h9build/tools/mise-*; do [ -e "$m" ] && cp "$m" /tmp/railpack/mise/; done
"$H9BUILD_RAILPACK" plan --out "$P" "$H9BUILD_SRC"
for m in /tmp/railpack/mise/mise-*; do
	[ -e "/h9build/tools/$(basename "$m")" ] || cp "$m" "$W/cache/mise-bin/"
done
# A provider that fails (a version it can't resolve, say) still writes a plan,
# with no steps: show Railpack's own account of why.
if ! jq -e '(.steps // []) | length > 0' "$P" >/dev/null; then
	echo "h9build: Railpack made no build steps:" >&2
	"$H9BUILD_RAILPACK" info --format json "$H9BUILD_SRC" | jq -r '.logs[]? | "  \(.Level): \(.Msg)"' >&2
	exit 1
fi
jq -r '"h9build: plan: \([.steps[].name] | join(", ")); start: \(.deploy.startCommand // "none")"' "$P" >&2

jq -r '
	def rank: if startswith("packages:") then 0 elif startswith("install") then 1 else 2 end;
	reduce (.steps | to_entries[] | select(.value.name | startswith("packages:apt:") | not)) as $s
		({max: 0, out: []};
		 ([.max, ($s.value.name | rank)] | max) as $r
		 | .max = $r
		 | .out += ["\($s.key) \(["runtime", "deps", "app"][$r]) \($s.value.name)"])
	| .out[]' "$P" >"$W/steps.txt"

# The Debian packages an apt step installs, from its command.
apt() {
	jq -r --arg p "$1" '[.steps[] | select(.name | startswith($p)) | .commands[]?.cmd // empty
		| capture("install -y (?<p>[^\u0027;&]*)").p | split(" ")[] | select(. != "")] | unique | .[]' "$P"
}
apt packages:apt:build >"$W/apt-build.txt"
apt packages:apt:runtime >"$W/apt-runtime.txt"

# What the run takes from each layer: each deploy input's paths, made
# absolute (they're relative to /app), with its excludes.
jq -r --rawfile steps "$W/steps.txt" '
	($steps | split("\n") | map(select(. != "") | split(" ") | {(.[2]): .[1]}) | add) as $layer
	| def abs: if . == "." or . == "./" or . == "/app" then "/app"
		elif startswith("/") then rtrimstr("/.") | rtrimstr("/")
		else "/app/" + (rtrimstr("/.") | rtrimstr("/")) end;
	.deploy.inputs[]? | select(.step and $layer[.step]) | . as $i
	# A packages step that builds above the runtime layer (Gleam'"'"'s
	# packages:mise:runtime, after its build) installs into it, or finds
	# what it wants installed there already: deploy from both.
	| ([$layer[$i.step]] + (if ($i.step | startswith("packages:")) and $layer[$i.step] != "runtime" then ["runtime"] else [] end))[] as $l
	| $i.include[]? | "\($l) \(abs) \([$i.exclude[]? | abs] | join(" "))"' "$P" >"$W/deploy.txt"

# Each layer's key: its steps as the plan has them, and the contents of the
# source files they copy in (and for the app layer, the deploy). h9build chains them, so a layer's key changes
# with the ones below it.
hashfiles() {
	(
		cd "$H9BUILD_SRC"
		# shellcheck disable=SC2086
		for f in $1; do [ -e "$f" ] && find "$f" -type f -exec sha256sum {} +; done
	) | awk -v ex="$excl" '
		BEGIN { n = split(ex, e) }
		{
			p = $2
			sub(/^\.\//, "", p)
			for (i = 1; i <= n; i++) if (p == e[i] || index(p, e[i] "/") == 1) next
			print
		}' | sort -k2
}
excl=$(jq -r '.exclude // [] | .[]' "$P")
for l in runtime deps app; do
	{
		for i in $(awk -v l="$l" '$2 == l { print $1 }' "$W/steps.txt"); do
			step=$(jq -c ".steps[$i]" "$P")
			echo "$step"
			for s in $(echo "$step" | jq -r '(.commands[]? | .src // empty), (.inputs[]? | select(.local == true) | .include[]?)'); do
				hashfiles "$s"
			done
		done
		# The app layer is pruned to what the plan deploys.
		[ "$l" = app ] && jq -c .deploy "$P"
	} | sha256sum | cut -c1-16 | sed "s/^/$l /"
done >"$W/keys.txt"

# The runtime layer is shared by every app whose runtime steps are the same:
# the same tools at the same versions (the mise config the plan writes, with
# Railpack's resolved versions), and the same settings and commands. The
# files those steps copy from the source count too, as a mise.toml can name
# more tools, except idiomatic version files (.nvmrc, .python-version, a
# Gemfile): the plan has already resolved the versions they name, and the
# rest of a Gemfile doesn't change what mise installs. h9build leaves the
# copies themselves out of the shared layer, and makes them in the deps layer.
idiomatic=" .nvmrc .node-version .python-version .python-versions .ruby-version Gemfile .go-version .java-version .sdkmanrc .bun-version package.json "
copies=none
key=$({
	for i in $(awk '$2 == "runtime" { print $1 }' "$W/steps.txt"); do
		step=$(jq -c ".steps[$i]" "$P")
		echo "$step"
		for s in $(echo "$step" | jq -r '(.commands[]? | .src // empty), (.inputs[]? | select(.local == true) | .include[]?)'); do
			case $idiomatic in *" $(basename "$s") "*) continue ;; esac
			hashfiles "$s"
		done
	done
} | sha256sum | cut -c1-16)
for i in $(awk '$2 == "runtime" { print $1 }' "$W/steps.txt"); do
	if jq -e ".steps[$i] | any(.commands[]?; has(\"src\")) or any(.inputs[]?; .local == true)" "$P" >/dev/null; then
		copies=copies
	fi
done
echo "$key $copies" >"$W/shared.txt"
