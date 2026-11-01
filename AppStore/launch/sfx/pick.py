"""Scores the MOSS takes (lower is better) and writes the picks as 48 kHz stereo WAVs, trimmed and normalised."""
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

raw, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)


def env(w, sr, ms=5):
    n = max(1, int(sr * ms / 1000))
    return np.sqrt(np.convolve(w ** 2, np.ones(n) / n, mode="same"))


def flatness(w):
    spec = np.abs(np.fft.rfft(w * np.hanning(len(w)))) + 1e-9
    return float(np.exp(np.mean(np.log(spec))) / np.mean(spec))


def score(path, kind):
    w, sr = sf.read(path, dtype="float32")
    w = w.reshape(-1)
    e = env(w, sr)
    if e.max() < 1e-3:
        return 99, None
    peak = int(np.argmax(e))
    attack = peak / sr                       # seconds to the loudest point
    tail = float(np.mean(e[-int(0.08 * sr):]) / e.max())  # energy left at the end
    flat = flatness(w)
    if kind == "pop":
        # Fast attack, quick decay, more tonal than noise.
        s = attack * 8 + tail * 4 + flat * 2
    else:
        # A whoosh peaks mid-way, is noisy, fades out, and has no clicks (sudden jumps).
        jumps = float(np.max(np.abs(np.diff(e))) / e.max())
        s = abs(attack - 0.3) * 2 + tail * 3 + (1 - flat) * 1.5 + jumps * 4
    return s, (attack, tail, flat)


for kind in ("pop", "whoosh"):
    takes = sorted(raw.glob(f"{kind}_*.wav"))
    ranked = sorted((score(p, kind)[0], p.name, score(p, kind)[1]) for p in takes)
    for s, name, m in ranked[:4]:
        print(f"{kind}: {name} score {s:.2f}  attack {m[0]:.3f}s tail {m[1]:.2f} flat {m[2]:.2f}")
    picks = [r[1] for r in ranked[: (3 if kind == 'pop' else 1)]]
    for i, name in enumerate(picks):
        dst = out / f"{kind}{i}.wav"
        # Trim leading silence, short fade-out, peak-normalise, 48 kHz stereo.
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(raw / name), "-af",
                        "silenceremove=start_periods=1:start_threshold=-45dB,afade=t=out:st=0.22:d=0.1,"
                        "loudnorm=I=-16:TP=-1.5,aformat=sample_rates=48000:channel_layouts=stereo"
                        if kind == "pop" else
                        "silenceremove=start_periods=1:start_threshold=-50dB,afade=t=out:st=0.55:d=0.2,"
                        "loudnorm=I=-18:TP=-1.5,aformat=sample_rates=48000:channel_layouts=stereo",
                        str(dst)], check=True)
        print(f"  → {dst.name} from {name}")
