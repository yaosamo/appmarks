# Bubbleg

Every open window as a small bubble in one floating panel, in the order they opened, the focused one ringed. Windows stay where they are.

- **Click** a bubble to focus its window; **drag** anywhere else to move the panel.
- It sticks, with a click, to the middle of each screen edge (above the Dock at the bottom) and to each corner, and drags freely anywhere else. Near the left or right display edge it turns into a column, near the top or bottom into a row.
- Dragged near a side of the active window it clicks onto it and slides along that side; from then on it sits on that side of whichever window is active, one picked in Mission Control included, and hides while no window is or while Mission Control is open. With no room outside the window, it tucks inside as a thin line that opens on hover.
- **Pause** (menu bar icon) hides the bubbles until **Resume**.
- **Hide Desktop Files** (menu bar icon) hides the files and folders on the desktop; Finder restarts to apply it.

## Settings

Menu bar icon → **Settings…** (⌘,):

- **Show bubbles**: turns the panel off without quitting.
- **Open at login**: on by default (set on first launch); turning it off here or in System Settings → General → Login Items sticks.
- **Always dark**: otherwise the bubbles follow the system's light or dark appearance.
- **Fine-tuning**: preview height, spacing, corner radius, hover size, gap from the window, background, app icon, and thumbnail resolution and refresh rate. Copy/Paste moves them around as JSON.

## Build and run

```bash
./build.sh
open build/Bubbleg.app
```

On first launch a welcome window walks through the two permissions: **Accessibility** (to see and focus windows) and **Screen Recording** (for live thumbnails). Each row opens the right System Settings pane and ticks itself once granted; macOS asks to reopen Bubbleg after Screen Recording. Menu bar icon → **Permissions…** brings the window back. Signing with your Apple Development identity keeps those grants across rebuilds.

## Distribute

`Bubbleg.xcodeproj` builds the same sources for release. It is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); run `xcodegen` after adding or removing source files.

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Info.plist`.
2. Open `Bubbleg.xcodeproj` → **Product → Archive**.
3. In the Organizer: **Distribute App → Direct Distribution**. Xcode signs it with your cloud-managed Developer ID certificate, notarizes it and exports a stapled `Bubbleg.app`.
4. Wrap it in the drag-to-Applications disk image: `dmg/make.sh path/to/Bubbleg.app` (needs [dmgbuild](https://github.com/dmgbuild/dmgbuild): `pipx install dmgbuild`). It writes `site/Bubbleg.dmg`: the app on the left, an Applications shortcut on the right, a pink arrow and a short hint between them. Push, and the site's **Download** button (and `/download`) serve it.

The app isn't sandboxed, since reading and focusing other apps' windows through Accessibility isn't allowed in the sandbox, so it ships with Developer ID rather than through the App Store. The hardened runtime is on, as notarization requires.

## Limits

- Primary display only.
