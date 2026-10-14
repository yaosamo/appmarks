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
    private(set) var isInMissionControl = false
    private var exposed: [CGWindowID] = []
    private var subscriptions: Set<AnyCancellable> = []
    private lazy var panel = StripPanel(model: strip) { [weak self] pid, replace in
        self?.select(app: pid, replacingStage: replace)
    }

    init() {
        // A hung app must not stall every click passing through the event tap.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFocusCheck() }
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
        publish()
        if appleStageManagerWasOn { AppleStageManager.setEnabled(true) }
    }

    /// Called from the event tap on every left click, before the target app sees it. Returns true when the
    /// click landed on a stage window's minimize button and that window has been parked instead.
    func parkIfMinimizeButton(at point: CGPoint) -> Bool {
        let titleBars = stage.compactMap { windows[$0]?.element.frame }
            .map { CGRect(x: $0.minX, y: $0.minY, width: 100, height: 56) }
        guard isActive, titleBars.contains(where: { $0.contains(point) }) else { return false }

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
    /// A plain click adds every off-stage window of the app to the stage; Option-click first sends the
    /// other apps' windows back. The front window lands in the middle, the rest cascade behind it.
    func select(app pid: pid_t, replacingStage: Bool) {
        let group = parked.compactMap { windows[$0] }.filter { $0.pid == pid && $0.present }
        guard isActive, let front = group.first else { return }
        ignoreFocus()
        if replacingStage {
            for other in Array(stage) where windows[other]?.pid != pid { park(other) }
        }
        for (depth, window) in group.enumerated().reversed() {
            bringToStage(window, cascade: depth)
            window.element.focus(appPID: pid)
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
        front.element.focus(appPID: pid)
        publish()
    }

    // Mission Control lays windows out around where they sit, so parked windows past the screen's right
    // edge stretch its layout to twice the screen and shrink every tile. macOS 27 exposes no signal that
    // Mission Control is open, so the event tap calls this on the key that opens it, before Dock sees it.
    func beginMissionControl() -> Bool {
        guard isActive, !isInMissionControl else { return false }
        isInMissionControl = true
        exposed = parked.filter { windows[$0]?.present == true }
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

    private func bringToStage(_ window: ManagedWindow, cascade depth: Int = 0) {
        let step = Settings.shared.style.stageCascade * Double(depth)
        place(window, in: Geometry.centered(window.size).offsetBy(dx: step, dy: step))
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
            MainActor.assumeIsolated { self?.checkFocus() }
        }
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
        publish()
    }

    private func forget(_ id: CGWindowID) {
        windows[id] = nil
        stage.remove(id)
        parked.removeAll { $0 == id }
        watchedWindows.remove(id)
    }

    private func publish() {
        let shown = parked.compactMap { windows[$0] }.filter(\.present)
        var order: [pid_t] = []
        var byApp: [pid_t: [StripWindow]] = [:]
        for window in shown {
            if byApp[window.pid] == nil { order.append(window.pid) }
            byApp[window.pid, default: []].append(StripWindow(id: window.id, title: window.title, thumbnail: window.thumbnail))
        }
        strip.items = order.map { pid in
            let app = NSRunningApplication(processIdentifier: pid)
            return StripItem(id: pid, appName: app?.localizedName ?? "", icon: app?.icon, windows: byApp[pid]!)
        }
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
        let ids = Set(windows.keys)
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
        for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
            AXObserverAddNotification(observer, window.element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        watchedWindows.insert(window.id)
    }

    private func handle(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            catchMinimizedStageWindows()
            scheduleFocusCheck()
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
