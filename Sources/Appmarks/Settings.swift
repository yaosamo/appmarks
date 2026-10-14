import AppKit
import SwiftUI

struct Style: Codable, Equatable {
    var stripPosition = StripPosition.left
    var itemSize = ItemSize.standard
    var density = Density.standard
    var alwaysDark = false

    var stripWidth = 180.0
    var stripPadding = 32.0
    var spacing = 24.0
    var stageMarginX = 16.0
    var stageMarginY = 12.0

    var maxWidth = 149.0
    var squeeze = 0.83
    var maxHeight = 96.0
    var cornerRadius = 7.0
    var angle = 23.0
    var hoverAngle = 23.0
    var perspective = 0.68
    var globalPerspective = true
    var globalAnchorX = 0.5
    var globalAnchorY = 0.5
    var cameraDistance = 500.0
    var hoverScale = 1.03
    var shadowRadius = 10.0
    var shadowOpacity = 0.12
    var shadowY = 7.0

    var showSwitcher = true
    var switcherSpot = WindowSpot.topLeft
    var switcherInside = false
    var switcherOffsetX = 8.0
    var switcherOffsetY = 0.0
    var switcherHeight = 32.0
    var switcherSpacing = 6.0
    var switcherCornerRadius = 5.0
    var switcherHoverScale = 1.15
    var switcherBackground = true
    var switcherShowIcon = true

    var showIcon = true
    var iconSize = 36.0
    var iconOffsetX = -1.0
    var iconOffsetY = 12.0

    var showLabel = true
    var titleOnHover = true
    var labelSize = 11.0
    var labelGap = 7.0

    var hoverDuration = 0.15
    var reorderDuration = 0.3

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

/// The presets scale the fine-tuning values rather than overwrite them, so both stay meaningful.
extension Style {
    var itemScale: Double { itemSize == .small ? 0.75 : 1 }
    var gapScale: Double { density == .dense ? 0.45 : 1 }
    var effectiveStripWidth: Double { stripWidth * (itemSize == .small ? 0.8 : 1) }
    /// On the right edge the strip is the left one mirrored: tilted and badged toward the screen's middle.
    var mirror: Double { stripPosition.onRight ? -1 : 1 }
}

enum StripPosition: String, Codable, CaseIterable, Identifiable {
    case leftTop, left, leftBottom, rightTop, right, rightBottom

    var id: Self { self }
    var onRight: Bool { [.rightTop, .right, .rightBottom].contains(self) }
    var alignment: Alignment {
        switch self {
        case .leftTop, .rightTop: .top
        case .left, .right: .center
        case .leftBottom, .rightBottom: .bottom
        }
    }
    var title: String {
        switch self {
        case .leftTop: "Top left"
        case .left: "Left"
        case .leftBottom: "Bottom left"
        case .rightTop: "Top right"
        case .right: "Right"
        case .rightBottom: "Bottom right"
        }
    }
}

enum ItemSize: String, Codable { case small, standard }
enum Density: String, Codable { case dense, standard }

/// Where the appmarks sit on the focused window: a corner or the middle of a side.
enum WindowSpot: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var id: Self { self }
    /// 0, 0.5 or 1 along each axis of the window.
    var unit: (x: Double, y: Double) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .right: (1, 0.5)
        case .bottomRight: (1, 1)
        case .bottom: (0.5, 1)
        case .bottomLeft: (0, 1)
        case .left: (0, 0.5)
        }
    }
    /// Stacked along the side they sit on: a column on the left and right, a row on the top and bottom.
    var isVertical: Bool { unit.x != 0.5 }
    var stackAlignment: HorizontalAlignment { unit.x == 0 ? .trailing : unit.x == 1 ? .leading : .center }
    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .top: "Top"
        case .topRight: "Top right"
        case .right: "Right"
        case .bottomRight: "Bottom right"
        case .bottom: "Bottom"
        case .bottomLeft: "Bottom left"
        case .left: "Left"
        }
    }

    /// The frame of something `size` big at this spot of `window`, in top-left-origin coordinates.
    /// `gap` is the distance from the edge it hugs; `inset` slides a corner stack along its side.
    func frame(_ size: CGSize, on window: CGRect, inside: Bool, gap: CGFloat, inset: CGFloat) -> CGRect {
        let (ux, uy) = unit
        let x: CGFloat = switch ux {
        case 0: inside ? window.minX + gap : window.minX - gap - size.width
        case 1: inside ? window.maxX - gap - size.width : window.maxX + gap
        default: window.midX - size.width / 2
        }
        let y: CGFloat = switch (ux, uy) {
        case (0.5, 0): inside ? window.minY + gap : window.minY - gap - size.height
        case (0.5, _): inside ? window.maxY - gap - size.height : window.maxY + gap
        case (_, 0): window.minY + inset
        case (_, 1): window.maxY - inset - size.height
        default: window.midY - size.height / 2
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 800),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Appmarks Settings"
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
                Section("Parked windows") {
                    ScreenPicker(selection: $settings.style.stripPosition)
                    Picker("Size", selection: $settings.style.itemSize) {
                        Text("Small").tag(ItemSize.small)
                        Text("Default").tag(ItemSize.standard)
                    }
                    Picker("Density", selection: $settings.style.density) {
                        Text("Dense").tag(Density.dense)
                        Text("Default").tag(Density.standard)
                    }
                    Toggle("App icons", isOn: $settings.style.showIcon)
                    Toggle("Labels", isOn: $settings.style.showLabel)
                }
                Section("Appmarks on windows") {
                    Toggle("Show on the focused window", isOn: $settings.style.showSwitcher)
                    Group {
                        WindowPicker(selection: $settings.style.switcherSpot, inside: settings.style.switcherInside)
                        Picker("Placement", selection: $settings.style.switcherInside) {
                            Text("Outside").tag(false)
                            Text("Inside").tag(true)
                        }
                    }
                    .disabled(!settings.style.showSwitcher)
                }
                Section {
                    Toggle("Open at login", isOn: Binding(
                        get: { openAtLogin },
                        set: { LaunchAtLogin.isEnabled = $0; openAtLogin = LaunchAtLogin.isEnabled }
                    ))
                    Toggle(isOn: $settings.style.alwaysDark) {
                        Text("Always dark")
                        Text("When off, panels follow the system's light or dark appearance.")
                    }
                    Toggle("Show fine-tuning", isOn: $showFineTuning)
                }
                if showFineTuning { fineTuning }
            }
            .formStyle(.grouped)
            .pickerStyle(.segmented)

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
        Section("Strip") {
            SliderRow("Width", $settings.style.stripWidth, 100...320)
            SliderRow("Edge padding", $settings.style.stripPadding, 0...200)
            SliderRow("Spacing", $settings.style.spacing, 0...80)
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
        Section("App icon") {
            SliderRow("Size", $settings.style.iconSize, 12...80)
            SliderRow("Offset X", $settings.style.iconOffsetX, -60...60)
            SliderRow("Offset Y", $settings.style.iconOffsetY, -60...60)
        }
        Section("Label") {
            Toggle("Window title on hover", isOn: $settings.style.titleOnHover)
            SliderRow("Font size", $settings.style.labelSize, 8...20)
            SliderRow("Gap", $settings.style.labelGap, 0...30)
        }
        Section("Appmarks on windows") {
            SliderRow("Gap from window", $settings.style.switcherOffsetX, -200...400)
            SliderRow("Corner inset", $settings.style.switcherOffsetY, -120...200)
            SliderRow("Preview height", $settings.style.switcherHeight, 16...120)
            SliderRow("Spacing", $settings.style.switcherSpacing, 0...30)
            SliderRow("Corner radius", $settings.style.switcherCornerRadius, 0...20)
            SliderRow("Hover scale", $settings.style.switcherHoverScale, 1...2, step: 0.01, digits: 2)
            Toggle("Background", isOn: $settings.style.switcherBackground)
            Toggle("App icon", isOn: $settings.style.switcherShowIcon)
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
}

// MARK: Spot pickers

private let sketchSize = CGSize(width: 300, height: 188)

/// A sketch of the screen with a slot on each spot the parked windows can sit; click one to move them.
private struct ScreenPicker: View {
    @Binding var selection: StripPosition

    var body: some View {
        Sketch {
            Rectangle().fill(.primary.opacity(0.07)).frame(height: 8)
                .position(x: sketchSize.width / 2, y: 4)
            Capsule().fill(.primary.opacity(0.1)).frame(width: 90, height: 8)
                .position(x: sketchSize.width / 2, y: sketchSize.height - 7)
            WindowShape().frame(width: 130, height: 86)
                .position(x: sketchSize.width / 2, y: sketchSize.height / 2)
            ForEach(StripPosition.allCases) { position in
                SpotButton(title: position.title, selected: selection == position,
                           chip: CGSize(width: 20, height: 11), vertical: true, spacing: 4) {
                    selection = position
                }
                .position(center(of: position))
            }
        }
    }

    private func center(of position: StripPosition) -> CGPoint {
        let x = position.onRight ? sketchSize.width - 19 : 19
        let y: CGFloat = switch position.alignment {
        case .top: 34.5
        case .bottom: sketchSize.height - 36.5
        default: sketchSize.height / 2
        }
        return CGPoint(x: x, y: y)
    }
}

/// A sketch of a window with a slot on each corner and the middle of each side, laid out by the same
/// rule the real appmarks use, so Inside and Outside move the slots as they would move the appmarks.
private struct WindowPicker: View {
    @Binding var selection: WindowSpot
    let inside: Bool
    @Environment(\.isEnabled) private var isEnabled

    private let window = CGRect(x: 65, y: 29, width: 170, height: 130)

    var body: some View {
        Sketch {
            WindowShape().frame(width: window.width, height: window.height)
                .position(x: window.midX, y: window.midY)
            ForEach(WindowSpot.allCases) { spot in
                let chip = CGSize(width: 14, height: 9)
                let stack = spot.isVertical ? CGSize(width: chip.width, height: chip.height * 3 + 4)
                                            : CGSize(width: chip.width * 3 + 4, height: chip.height)
                let frame = spot.frame(stack, on: window, inside: inside, gap: 6, inset: 5)
                SpotButton(title: spot.title, selected: selection == spot,
                           chip: chip, vertical: spot.isVertical, spacing: 2) {
                    selection = spot
                }
                .position(x: frame.midX, y: frame.midY)
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.snappy(duration: 0.2), value: inside)
    }
}

private struct Sketch<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.04))
            content
        }
        .frame(width: sketchSize.width, height: sketchSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

private struct WindowShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.background)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.7)).frame(width: 5, height: 5) }
                }
                .padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

/// A dashed slot of three little previews, filled with the accent colour when chosen.
private struct SpotButton: View {
    let title: String
    let selected: Bool
    let chip: CGSize
    let vertical: Bool
    let spacing: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
        Button(action: action) {
            layout {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(selected ? Color.accentColor : hovering ? Color.accentColor.opacity(0.35) : .clear)
                        .frame(width: chip.width, height: chip.height)
                }
            }
            .padding(3)
            .overlay {
                if !selected {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(hovering ? Color.accentColor : .primary.opacity(0.3),
                                      style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.snappy(duration: 0.15), value: selected)
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
