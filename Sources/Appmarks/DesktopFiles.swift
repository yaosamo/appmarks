import Foundation

/// Finder draws the desktop's files and folders only while `CreateDesktop` is on, and reads it at launch,
/// so a change takes a Finder restart, which launchd does by itself after `killall`.
enum DesktopFiles {
    private static let domain = "com.apple.finder" as CFString
    private static let key = "CreateDesktop" as CFString

    static var isHidden: Bool {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? Bool == false
    }

    static func setHidden(_ hidden: Bool) {
        CFPreferencesSetAppValue(key, !hidden as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/killall"), arguments: ["Finder"])
        Log.write("desktop files -> \(hidden ? "hidden" : "shown")")
    }
}
