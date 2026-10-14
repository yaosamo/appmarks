# SideStage

A personal Stage Manager: every window except the one you're working in moves to a thumbnail strip on the left edge.

- **Click a thumbnail** to bring that window to the middle of the screen. Windows already on stage stay where they are.
- **Option-click** (or right-click, then *Show Only This Window*) to send everything else back to the strip.
- **⌃⌥↓** sends the focused window back to the strip.
- **Cmd-Tab or a Dock click** onto an off-stage window brings it onto the stage too.
- **Pause** (menu bar icon) or **Quit** puts every window back where it was.

## Build and run

```bash
./build.sh
open build/SideStage.app
```

On first launch, grant **Accessibility** (required, to move windows) and **Screen Recording** (optional, for live thumbnails; without it the strip shows app icons) in System Settings → Privacy & Security, then relaunch. Signing with your Apple Development identity keeps those grants across rebuilds.

## Limits

- Primary display only. Off-stage windows are parked at its bottom-right corner, because macOS has no public API for hiding a single window.
- Windows move instantly. Apple's 3D shrink animation uses private WindowServer APIs.
- If SideStage is force-killed (`kill -9`), parked windows stay in the corner until the next launch, which picks them up again.
