"""Assembles the dynamic cut: rendered intro (intro.swift) → the 4K take under one smooth virtual camera → end card.

    python3 AppStore/launch/build_dynamic.py <take.mov> <intro-frames-dir> <layers-dir> <end.png> <out.mp4> [music]

The camera is keyframed on output time and eased between keys, so cutting idle time out of the take never
changes the framing. <layers-dir> is cards.swift's output (ground.png, icon.png); <end.png> is the end card's text.
"""
import subprocess
import sys

take, intro, layers, end_text, out = sys.argv[1:6]
music = sys.argv[6] if len(sys.argv) > 6 else None
CLICK = __file__.rsplit("/AppStore/", 1)[0] + "/Resources/click.wav"

FPS = 30
INTRO = 2.8
# Take segments: (source start, source end, speed). The idle stretch after the snap (4.6–9.9 s) is cut.
SEGMENTS = [(2.2, 4.6, 1.0), (9.9, 15.9, 1.6), (15.9, 19.4, 1.0)]
REAL = sum((b - a) / s for a, b, s in SEGMENTS)
SNAP = INTRO + (4.2 - 2.2)          # the panel clicks onto the window
END_FADE = INTRO + REAL - 0.25      # crossfade into the end card
TOTAL = END_FADE + 3.1

# Camera keys on output time: (t, x, y, width) in the take's 3840×2160 pixels; height = width × 9/16.
# One fixed framing for the whole take (the intro's pull back lands on it): moving the camera mid-take read as
# the whole picture shifting. It holds everything: the docked panel, the switches and the window swings.
KEYS = [
    (INTRO, 0, 200, 3200),
    (TOTAL, 0, 200, 3200),
]


def eased(i):
    """ffmpeg expression for one key-to-key segment, eased in and out (cubic)."""
    t0, *a = KEYS[i]
    t1, *b = KEYS[i + 1]
    p = f"((T-{t0})/{t1 - t0})"
    e = f"if(lt({p},0.5),4*pow({p},3),1-pow(-2*{p}+2,3)/2)"
    return [f"({a[k]}+({b[k] - a[k]})*{e})" for k in range(3)]


def piecewise(k):
    expr = str(KEYS[-1][1 + k])
    for i in reversed(range(len(KEYS) - 1)):
        expr = f"if(lt(T,{KEYS[i + 1][0]}),{eased(i)[k]},{expr})"
    return expr.replace("T", f"(on/{FPS}+{INTRO})")


X, Y, W = piecewise(0), piecewise(1), piecewise(2)
zoom = f"3840/({W})"

segs = []
for i, (a, b, s) in enumerate(SEGMENTS):
    segs.append(f"[t{i}]trim={a}:{b},setpts=(PTS-STARTPTS)/{s}[s{i}]")
split = f"[1:v]fps={FPS},split={len(SEGMENTS)}" + "".join(f"[t{i}]" for i in range(len(SEGMENTS)))

graph = ";\n".join([
    f"[0:v]fps={FPS},format=yuv420p,setsar=1[intro]",
    split,
    *segs,
    "".join(f"[s{i}]" for i in range(len(SEGMENTS))) + f"concat=n={len(SEGMENTS)}:v=1,"
    f"zoompan=z='{zoom}':x='{X}':y='{Y}':d=1:s=1920x1080:fps={FPS},format=yuv420p,setsar=1[real]",
    "[intro][real]concat=n=2:v=1,fps=30,settb=1/30[body]",
    # End card: ground, icon and text rising 12 px as they fade in over the last frames of the take.
    f"[2:v]format=yuv420p,setsar=1[ground]",
    f"[3:v]format=rgba,fade=t=in:st=0.2:d=0.3:alpha=1[icon]",
    f"[4:v]format=rgba,fade=t=in:st=0.4:d=0.3:alpha=1[text]",
    "[ground][icon]overlay=0:'12*pow(1-min(max((t-0.2)/0.3,0),1),3)'[g1]",
    "[g1][text]overlay=0:'12*pow(1-min(max((t-0.4)/0.3,0),1),3)',format=yuv420p,fps=30,settb=1/30[card]",
    f"[body][card]xfade=transition=fade:duration=0.5:offset={END_FADE:.3f},fade=t=out:st={TOTAL - 0.4:.3f}:d=0.4,format=yuv420p[vout]",
    f"[5:a]aformat=sample_rates=48000:channel_layouts=stereo,adelay={int(SNAP * 1000)}|{int(SNAP * 1000)},apad,atrim=0:{TOTAL:.3f}[click]",
    (f"[6:a]aformat=sample_rates=48000:channel_layouts=stereo,atrim=0:{TOTAL:.3f},afade=t=out:st={TOTAL - 1.0:.3f}:d=1.0,"
     f"volume=0.8[music];[music][click]amix=inputs=2:duration=first:normalize=0[aout]") if music else "[click]anull[aout]",
])

card_len = TOTAL - END_FADE + 0.1
cmd = ["ffmpeg", "-v", "error", "-y",
       "-framerate", str(FPS), "-i", f"{intro}/f%03d.png",
       "-i", take,
       "-loop", "1", "-framerate", str(FPS), "-t", f"{card_len:.3f}", "-i", f"{layers}/ground.png",
       "-loop", "1", "-framerate", str(FPS), "-t", f"{card_len:.3f}", "-i", f"{layers}/icon.png",
       "-loop", "1", "-framerate", str(FPS), "-t", f"{card_len:.3f}", "-i", end_text,
       "-i", CLICK]
if music:
    cmd += ["-i", music]
cmd += ["-filter_complex", graph, "-map", "[vout]", "-map", "[aout]", "-t", f"{TOTAL:.3f}",
        "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-profile:v", "high", "-level", "4.2", "-r", str(FPS),
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-movflags", "+faststart", out]
subprocess.run(cmd, check=True)
print(f"wrote {out}: {TOTAL:.2f} s, snap at {SNAP:.2f} s")
