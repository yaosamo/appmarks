# Appmarks site

The one-page website, served by Vercel with this folder as the project root.

- **Demo video:** `demo-av1.mp4` (AV1, picked by browsers that can decode it) and `demo.mp4` (H.264 fallback), both 1920×1080, 60 fps, no audio, plus `demo-poster.jpg` shown while it loads. To replace it from a new recording:

  ```bash
  ffmpeg -i Demo.mov -an -vf "scale=1920:-2:flags=lanczos" -c:v libsvtav1 -preset 5 -crf 42 -g 300 -pix_fmt yuv420p10le -movflags +faststart site/demo-av1.mp4
  ffmpeg -i Demo.mov -an -vf "scale=1920:-2:flags=lanczos" -c:v libx264 -preset slow -crf 24 -profile:v high -pix_fmt yuv420p -movflags +faststart site/demo.mp4
  ffmpeg -ss 1 -i Demo.mov -frames:v 1 -vf "scale=1920:-2:flags=lanczos" -q:v 4 site/demo-poster.jpg
  ```

- **Icon:** `site/icon.svg` is a placeholder; replace it with the real app icon.
