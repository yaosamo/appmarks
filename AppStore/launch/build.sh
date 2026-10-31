#!/usr/bin/env bash
# Assembles the launch video from the raw take and the layers drawn by cards.swift.
#
#   AppStore/launch/build.sh <take.mov> <layers-dir> <out.mp4> <store|launch> [music.mp3]
#
# store  → ends on "Bubbleg · For Mac" (App Store previews may not mention price)
# launch → ends on "Free for Mac · bubbleg.yaosamo.com"
#
# Timeline (s): title 0–2.4 · hover 2.4–5.0 · click 5.0–9.4 · snap 9.4–12.3 · follow 12.3–17.8 · end 17.8–20.8
set -euo pipefail
TAKE=$1 L=$2 OUT=$3 CUT=$4 MUSIC=${5:-}
CLICK="$(dirname "$0")/../../Resources/click.wav"
DUR=20.8
END="$L/end-$CUT.png"

# Ease-out cubic rise of 12 px over 250 ms, starting at $1 seconds.
rise() { echo "12*pow(1-min(max((t-$1)/0.25\,0)\,1)\,3)"; }

AUDIO_IN=() AUDIO_FILTER="[13:a]aformat=sample_rates=48000:channel_layouts=stereo,adelay=11000|11000,volume=0.9,apad,atrim=0:$DUR[aout]"
if [[ -n $MUSIC ]]; then
  AUDIO_IN=(-i "$MUSIC")
  AUDIO_FILTER="[13:a]aformat=sample_rates=48000:channel_layouts=stereo,adelay=11000|11000,volume=0.9,apad,atrim=0:$DUR[click];
  [14:a]aformat=sample_rates=48000:channel_layouts=stereo,atrim=0:$DUR,afade=t=in:d=0.3,afade=t=out:st=$(echo "$DUR-1.2" | bc):d=1.2,volume=0.55[music];
  [music][click]amix=inputs=2:duration=first:normalize=0[aout]"
fi

ffmpeg -v error -y \
  -loop 1 -framerate 30 -t $DUR -i "$L/ground.png" \
  -loop 1 -framerate 30 -t $DUR -i "$L/canvas.png" \
  -loop 1 -framerate 30 -t $DUR -i "$L/icon.png" \
  -loop 1 -framerate 30 -t $DUR -i "$L/title.png" \
  -loop 1 -framerate 30 -t $DUR -i "$END" \
  -loop 1 -framerate 30 -t $DUR -i "$L/mask.png" \
  -loop 1 -framerate 30 -t $DUR -i "$L/cap-1.png" \
  -loop 1 -framerate 30 -t $DUR -i "$L/cap-2.png" \
  -loop 1 -framerate 30 -t $DUR -i "$L/cap-3.png" \
  -loop 1 -framerate 30 -t $DUR -i "$L/cap-4.png" \
  -i "$TAKE" -i "$TAKE" -i "$TAKE" \
  -i "$CLICK" "${AUDIO_IN[@]}" \
  -filter_complex "
  [10:v]split=2[t1][t4];
  [t1]trim=2.6:5.2,setpts=PTS-STARTPTS,scale=3840:2160:flags=lanczos,zoompan=z='1.333+0.267*(1-pow(1-min(on/78,1),3))':x='0':y='ih*0.49-ih/zoom/2':d=1:s=1640x922:fps=30,setsar=1[b1];
  [11:v]trim=5.2:10.7,setpts=(PTS-STARTPTS)/1.25,crop=1600:900:0:90,scale=1640:922:flags=lanczos,setsar=1[b2];
  [12:v]trim=11.3:14.2,setpts=PTS-STARTPTS,crop=1440:810:0:135,scale=1640:922:flags=lanczos,setsar=1[b3];
  [t4]trim=16.5:23.4,setpts=(PTS-STARTPTS)/1.25,scale=1640:922:flags=lanczos,setsar=1[b4];
  [b1][b2][b3][b4]concat=n=4:v=1,fps=30,format=rgba[foot];
  [5:v]format=gray[m];
  [foot][m]alphamerge,setpts=PTS+2.4/TB,fade=t=in:st=2.4:d=0.3:alpha=1,fade=t=out:st=17.5:d=0.3:alpha=1[card];
  [1:v]format=rgba,fade=t=in:st=2.2:d=0.3:alpha=1,fade=t=out:st=17.5:d=0.3:alpha=1[canvas];
  [2:v]format=rgba,fade=t=in:st=0.15:d=0.25:alpha=1,fade=t=out:st=2.1:d=0.15:alpha=1[icon1];
  [3:v]format=rgba,fade=t=in:st=0.35:d=0.25:alpha=1,fade=t=out:st=2.1:d=0.15:alpha=1[title];
  [2:v]format=rgba,fade=t=in:st=17.9:d=0.25:alpha=1[icon2];
  [4:v]format=rgba,fade=t=in:st=18.1:d=0.25:alpha=1[end];
  [6:v]format=rgba,fade=t=in:st=2.6:d=0.25:alpha=1,fade=t=out:st=4.85:d=0.15:alpha=1[c1];
  [7:v]format=rgba,fade=t=in:st=5.05:d=0.25:alpha=1,fade=t=out:st=9.25:d=0.15:alpha=1[c2];
  [8:v]format=rgba,fade=t=in:st=9.45:d=0.25:alpha=1,fade=t=out:st=12.15:d=0.15:alpha=1[c3];
  [9:v]format=rgba,fade=t=in:st=12.35:d=0.25:alpha=1,fade=t=out:st=17.45:d=0.15:alpha=1[c4];
  [0:v][canvas]overlay=0:0[v0];
  [v0][card]overlay=140:230:eof_action=pass[v1];
  [v1][icon1]overlay=0:'$(rise 0.15)'[v2];
  [v2][title]overlay=0:'$(rise 0.35)'[v3];
  [v3][icon2]overlay=0:'$(rise 17.9)'[v4];
  [v4][end]overlay=0:'$(rise 18.1)'[v5];
  [v5][c1]overlay=0:'$(rise 2.6)'[v6];
  [v6][c2]overlay=0:'$(rise 5.05)'[v7];
  [v7][c3]overlay=0:'$(rise 9.45)'[v8];
  [v8][c4]overlay=0:'$(rise 12.35)',fade=t=out:st=20.4:d=0.4,format=yuv420p[vout];
  $AUDIO_FILTER" \
  -map "[vout]" -map "[aout]" -t $DUR \
  -c:v libx264 -preset slow -crf 16 -profile:v high -level 4.2 -r 30 \
  -c:a aac -b:a 256k -ar 48000 -movflags +faststart "$OUT"
echo "wrote $OUT"
