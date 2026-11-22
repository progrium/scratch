#!/bin/bash
# The spec's reference run, under Xvfb :99 with lavapipe, driven by xdotool.
# Start Xvfb :99 -screen 0 1440x900x24 first. Writes payroll.gif and
# payroll-errors.png / payroll.png to $OUT (default: this directory).
set -e
cd "$(dirname "$0")"
OUT=${OUT:-.}
export DISPLAY=:99 VK_ICD_FILENAMES=/opt/lavapipe/lvp_icd.json
./target/release/payroll > ${TMPDIR:-/tmp}/payroll.log 2>&1 & PID=$!
for i in $(seq 30); do WID=$(xdotool search --onlyvisible --name '^Payroll$' 2>/dev/null | tail -1); [ -n "$WID" ] && break; sleep 1; done
eval $(xdotool getwindowgeometry --shell $WID)
shot() { sleep 1; import -window root -crop ${WIDTH}x${HEIGHT}+${X}+${Y} +repage $OUT/$1.png; }
click() { xdotool mousemove $((X+$1)) $((Y+$2)) click 1; }
typ() { xdotool type --delay 60 "$1"; }
MP4=${TMPDIR:-/tmp}/payroll.mp4
sleep 2
ffmpeg -loglevel error -y -f x11grab -draw_mouse 0 -framerate 10 -video_size ${WIDTH}x${HEIGHT} -i :99+$X,$Y $MP4 & REC=$!
sleep 1
click 711 106; sleep 2
shot payroll-errors
click 108 106; typ "Grace Hopper"; xdotool key Tab; typ "45"; xdotool key Tab; typ "62.50"; xdotool key Return; sleep 2
typ "Alan Turing"; xdotool key Tab; typ "38"; xdotool key Tab; typ "71.25"; xdotool key Return; sleep 2
typ "Ada Lovelace"; xdotool key Tab; typ "52"; xdotool key Tab; typ "88"; xdotool key Return; sleep 3
kill -INT $REC; wait $REC 2>/dev/null || true
shot payroll 0
ffmpeg -loglevel error -y -i $MP4 -vf "fps=10,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse" $OUT/payroll.gif
kill $PID
