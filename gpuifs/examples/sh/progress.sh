#!/usr/bin/env bash
# progress.sh: a progress window for any long command, driven from the
# host with plan9port's 9p(1) over gpuifs -a. No h9 machine is involved:
# this is the "outside client" mode of DESIGN.md § Running a client in h9.
#
#	./progress.sh 'Building release' make -j8 release
#	./progress.sh -n 120 'Converting photos' ./convert.sh *.heic   # -n: expected lines, for a real bar
#
# The window shows the latest output line, a bar (indeterminate unless -n
# says how many lines to expect), elapsed time, and a Details section with
# the full log. Cancel kills the command. The script exits with its status.
#
# Shows: a host-side client in bash, gpuifs -a unix!path, 9p write/read,
# progress, collapsible, a readonly editor as a log, notify on finish,
# button labels and variants changed as state moves on.   Needs: M3
set -u

expect=0
if [[ ${1:-} == -n ]]; then expect=$2; shift 2; fi
[[ $# -ge 2 ]] || { echo "usage: progress.sh [-n lines] title command [arg...]" >&2; exit 2; }
title=$1; shift

sock=${TMPDIR:-/tmp}/gpuifs-progress.$$
addr="unix!$sock"
log=$(mktemp)
trap 'rm -f "$log" "$sock"' EXIT

gpuifs -t "$title" -a "$addr" &
host=$!
for _ in $(seq 50); do 9p -a "$addr" ls / >/dev/null 2>&1 && break; sleep 0.1; done

put() { printf '%s' "$2" | 9p -a "$addr" write "$1"; }        # one value or one command
q() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }             # Plan 9 quoting

put ctl "window main title=$(q "$title") size=520,200 min=420,180 pos=center"
w=windows/main
r=$w/root
put $r/tree "div root  style='v_flex size_full p=20 gap=10 bg=background'
  div head  style='h_flex items_center gap=8'
    spinner spin  style=sm
    text title  style='font_semibold flex_1'  text=$(q "$title")
    text time  style='text_sm text_color=muted_foreground font_family=monospace'  text=0:00
  progress bar
  text line  style='text_xs text_color=muted_foreground truncate font_family=monospace'  text=Starting…
  collapsible more
    button trigger  label=Details  icon=chevron-right  style='ghost xs'
    div content  style=h=200
      editor log  readonly=on  soft_wrap=on  style=size_full
  div foot  style='h_flex justify_end'
    button cancel  label=Cancel  style=outline  tag=cancel
"
put keymap "escape cancel"

# Run the command, its output into the log; a reader updates the window.
start=$SECONDS
"$@" >"$log" 2>&1 &
job=$!

# Events from the host: Cancel, Close, and the window's close button.
9p -a "$addr" read events | while read -r name rest; do
	case "$name $rest" in
	*tag=cancel*|*id=cancel*|close*)
		if kill -0 "$job" 2>/dev/null; then kill "$job"; else put ctl quit; fi ;;
	quit*) put ctl quit ;;
	esac
done &

lines=0
while kill -0 "$job" 2>/dev/null; do
	sleep 0.25
	n=$(wc -l <"$log")
	if (( n != lines )); then
		lines=$n
		put $r/line/text "$(tail -n 1 "$log" | cut -c1-200)"
		(( expect > 0 )) && put $r/bar/value $(( n * 100 / expect > 99 ? 99 : n * 100 / expect ))
	fi
	t=$(( SECONDS - start )); put $r/head/time/text "$(printf '%d:%02d' $((t / 60)) $((t % 60)))"
done
wait "$job"; status=$?

# Done: full bar, the whole log, and the button becomes Close.
put $w/ctl begin
put $r/bar/value 100
put $r/head/ctl "delete spin"
put $r/more/content/log/value "$(cat "$log")"
put $r/foot/cancel/label Close
put $r/foot/cancel/style primary
if (( status == 0 )); then
	put $r/line/text "Finished in $(( SECONDS - start ))s"
	put $w/ctl "notify $(q "$title: done") type=success"
else
	put $r/line/text "Failed with status $status"
	put $r/more/open on
	put $w/ctl "notify $(q "$title failed") type=error sticky=on"
fi
put $w/ctl commit

wait "$host"
exit "$status"
