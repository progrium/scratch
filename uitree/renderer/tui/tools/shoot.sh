#!/bin/bash
# shoot.sh: run an example in a real terminal (xterm on Xvfb, through
# tmux so keys and mouse can be scripted) and record screenshots and a GIF.
#
#	tools/shoot.sh NAME          counter, hello, signin or todo
#
# Needs Xvfb, xterm, tmux and ImageMagick, a built zig-out/bin/uitree-tui,
# and $H9ROOT naming a 9front root (see README.md). Writes
# examples/screenshots/NAME*.png and NAME.gif.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
out=$here/examples/screenshots
mkdir -p "$out"
frames=$(mktemp -d)
n=0
sock=uitree-shoot-$$
disp=:${DISPLAY_NUM:-77}
T() { tmux -L "$sock" "$@"; }

start() { # cols rows title script [flags]
	cols=$1 rows=$2
	T new-session -d -s ui -x "$1" -y "$2" \
		"cd '$here/examples' && TERM=xterm-256color COLORTERM=truecolor LANG=C.UTF-8 '$here/zig-out/bin/uitree-tui' $5 -t '$3' rc $4; sleep 600"
	T set -t ui status off
	Xvfb "$disp" -screen 0 1600x1200x24 >/dev/null 2>&1 &
	xvfb=$!
	sleep 1
	LANG=C.UTF-8 LC_ALL=C.UTF-8 DISPLAY=$disp xterm -u8 -geometry "${1}x${2}+0+0" \
		-fa 'DejaVu Sans Mono' -fs 13 -bg white -fg black -b 0 -bw 0 +sb \
		-xrm 'XTerm*termName: xterm-direct' \
		-e env LANG=C.UTF-8 tmux -L "$sock" -u attach -t ui >/dev/null 2>&1 &
	xterm=$!
	sleep 6
}
stop() {
	T kill-server 2>/dev/null || true
	kill $xterm $xvfb 2>/dev/null || true
}
trap stop EXIT
hex() { printf '%s' "$1" | od -An -tx1 | tr -s ' \n' ' '; }
# Mouse in cell coordinates, 0-based, as SGR reports.
press() { T send-keys -t ui -H $(hex $'\e'"[<0;$(($1+1));$(($2+1))M"); }
release() { T send-keys -t ui -H $(hex $'\e'"[<0;$(($1+1));$(($2+1))m"); }
move() { T send-keys -t ui -H $(hex $'\e'"[<35;$(($1+1));$(($2+1))M"); sleep 0.4; }
click() { move "$1" "$2"; press "$1" "$2"; sleep 0.15; release "$1" "$2"; sleep 1; }
keys() { T send-keys -t ui "$@"; sleep 0.6; }
type() { T send-keys -t ui -l "$1"; sleep 0.8; }
frame() { # [png name]: a GIF frame, and a named PNG if given
	sleep 0.6
	DISPLAY=$disp import -window root "$frames/raw.png"
	convert "$frames/raw.png" \
		-bordercolor black -border 1 -trim +repage "$frames/f$(printf %03d $n).png"
	[ -n "$1" ] && cp "$frames/f$(printf %03d $n).png" "$out/$1.png"
	n=$((n + 1))
}
gif() {
	convert -delay 90 -loop 0 "$frames"/f*.png -layers Optimize "$out/$1.gif"
}

case $1 in
counter)
	start 48 12 Counter counter.rc
	frame counter
	click 33 6; frame; click 33 6; frame; click 33 6; frame
	click 14 6; frame
	keys =; frame; keys =; frame counter-after
	gif counter
	;;
hello)
	start 56 10 Greeter hello.rc
	frame hello
	type Jeff; frame
	keys Enter; frame hello-greeted
	gif hello
	;;
signin)
	start 50 22 'Sign in' signin.rc
	frame signin
	type bob; frame
	keys Enter; frame signin-errors
	keys BSpace BSpace BSpace; type bob@example.com; frame
	keys Tab; type hunter2; frame
	keys Enter; sleep 2; frame signin-welcome
	gif signin
	;;
todo)
	rm -f "$here/examples/todo.txt"
	start 56 24 Todos todo.rc
	frame todo
	type 'Buy milk'; keys Enter; frame
	type 'Write the W7 PR'; keys Enter; frame
	type 'Walk the dog'; keys Enter; frame
	click 5 6; frame
	move 30 7; frame todo-items
	click 25 22; frame todo-active
	click 33 22; frame
	click 46 22; frame
	click 18 22; frame todo-cleared
	gif todo
	rm -f "$here/examples/todo.txt"
	;;
*)
	echo "usage: $0 counter|hello|signin|todo" >&2
	exit 2
	;;
esac
echo "$out/$1.gif"
