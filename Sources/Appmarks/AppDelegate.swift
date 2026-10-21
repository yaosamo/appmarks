import AppKit
import Carbon
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let manager = StageManager()
    private lazy var interceptor = EventInterceptor(manager: manager)
    private let settingsWindow = SettingsWindow()
    private let welcomeWindow = WelcomeWindow()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var desktopFilesItem: NSMenuItem!
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        HotKey.register(keyCode: kVK_DownArrow, modifiers: controlKey | optionKey) { [weak self] in
            self?.manager.sendFocusedToStrip()
        }
        restoreWindowsOnSignals()
        followAppearanceSetting()
        LaunchAtLogin.enableOnFirstLaunch()
        if !Permission.allGranted { welcomeWindow.show() }
        startWhenTrusted()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()
    }

    /// The welcome window asks for the permissions; this only waits for Accessibility, then starts.
    private func startWhenTrusted() {
        let trusted = AXIsProcessTrusted()
        Log.write("launch: accessibility=\(trusted)")
        if trusted {
            manager.start()
            interceptor.start()
            updateMenu()
            return
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            MainActor.assumeIsolated { self?.startWhenTrusted() }
        }
    }

    /// `kill` or Ctrl-C would otherwise skip applicationWillTerminate and leave windows parked off-screen.
    private func restoreWindowsOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }

    private func followAppearanceSetting() {
        Settings.shared.$style.map(\.alwaysDark).removeDuplicates().receive(on: RunLoop.main)
            .sink { dark in MainActor.assumeIsolated { NSApp.appearance = dark ? NSAppearance(named: .darkAqua) : nil } }
            .store(in: &subscriptions)
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.leadinghalf.inset.filled", accessibilityDescription: "Appmarks")
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "Pause", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let send = NSMenuItem(title: "Park Focused Window  ⌃⌥↓", action: #selector(sendToStrip), keyEquivalent: "")
        send.target = self
        menu.addItem(send)
        desktopFilesItem = NSMenuItem(title: "Hide Desktop Files", action: #selector(toggleDesktopFiles), keyEquivalent: "")
        desktopFilesItem.target = self
        menu.addItem(desktopFilesItem)
        menu.addItem(.separator())
        let appearance = NSMenuItem(title: "Settings…", action: #selector(showAppearance), keyEquivalent: ",")
        appearance.target = self
        menu.addItem(appearance)
        let permissions = NSMenuItem(title: "Permissions…", action: #selector(showWelcome), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)
        menu.addItem(NSMenuItem(title: "Quit Appmarks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The setting can also change from Terminal, so the tick is read fresh each time.
    func menuWillOpen(_ menu: NSMenu) {
        desktopFilesItem.state = DesktopFiles.isHidden ? .on : .off
    }

    private func updateMenu() {
        toggleItem.title = manager.isActive ? "Pause (restore all windows)" : "Resume"
    }

    @objc private func toggle() {
        manager.isActive ? manager.stop() : manager.start()
        updateMenu()
    }

    @objc private func sendToStrip() { manager.sendFocusedToStrip() }

    @objc private func toggleDesktopFiles() { DesktopFiles.setHidden(!DesktopFiles.isHidden) }

    @objc private func showAppearance() { settingsWindow.show() }

    @objc private func showWelcome() { welcomeWindow.show() }
}
