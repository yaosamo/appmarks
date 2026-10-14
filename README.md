# Appmarks

A personal Stage Manager: every window except the ones you're working in is parked as a thumbnail on the side of the screen, and the other windows on stage are pinned as small appmarks to the focused window.

- **Click a parked window** to bring it to the middle of the screen. Windows already on stage stay where they are.
- **Option-click** (or right-click, then *Show Only This Window*) to park everything else.
- **⌃⌥↓**, **⌘M** or the minimize button parks the focused window.
- **Cmd-Tab or a Dock click** onto a parked window brings it onto the stage too.
- **Pause** (menu bar icon) or **Quit** puts every window back where it was.

## Settings

Menu bar icon → **Settings…** (⌘,):

- **Parked windows**: pick the spot on a screen sketch (left or right, top, center or bottom), size, density, app icons and labels.
- **Appmarks on windows**: pick the spot on a window sketch (any corner or the middle of any side), inside or outside the window.
- **Always dark**: otherwise the panels follow the system's light or dark appearance.
- **Fine-tuning** shows every underlying value; Copy/Paste moves them around as JSON.

## Build and run

```bash
./build.sh
open build/Appmarks.app
```

On first launch, grant **Accessibility** (required, to move windows) and **Screen Recording** (optional, for live thumbnails; without it the strip shows app icons) in System Settings → Privacy & Security, then relaunch. Signing with your Apple Development identity keeps those grants across rebuilds.

## Limits

- Primary display only. Parked windows sit just past the bottom-right corner, because macOS has no public API for hiding a single window.
- Windows move instantly. Apple's 3D shrink animation uses private WindowServer APIs.
- If Appmarks is force-killed (`kill -9`), parked windows stay in the corner until the next launch, which picks them up again.
