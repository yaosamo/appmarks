# Appmarks

A personal Stage Manager: every window except the ones you're working in is parked as a thumbnail on the side of the screen, and the other windows on stage are pinned as small appmarks to the focused window.

- **Click a parked window** to bring it to the middle of the screen. Windows already on stage stay where they are.
- **Option-click** (or right-click, then *Show Only This Window*) to park everything else.
- **⌃⌥↓**, **⌘M** or the minimize button parks the focused window.
- **Cmd-Tab or a Dock click** onto a parked window brings it onto the stage too.
- **Pause** (menu bar icon) or **Quit** puts every window back where it was.

## Floating appmarks (experiment, the default for now)

With **Park windows on the side** off in Settings, windows stay where they are and every open window is an appmark in one floating panel, in the order they opened, the focused one ringed.

- **Click** an appmark to focus its window; **drag** anywhere else to move the panel.
- It sticks to the middle of each screen edge and to each corner (a column on the sides, a row on the top and bottom), and drags freely anywhere else.
- Dragged near a window's side it clicks onto it, slides along that side and follows the window. With no room outside the window, it tucks inside as a thin line that opens on hover.

## Settings

Menu bar icon → **Settings…** (⌘,):

- **Parked windows**: pick the spot on a screen sketch (left or right, top, center or bottom), size, density, app icons and labels.
- **Appmarks on windows**: pick the spot on a window sketch (any corner or the middle of any side), inside or outside the window.
- **Open at login**: on by default (set on first launch); turning it off here or in System Settings → General → Login Items sticks.
- **Always dark**: otherwise the panels follow the system's light or dark appearance.
- **Fine-tuning** shows every underlying value; Copy/Paste moves them around as JSON.

## Build and run

```bash
./build.sh
open build/Appmarks.app
```

On first launch a welcome window walks through the two permissions: **Accessibility** (to move windows) and **Screen Recording** (for live thumbnails of parked windows). Each row opens the right System Settings pane and ticks itself once granted; macOS asks to reopen Appmarks after Screen Recording. Menu bar icon → **Permissions…** brings the window back. Signing with your Apple Development identity keeps those grants across rebuilds.

## Limits

- Primary display only. Parked windows sit just past the bottom-right corner, because macOS has no public API for hiding a single window.
- Windows move instantly. Apple's 3D shrink animation uses private WindowServer APIs.
- If Appmarks is force-killed (`kill -9`), parked windows stay in the corner until the next launch, which picks them up again.
