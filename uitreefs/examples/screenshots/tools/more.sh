#!/bin/bash
# Usage: more.sh EXAMPLE  (sed-counter ps-stamps cobol-payroll jq-ttt lua-mixer node-jsonview
# python-expenses ruby-regex forth-rpn scheme-deriv, or all)
# The sed, PostScript, COBOL, jq, Lua, Node, Python, Ruby, Forth and Scheme examples, run in uitreefs under Xvfb and
# driven with xdotool, like inter.sh. sed is 9front's, inside h9; the rest
# are Linux programs, run by h9 on the Alpine root
# that linuxroot.sh makes ($H9LINUX).
. $(dirname "$0")/lib.sh
H9LINUX=${H9LINUX:-$UITREEFS_DIR/third_party/hyper9/.local/linux/edge-tools}
[ -d "$H9LINUX/usr/bin" ] || { echo "no Linux root at $H9LINUX: run linuxroot.sh" >&2; exit 1; }
typ() { xdotool type --delay 60 "$1"; }
run() { n=$1; shift; start $n 300 $G "$@"; waitwin 40 || { echo "$n: no window"; return 1; }; sleep 5; }
one() {
case $1 in
sed-counter)
	cd $UITREEFS_DIR/examples/sed
	run counter -t Counter sed -nuf counter.sed /mnt/ui/events
	shot sed-counter 0
	recstart sed-counter
	for i in $(seq 12); do click 345 80; sleep .3; done; sleep 1
	for i in $(seq 15); do click 73 80; sleep .3; done; sleep 1
	click 210 191; sleep 1.5
	recstop sed-counter
	# 2026 presses of =, each one a full sed re-render
	xdotool key --delay 4 --repeat 2026 equal; sleep 8
	shot sed-counter-2026 0;;
ps-stamps)
	cd $UITREEFS_DIR/examples/ps
	run stamps -t Stamps --dir $H9LINUX:'#L' sh -c 'exec gs -q -dNODISPLAY -sui="$ui" --permit-file-all="$ui/*" stamps.ps <$ui/events'
	recstart ps-stamps
	click 150 580; sleep 1.5
	click 440 19; sleep .8; click 330 600; sleep 1.5
	click 102 19; sleep .8; click 466 19; sleep .8; click 430 300; sleep 1.5
	click 196 19; sleep .8; click 690 230; sleep 1.5
	click 277 19; sleep .8; click 590 520; sleep 1.2; click 790 500; sleep 1.2; click 820 330; sleep 1.2
	click 808 19; sleep 1; click 800 360; sleep 2
	recstop ps-stamps
	shot ps-stamps 0;;
cobol-payroll)
	cd $UITREEFS_DIR/examples/cobol
	$G --headless --dir $H9LINUX:'#L' cobc -x payroll.cob || exit 1
	run payroll -t Payroll --dir $H9LINUX:'#L' ./payroll
	recstart cobol-payroll
	click 481 207; sleep 2
	click 481 82; typ "Grace Hopper"; xdotool key Tab; typ "45"; xdotool key Tab; typ "62.50"; xdotool key Return; sleep 2
	typ "Alan Turing"; xdotool key Tab; typ "38"; xdotool key Tab; typ "71.25"; xdotool key Return; sleep 2
	typ "Ada Lovelace"; xdotool key Tab; typ "52"; xdotool key Tab; typ "88"; xdotool key Return; sleep 3
	recstop cobol-payroll
	shot cobol-payroll 0
	rm -f payroll;;
jq-ttt)
	cd $UITREEFS_DIR/examples/jq
	run ttt -t Tic-tac-toe --dir $H9LINUX:'#L' sh -c 'jq -nRj --unbuffered -f ttt.jq <$ui/events >$ui/win/main/ctl'
	recstart jq-ttt
	cell() { click $((70 + ($1 % 3) * 100)) $((118 + ($1 / 3) * 100)); sleep 1.3; }
	for c in 4 2 3 7 8; do cell $c; done; sleep 1.5
	shot jq-ttt-draw 0
	click 170 428; sleep 1.2
	for c in 0 8 2; do cell $c; done; sleep 2
	recstop jq-ttt
	shot jq-ttt 0;;
lua-mixer)
	cd $UITREEFS_DIR/examples/lua
	run mixer -t Mixer --dir $H9LINUX:'#L' lua5.4 mixer.lua
	shot lua-mixer 0
	recstart lua-mixer
	click 420 187; sleep 1; click 150 222; sleep 1; click 244 305; sleep 1.5
	click 360 305; sleep 1.5; click 244 305; sleep 1.5
	click 98 305; typ "#e11d48"; xdotool key Return; sleep 1.5; click 244 305; sleep 1.5
	click 360 305; sleep 1.5; click 244 305; sleep 1.5; click 44 410; sleep 2
	recstop lua-mixer
	shot lua-mixer-palette 0;;
node-jsonview)
	cd $UITREEFS_DIR/examples/node
	run jsonview -t JSON --dir $H9LINUX:'#L' node jsonview.js sample.json
	shot node-jsonview 0
	recstart node-jsonview
	click 126 143; sleep 2; click 111 279; sleep 2
	click 840 29; typ "ui"; sleep 3
	recstop node-jsonview
	shot node-jsonview-filter 0;;
python-expenses)
	cd $UITREEFS_DIR/examples/python
	rm -f expenses.txt
	run expenses -t Expenses --dir $H9LINUX:'#L' python3 expenses.py
	shot python-expenses 0
	recstart python-expenses
	exp() { click 150 105; typ "$1"; xdotool key Tab; typ "$2"; click 150 247; sleep .8; click 60 $3; sleep .5; click 150 295; sleep 2; }
	exp "Coffee beans" 12.50 289; exp "Train pass" 64 320; exp "Lamp" 39.90 351; exp "Concert" 48 382; exp "Groceries" 83.20 289
	sleep 1
	recstop python-expenses
	shot python-expenses-added 0
	rm -f expenses.txt;;
forth-rpn)
	cd $UITREEFS_DIR/examples/forth
	run rpn -t RPN --dir $H9LINUX:'#L' gforth rpn.fs
	shot forth-rpn 0
	recstart forth-rpn
	key() { click $((64 + $1 * 103)) $((395 + $2 * 38)); sleep 1.2; }
	click 200 308; typ "6 7 *"; xdotool key Return; sleep 1.5
	typ ": sq dup * ;"; xdotool key Return; sleep 1.5
	key 0 3; key 1 3; click 115 585; sleep 1.2
	click 33 661; sleep 1.5; key 3 4
	key 0 0; key 3 2; sleep .5
	click 92 351; sleep 2
	click 200 308; typ ": upto 0 do i . loop ;"; xdotool key Return; sleep 1.2
	typ "C upto"; xdotool key Return; sleep 2
	shot forth-rpn-hex 0
	click 41 351; sleep 1.5
	key 1 0; key 1 0; key 1 0; sleep 2
	recstop forth-rpn
	shot forth-rpn-error 0;;
scheme-deriv)
	cd $UITREEFS_DIR/examples/scheme
	run deriv -t Derivatives --dir $H9LINUX:'#L' chibi-scheme deriv.scm; sleep 10
	shot scheme-deriv 0
	recstart scheme-deriv
	hover() { xdotool mousemove $((X+$1)) $((Y+$2)); sleep ${3:-.15}; }
	for x in $(seq 260 20 900); do hover $x 420; done; sleep 1
	click 100 128; sleep 2.5
	for x in $(seq 900 -24 280); do hover $x 420; done; sleep 1
	click 100 264; sleep 2.5
	for x in $(seq 280 24 900); do hover $x 420; done; sleep 1
	click 585 61; xdotool key ctrl+a; typ "(/ (^ x 2) (+ 1 (^ x 2)))"; xdotool key Return; sleep 2.5
	for x in $(seq 260 20 900); do hover $x 420; done; hover 690 420 2
	recstop scheme-deriv
	shot scheme-deriv-tangent 0
	click 585 61; xdotool key ctrl+a; typ "(* x (frob x))"; xdotool key Return; sleep 2
	shot scheme-deriv-error 0;;
ruby-regex)
	cd $UITREEFS_DIR/examples/ruby
	run regex -t Regex --dir $H9LINUX:'#L' ruby regex.rb
	shot ruby-regex 0
	recstart ruby-regex
	click 370 40; xdotool key ctrl+a; typ '\d{4}'; sleep 2
	xdotool key ctrl+a; typ '(\w+)@([\w.-]+)'; sleep 3
	recstop ruby-regex
	shot ruby-regex-groups 0;;
esac
killall_g
grep -v "^exit=143" $CAPTMP/${n:-$1}.log | tail -5
}
if [ "$1" = all ]; then for e in sed-counter ps-stamps cobol-payroll jq-ttt lua-mixer node-jsonview python-expenses ruby-regex forth-rpn scheme-deriv; do one $e; done; else one "$1"; fi
