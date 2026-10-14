import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = StageManager()
    private lazy var interceptor = EventInterceptor(manager: manager)
    private let settingsWindow = SettingsWindow()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        HotKey.register(keyCode: kVK_DownArrow, modifiers: controlKey | optionKey) { [weak self] in
            self?.manager.sendFocusedToStrip()
        }
        restoreWindowsOnSignals()
        startWhenTrusted()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()
    }

    private func startWhenTrusted() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(prompt)
        Log.write("launch: accessibility=\(trusted)")
        if trusted {
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
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

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.leadinghalf.inset.filled", accessibilityDescription: "Appmarks")
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "Pause", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let send = NSMenuItem(title: "Send Focused Window to Strip  ⌃⌥↓", action: #selector(sendToStrip), keyEquivalent: "")
        send.target = self
        menu.addItem(send)
        menu.addItem(.separator())
        let appearance = NSMenuItem(title: "Appearance…", action: #selector(showAppearance), keyEquivalent: ",")
        appearance.target = self
        menu.addItem(appearance)
        let settings = NSMenuItem(title: "Open Privacy Settings…", action: #selector(openPrivacy), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Appmarks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateMenu() {
        toggleItem.title = manager.isActive ? "Pause (restore all windows)" : "Resume"
    }

    @objc private func toggle() {
        manager.isActive ? manager.stop() : manager.start()
        updateMenu()
    }

    @objc private func sendToStrip() { manager.sendFocusedToStrip() }

    @objc private func showAppearance() { settingsWindow.show() }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
