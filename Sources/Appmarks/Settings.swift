import AppKit
import SwiftUI

struct Style: Codable, Equatable {
    var stripWidth = 180.0
    var stripPadding = 32.0
    var spacing = 26.0
    var centerVertically = false
    var stageMarginX = 16.0
    var stageMarginY = 12.0

    var maxWidth = 128.0
    var squeeze = 1.0
    var maxHeight = 96.0
    var cornerRadius = 7.0
    var angle = 18.0
    var hoverAngle = 0.0
    var perspective = 0.55
    var globalPerspective = false
    var globalAnchorX = 0.5
    var globalAnchorY = 0.5
    var cameraDistance = 500.0
    var hoverScale = 1.07
    var shadowRadius = 10.0
    var shadowOpacity = 0.35
    var shadowY = 5.0

    var showSwitcher = true
    var switcherPlacement = SwitcherPlacement.outsideLeft
    var switcherVertical = true
    var switcherOffsetX = 8.0
    var switcherOffsetY = 0.0
    var switcherHeight = 32.0
    var switcherSpacing = 6.0
    var switcherCornerRadius = 5.0
    var switcherHoverScale = 1.15
    var switcherBackground = true
    var switcherShowIcon = true

    var showIcon = true
    var iconSize = 34.0
    var iconOffsetX = -10.0
    var iconOffsetY = 12.0

    var showLabel = true
    var titleOnHover = true
    var labelSize = 11.0
    var labelGap = 8.0

    var hoverDuration = 0.15
    var reorderDuration = 0.3

    var captureWidth = 360.0
    var refreshInterval = 2.0

    /// Overlays whatever keys the JSON carries onto the defaults, so a partial or older paste still loads.
    static func decode(_ data: Data) -> Style? {
        guard let given = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Style())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: base.merging(given) { $1 })
        else { return nil }
        return try? JSONDecoder().decode(Style.self, from: merged)
    }
}

enum SwitcherPlacement: String, Codable {
    case outsideLeft, insideTopLeft, insideTopRight
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private static let key = "style"

    @Published var style: Style {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(style), forKey: Self.key) }
    }

    /// Falls back to the settings saved under the app's former name, SideStage.
    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.key)
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 760),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Appmarks Appearance"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
            if let screen = NSScreen.screens.first?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 460, y: screen.maxY - 20))
            }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Strip") {
                    SliderRow("Width", $settings.style.stripWidth, 100...320)
                    SliderRow("Edge padding", $settings.style.stripPadding, 0...200)
                    SliderRow("Spacing", $settings.style.spacing, 0...80)
                    Toggle("Center vertically", isOn: $settings.style.centerVertically)
                    SliderRow("Stage margin X", $settings.style.stageMarginX, 0...120)
                    SliderRow("Stage margin Y", $settings.style.stageMarginY, 0...120)
                }
                Section("Thumbnail") {
                    SliderRow("Max width", $settings.style.maxWidth, 60...300)
                    SliderRow("Max height", $settings.style.maxHeight, 40...240)
                    SliderRow("Width squeeze", $settings.style.squeeze, 0.2...1, step: 0.01, digits: 2)
                    SliderRow("Corner radius", $settings.style.cornerRadius, 0...30)
                    SliderRow("Angle", $settings.style.angle, -60...60, unit: "°")
                    SliderRow("Hover angle", $settings.style.hoverAngle, -60...60, unit: "°")
                    SliderRow("Perspective", $settings.style.perspective, 0...1.5, step: 0.01, digits: 2)
                    Toggle("Global perspective", isOn: $settings.style.globalPerspective)
                    SliderRow("Camera distance", $settings.style.cameraDistance, 100...3000, step: 10)
                        .disabled(!settings.style.globalPerspective)
                    SliderRow("Vanishing point X", $settings.style.globalAnchorX, 0...1, step: 0.01, digits: 2)
                        .disabled(!settings.style.globalPerspective)
                    SliderRow("Vanishing point Y", $settings.style.globalAnchorY, 0...1, step: 0.01, digits: 2)
                        .disabled(!settings.style.globalPerspective)
                    SliderRow("Hover scale", $settings.style.hoverScale, 0.8...1.5, step: 0.01, digits: 2)
                    SliderRow("Shadow radius", $settings.style.shadowRadius, 0...40)
                    SliderRow("Shadow opacity", $settings.style.shadowOpacity, 0...1, step: 0.01, digits: 2)
                    SliderRow("Shadow Y", $settings.style.shadowY, -20...30)
                }
                Section("Window switcher") {
                    Toggle("Show on focused window", isOn: $settings.style.showSwitcher)
                    Picker("Placement", selection: $settings.style.switcherPlacement) {
                        Text("Outside, left of window").tag(SwitcherPlacement.outsideLeft)
                        Text("Inside, top left").tag(SwitcherPlacement.insideTopLeft)
                        Text("Inside, top right").tag(SwitcherPlacement.insideTopRight)
                    }
                    Toggle("Stack vertically", isOn: $settings.style.switcherVertical)
                    SliderRow("Offset X", $settings.style.switcherOffsetX, -200...400)
                    SliderRow("Offset Y", $settings.style.switcherOffsetY, -120...200)
                    SliderRow("Preview height", $settings.style.switcherHeight, 16...120)
                    SliderRow("Spacing", $settings.style.switcherSpacing, 0...30)
                    SliderRow("Corner radius", $settings.style.switcherCornerRadius, 0...20)
                    SliderRow("Hover scale", $settings.style.switcherHoverScale, 1...2, step: 0.01, digits: 2)
                    Toggle("Background", isOn: $settings.style.switcherBackground)
                    Toggle("App icon", isOn: $settings.style.switcherShowIcon)
                }
                Section("App icon") {
                    Toggle("Show icon", isOn: $settings.style.showIcon)
                    SliderRow("Size", $settings.style.iconSize, 12...80)
                    SliderRow("Offset X", $settings.style.iconOffsetX, -60...60)
                    SliderRow("Offset Y", $settings.style.iconOffsetY, -60...60)
                }
                Section("Label") {
                    Toggle("Show label", isOn: $settings.style.showLabel)
                    Toggle("Window title on hover", isOn: $settings.style.titleOnHover)
                    SliderRow("Font size", $settings.style.labelSize, 8...20)
                    SliderRow("Gap", $settings.style.labelGap, 0...30)
                }
                Section("Motion") {
                    SliderRow("Hover duration", $settings.style.hoverDuration, 0...1, step: 0.01, digits: 2, unit: "s")
                    SliderRow("Reorder duration", $settings.style.reorderDuration, 0...1.5, step: 0.01, digits: 2, unit: "s")
                }
                Section("Capture") {
                    SliderRow("Resolution", $settings.style.captureWidth, 120...1200, step: 20, unit: "px")
                    SliderRow("Refresh every", $settings.style.refreshInterval, 0.5...10, step: 0.5, digits: 1, unit: "s")
                }
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
        .frame(minWidth: 400, minHeight: 400)
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
