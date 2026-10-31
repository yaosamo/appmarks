import AppKit
@preconcurrency import ApplicationServices
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

/// A standard window as one sync read it, off the main thread.
private struct SeenWindow {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let title: String?
    let minimized: Bool
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

    /// Every Accessibility call waits on the app that answers it, and some apps take a few hundred ms per
    /// question (the Godot editor does), which on the main thread froze the bubbles mid-follow for over a
    /// second at every sync. So the main thread asks nothing: the sync reads on one queue, and the active
    /// window and focusing go through another so a slow sync never holds them up.
    private let syncQueue = DispatchQueue(label: "Bubbleg.sync", qos: .userInitiated)
    private let focusQueue = DispatchQueue(label: "Bubbleg.focus", qos: .userInteractive)
    private var syncing = false
    private var syncAgain = false
    private var lookingUpFocus = false
    private var lookUpFocusAgain = false

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
        Log.write("start: screenCapture=\(CGPreflightScreenCaptureAccess())")
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

    /// Looks up the active window, then shows every window on screen, the active one marked, in the
    /// order they opened. While Bubbleg's own Settings window is focused, it keeps marking the last
    /// window; an app with no window open, or the desktop, leaves none active.
    private func updateWidget() {
        guard isActive, Settings.shared.style.showSwitcher else { return widget.orderOut(nil) }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else {
            return showWidget()
        }
        guard !lookingUpFocus else { lookUpFocusAgain = true; return }
        lookingUpFocus = true
        let pid = app.processIdentifier
        let known = windows.values.filter { $0.pid == pid }.map { (id: $0.id, element: $0.element) }
        focusQueue.async { [weak self] in
            let id = AXUIElementCreateApplication(pid).focusedWindow
                .flatMap { WindowIDs.resolve([$0], pid: pid, known: known)[0] }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lookingUpFocus = false
                    self.focused = id
                    self.showWidget()
                    if self.lookUpFocusAgain {
                        self.lookUpFocusAgain = false
                        self.updateWidget()
                    }
                }
            }
        }
    }

    private func showWidget() {
        let style = Settings.shared.style
        guard isActive, style.showSwitcher else { return widget.orderOut(nil) }
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
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        let (element, pid, minimized) = (window.element, window.pid, window.minimized)
        focusQueue.async {
            if minimized { element.setMinimized(false) }
            element.focus(appPID: pid)
        }
        scheduleUpdate()
    }

    /// Reads every app's windows on the sync queue and takes the result back on the main thread. A sync
    /// asked for while one is still reading runs once it lands.
    func reconcile() {
        guard !syncing else { syncAgain = true; return }
        syncing = true
        let pids = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != getpid()
        }.map(\.processIdentifier)
        let known = windows.values.map { (id: $0.id, pid: $0.pid, element: $0.element) }
        let (observers, watched) = (self.observers, watchedWindows)
        // The address alone crosses to the sync queue; the manager lives as long as the app.
        let address = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        syncQueue.async { [weak self] in
            let refcon = UnsafeMutableRawPointer(bitPattern: address)!
            var added: [pid_t: AXObserver] = [:]
            var seen: [SeenWindow] = []
            var newlyWatched: [CGWindowID] = []
            for pid in pids {
                let observer = observers[pid] ?? Self.observe(pid, refcon: refcon)
                if observers[pid] == nil { added[pid] = observer }
                let elements = AXUIElementCreateApplication(pid).windows.filter { element in
                    guard element.subrole == kAXStandardWindowSubrole, let frame = element.frame else { return false }
                    return frame.width >= 120 && frame.height >= 80
                }
                let mine = known.filter { $0.pid == pid }.map { (id: $0.id, element: $0.element) }
                for (element, id) in zip(elements, WindowIDs.resolve(elements, pid: pid, known: mine)) {
                    guard let id else { continue }
                    seen.append(SeenWindow(id: id, pid: pid, element: element, title: element.title, minimized: element.isMinimized))
                    if let observer, !watched.contains(id) {
                        Self.watch(element, observer: observer, refcon: refcon)
                        newlyWatched.append(id)
                    }
                }
            }
            let seenIDs = Set(seen.map(\.id))
            let live = Set(pids)
            let gone = Set(known.filter { !seenIDs.contains($0.id) && (!live.contains($0.pid) || $0.element.frame == nil) }.map(\.id))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(seen: seen, gone: gone, live: live, added: added, newlyWatched: newlyWatched)
                }
            }
        }
    }

    private func apply(seen: [SeenWindow], gone: Set<CGWindowID>, live: Set<pid_t>, added: [pid_t: AXObserver], newlyWatched: [CGWindowID]) {
        for (pid, observer) in added where observers[pid] == nil {
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }
        watchedWindows.formUnion(newlyWatched)
        for found in seen {
            let window = windows[found.id] ?? {
                let window = ManagedWindow(id: found.id, pid: found.pid, element: found.element, title: found.title ?? "")
                windows[found.id] = window
                openingOrder.append(found.id)
                return window
            }()
            window.element = found.element
            window.title = found.title ?? window.title
            window.present = true
            window.minimized = found.minimized
        }
        let seenIDs = Set(seen.map(\.id))
        for (id, window) in windows where !seenIDs.contains(id) {
            if gone.contains(id) {
                forget(id)
            } else {
                window.present = false
            }
        }
        for pid in observers.keys where !live.contains(pid) { observers[pid] = nil }
        appInfoCache = appInfoCache.filter { live.contains($0.key) }
        syncing = false
        updateWidget()
        if syncAgain {
            syncAgain = false
            reconcile()
        }
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
            showWidget()
        }
    }

    // MARK: Accessibility notifications

    /// Registered on the sync queue; the notifications themselves arrive on the main run loop, which the
    /// observer joins once the sync lands.
    private nonisolated static func observe(_ pid: pid_t, refcon: UnsafeMutableRawPointer) -> AXObserver? {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let manager = Unmanaged<StageManager>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { manager.handle(name, element) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return nil }
        let app = AXUIElementCreateApplication(pid)
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        return observer
    }

    private nonisolated static func watch(_ element: AXUIElement, observer: AXObserver, refcon: UnsafeMutableRawPointer) {
        for name in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
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
