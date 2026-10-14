import AppKit
import SwiftUI

struct SwitcherItem: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let icon: NSImage?
    let thumbnail: NSImage?

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.title == b.title && a.thumbnail === b.thumbnail
    }
}

final class SwitcherModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
}

/// Previews of the other windows on stage, pinned to a corner of the focused window. It follows focus
/// rather than sitting on every window, since a window behind would cover its own copy anyway.
final class SwitcherPanel: NSPanel {
    private let host: NSView
    private var attachedID: CGWindowID = 0
    private var placedFor = CGRect.null
    private var style = Style()
    private var size = CGSize.zero
    private var link: CADisplayLink?
    private var lastChange = Date.distantPast

    init(model: SwitcherModel, onSelect: @escaping (CGWindowID) -> Void) {
        host = FirstClickHostingView(rootView: SwitcherView(model: model, onSelect: onSelect))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        contentView = host
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

    var body: some View {
        let style = settings.style
        let spacing = style.switcherSpacing * style.gapScale
        let layout = style.switcherSpot.isVertical
            ? AnyLayout(VStackLayout(alignment: style.switcherSpot.stackAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout {
            ForEach(model.items) { item in
                SwitcherChip(item: item, style: style)
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
        // Room for a hovered appmark to grow inside the panel. Previews are up to about twice as wide
        // as they are tall, so a side grows by at most height × (scale − 1).
        .padding(style.switcherHeight * (style.switcherHoverScale - 1) + 4)
        .fixedSize()
    }
}

private struct SwitcherChip: View {
    let item: SwitcherItem
    let style: Style
    @State private var hovering = false

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
        .scaleEffect(hovering ? style.switcherHoverScale : 1)
        .zIndex(hovering ? 1 : 0)
        .animation(.easeOut(duration: style.hoverDuration), value: hovering)
        .onHover { hovering = $0 }
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
