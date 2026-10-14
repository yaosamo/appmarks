# Appmarks site

The one-page website, served by Vercel with this folder as the project root.

- **Demo video:** `demo-av1.mp4` (AV1, picked by browsers that can decode it) and `demo.mp4` (H.264 fallback), both 1920×1080 with the recording's own frame timing and AAC audio, plus `demo-poster.jpg` shown while it loads. It autoplays muted; a click turns sound and the native controls on. To replace it from a new recording:

  ```bash
  # Video and audio in one pass keeps them in sync. The audio gets a fixed +14 dB with a
  # limiter on peaks; adaptive loudness (loudnorm) blows up the hiss in quiet stretches.
  AUDIO='-af highpass=f=80,volume=14dB,alimiter=limit=0.84:level=false -ar 48000 -c:a aac -b:a 96k'
  ffmpeg -i Demo.mov -map 0:v -map 0:a -fps_mode passthrough -vf "scale=1920:-2:flags=lanczos" \
    -c:v libsvtav1 -preset 5 -crf 42 -g 300 -pix_fmt yuv420p10le $AUDIO -movflags +faststart site/demo-av1.mp4
  ffmpeg -i Demo.mov -map 0:v -map 0:a -fps_mode passthrough -vf "scale=1920:-2:flags=lanczos" \
    -c:v libx264 -preset slow -crf 24 -profile:v high -pix_fmt yuv420p $AUDIO -movflags +faststart site/demo.mp4
  ffmpeg -ss 1 -i Demo.mov -frames:v 1 -vf "scale=1920:-2:flags=lanczos" -q:v 4 site/demo-poster.jpg
  ```

  The +14 dB suits a quiet recording (about -31 LUFS); check a new one with `ffmpeg -i Demo.mov -af loudnorm=print_format=summary -f null -` and aim for roughly -16 LUFS.

- **Icon:** `site/icon.svg` is a placeholder; replace it with the real app icon.
