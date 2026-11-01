#!/usr/bin/env bash
# Take 2: snap, quick switches, fast window swings. Records a 1920×1080 pt region (3840×2160 px) at 30 fps.
set -u
S=/Users/yaroslavsamoylov/.claude/jobs/73cd74ec/tmp/v2
D=/Users/yaroslavsamoylov/.claude/jobs/73cd74ec/tmp/shoot/director
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
mark() { echo "$(perl -MTime::HiRes=time -e "printf '%.3f', time - $TF") $1" >> $S/marks.txt; }
# Centre of bubble i: on the left screen edge (edge) or on a window's left side (window).
bubble() {
  read -r px py _ < <($D panel | head -1)
  local x
  [[ $2 == edge ]] && x=54 || x=$((px + 125))
  echo "$x $(perl -e "printf '%d', $py + 89 + 64.5 * $1")"
}
switch_to() { # glide in from the right so the target is the first bubble entered, then click
  read -r x y < <(bubble "$1" window)
  $D move $((x + 220)) "$y" 0.18
  $D move "$x" "$y" 0.22
  sleep 0.12; mark "click-$1"; $D click; sleep 0.5
}

rm -f $S/take2.mov $S/marks.txt
$D move 1700 1300 0.2
TF=$(now)
ffmpeg -v error -y -f avfoundation -capture_cursor 1 -framerate 30 -i "3:none" \
  -vf "crop=3840:2160:0:360" -c:v h264_videotoolbox -b:v 60M -pix_fmt yuv420p $S/take2.mov </dev/null &
FF=$!
sleep 2.2
mark start
sleep 0.8

# A. Snap onto the Dots window's left side.
read -r x y < <(bubble 0 edge)
mark drag-start
$D drag "$x" "$y" 345 690 0.8
mark snapped
$D move 760 820 0.3; sleep 0.35

# B. Quick switches: Nothing, Applications, Yaosamo.
switch_to 2
switch_to 3
switch_to 1

# C. Fast swings of the Yaosamo window by its title bar; the bubbles follow.
$D move 1300 456 0.3
mark swing
$D path 1300 456  1480 330 0.45  1170 560 0.5  1380 410 0.4  1300 456 0.35
mark swing-end
$D move 1650 1180 0.4
sleep 1.2
mark end
kill -INT $FF; wait $FF 2>/dev/null
cat $S/marks.txt
