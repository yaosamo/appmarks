import Foundation
import ServiceManagement

/// Appmarks opens at login by default. It registers itself only on the first launch, so turning it
/// off in Settings or in System Settings → General → Login Items sticks.
enum LaunchAtLogin {
    private static let enabledOnceKey = "launchAtLoginEnabledOnce"

    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.write("launch at login: \(newValue ? "register" : "unregister") failed: \(error)")
            }
        }
    }

    static func enableOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: enabledOnceKey) else { return }
        UserDefaults.standard.set(true, forKey: enabledOnceKey)
        isEnabled = true
    }
}
