import AppKit
import SwiftUI

/// The keys keep their old `switcher` names, so settings saved by earlier versions still load.
struct Style: Codable, Equatable {
    var showSwitcher = true
    var alwaysDark = false

    /// How far snapped bubbles sit from the window's edge.
    var switcherOffsetX = 8.0
    var switcherHeight = 32.0
    var switcherSpacing = 6.0
    var switcherCornerRadius = 5.0
    /// The square the bubble under the pointer grows to.
    var switcherHoverSize = 80.0
    var switcherBackground = true
    var switcherShowIcon = true

    var captureWidth = 360.0
    var refreshInterval = 5.0

    /// Overlays whatever keys the JSON carries onto the defaults, so a partial or older paste still loads.
    static func decode(_ data: Data) -> Style? {
        guard let given = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Style())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(given) { $1 })
        else { return nil }
        return try? JSONDecoder().decode(Style.self, from: merged)
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private static let key = "style"

    @Published var style: Style {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(style), forKey: Self.key) }
    }

    /// Falls back to the settings saved under the app's former names, Appmarks and SideStage.
    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.key)
            ?? UserDefaults(suiteName: "com.yaric.appmarks")?.data(forKey: Self.key)
            ?? UserDefaults(suiteName: "com.yaric.sidestage")?.data(forKey: Self.key)
        style = saved.flatMap(Style.decode) ?? Style()
    }

    func copy() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(style), let json = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    func paste() -> Bool {
        guard let data = NSPasteboard.general.string(forType: .string)?.data(using: .utf8),
              let pasted = Style.decode(data)
        else { return false }
        style = pasted
        return true
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Bubbleg Settings"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
            if let screen = NSScreen.screens.first?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 480, y: screen.maxY - 20))
            }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: Settings
    @AppStorage("showFineTuning") private var showFineTuning = false
    @State private var status = ""
    @State private var openAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: $settings.style.showSwitcher) {
                        Text("Show bubbles")
                        Text("Every open window as a bubble in a panel you can drag anywhere or snap onto the active window.")
                    }
                    Toggle("Open at login", isOn: Binding(
                        get: { openAtLogin },
                        set: { LaunchAtLogin.isEnabled = $0; openAtLogin = LaunchAtLogin.isEnabled }
                    ))
                    Toggle(isOn: $settings.style.alwaysDark) {
                        Text("Always dark")
                        Text("When off, the bubbles follow the system's light or dark appearance.")
                    }
                    Toggle("Show fine-tuning", isOn: $showFineTuning)
                }
                if showFineTuning { fineTuning }
            }
            .formStyle(.grouped)

            HStack {
                Button("Copy") { settings.copy(); status = "Copied as JSON" }
                Button("Paste") { status = settings.paste() ? "Pasted" : "Clipboard has no settings JSON" }
                Spacer()
                Text(status).foregroundStyle(.secondary).font(.caption)
                Button("Reset") { settings.style = Style(); status = "Reset to defaults" }
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 400)
        // The window is reused, and Login Items can change in System Settings while it is closed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            openAtLogin = LaunchAtLogin.isEnabled
        }
    }

    @ViewBuilder private var fineTuning: some View {
        Section("Bubbles") {
            SliderRow("Preview height", $settings.style.switcherHeight, 16...120)
            SliderRow("Spacing", $settings.style.switcherSpacing, 0...30)
            SliderRow("Corner radius", $settings.style.switcherCornerRadius, 0...20)
            SliderRow("Hover size", $settings.style.switcherHoverSize, 40...400, unit: "px")
            SliderRow("Gap from window", $settings.style.switcherOffsetX, -200...400)
            Toggle("Background", isOn: $settings.style.switcherBackground)
            Toggle("App icon", isOn: $settings.style.switcherShowIcon)
        }
        Section("Capture") {
            SliderRow("Resolution", $settings.style.captureWidth, 120...1200, step: 20, unit: "px")
            SliderRow("Refresh every", $settings.style.refreshInterval, 0.5...10, step: 0.5, digits: 1, unit: "s")
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let digits: Int
    let unit: String

    init(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
         step: Double = 1, digits: Int = 0, unit: String = "") {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.digits = digits
        self.unit = unit
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                // Rounded in the binding rather than passed as `step:`, which makes AppKit draw a tick per step.
                Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                Text(value.formatted(.number.precision(.fractionLength(digits))) + unit)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}
