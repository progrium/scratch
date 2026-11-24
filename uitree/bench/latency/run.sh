#!/bin/sh
# run.sh [N]: the counter-click latency table in README.md, on this machine.
#
# Builds what it needs, then clicks the counter's + N times (default 200)
# in each setup and prints each one's numbers. Needs zig 0.16, cargo, go
# and python3; for the rc and h9 rows, $H9ROOT or a built-in root with rc.
# Pass ONLY='1 3' to run some rows.
set -e
N=${1:-200}
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d)
trap 'pkill -f "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT
want() { [ -z "$ONLY" ] || echo " $ONLY " | grep -q " $1 "; }

echo "== build" >&2
(cd "$top/core" && zig build -Dh9=true -Doptimize=ReleaseFast && zig build remote -Dh9=true -Doptimize=ReleaseFast) >&2
(cd "$here/counter-go" && go build -o "$tmp/counter-host" . && GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0 go build -o "$tmp/counter-go" .) >&2
if want 1 || want 2 || want 3 || want 4; then
	# The core built above (ReleaseFast), not uitcore-sys's own ReleaseSafe
	# build: h9 in ReleaseSafe starts guest processes several times slower,
	# which made rc look slower behind GPUI than behind uitree-remote.
	(cd "$top/renderer/gpui" && export UITCORE_LIB_DIR="$top/core/zig-out/lib" && cargo build --release -p uitree && cargo build --release -p host --example native_counter) >&2
fi
gpui=$top/renderer/gpui/target/release/uitree
native=$top/renderer/gpui/target/release/examples/native_counter
remote=$top/core/zig-out/bin/uitree-remote
toy=$top/renderer/toy-py/render.py
cp "$top/renderer/gpui/examples/counter.rc" "$top/renderer/gpui/examples/lib.rc" "$tmp/"
cd "$tmp"

if want 1; then echo "== 1. native GPUI"; "$native" "$N"; fi
if want 2; then echo "== 2. built-in renderer, Go app on the host (9P over a unix socket)"
	UITREE_CLICK_BENCH=$N UITREE_HOST_APP="$tmp/counter-host" "$gpui"; fi
if want 3; then echo "== 3. built-in renderer, Go app in h9 (GOOS=plan9 GOARCH=amd64)"
	UITREE_CLICK_BENCH=$N "$gpui" ./counter-go; fi
if want 4; then echo "== 4. built-in renderer, counter.rc in h9"
	UITREE_CLICK_BENCH=$N "$gpui" rc counter.rc; fi
# 4m: row 4 without counter.rc's keys and menu writes, which only the
# built-in renderer acts on (a platform menu bar). Not in the default run:
# ONLY=4m, to tell whether those are what stalls row 4 on macOS.
if [ -n "$ONLY" ] && want 4m; then echo "== 4m. row 4, counter.rc without keys and menu"
	sed '/^echo .=  *inc/,/menu\/Counter$/d' counter.rc >counter-nomenu.rc
	UITREE_CLICK_BENCH=$N "$gpui" rc counter-nomenu.rc; fi

# 4a and 7a: rows 4 and 7 with a counter.rc that runs no awk (the label
# toggles a/b instead of counting), to split rc's process starts from its
# 9P traffic. Only when named: ONLY='4a 7a'.
sed 's/n=`{add \$n 1}/if(~ $n a) n=b; if not n=a/' counter.rc >counter-noawk.rc
if [ -n "$ONLY" ] && want 4a; then echo "== 4a. row 4, counter.rc without awk"
	UITREE_CLICK_BENCH=$N "$gpui" rc counter-noawk.rc; fi

# The 9P renderer rows: uitree-remote serves the renderer tree, the Python
# toy renderer clicks and times click -> new text applied (no frame).
pids=
nine() {
	"$remote" -R "unix!$tmp/r.sock" "$@" 2>"$tmp/remote.log" &
	pids="$pids $!"
	while [ ! -S "$tmp/r.sock" ]; do sleep 0.1; done
}
stop() { kill $pids 2>/dev/null || true; wait 2>/dev/null || true; pids=; rm -f "$tmp/r.sock" "$tmp/a.sock"; }
if want 5; then echo "== 5. 9P renderer (Python), Go app on the host"
	nine -a "unix!$tmp/a.sock"
	while [ ! -S "$tmp/a.sock" ]; do sleep 0.1; done
	UI_DIAL="unix!$tmp/a.sock" "$tmp/counter-host" &
	pids="$pids $!"
	python3 -u "$toy" "unix!$tmp/r.sock" --bench "$N"; stop; fi
if want 6; then echo "== 6. 9P renderer (Python), Go app in h9"
	nine ./counter-go; python3 -u "$toy" "unix!$tmp/r.sock" --bench "$N"; stop; fi
if want 7; then echo "== 7. 9P renderer (Python), counter.rc in h9"
	nine rc counter.rc; python3 -u "$toy" "unix!$tmp/r.sock" --bench "$N"; stop; fi
if [ -n "$ONLY" ] && want 7a; then echo "== 7a. row 7, counter.rc without awk"
	nine rc counter-noawk.rc; python3 -u "$toy" "unix!$tmp/r.sock" --bench "$N"; stop; fi
