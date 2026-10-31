# Bubbleg

Every open window as a small bubble in one floating panel, in the order they opened, the focused one ringed. Windows stay where they are.

- **Click** a bubble to focus its window; **drag** anywhere else to move the panel.
- It sticks, with a click, to the middle of each screen edge (above the Dock at the bottom) and to each corner, and drags freely anywhere else. Near the left or right display edge it turns into a column, near the top or bottom into a row.
- Dragged near a side of the active window it clicks onto it and slides along that side; from then on it sits on that side of whichever window is active, one picked in Mission Control included, and hides while no window is or while Mission Control is open. With no room outside the window, it tucks inside as a thin line that opens on hover.
- **Pause** (menu bar icon) hides the bubbles until **Resume**.
- **Hide Desktop Files** (menu bar icon) hides the files and folders on the desktop; Finder restarts to apply it. Not in the App Store build, whose sandbox can't change Finder.

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

On first launch a welcome window walks through the two permissions: **Accessibility** (to see and focus windows) and **Screen Recording** (for live thumbnails). Each row opens the right System Settings pane and ticks itself once granted; macOS asks to reopen Bubbleg after Screen Recording. It floats above other windows, System Settings included, so the steps stay in sight. Menu bar icon → **Permissions…** brings the window back. Signing with your Apple Development identity keeps those grants across rebuilds. macOS ties each grant to the signature, though, so a development build and the notarized Developer ID copy count as different apps sharing one switch: switching between them, reset with `tccutil reset All com.yaric.bubbleg` and grant again.

## Distribute

`Bubbleg.xcodeproj` builds the same sources for release. It is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen); run `xcodegen` after adding or removing source files.

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Info.plist`.
2. Open `Bubbleg.xcodeproj` → **Product → Archive**.
3. In the Organizer: **Distribute App → Direct Distribution**. Xcode signs it with your cloud-managed Developer ID certificate, notarizes it and exports a stapled `Bubbleg.app`.
   From Terminal instead, the same steps:
   ```bash
   xcodebuild -project Bubbleg.xcodeproj -scheme Bubbleg -configuration Release -destination 'generic/platform=macOS' \
     -archivePath build/Bubbleg.xcarchive archive -allowProvisioningUpdates
   # export.plist: method developer-id, destination upload, signingStyle automatic, teamID 6J57A4298A
   xcodebuild -exportArchive -archivePath build/Bubbleg.xcarchive -exportOptionsPlist export.plist \
     -exportPath build/upload -allowProvisioningUpdates
   # Once Apple has notarized it (a few minutes; this fails until then):
   xcodebuild -exportNotarizedApp -archivePath build/Bubbleg.xcarchive -exportPath build/notarized
   ```
4. Wrap it in the drag-to-Applications disk image: `dmg/make.sh path/to/Bubbleg.app` (needs [dmgbuild](https://github.com/dmgbuild/dmgbuild): `pipx install dmgbuild`). It writes `site/Bubbleg.dmg`: the app on the left, an Applications shortcut on the right, a pink arrow and a short hint between them. Push, and the site's **Download** button (and `/download`) serve it.

This Developer ID build isn't sandboxed, so it keeps Hide Desktop Files and the exact private window lookup. The hardened runtime is on, as notarization requires.

### Mac App Store

The `Bubbleg App Store` scheme builds a sandboxed copy of the same sources for the Mac App Store: `AppStore/archive.sh` archives it and exports (or, with `--upload`, uploads) the package. What differs, the listing copy, App Review notes, privacy answers and screenshots are in [AppStore/README.md](AppStore/README.md).

## Limits

- Primary display only.
