#!/bin/sh
# build.sh LAYER: run by h9build in the builder root, to build one layer of
# the app (runtime, deps, or app) from the steps of Railpack's plan that
# steps.txt assigns it, in order, as Railpack's BuildKit backend would.
#
# h9build stacks the layers below LAYER over the builder root, and LAYER's
# directory on top as its up layer, so whatever the steps change anywhere in
# the root lands there, as a layer, and the trees below aren't touched. /tmp
# is a tree in memory, so it doesn't.
#
# The earlier layers' steps aren't run again, but their variables and PATH
# entries carry on, as a BuildKit state's environment does. apt steps aren't
# run either: h9build installs Wolfi packages for them into the roots.
#
# build.sh env runs no step, and writes the run environment to env.
set -eu
W=/mnt/term/cwd
P=$W/plan.json
layer=$1
log() { echo "h9build: $*" >&2; }

# mise, at the version Railpack pins (its builder image's tag), on PATH as
# Railpack's builder image has it, but as a link in /tmp to the tools rather
# than a copy in the layer.
v=$(jq -r '[.steps[].inputs[]?.image // empty | capture("mise-(?<v>[0-9.]+)").v][0] // empty' "$P")
mise=/h9build/tools/mise-$v
[ -n "$v" ] && [ -x "$mise" ] || mise=$(ls /h9build/tools/mise-* 2>/dev/null | tail -1)
[ -n "$mise" ] || { log "no mise in the tools; did plan.sh run?"; exit 1; }
mkdir -p /tmp/bin
ln -sf "$mise" /tmp/bin/mise
export PATH=/tmp/bin:/usr/local/bin:/usr/bin:/bin

# Package managers' caches, kept per app under the cwd. The plan names its
# cache directories (/root/.npm, /root/.cache/uv), but they'd land in the
# layer, and a link from there to the cwd would land in it too. So point
# the managers at the cwd instead.
C=$W/cache
mkdir -p "$C"
caches() {
	export npm_config_cache=$C/npm YARN_CACHE_FOLDER=$C/yarn PNPM_STORE_DIR=$C/pnpm \
		BUN_INSTALL_CACHE_DIR=$C/bun UV_CACHE_DIR=$C/uv PIP_CACHE_DIR=$C/pip \
		POETRY_CACHE_DIR=$C/poetry GOMODCACHE=$C/go/mod GOCACHE=$C/go/build \
		BUNDLE_USER_CACHE=$C/bundle COMPOSER_CACHE_DIR=$C/composer \
		ZIG_GLOBAL_CACHE_DIR=$C/zig HEX_HOME=$C/hex MIX_HOME=$C/mix \
		REBAR_CACHE_DIR=$C/rebar NUGET_PACKAGES=$C/nuget
}

# copy SRC DEST: a copy command. SRC is a pattern in the source, and one that
# matches nothing is skipped (Railpack writes optional ones as "Cargo.lock*").
copy() {
	(
		cd "$H9BUILD_SRC"
		for f in $1; do
			[ -e "$f" ] || continue
			case $2 in
			*'*'*) d=/app/$f ;;
			. | */) d=/app/$2/$(basename "$f") ;;
			/*) d=$2 ;;
			*) d=/app/$2 ;;
			esac
			mkdir -p "$(dirname "$d")"
			cp -a "$f" "$d"
		done
	)
}

# The source, less what the plan excludes, for a step that takes the local
# source: the paths its input includes.
excludes=$(jq -r '.exclude // [] | .[]' "$P")
source_in() {
	inc=$1
	set --
	for e in $excludes; do set -- "$@" --exclude "./$e"; done
	(cd "$H9BUILD_SRC" && tar "$@" -cf - "./$inc") | tar -C /app -xf -
}

# The directories that hold mise's runtimes' executables, for PATH in place of
# its shims: shims would run every command through mise, which the run root
# doesn't have. Each installed version's bin, read from the layer, since
# mise's own bin-paths re-resolves versions under the plan's settings and can
# miss what it just installed; or, for tools from aqua (uv), the .mise-bins
# links mise makes to their binaries; or else the directories that hold
# executables.
runtime_path() {
	[ -d /mise/installs ] || return 0
	bins=
	for v in /mise/installs/*/*; do
		# A relative link is an alias (node/24 -> ./24.22.2); an absolute
		# one is where the version is (dotnet's -> /mise/dotnet-root).
		if [ -L "$v" ]; then
			case $(readlink "$v") in /*) ;; *) continue ;; esac
		fi
		[ -d "$v" ] || continue
		if [ -d "$v/bin" ]; then
			bins=$bins$v/bin:
		elif [ -d "$v/.mise-bins" ]; then
			bins=$bins$v/.mise-bins:
		else
			for d in $(cd "$v" && find . -maxdepth 2 -type f -perm -u+x -exec dirname {} \; | sort -u); do
				case $d in . ) bins=$bins$v: ;; *) bins=$bins$v/${d#./}: ;; esac
			done
		fi
	done
	export PATH="$bins$PATH"
}

# Hex's OTP builds link crypto against Ubuntu's libcrypto, which has SM4
# (EVP_sm4_cbc), and Wolfi's leaves it out, so the crypto NIF doesn't load and
# Mix can't fetch Hex over TLS. When that's so, give it Ubuntu 24.04's
# libcrypto where crypto.so's RUNPATH looks first, /usr/lib/TRIPLET, in the
# runtime layer. Nothing else looks there.
ubuntu_libcrypto() {
	"$1/bin/erl" -noshell -eval 'try crypto:info_lib() of _ -> halt(0) catch _:_ -> halt(1) end' 2>/dev/null && return 0
	case $(uname -m) in
	x86_64) a=amd64 t=x86_64 u=https://archive.ubuntu.com/ubuntu ;;
	aarch64) a=arm64 t=aarch64 u=https://ports.ubuntu.com/ubuntu-ports ;;
	*) return 0 ;;
	esac
	f=$(curl -fsSL "$u/dists/noble-updates/main/binary-$a/Packages.gz" | gzip -dc |
		awk '/^Package: /{p=$2} p=="libssl3t64" && /^Filename: /{print $2}' | head -1)
	[ -n "$f" ] || { log "  no Ubuntu libssl3t64 found; erlang's crypto won't load"; return 0; }
	log "  erlang's crypto with Ubuntu's libcrypto ($(basename "$f"))"
	x=$(mktemp -d)
	(cd "$x" && curl -fsSL "$u/$f" -o p.deb && ar x p.deb && zstd -dc data.tar.zst | tar -xf - "./usr/lib/$t-linux-gnu/libcrypto.so.3") &&
		mkdir -p "/usr/lib/$t-linux-gnu" && cp "$x/usr/lib/$t-linux-gnu/libcrypto.so.3" "/usr/lib/$t-linux-gnu/"
	rm -rf "$x"
}

# Erlang from Hex's prebuilt OTP (builds.hex.pm, for Ubuntu 24.04) rather
# than mise's, which builds it from source with kerl on Linux: minutes
# natively, and longer than h9build waits under h9. It goes where mise would
# install it, so mise install takes it as installed, and then installs
# Elixir or Gleam over it. A version Hex doesn't have is left to mise.
prebuilt_erlang() {
	v=$(cd /app && mise ls --json erlang 2>/dev/null | jq -r '[.[] | select(.installed | not) | .version][0] // empty')
	[ -n "$v" ] || return 0
	case $(uname -m) in x86_64) a=amd64 ;; aarch64) a=arm64 ;; *) return 0 ;; esac
	d=/mise/installs/erlang/$v
	log "  erlang $v from builds.hex.pm"
	mkdir -p "$d"
	if curl -fsSL "https://builds.hex.pm/builds/otp/$a/ubuntu-24.04/OTP-$v.tar.gz" | tar -xzf - -C "$d" --strip-components=1 &&
		(cd "$d" && ./Install -minimal "$d" >/dev/null); then
		ubuntu_libcrypto "$d"
		return 0
	fi
	log "  no prebuilt erlang $v; mise builds it"
	rm -rf "$d"
}

mkdir -p /app
while read -r i l name; do
	case $layer:$l in
	runtime:deps | runtime:app | deps:app) break ;;
	esac
	run=
	[ "$l" = "$layer" ] && run=1
	# The runtime layer is shared between apps without the files its steps
	# copy from the source, so the deps layer makes those copies.
	copies=
	[ "$l:$layer" = runtime:deps ] && copies=1
	step=$(jq -c ".steps[$i]" "$P")
	[ -n "$run" ] && log "step $name"
	vars=$(echo "$step" | jq -r '.variables // {} | to_entries[] | "\(.key)=\(.value)"')
	if [ -n "$vars" ]; then
		while IFS= read -r kv; do export "$kv"; done <<EOF
$vars
EOF
	fi
	# The step's own cache directories (UV_CACHE_DIR=/opt/uv-cache) give
	# way to the cwd's.
	caches
	# mise's downloads go to the cache rather than the layer, and its
	# shims to /tmp: they're links to the mise binary, a path only the
	# builder has, and runtime_path takes their place. Ruby comes
	# precompiled, as mise offers, rather than built from source by
	# ruby-build, which takes many minutes (and, under h9, can hang);
	# H9BUILD_RUBY_COMPILE=1 builds it.
	case $name in
	packages:*)
		export MISE_CACHE_DIR=$C/mise MISE_SHIMS_DIR=/tmp/mise-shims MISE_YES=1
		[ "${H9BUILD_RUBY_COMPILE:-}" = 1 ] || export MISE_RUBY_COMPILE=false
		;;
	esac
	if [ -n "$run$copies" ]; then
		for s in $(echo "$step" | jq -r '.inputs[]? | select(.local == true) | .include[]?'); do
			source_in "$s"
		done
	fi
	cmds=$(echo "$step" | jq -c '.commands // [] | .[]')
	if [ -n "$cmds" ]; then
		while IFS= read -r c; do
			if echo "$c" | jq -e 'has("path")' >/dev/null && ! echo "$c" | jq -e 'has("name")' >/dev/null; then
				d=$(echo "$c" | jq -r .path)
				[ "$d" = /mise/shims ] && continue
				export PATH="$d:$PATH"
				continue
			fi
			if [ -z "$run" ]; then
				if [ -n "$copies" ] && echo "$c" | jq -e 'has("src")' >/dev/null; then
					copy "$(echo "$c" | jq -r .src)" "$(echo "$c" | jq -r .dest)"
				fi
				continue
			fi
			if echo "$c" | jq -e 'has("cmd")' >/dev/null; then
				cmd=$(echo "$c" | jq -r .cmd)
				log "  $(echo "$c" | jq -r '.customName // .cmd')"
				case $cmd in "mise install"*) prebuilt_erlang ;; esac
				(cd /app && sh -c "$cmd") </dev/null
			elif echo "$c" | jq -e 'has("image")' >/dev/null; then
				log "  skipping a copy from $(echo "$c" | jq -r .image): h9build doesn't fetch images"
			elif echo "$c" | jq -e 'has("src")' >/dev/null; then
				copy "$(echo "$c" | jq -r .src)" "$(echo "$c" | jq -r .dest)"
			elif echo "$c" | jq -e 'has("name")' >/dev/null; then
				f=$(echo "$c" | jq -r .path)
				case $f in /*) ;; *) f=/app/$f ;; esac
				mkdir -p "$(dirname "$f")"
				echo "$step" | jq -r --arg a "$(echo "$c" | jq -r .name)" '.assets[$a]' >"$f"
			fi
		done <<EOF
$cmds
EOF
	fi
	case $name in
	packages:mise*) runtime_path ;;
	esac
done <"$W/steps.txt"

[ "$layer" = env ] || exit 0

# The run environment: the deploy variables, the start command, and the PATH
# the steps made, less the builder's own directories.
{
	jq -r '.deploy.variables // {} | to_entries[] | "\(.key)=\(.value)"' "$P"
	# h9 has no inotify, which .NET's FileSystemWatcher needs: ASP.NET's
	# configuration watches its JSON files, so have it poll instead.
	if jq -e '.deploy.variables.DOTNET_ROOT' "$P" >/dev/null; then
		echo DOTNET_USE_POLLING_FILE_WATCHER=1
	fi
	echo "H9BUILD_START=$(jq -r '.deploy.startCommand // "sh"' "$P")"
	keep=
	IFS=:
	for d in $PATH; do
		case $d in /tmp/* | /h9build/* | /usr/local/bin | /usr/bin | /bin) ;; *) keep=$keep$d: ;; esac
	done
	unset IFS
	echo "PATH=${keep}/usr/local/bin:/usr/bin:/bin"
} >"$W/env"
