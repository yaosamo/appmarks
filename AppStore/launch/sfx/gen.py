"""MOSS-SoundEffect takes for the dynamic cut's intro: a whoosh for the panel flying in, pops for the bubbles."""
import sys
from pathlib import Path

import mlx.core as mx
import mlx_speech
import numpy as np
import soundfile as sf

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
SPEC = {
    "whoosh": [("a quick soft airy whoosh, something small flying past fast, short, clean, no reverb", 0.7, 6)],
    "pop": [("a single soft bubble pop, short, round, bright, close-up, dry, no reverb", 0.4, 10),
            ("a tiny playful plop of a bubble landing, short, dry", 0.4, 6)],
}
model = mlx_speech.tts.load("moss-sound-effect")
for name, jobs in SPEC.items():
    for pi, (prompt, dur, takes) in enumerate(jobs):
        for k in range(takes):
            f = out / f"{name}_p{pi}_t{k}.wav"
            if f.exists():
                continue
            mx.random.seed(1000 * pi + k + 11)
            r = model.generate(prompt, duration_seconds=dur, max_new_tokens=int(dur * 12.5 * 1.6) + 12)
            w = np.asarray(r.waveform, dtype=np.float32).reshape(-1)
            sf.write(f, w, r.sample_rate, subtype="FLOAT")
            print(f"{f.name}: {len(w) / r.sample_rate:.2f}s", flush=True)
