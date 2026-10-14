import AppKit
import ApplicationServices
import Combine

final class ManagedWindow {
    let id: CGWindowID
    let pid: pid_t
    var element: AXUIElement
    var title: String
    var size: CGSize
    var savedOrigin: CGPoint?
    var thumbnail: NSImage?
    /// False while the window lives on another Space: AX only lists the current Space's windows.
    var present = true

    init(id: CGWindowID, pid: pid_t, element: AXUIElement, title: String, size: CGSize) {
        self.id = id
        self.pid = pid
        self.element = element
        self.title = title
        self.size = size
    }
}

@MainActor
final class StageManager {
    let strip = StripModel()
    private(set) var isActive = false

    private var windows: [CGWindowID: ManagedWindow] = [:]
    private var stage: Set<CGWindowID> = []
    private var parked: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var watchedWindows: Set<CGWindowID> = []
    private var ignoreFocusUntil = Date.distantPast
    private var timers: [Timer] = []
    private var capturing = false
    private var appleStageManagerWasOn = false
    private var unminimizing: Set<CGWindowID> = []
    private var minimizeItems: [pid_t: AXUIElement] = [:]
    private var thumbnailTimer: Timer?
    private var thumbnailTick = 0
    private var appInfoCache: [pid_t: (name: String, icon: NSImage?)] = [:]
    private(set) var isInMissionControl = false
    private var exposed: [CGWindowID] = []
    private var subscriptions: Set<AnyCancellable> = []
    private let switcherModel = SwitcherModel()
    private var recentFocus: [CGWindowID] = []
    private lazy var switcher = SwitcherPanel(model: switcherModel) { [weak self] id in
        self?.focusStageWindow(id)
    }
    private lazy var panel = StripPanel(model: strip, onSelect: { [weak self] id, replace in
        self?.select(id, replacingStage: replace)
    }, onDrag: { [weak self] id, ended in
        self?.dragThumbnail(id, ended: ended)
    })
    private let proxy = DragProxy()
    private var proxyImages: [CGWindowID: NSImage] = [:]
    /// The window being carried to the strip: where it was grabbed (as a fraction of its size), its frame
    /// when taken over, and where it sat before the drag began.
    private var carried: (id: CGWindowID, grab: CGPoint, size: CGSize, origin: CGPoint)?

    init() {
        // A hung app must not stall every click passing through the event tap.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateSwitcher()
                self?.scheduleFocusCheck()
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
        let style = Settings.shared.$style.receive(on: RunLoop.main)
        style.map(\.stripWidth).removeDuplicates().dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.panel.reposition() } }
            .store(in: &subscriptions)
        style.map(\.refreshInterval).removeDuplicates().dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { if self?.isActive == true { self?.scheduleThumbnails() } } }
            .store(in: &subscriptions)
        style.dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateSwitcher() } }
            .store(in: &subscriptions)
        style.map(\.captureWidth).removeDuplicates().dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshThumbnails() } }
            .store(in: &subscriptions)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.reposition() }
        }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        appleStageManagerWasOn = AppleStageManager.isEnabled
        if appleStageManagerWasOn { AppleStageManager.setEnabled(false) }
        reconcile()
        let keep = frontmostFocusedWindowID()
        for id in Array(stage) where id != keep { park(id) }
        if let keep, let window = windows[keep], let frame = window.element.frame, frame.minX < Geometry.stageArea.minX {
            place(window, in: Geometry.centered(frame.size))
        }
        panel.orderFrontRegardless()
        publish()
        Log.write("start: stage=\(stage.count) parked=\(parked.count) strip=\(strip.items.count) panel=\(panel.frame) visible=\(panel.isVisible) screenCapture=\(CGPreflightScreenCaptureAccess())")
        timers = [
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            },
        ]
        scheduleThumbnails()
    }

    /// Puts every off-stage window back where it was. Runs on pause and on quit, so nothing stays stranded off-screen.
    func stop() {
        isActive = false
        timers.forEach { $0.invalidate() }
        timers = []
        thumbnailTimer?.invalidate()
        thumbnailTimer = nil
        for id in parked {
            guard let window = windows[id] else { continue }
            if let origin = window.savedOrigin {
                place(window, in: CGRect(origin: origin, size: window.size))
            } else {
                place(window, in: Geometry.centered(window.size))
            }
            stage.insert(id)
        }
        parked = []
        panel.orderOut(nil)
        switcher.orderOut(nil)
        publish()
        if appleStageManagerWasOn { AppleStageManager.setEnabled(true) }
    }

    /// Called from the event tap on every left click, before the target app sees it. Returns true when the
    /// click landed on a stage window's minimize button and that window has been parked instead.
    func parkIfMinimizeButton(at point: CGPoint) -> Bool {
        guard isActive else { return false }
        // Runs on every click system-wide, so the cheap window-server frames gate the Accessibility hit test.
        let titleBars = WindowServer.frames(of: Array(stage)).map { CGRect(x: $0.minX, y: $0.minY, width: 100, height: 56) }
        guard titleBars.contains(where: { $0.contains(point) }) else { return false }

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, hit.subrole == kAXMinimizeButtonSubrole, hit.isEnabled,
              let id = hit.window?.windowID, stage.contains(id), let pid = windows[id]?.pid
        else { return false }
        ignoreFocus(for: 1)
        park(id)
        focusNextStageWindow(of: pid)
        publish()
        return true
    }

    /// Called from the event tap on ⌘M. Returns true when the focused stage window has been parked
    /// instead of minimized, which only happens in apps whose ⌘M is Minimize.
    func parkFocusedIfMinimizeShortcut() -> Bool {
        guard isActive, let app = NSWorkspace.shared.frontmostApplication,
              let id = frontmostFocusedWindowID(), stage.contains(id),
              minimizeItem(for: app.processIdentifier)?.isEnabled == true
        else { return false }
        ignoreFocus(for: 1)
        park(id)
        focusNextStageWindow(of: app.processIdentifier)
        publish()
        return true
    }

    /// The app otherwise keeps focus on the window just parked, so ⌘M twice would hit a hidden window.
    private func focusNextStageWindow(of pid: pid_t) {
        guard let next = stage.compactMap({ windows[$0] }).first(where: { $0.pid == pid }) else { return }
        next.element.focus(appPID: pid)
    }

    private func minimizeItem(for pid: pid_t) -> AXUIElement? {
        if let item = minimizeItems[pid], item.title != nil { return item }
        minimizeItems[pid] = AXUIElementCreateApplication(pid).minimizeMenuItem
        return minimizeItems[pid]
    }

    /// A plain click adds the window to whatever is already on stage; Option-click swaps the stage for it.
    func select(_ id: CGWindowID, replacingStage: Bool) {
        guard isActive, let window = windows[id] else { return }
        ignoreFocus()
        if replacingStage {
            for other in Array(stage) where other != id { park(other) }
        }
        bringToStage(window)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        window.element.focus(appPID: window.pid)
        publish()
    }

    // Mission Control lays windows out around where they sit, so parked windows past the screen's right
    // edge stretch its layout to twice the screen and shrink every tile. macOS 27 exposes no signal that
    // Mission Control is open, so the event tap calls this on the key that opens it, before Dock sees it.
    func beginMissionControl() -> Bool {
        guard isActive, !isInMissionControl else { return false }
        isInMissionControl = true
        exposed = parked.filter { windows[$0]?.present == true }
        switcher.orderOut(nil)
        for id in exposed {
            guard let window = windows[id] else { continue }
            place(window, in: window.savedOrigin.map { CGRect(origin: $0, size: window.size) } ?? Geometry.centered(window.size))
        }
        return true
    }

    /// Mission Control closes on the click or key that follows; give its zoom-out time to finish, then keep
    /// the window it chose on stage and send the rest back to the strip.
    func scheduleMissionControlEnd() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated { self?.endMissionControl() }
        }
    }

    private func endMissionControl() {
        guard isInMissionControl else { return }
        isInMissionControl = false
        let chosen = frontmostFocusedWindowID()
        for id in exposed where id != chosen {
            windows[id]?.element.setPosition(Geometry.parkPoint)
        }
        if let chosen, exposed.contains(chosen) {
            parked.removeAll { $0 == chosen }
            stage.insert(chosen)
        }
        exposed = []
        ignoreFocus()
        publish()
    }

    /// Dragging a thumbnail out of the strip drops its window onto the stage, centred under the pointer.
    /// Dragging a thumbnail out of the strip is the drag-in run backwards: the stand-in leaves the strip
    /// tilted, straightens, then grows to full size, and the window lands where it is let go.
    func dragThumbnail(_ id: CGWindowID, ended: Bool) {
        let point = Geometry.toAXPoint(NSEvent.mouseLocation)
        if ended { return endCarry(at: point) }
        if carried == nil {
            guard isActive, let window = windows[id] else { return }
            carried = (id, CGPoint(x: 0.5, y: 0.06), window.size, window.savedOrigin ?? .zero)
            ignoreFocus(for: 2)
            proxy.show(proxyImages[id] ?? window.thumbnail)
            prepareCarry(id)
            publish()
        }
        carry(to: point)
    }

    /// The stage window whose title bar sits under `point`, i.e. the one a drag starting there moves.
    func stageWindowTitleBar(at point: CGPoint) -> CGWindowID? {
        guard isActive, let id = frontmostFocusedWindowID(), stage.contains(id),
              let frame = windows[id]?.element.frame,
              CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 60).contains(point)
        else { return nil }
        return id
    }

    /// 0 while the pointer is farther than the drag shrink distance from the strip, 1 over the strip.
    var isCarrying: Bool { carried != nil }

    func dragProgress(at x: CGFloat) -> CGFloat {
        let span = Settings.shared.style.dragTransition
        return min(max((Geometry.stripWidth + span - x) / span, 0), 1)
    }

    /// Captures the dragged window at full resolution while it is still being dragged natively, so the
    /// stand-in is sharp when it takes over rather than the strip's small thumbnail.
    func prepareCarry(_ id: CGWindowID) {
        guard let width = windows[id]?.size.width else { return }
        Task { @MainActor in
            guard let image = await Thumbnails.capture([id], width: width * 2)[id] else { return }
            proxyImages[id] = image
            if carried?.id == id { proxy.setImage(image) }
        }
    }

    /// Hides the real window and shows the stand-in in its place; the caller then ends the native drag.
    func beginCarry(_ id: CGWindowID, at point: CGPoint, startedAt start: CGPoint) -> Bool {
        guard isActive, stage.contains(id), let window = windows[id], let frame = window.element.frame else { return false }
        carried = (id, CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height),
                   frame.size, CGPoint(x: frame.minX - (point.x - start.x), y: frame.minY - (point.y - start.y)))
        ignoreFocus(for: 2)
        proxy.show(proxyImages[id] ?? window.thumbnail)
        carry(to: point)
        window.element.setPosition(Geometry.parkPoint)
        return true
    }

    func carry(to point: CGPoint) {
        guard let carried else { return }
        let style = Settings.shared.style
        let p = dragProgress(at: point.x)
        // Stage Manager's order: the window shrinks to thumbnail size first, and only then turns into the
        // strip's perspective. Dragging out runs the same curve backwards.
        let split = style.dragShrinkPortion
        let shrink = min(p / split, 1)
        let tilt = split < 1 ? max((p - split) / (1 - split), 0) : 0
        let fit = min(style.maxWidth / carried.size.width, style.maxHeight / carried.size.height)
        let target = CGSize(width: carried.size.width * fit * style.squeeze, height: carried.size.height * fit)
        let size = CGSize(width: carried.size.width + (target.width - carried.size.width) * shrink,
                          height: carried.size.height + (target.height - carried.size.height) * shrink)
        let origin = CGPoint(x: point.x - carried.grab.x * size.width, y: point.y - carried.grab.y * size.height)
        proxy.update(frame: CGRect(origin: origin, size: size), tilt: tilt,
                     cornerRadius: 10 + (style.cornerRadius - 10) * shrink, style: style)
    }

    /// Let go over the strip and the window is (or stays) parked; anywhere else it lands full size on the
    /// stage under the pointer.
    func endCarry(at point: CGPoint) {
        proxy.orderOut(nil)
        guard let carried, let window = windows[carried.id] else { return }
        self.carried = nil
        proxyImages[carried.id] = nil
        if point.x < Geometry.stripWidth {
            if stage.contains(carried.id) {
                window.size = carried.size
                window.savedOrigin = carried.origin
                stage.remove(carried.id)
                parked.removeAll { $0 == carried.id }
                parked.insert(carried.id, at: 0)
                focusNextStageWindow(of: window.pid)
            }
        } else {
            let origin = CGPoint(x: point.x - carried.grab.x * carried.size.width,
                                 y: max(point.y - carried.grab.y * carried.size.height, Geometry.stageArea.minY))
            place(window, in: CGRect(origin: origin, size: carried.size))
            parked.removeAll { $0 == carried.id }
            stage.insert(carried.id)
            NSRunningApplication(processIdentifier: window.pid)?.activate()
            window.element.focus(appPID: window.pid)
        }
        publish()
    }

    /// A window dragged by its title bar and released over the strip is parked. It remembers where it
    /// was before the drag, so it comes back there rather than at the strip's edge.
    func windowDragEnded(_ id: CGWindowID, at point: CGPoint, movedBy delta: CGVector) {
        guard isActive, point.x < Geometry.stripWidth, stage.contains(id), let window = windows[id] else { return }
        let frame = window.element.frame
        ignoreFocus(for: 1)
        park(id)
        if let frame { window.savedOrigin = CGPoint(x: frame.minX - delta.dx, y: frame.minY - delta.dy) }
        focusNextStageWindow(of: window.pid)
        publish()
    }

    func sendFocusedToStrip() {
        guard isActive, let id = frontmostFocusedWindowID(), stage.contains(id) else { return }
        ignoreFocus()
        park(id)
        publish()
    }

    private func park(_ id: CGWindowID) {
        guard let window = windows[id] else { return }
        if let frame = window.element.frame, !Geometry.isParked(frame) {
            window.size = frame.size
            window.savedOrigin = frame.origin
        }
        window.element.setPosition(Geometry.parkPoint)
        Log.write("park \(id) '\(window.title)' -> \(Geometry.parkPoint) landed \(window.element.frame.map { "\($0)" } ?? "nil")")
        stage.remove(id)
        parked.removeAll { $0 == id }
        parked.insert(id, at: 0)
    }

    private func bringToStage(_ window: ManagedWindow) {
        place(window, in: Geometry.centered(window.size))
        parked.removeAll { $0 == window.id }
        stage.insert(window.id)
    }

    /// Position, size, position again: apps clamp a resize against the frame they currently sit in.
    private func place(_ window: ManagedWindow, in frame: CGRect) {
        window.element.setPosition(frame.origin)
        window.element.setSize(frame.size)
        window.element.setPosition(frame.origin)
    }

    private func ignoreFocus(for seconds: TimeInterval = 0.4) {
        ignoreFocusUntil = max(ignoreFocusUntil, Date().addingTimeInterval(seconds))
    }

    // Cmd-Tab or a Dock click onto an off-stage window pulls it onto the stage. The short delay lets a
    // closing or minimising window's own notification land first, so its sibling is not dragged in.
    private func scheduleFocusCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.checkFocus()
                self?.updateSwitcher()
            }
        }
    }

    /// Pins previews of the other stage windows to the focused window's corner, most recently used first.
    func updateSwitcher() {
        let style = Settings.shared.style
        // While SideStage's own Appearance window is focused, stay on the last window so tuning is visible.
        let ownWindowFocused = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        guard isActive, style.showSwitcher, !isInMissionControl,
              let id = ownWindowFocused ? recentFocus.first : frontmostFocusedWindowID(), stage.contains(id),
              let frame = windows[id]?.element.frame
        else { return switcher.orderOut(nil) }

        recentFocus.removeAll { $0 == id || !stage.contains($0) }
        recentFocus.insert(id, at: 0)
        let others = stage.filter { $0 != id && windows[$0]?.present == true }
            .sorted { (recentFocus.firstIndex(of: $0) ?? .max) < (recentFocus.firstIndex(of: $1) ?? .max) }
        guard !others.isEmpty else { return switcher.orderOut(nil) }

        let items = others.compactMap { windows[$0] }.map {
            SwitcherItem(id: $0.id, title: $0.title, icon: appInfo($0.pid).icon,
                         thumbnail: $0.thumbnail)
        }
        // The 1s sync and every thumbnail refresh land here; with nothing changed, skip the relayout.
        if items == switcherModel.items, switcher.isVisible, switcher.isAttached(to: id, frame: frame, style: style) { return }
        if items != switcherModel.items { switcherModel.items = items }
        switcher.attach(to: frame, id: id, style: style)
    }

    private func focusStageWindow(_ id: CGWindowID) {
        guard let window = windows[id] else { return }
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        window.element.focus(appPID: window.pid)
        scheduleFocusCheck()
    }

    private func checkFocus() {
        guard isActive, !isInMissionControl, Date() > ignoreFocusUntil,
              let id = frontmostFocusedWindowID(), let window = windows[id], !stage.contains(id)
        else { return }
        bringToStage(window)
        publish()
    }

    private func frontmostFocusedWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier).focusedWindow?.windowID
    }

    func reconcile() {
        guard !isInMissionControl else { return }
        catchMinimizedStageWindows()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != getpid()
        }
        let livePIDs = Set(apps.map(\.processIdentifier))
        var seen = Set<CGWindowID>()

        for app in apps {
            let pid = app.processIdentifier
            if observers[pid] == nil { observe(pid) }
            for element in AXUIElementCreateApplication(pid).windows {
                guard element.subrole == kAXStandardWindowSubrole, !element.isMinimized,
                      let id = element.windowID, let frame = element.frame,
                      frame.width >= 120, frame.height >= 80
                else { continue }
                seen.insert(id)
                if let window = windows[id] {
                    window.element = element
                    watch(window)
                    window.title = element.title ?? window.title
                    window.present = true
                    if parked.contains(id), !Geometry.isParked(frame) {
                        Log.write("unpark-by-move \(id) '\(window.title)' frame \(frame)")
                        parked.removeAll { $0 == id }
                        stage.insert(id)
                    }
                } else {
                    let window = ManagedWindow(id: id, pid: pid, element: element, title: element.title ?? "", size: frame.size)
                    windows[id] = window
                    watch(window)
                    if Geometry.isParked(frame) {
                        parked.append(id)
                    } else {
                        stage.insert(id)
                    }
                }
            }
        }

        for (id, window) in windows where !seen.contains(id) && !unminimizing.contains(id) {
            if !livePIDs.contains(window.pid) || window.element.frame == nil || window.element.isMinimized {
                forget(id)
            } else {
                window.present = false
            }
        }
        for pid in observers.keys where !livePIDs.contains(pid) { observers[pid] = nil }
        minimizeItems = minimizeItems.filter { livePIDs.contains($0.key) }
        appInfoCache = appInfoCache.filter { livePIDs.contains($0.key) }
        publish()
    }

    private func forget(_ id: CGWindowID) {
        windows[id] = nil
        stage.remove(id)
        parked.removeAll { $0 == id }
        watchedWindows.remove(id)
    }

    /// An app's name and icon never change while it runs, and looking them up costs a sysctl and a bundle
    /// read, which every redraw used to pay per item.
    private func appInfo(_ pid: pid_t) -> (name: String, icon: NSImage?) {
        if let cached = appInfoCache[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let info = (name: app?.localizedName ?? "", icon: app?.icon)
        appInfoCache[pid] = info
        return info
    }

    private func publish() {
        let items = parked.compactMap { id -> StripItem? in
            guard let window = windows[id], window.present else { return nil }
            let app = appInfo(window.pid)
            return StripItem(id: id, title: window.title, appName: app.name, icon: app.icon, thumbnail: window.thumbnail,
                             isCarried: id == carried?.id)
        }
        if items != strip.items { strip.items = items }
        updateSwitcher()
    }

    private func scheduleThumbnails() {
        thumbnailTimer?.invalidate()
        thumbnailTimer = Timer.scheduledTimer(withTimeInterval: Settings.shared.style.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshThumbnails() }
        }
        refreshThumbnails()
    }

    private func refreshThumbnails() {
        guard isActive, !capturing else { return }
        capturing = true
        // Stage windows feed the switcher and change constantly; parked ones sit off-screen and rarely do,
        // so they are refreshed every fifth tick, and as soon as one has no thumbnail yet.
        thumbnailTick += 1
        let includeParked = thumbnailTick % 5 == 1
        let ids = Set(windows.keys.filter { stage.contains($0) || includeParked || windows[$0]?.thumbnail == nil })
        Task { @MainActor in
            let images = await Thumbnails.capture(ids, width: Settings.shared.style.captureWidth)
            for (id, image) in images { windows[id]?.thumbnail = image }
            capturing = false
            publish()
        }
    }

    // Focus leaves a window the moment its minimize starts, while kAXWindowMiniaturizedNotification only
    // arrives once the genie has finished, so focus changes and the sync tick are where minimize is caught.
    private func catchMinimizedStageWindows() {
        guard isActive, !isInMissionControl else { return }
        for id in Array(stage) where windows[id]?.element.isMinimized == true {
            parkMinimized(id)
        }
    }

    /// Minimize sends the window to the strip, not the Dock. There is no public hook before the genie
    /// runs, so the window is moved off-screen while still minimized and then restored there.
    private func parkMinimized(_ id: CGWindowID) {
        guard let window = windows[id], !unminimizing.contains(id) else { return }
        ignoreFocus(for: 1.5)
        unminimizing.insert(id)
        park(id)
        window.element.setMinimized(false)
        publish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.windows[id] else { return }
                self.unminimizing.remove(id)
                if let frame = window.element.frame, !Geometry.isParked(frame) {
                    window.element.setPosition(Geometry.parkPoint)
                }
                Log.write("minimize -> strip \(id) '\(window.title)' landed \(window.element.frame.map { "\($0)" } ?? "nil")")
            }
        }
    }

    // MARK: Accessibility notifications

    private func observe(_ pid: pid_t) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let manager = Unmanaged<StageManager>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { manager.handle(name, element) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func watch(_ window: ManagedWindow) {
        guard let observer = observers[window.pid], !watchedWindows.contains(window.id) else { return }
        for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                     kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(observer, window.element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        watchedWindows.insert(window.id)
    }

    private func handle(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            catchMinimizedStageWindows()
            updateSwitcher()
            scheduleFocusCheck()
        case kAXMovedNotification, kAXResizedNotification:
            switcher.follow()
        case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
            ignoreFocus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        default:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
    }
}
