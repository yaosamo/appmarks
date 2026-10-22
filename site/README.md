# Appmarks site

The one-page website, served by Vercel with this folder as the project root.

- **Demo video:** `demo-av1.mp4` (AV1, picked by browsers that can decode it) and `demo.mp4` (H.264 fallback), both 1920×1080 with AAC audio, plus `demo-poster.jpg` shown while it loads. It autoplays muted; a click turns sound and the native controls on. To replace it from a new recording:

  ```bash
  # 1. Let macOS (AVFoundation, same as QuickTime) read the recording. ffmpeg misreads the start
  #    trim that screen recorders write and puts the video ~0.7 s off the audio.
  avconvert --source Demo.mov --preset Preset1920x1080 --output qt.mov --replace

  # 2. Compress. Video and audio in one pass; the audio gets a fixed +14 dB with a limiter on
  #    peaks (adaptive loudnorm blows up the hiss in quiet stretches).
  AUDIO='-af highpass=f=80,volume=14dB,alimiter=limit=0.84:level=false -ar 48000 -c:a aac -b:a 96k'
  ffmpeg -i qt.mov -map 0:v -map 0:a -fps_mode passthrough \
    -c:v libsvtav1 -preset 5 -crf 42 -g 300 -pix_fmt yuv420p10le $AUDIO -movflags +faststart site/demo-av1.mp4
  ffmpeg -i qt.mov -map 0:v -map 0:a -fps_mode passthrough \
    -c:v libx264 -preset slow -crf 24 -profile:v high -pix_fmt yuv420p $AUDIO -movflags +faststart site/demo.mp4
  ffmpeg -ss 1 -i qt.mov -frames:v 1 -q:v 4 site/demo-poster.jpg
  ```

  The +14 dB suits a quiet recording (about -31 LUFS); check a new one with `ffmpeg -i qt.mov -af loudnorm=print_format=summary -f null -` and aim for roughly -16 LUFS.

  The current demo joins three recordings, each converted with `avconvert` first and given its own gain (+16, +18 and +20 dB) to even out their levels, with the Finder sidebar's "Credentiable" row blurred wherever it shows.

- **Icon:** `icon.png` (256px, transparent; page icon and favicon) and `apple-touch-icon.png` (180px, opaque, since iOS fills transparency with black), cut from the same artwork as the app's `Resources/AppIcon.icns`.
