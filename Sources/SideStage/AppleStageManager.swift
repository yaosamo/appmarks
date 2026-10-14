import Foundation

/// Apple's Stage Manager re-lays-out the same windows SideStage moves, so the two cannot run together.
/// WindowManager picks the preference up live, the same way the Control Center toggle does.
enum AppleStageManager {
    private static let domain = "com.apple.WindowManager" as CFString
    private static let key = "GloballyEnabled" as CFString

    static var isEnabled: Bool {
        CFPreferencesCopyAppValue(key, domain) as? Bool ?? false
    }

    static func setEnabled(_ enabled: Bool) {
        CFPreferencesSetAppValue(key, enabled as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
        Log.write("apple stage manager -> \(enabled)")
    }
}
