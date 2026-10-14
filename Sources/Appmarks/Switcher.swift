import AppKit
import SwiftUI

struct SwitcherItem: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage?
    let thumbnail: NSImage?

    /// What the hover label says: the window's title, or its app for windows without one.
    var label: String { title.isEmpty ? appName : title }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.title == b.title && a.appName == b.appName && a.thumbnail === b.thumbnail
    }
}

final class SwitcherModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
}

/// Previews of the other windows on stage, pinned to a corner of the focused window. It follows focus
/// rather than sitting on every window, since a window behind would cover its own copy anyway.
final class SwitcherPanel: NSPanel {
    private let host: NSView
    private let label: AppmarkLabel
    private var attachedID: CGWindowID = 0
    private var placedFor = CGRect.null
    private var style = Style()
    private var size = CGSize.zero
    private var link: CADisplayLink?
    private var lastChange = Date.distantPast

    init(model: SwitcherModel, onSelect: @escaping (CGWindowID) -> Void) {
        let label = AppmarkLabel()
        self.label = label
        host = FirstClickHostingView(rootView: SwitcherView(model: model, onSelect: onSelect) { item, hovering, chip in
            label.update(item, hovering: hovering, chip: chip)
        })
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        contentView = host
        label.owner = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `window` is the focused window's frame in Accessibility coordinates (top-left origin). Ordered
    /// directly above that window at normal level, so windows in front of it also cover the switcher.
    func attach(to window: CGRect, id: CGWindowID, style: Style) {
        host.layoutSubtreeIfNeeded()
        size = host.fittingSize
        self.style = style
        attachedID = id
        place(window)
        order(.above, relativeTo: Int(id))
    }

    func isAttached(to id: CGWindowID, frame: CGRect, style: Style) -> Bool {
        attachedID == id && placedFor == frame && self.style == style
    }

    /// Apps report moves at their own pace, often 10–20 times a second or only on release, while the
    /// window server has the real frame every refresh; follow that until the window is still for 300ms.
    func follow() {
        lastChange = Date()
        guard link == nil, isVisible else { return }
        link = NSScreen.screens[0].displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    override func orderOut(_ sender: Any?) {
        link?.invalidate()
        link = nil
        label.hide()
        super.orderOut(sender)
    }

    @objc private func tick() {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], attachedID) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String], let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
        else { return orderOut(nil) }
        if frame != placedFor {
            place(frame)
            lastChange = Date()
        } else if Date().timeIntervalSince(lastChange) > 0.3 {
            link?.invalidate()
            link = nil
        }
    }

    private func place(_ window: CGRect) {
        // The label points at where an appmark was; it comes back on the next hover.
        if window != placedFor { label.hide() }
        placedFor = window
        var frame = style.switcherSpot.frame(size, on: window, inside: style.switcherInside,
                                             gap: style.switcherOffsetX, inset: style.switcherOffsetY)
        // Outside a window that touches a screen edge, the appmarks would otherwise hang off the screen.
        let screen = Geometry.visibleArea
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        let primaryHeight = NSScreen.screens[0].frame.height
        setFrame(NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: size.width, height: size.height), display: true)
    }
}

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var settings = Settings.shared
    let onSelect: (CGWindowID) -> Void
    /// The hovered appmark, whether the pointer entered or left it, and its frame in the panel.
    let onHover: (SwitcherItem, Bool, CGRect) -> Void

    var body: some View {
        let style = settings.style
        let spacing = style.switcherSpacing * style.gapScale
        let layout = style.switcherSpot.isVertical
            ? AnyLayout(VStackLayout(alignment: style.switcherSpot.stackAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout {
            ForEach(model.items) { item in
                SwitcherChip(item: item, style: style) { hovering, frame in onHover(item, hovering, frame) }
                    .onTapGesture { onSelect(item.id) }
            }
        }
        .padding(style.switcherBackground ? 5 : 0)
        .background {
            if style.switcherBackground {
                Backdrop(cornerRadius: style.switcherCornerRadius + 4)
                    .overlay(RoundedRectangle(cornerRadius: style.switcherCornerRadius + 4).strokeBorder(.primary.opacity(0.1)))
            }
        }
        .padding(style.switcherHoverScale * 4)
        .fixedSize()
    }
}

private struct SwitcherChip: View {
    let item: SwitcherItem
    let style: Style
    let onHover: (Bool, CGRect) -> Void
    @State private var hovering = false
    @State private var frame = CGRect.zero

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: style.switcherCornerRadius).fill(.regularMaterial)
                        .aspectRatio(1.5, contentMode: .fit)
                }
            }
            .frame(height: style.switcherHeight)
            .clipShape(RoundedRectangle(cornerRadius: style.switcherCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: style.switcherCornerRadius).stroke(.primary.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            if style.showIcon, style.switcherShowIcon, let icon = item.icon {
                Image(nsImage: icon).resizable()
                    .frame(width: style.switcherHeight * 0.5, height: style.switcherHeight * 0.5)
                    .offset(x: 4, y: 4)
            }
        }
        // Measured before the hover scale, so the label sits off the appmark's resting frame.
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { frame = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { _, new in frame = new }
        })
        .scaleEffect(hovering ? style.switcherHoverScale : 1)
        .animation(.easeOut(duration: style.hoverDuration), value: hovering)
        .onHover {
            hovering = $0
            onHover($0, frame)
        }
    }
}

/// The hovered appmark's window name. It gets a panel of its own, because the appmarks' panel is
/// sized tightly around them and would clip anything sticking out.
final class AppmarkLabel: NSPanel {
    weak var owner: NSWindow?
    private let host = NSHostingView(rootView: AppmarkLabelView(text: "", fontSize: 11))
    private var shownID: CGWindowID?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func hide() {
        shownID = nil
        orderOut(nil)
    }

    /// `chip` is in the owner's content coordinates (top-left origin). Moving straight from one appmark
    /// to the next can report the new one's enter before the old one's exit, so an exit only hides
    /// the label when it is for the appmark being shown.
    func update(_ item: SwitcherItem, hovering: Bool, chip: CGRect) {
        let style = Settings.shared.style
        guard hovering else {
            if shownID == item.id { hide() }
            return
        }
        guard style.switcherLabel, !item.label.isEmpty, let owner else { return hide() }

        host.rootView = AppmarkLabelView(text: item.label, fontSize: style.labelSize)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let anchor = NSRect(x: owner.frame.minX + chip.minX, y: owner.frame.maxY - chip.maxY, width: chip.width, height: chip.height)
        let screen = owner.screen?.visibleFrame ?? Geometry.visibleArea
        let spot = style.switcherSpot
        let growth = (style.switcherHoverScale - 1) / 2

        // Off the side the appmarks don't continue on: beside a column, above or below a row. Outside the
        // window that is away from it, inside it is toward the middle; flip if it would leave the screen.
        var origin = CGPoint.zero
        if spot.isVertical {
            let gap = 6 + anchor.width * growth
            var left = (spot.unit.x == 0) != style.switcherInside
            func x(_ left: Bool) -> CGFloat { left ? anchor.minX - gap - size.width : anchor.maxX + gap }
            if x(left) < screen.minX || x(left) + size.width > screen.maxX { left.toggle() }
            origin = CGPoint(x: x(left), y: anchor.midY - size.height / 2)
        } else {
            let gap = 6 + anchor.height * growth
            var above = (spot.unit.y == 0) != style.switcherInside
            func y(_ above: Bool) -> CGFloat { above ? anchor.maxY + gap : anchor.minY - gap - size.height }
            if y(above) < screen.minY || y(above) + size.height > screen.maxY { above.toggle() }
            origin = CGPoint(x: anchor.midX - size.width / 2, y: y(above))
        }
        origin.x = max(screen.minX, min(origin.x, screen.maxX - size.width))
        origin.y = max(screen.minY, min(origin.y, screen.maxY - size.height))

        setFrame(NSRect(origin: origin, size: size), display: true)
        order(.above, relativeTo: owner.windowNumber)
        shownID = item.id
    }
}

private struct AppmarkLabelView: View {
    let text: String
    let fontSize: Double

    var body: some View {
        // A notch under the strip's labels: it sits right next to small appmarks.
        Text(text)
            .font(.system(size: max(fontSize - 1, 8), weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 240)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Backdrop(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.1)))
    }
}

/// Behind-window vibrancy, which follows the system's light or dark appearance. SwiftUI materials only
/// blend with the panel's own clear content, so they render the same murky dark in either mode.
private struct Backdrop: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        // The panel is never key, and an inactive effect view drops its vibrancy.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let edge = cornerRadius * 2 + 1
        let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        mask.resizingMode = .stretch
        view.maskImage = mask
    }
}
