import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let manager = StageManager()
    private let settingsWindow = SettingsWindow()
    private let welcomeWindow = WelcomeWindow()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var desktopFilesItem: NSMenuItem!
    private var permissionTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        followAppearanceSetting()
        LaunchAtLogin.enableOnFirstLaunch()
        if !Permission.allGranted { welcomeWindow.show() }
        startWhenTrusted()
    }

    /// The welcome window asks for the permissions; this only waits for Accessibility, then starts.
    private func startWhenTrusted() {
        let trusted = AXIsProcessTrusted()
        Log.write("launch: accessibility=\(trusted)")
        if trusted {
            manager.start()
            updateMenu()
            return
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            MainActor.assumeIsolated { self?.startWhenTrusted() }
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
        toggleItem.title = manager.isActive ? "Pause" : "Resume"
    }

    @objc private func toggle() {
        manager.isActive ? manager.stop() : manager.start()
        updateMenu()
    }

    @objc private func toggleDesktopFiles() { DesktopFiles.setHidden(!DesktopFiles.isHidden) }

    @objc private func showAppearance() { settingsWindow.show() }

    @objc private func showWelcome() { welcomeWindow.show() }
}
