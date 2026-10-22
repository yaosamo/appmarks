import AppKit
import ApplicationServices
import Combine

final class ManagedWindow {
    let id: CGWindowID
    let pid: pid_t
    var element: AXUIElement
    var title: String
    var thumbnail: NSImage?
    /// False while the window lives on another Space: AX only lists the current Space's windows.
    var present = true
    var minimized = false

    init(id: CGWindowID, pid: pid_t, element: AXUIElement, title: String) {
        self.id = id
        self.pid = pid
        self.element = element
        self.title = title
    }
}

/// Keeps track of every open window and shows them all as one floating set of bubbles.
@MainActor
final class StageManager {
    private(set) var isActive = false

    private var windows: [CGWindowID: ManagedWindow] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var watchedWindows: Set<CGWindowID> = []
    private var syncTimer: Timer?
    private var capturing = false
    private var thumbnailTimer: Timer?
    private var appInfoCache: [pid_t: (name: String, icon: NSImage?)] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    /// The active window, which the bubbles ring and snap onto.
    private var focused: CGWindowID?
    /// Windows in the order Bubbleg first saw them, which is the bubbles' fixed order.
    private var openingOrder: [CGWindowID] = []
    private lazy var widget = WidgetPanel(onSelect: { [weak self] id in self?.focus(id) },
                                          snapTargets: { [weak self] in self?.snapTargets() ?? [] })

    init() {
        // A hung app must not stall the sync.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateWidget()
                self?.scheduleUpdate()
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
        let style = Settings.shared.$style.receive(on: RunLoop.main)
        style.map(\.refreshInterval).removeDuplicates().dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { if self?.isActive == true { self?.scheduleThumbnails() } } }
            .store(in: &subscriptions)
        style.dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateWidget() } }
            .store(in: &subscriptions)
        style.map(\.captureWidth).removeDuplicates().dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshThumbnails() } }
            .store(in: &subscriptions)
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        reconcile()
        Log.write("start: windows=\(windows.count) screenCapture=\(CGPreflightScreenCaptureAccess())")
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        scheduleThumbnails()
    }

    func stop() {
        isActive = false
        syncTimer?.invalidate()
        syncTimer = nil
        thumbnailTimer?.invalidate()
        thumbnailTimer = nil
        widget.orderOut(nil)
    }

    // Focus settles a moment after an app activates, and a closing or minimising window's own
    // notification lands first, so the bubbles look again shortly after.
    private func scheduleUpdate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.updateWidget() }
        }
    }

    /// Every window on screen, the active one marked, in the order they opened.
    private func updateWidget() {
        let style = Settings.shared.style
        guard isActive, style.showSwitcher else { return widget.orderOut(nil) }
        // While Bubbleg's own Settings window is focused, keep marking the last window; an app with no
        // window open, or the desktop, leaves none active.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() {
            focused = frontmostFocusedWindowID()
        }
        let items = openingOrder.compactMap { windows[$0] }.filter(\.present).map {
            SwitcherItem(id: $0.id, title: $0.title, icon: appInfo($0.pid).icon, thumbnail: $0.thumbnail,
                         isFocused: $0.id == focused, isMinimized: $0.minimized)
        }
        widget.update(items: items, focused: focused, style: style)
    }

    /// Only the active window: snapped, the bubbles move to whichever window is active anyway.
    private func snapTargets() -> [(id: CGWindowID, frame: CGRect)] {
        guard let focused, windows[focused]?.present == true else { return [] }
        return WindowServer.onScreen([focused])
    }

    private func focus(_ id: CGWindowID) {
        guard let window = windows[id] else { return }
        if window.minimized { window.element.setMinimized(false) }
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        window.element.focus(appPID: window.pid)
        scheduleUpdate()
    }

    private func frontmostFocusedWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier).focusedWindow?.windowID
    }

    func reconcile() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != getpid()
        }
        let livePIDs = Set(apps.map(\.processIdentifier))
        var seen = Set<CGWindowID>()

        for app in apps {
            let pid = app.processIdentifier
            if observers[pid] == nil { observe(pid) }
            for element in AXUIElementCreateApplication(pid).windows {
                guard element.subrole == kAXStandardWindowSubrole,
                      let id = element.windowID, let frame = element.frame,
                      frame.width >= 120, frame.height >= 80
                else { continue }
                seen.insert(id)
                let window = windows[id] ?? {
                    let window = ManagedWindow(id: id, pid: pid, element: element, title: element.title ?? "")
                    windows[id] = window
                    openingOrder.append(id)
                    return window
                }()
                window.element = element
                watch(window)
                window.title = element.title ?? window.title
                window.present = true
                window.minimized = element.isMinimized
            }
        }

        for (id, window) in windows where !seen.contains(id) {
            if !livePIDs.contains(window.pid) || window.element.frame == nil {
                forget(id)
            } else {
                window.present = false
            }
        }
        for pid in observers.keys where !livePIDs.contains(pid) { observers[pid] = nil }
        appInfoCache = appInfoCache.filter { livePIDs.contains($0.key) }
        updateWidget()
    }

    private func forget(_ id: CGWindowID) {
        windows[id] = nil
        openingOrder.removeAll { $0 == id }
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
            updateWidget()
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
        for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(observer, window.element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        watchedWindows.insert(window.id)
    }

    private func handle(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            updateWidget()
            scheduleUpdate()
        case kAXMovedNotification, kAXResizedNotification:
            widget.follow()
        default:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
    }
}
