# Bubbleg on the Mac App Store

Everything for the App Store release: the sandboxed build, the listing copy, App Review notes, privacy answers and screenshots. The Developer ID build (the website's DMG) is unchanged and still ships as before.

## How the App Store build differs

The `Bubbleg App Store` scheme (target `BubblegAppStore` in `project.yml`) builds the same sources with `APP_STORE` defined and the App Sandbox on (`AppStore/Bubbleg.entitlements`):

| | Developer ID (site) | App Store |
|---|---|---|
| Sandbox | off | **on** (the App Store requires it) |
| Window ID lookup | `_AXUIElementGetWindow` (private) | public: the window server's list matched by owner, frame, then title (App Review rejects private API, guideline 2.5.1) |
| Hide Desktop Files | yes | **removed**: the sandbox can't write Finder's preferences or restart Finder |
| Open at login | on by default after first launch | **off until the user ticks it** in the welcome window or Settings (guideline 2.4.5(iii)) |

Accessibility and Screen Recording both work in the sandbox once the user allows them in System Settings, as Magnet, Moom and BetterSnapTool do on the Mac App Store. Each build has its own signature, so macOS asks for the permissions again for the App Store copy.

## Build and upload

```bash
AppStore/archive.sh            # → build/appstore/Bubbleg.pkg, signed for the Mac App Store
AppStore/archive.sh --upload   # archives and uploads to App Store Connect in one go
```

Signing is automatic (team 6J57A4298A). Xcode creates the Apple Distribution and Mac Installer Distribution certificates and the Mac App Store profile in the cloud. Every upload needs a `CFBundleVersion` in `Info.plist` higher than the last one uploaded.

## One-time setup in App Store Connect

1. [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Apps → + → New App**: platform **macOS**, name **Bubbleg** (if it's taken, use the fallback below), primary language English (U.S.), bundle ID **com.yaric.bubbleg**, SKU `bubbleg`.
2. **Pricing and Availability**: Free, all countries.
3. **App Privacy**: privacy policy URL, then **Data Not Collected** (see below).
4. **App Information**: category **Productivity**, secondary **Utilities**; content rights: no third-party content; age rating questionnaire: all "None" → 4+.
5. Upload a build (`AppStore/archive.sh --upload`), wait for processing (~15 min), pick it on the version page, fill in the listing below, add screenshots, then **Add for Review → Submit**.

## Listing

**Name** (30 max): `Bubbleg`. Fallback if taken: `Bubbleg: Window Switcher`

**Subtitle** (30 max): `Every window, one click away`

**Promotional text** (170 max; can be changed any time without review):
> Every open window as a small live preview in one floating panel. Click to switch, drag it anywhere, or snap it onto the window you're in. Free, with no in-app purchases.

**Description** (4000 max):
> Bubbleg puts every open window one click away. Each window becomes a small live preview in a floating panel, in the order you opened them, with the one you're in ringed. Your windows stay exactly where they are.
>
> CLICK TO SWITCH
> Click a bubble and its window comes to the front, even if it's minimized or in another app.
>
> PUT IT ANYWHERE
> Drag the panel by its background. It clicks into the middle of each screen edge and into each corner, and turns into a column at the sides and a row at the top or bottom.
>
> SNAP IT TO YOUR WINDOW
> Drop it next to the window you're working in and it attaches to that side. From then on it follows whichever window is active, slides along with it as you move it, and tucks inside as a thin line when there's no room outside.
>
> MAKE IT YOURS
> Preview size, spacing, corner radius, hover size, background, app icons, thumbnail sharpness and refresh rate, all adjustable. Light, dark, or follows the system. Pause it from the menu bar whenever you like.
>
> PRIVATE BY DESIGN
> Bubbleg needs Accessibility to see and switch windows, and Screen Recording to draw the previews. Previews are made on your Mac, kept in memory only, and never leave it. Bubbleg collects no data and never connects to the internet.
>
> Free, with no in-app purchases. Requires macOS 14 Sonoma or later. Works on the main display.

**Keywords** (100 max, comma-separated, no spaces after commas):
`window,switcher,switch,windows,preview,dock,alt tab,stage,multitask,productivity,menu bar,focus`

**Support URL**: `https://bubbleg.yaosamo.com/support`
**Marketing URL**: `https://bubbleg.yaosamo.com`
**Privacy Policy URL**: `https://bubbleg.yaosamo.com/privacy`
**Copyright**: `2026 Yaroslav Samoylov`
**Version**: `0.1.2` (matches `Info.plist`; bump both to `1.0` for a cleaner first App Store version if you like)

## App Privacy answers

- Do you or your third-party partners collect data from this app? **No** → *Data Not Collected*.
- Tracking: **No**.
- Export compliance: answered in the build (`ITSAppUsesNonExemptEncryption = NO`), so no questions on upload.

## Notes for App Review

Paste into **App Review Information → Notes**. No sign-in is needed, so leave the demo account empty.

> Bubbleg is a window switcher. It shows every open window as a small live preview in a floating panel, and clicking a preview brings that window to the front.
>
> Why it asks for two permissions:
> • Accessibility: to list the open windows of other apps, read their titles and positions, and raise or unminimize the window the user clicks. This is the app's core function, the same use as other window managers on the Mac App Store.
> • Screen Recording: to draw the preview thumbnail of each window with ScreenCaptureKit. Thumbnails are held in memory only, never written to disk or sent anywhere. The app makes no network connections.
>
> How to test:
> 1. Launch Bubbleg. A welcome window explains both permissions; click "Open Settings" on each row and turn Bubbleg on. macOS asks to reopen the app after Screen Recording.
> 2. Open two or three windows (Finder, Safari, TextEdit). A panel of bubbles appears; each bubble is one window.
> 3. Click a bubble to bring that window forward. Drag the panel by its background to move it; drop it next to the active window to attach it there.
> 4. The menu bar icon has Pause/Resume, Settings… (appearance, Open at login, fine-tuning) and Permissions….
>
> The app is a menu bar app (LSUIElement), so it has no Dock icon. "Open at login" is off until the user turns it on.

## Screenshots and App Preview (ready in `media/`)

Upload in this order, from `AppStore/media/`:

| # | Screenshot | Shows |
|---|---|---|
| 1 | `screenshots/1-every-window.jpg`: **Every window, one click away** | hovering a bubble grows it into a live preview (Finder → Applications) |
| 2 | `screenshots/2-snaps-onto-window.jpg`: **Snaps onto the window you're in** | five bubbles attached to the active Safari window, the active one ringed |
| 3 | `screenshots/3-click-to-switch.jpg`: **Click to switch. It follows along.** | after a click, Nothing is in front and the panel moved with it |
| 4 | `screenshots/4-screen-edge.jpg`: **Or park it on any screen edge** | the panel docked as a column on the left edge |
| 5 | `screenshots/5-make-it-yours.jpg`: **Make it yours** | Settings with Fine-tuning open |

All are 2880×1800 with captions on a dark canvas. `screenshots/plain/` has the same five without captions (2880×1800 and 2560×1600, both accepted) if you'd rather show the bare screen.

**Videos** (20.8 s, 1920×1080, 30 fps, H.264 + stereo AAC 256 kbps; Apple's Mac App Preview spec is 15–30 s at 1920×1080):

- `media/app-preview.mp4`: the App Store cut. It ends on "Bubbleg · For Mac", with no price, since App Store previews may not mention one. Upload it above the screenshots on the version page and set the poster frame to about 0:06.
- `media/launch-video.mp4`: the same film for the site and social, ending on "Free for Mac · bubbleg.yaosamo.com".

Both open on the icon and "Every window on your Mac, one click away", then show four beats of real footage, each with a caption on top: *All your windows, as bubbles* (slow push-in as a bubble grows) · *Click one to jump right to it* · *Drop it on your window. It snaps on.* (with Bubbleg's own click) · *And follows you wherever you go*. The only sound is that click; pass a music file as the fifth argument to `build.sh` to add a bed.

Rebuild from the raw take with `AppStore/launch/`: `swift AppStore/launch/cards.swift <layers-dir> <icon-1024.png>` draws the title, end card, captions and canvas, then `AppStore/launch/build.sh <take.mov> <layers-dir> <out.mp4> store|launch [music]` assembles the film. Captions and cut points live in those two files.

Everything was shot in dark mode on a 5K display at 2× zoom, with only Safari (dots.yaosamo.com, nothing.yaosamo.com, yaosamo.com) and Finder (Applications and a folder of the Bubbleg artwork) open, and Preview height 56, Hover size 150, Resolution 720px, Refresh 1 s.

### Reshooting

`frame.swift` captions any capture: `swift AppStore/screenshots/frame.swift raw.png "Caption" out.png dark` (2880×1800 out; any 16:10 or 16:9 in).

`AppStore/shoot/` holds the tooling that made these: `director.swift` (hide apps, place windows, find the panel, glide, click and drag the pointer) and `video.sh` (the scripted, recorded take). Stage first: hide every app but Finder and Safari (System Events `set visible … to false`), open the five windows, set the fine-tuning values above, put the panel on the left screen edge, then `bash AppStore/shoot/video.sh` and leave the mouse alone for 30 s. Stills are `screencapture -x [-C] -R x,y,1280,800` (points → 2560×1600) or `-R x,y,1440,900` (→ 2880×1800) around the panel.
