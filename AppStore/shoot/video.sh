#!/usr/bin/env bash
# Scripted take for the App Preview. Records the 5K screen (avfoundation device 3), crops a 1440×810 pt
# close-up at 30 fps into build/shoot/take.mov. Set up the stage first (see AppStore/README.md → Reshooting);
# the panel starts docked on the left screen edge with five windows: Artwork, Applications, Nothing, Dots, Yaosamo.
set -u
cd "$(dirname "$0")/../.."
S=build/shoot
D=$S/director
mkdir -p $S
[[ -x $D ]] || swiftc -O AppStore/shoot/director.swift -o $D
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
mark() { echo "$(perl -MTime::HiRes=time -e "printf '%.2f', time - $T0") $1" >> $S/marks.txt; }
# Bubble i (0-based) centre: snapped to a window's left side vs docked on the left screen edge.
bubble() { # $1 index, $2 mode (edge|window)
  read -r px py _ < <($D panel | head -1)
  local x
  [[ $2 == edge ]] && x=56 || x=$((px + 125))
  local y; y=$(perl -e "printf '%d', $py + 89 + 64.5 * $1")
  echo "$x $y"
}
approach() { # glide in horizontally from the right so the target is the first bubble entered
  read -r x y < <(bubble "$1" "$2")
  $D move $((x + 260)) "$y" 0.5
  $D move "$x" "$y" 0.6
}

rm -f $S/take.mov $S/marks.txt
$D move 1300 1000 0.2
TF=$(now)
ffmpeg -v error -y -f avfoundation -capture_cursor 1 -framerate 30 -i "3:none" \
  -vf "crop=2880:1620:0:560,scale=1920:1080:flags=lanczos" -c:v h264_videotoolbox -b:v 24M -pix_fmt yuv420p \
  $S/take.mov </dev/null &
FF=$!
sleep 2.5
T0=$(now); mark start; echo "ffmpeg-launched-before-start $(perl -e "printf '%.2f', $T0 - $TF")" >> $S/marks.txt

sleep 1.0
approach 1 edge; sleep 0.9; mark click-apps; $D click; sleep 1.4      # Finder: Applications
$D move 300 1000 0.5; sleep 0.3
approach 3 edge; sleep 0.7; mark click-dots; $D click; sleep 1.3      # Safari: Dots
read -r x y < <(bubble 3 edge)
mark drag-start; $D drag "$x" "$y" 225 640 1.6; mark snapped; sleep 1.2   # onto Dots' left side
$D move 1300 1000 0.5; sleep 0.3
mark window-drag; $D drag 1120 346 1240 300 1.2; sleep 1.0             # bubbles follow the window
approach 4 window; sleep 0.8; mark click-yaosamo; $D click; sleep 2.2  # Safari: Yaosamo
$D move 1300 1050 0.6; sleep 1.5
mark end

kill -INT $FF; wait $FF 2>/dev/null
cat $S/marks.txt
