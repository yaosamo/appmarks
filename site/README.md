# Appmarks site

The one-page website, served by Vercel with this folder as the project root.

- **Demo video:** `demo-av1.mp4` (AV1, picked by browsers that can decode it) and `demo.mp4` (H.264 fallback), both 1920×1080, 60 fps, with loudness-normalized AAC audio, plus `demo-poster.jpg` shown while it loads. It autoplays muted; a click turns sound and the native controls on. To replace it from a new recording:

  ```bash
  ffmpeg -i Demo.mov -an -vf "scale=1920:-2:flags=lanczos" -c:v libsvtav1 -preset 5 -crf 42 -g 300 -pix_fmt yuv420p10le av1.mp4
  ffmpeg -i Demo.mov -an -vf "scale=1920:-2:flags=lanczos" -c:v libx264 -preset slow -crf 24 -profile:v high -pix_fmt yuv420p h264.mp4
  # add the audio, normalized to -16 LUFS
  for v in av1:demo-av1 h264:demo; do
    ffmpeg -i "${v%%:*}.mp4" -i Demo.mov -map 0:v -map 1:a -c:v copy -af "loudnorm=I=-16:TP=-1.5:LRA=11" -ar 48000 -c:a aac -b:a 96k -shortest -movflags +faststart "site/${v##*:}.mp4"
  done
  ffmpeg -ss 1 -i Demo.mov -frames:v 1 -vf "scale=1920:-2:flags=lanczos" -q:v 4 site/demo-poster.jpg
  ```

- **Icon:** `site/icon.svg` is a placeholder; replace it with the real app icon.
