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

/// The pointer over the appmarks, in the panel's top-left-origin coordinates; nil when it is elsewhere.
final class AppmarkHover: ObservableObject {
    @Published var pointer: CGPoint?
}

/// Previews of the other windows on stage, pinned to a corner of the focused window. It follows focus
/// rather than sitting on every window, since a window behind would cover its own copy anyway.
final class SwitcherPanel: NSPanel {
    private let host: NSView
    private let model: SwitcherModel
    private let hover = AppmarkHover()
    private var monitors: [Any] = []
    private var attachedID: CGWindowID = 0
    private var placedFor = CGRect.null
    private var style = Style()
    private var layout = AppmarkLayout(items: [], style: Style())
    private var link: CADisplayLink?
    private var lastChange = Date.distantPast
    /// Where the panel is heading, in screen coordinates; it eases there rather than jumping.
    private var target = NSRect.zero

    init(model: SwitcherModel, onSelect: @escaping (CGWindowID) -> Void) {
        self.model = model
        host = FirstClickHostingView(rootView: SwitcherView(model: model, hover: hover, onSelect: onSelect))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `window` is the focused window's frame in Accessibility coordinates (top-left origin). Ordered
    /// directly above that window at normal level, so windows in front of it also cover the switcher.
    /// Showing up on a new window is instant; a move on the same window glides like `follow`.
    func attach(to window: CGRect, id: CGWindowID, style: Style) {
        layout = AppmarkLayout(items: model.items, style: style)
        self.style = style
        let glide = id == attachedID && isVisible
        attachedID = id
        place(window, glide: glide)
        order(.above, relativeTo: Int(id))
        trackPointer()
    }

    func isAttached(to id: CGWindowID, frame: CGRect, style: Style) -> Bool {
        attachedID == id && placedFor == frame && self.style == style
    }

    /// Apps report moves at their own pace, often 10–20 times a second or only on release, while the
    /// window server has the real frame every refresh; follow that until the window is still for 300ms
    /// and the appmarks have caught up.
    func follow() {
        lastChange = Date()
        startLink()
    }

    override func orderOut(_ sender: Any?) {
        link?.invalidate()
        link = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hover.pointer = nil
        super.orderOut(sender)
    }

    /// Most of the panel is clear room to grow, and the pointer over a clear pixel belongs to the window
    /// underneath, so SwiftUI hover would miss it leaving. Every move, wherever it goes, is checked
    /// against the appmarks' current outline instead.
    private func trackPointer() {
        guard monitors.isEmpty else { return }
        let moved = { [weak self] in MainActor.assumeIsolated { self?.pointerMoved() } }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in moved() },
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in moved(); return event },
        ].compactMap { $0 }
    }

    private func pointerMoved() {
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        let outline = layout.backdrop(layout.frames(pointer: hover.pointer))
        let pointer = outline.contains(local) ? local : nil
        if pointer != hover.pointer { hover.pointer = pointer }
    }

    private func startLink() {
        guard link == nil, isVisible else { return }
        link = NSScreen.screens[0].displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], attachedID) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String], let window = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
        else { return orderOut(nil) }
        if window != placedFor {
            place(window, glide: true)
            lastChange = Date()
        }
        step(seconds: link.targetTimestamp - link.timestamp)
        if frame.origin == target.origin, Date().timeIntervalSince(lastChange) > 0.3 {
            link.invalidate()
            self.link = nil
        }
    }

    /// Eases toward the target, closing most of the gap in about 0.1s, so a window that lags or
    /// jumps mid-drag pulls the appmarks along smoothly instead of teleporting them.
    private func step(seconds: Double) {
        let pull = 1 - exp(-max(seconds, 1 / 240) / 0.035)
        var origin = frame.origin
        origin.x += (target.minX - origin.x) * pull
        origin.y += (target.minY - origin.y) * pull
        if abs(target.minX - origin.x) < 0.5, abs(target.minY - origin.y) < 0.5 { origin = target.origin }
        setFrame(NSRect(origin: origin, size: target.size), display: true)
    }

    private func place(_ window: CGRect, glide: Bool) {
        placedFor = window
        // The resting appmarks and their backdrop are what sits on the window; the rest is room to grow.
        let pinned = layout.resting.insetBy(dx: -layout.backdropPadding, dy: -layout.backdropPadding)
        var frame = style.switcherSpot.frame(pinned.size, on: window, inside: style.switcherInside,
                                             gap: style.switcherOffsetX, inset: style.switcherOffsetY)
        // Outside a window that touches a screen edge, the appmarks would otherwise hang off the screen.
        let screen = Geometry.visibleArea
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        let panelTop = frame.minY - pinned.minY
        let primaryHeight = NSScreen.screens[0].frame.height
        target = NSRect(x: frame.minX - pinned.minX, y: primaryHeight - panelTop - layout.size.height,
                        width: layout.size.width, height: layout.size.height)
        if glide {
            startLink()
        } else {
            setFrame(target, display: true)
        }
    }
}

/// Where each appmark sits, at rest and with the one under the pointer grown to fit `switcherHoverSize`
/// square. It grows away from the window, so the edge facing it stays put, and its neighbours slide
/// aside rather than being covered. The panel is sized up front for the largest appmark grown, and
/// `resting` is the box the appmarks fill at rest.
struct AppmarkLayout {
    let size: CGSize
    let resting: CGRect
    let backdropPadding: CGFloat
    let cornerRadius: CGFloat

    private let vertical: Bool
    /// Growing toward smaller x (a column left of its window edge) or smaller y (a row above it).
    private let growsTowardStart: Bool
    private let along: [CGFloat]
    private let across: [CGFloat]
    private let peak: [CGFloat]
    private let spacing: CGFloat
    /// Where the resting stack starts along its axis, in the panel.
    private let start: CGFloat

    init(items: [SwitcherItem], style: Style) {
        let spot = style.switcherSpot
        let vertical = spot.isVertical
        self.vertical = vertical
        growsTowardStart = ((vertical ? spot.unit.x : spot.unit.y) == 0) != style.switcherInside
        backdropPadding = style.switcherBackground ? 5 : 0
        cornerRadius = style.switcherCornerRadius
        spacing = style.switcherSpacing * style.gapScale

        let height = CGFloat(style.switcherHeight)
        let sizes = items.map { item -> CGSize in
            let aspect = item.thumbnail.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1.5 } ?? 1.5
            return CGSize(width: height * aspect, height: height)
        }
        let box = CGFloat(style.switcherHoverSize)
        let along = sizes.map { vertical ? $0.height : $0.width }
        let across = sizes.map { vertical ? $0.width : $0.height }
        self.along = along
        self.across = across
        let peak = sizes.map { max(1, min(box / $0.width, box / $0.height)) }
        self.peak = peak

        let length = along.reduce(0, +) + spacing * CGFloat(max(along.count - 1, 0))
        // Growth along the axis can land wholly on either side of the pointer.
        let margin = zip(peak, along).map { ($0 - 1) * $1 }.max() ?? 0
        // Room for the backdrop, shadows and the icon badge that pokes out of an appmark's corner.
        let edge = backdropPadding + 10
        start = edge + margin
        let restingCross = across.max() ?? 0
        let crossExtent = (zip(across, peak).map { $0 * $1 }.max() ?? 0) + 2 * edge
        let crossStart = growsTowardStart ? crossExtent - edge - restingCross : edge
        let alongExtent = length + 2 * (edge + margin)
        size = vertical ? CGSize(width: crossExtent, height: alongExtent) : CGSize(width: alongExtent, height: crossExtent)
        resting = vertical ? CGRect(x: crossStart, y: start, width: restingCross, height: length)
                           : CGRect(x: start, y: crossStart, width: length, height: restingCross)
    }

    /// Each appmark's frame in the panel (top-left origin) with the pointer at `pointer`, or at rest.
    /// The stack shifts so the spot under the pointer stays under it, as in the Dock.
    func frames(pointer: CGPoint?) -> [CGRect] {
        let restingStarts = along.indices.map { i in along[..<i].reduce(0, +) + spacing * CGFloat(i) }
        var scales = Array(repeating: CGFloat(1), count: along.count)
        var at: CGFloat = 0
        if let pointer {
            at = (vertical ? pointer.y : pointer.x) - start
            // The appmark whose resting slot, gaps split down the middle, holds the pointer.
            if let hovered = along.indices.last(where: { at >= restingStarts[$0] - spacing / 2 }) ?? along.indices.first {
                scales[hovered] = peak[hovered]
            }
        }
        var starts: [CGFloat] = []
        var cursor: CGFloat = 0
        for i in along.indices {
            starts.append(cursor)
            cursor += along[i] * scales[i] + spacing
        }
        // Where the pointer's resting spot lands once magnified; the difference pins it in place.
        var landed = at
        for i in along.indices.reversed() where at >= restingStarts[i] {
            let into = at - restingStarts[i]
            landed = into <= along[i] ? starts[i] + into * scales[i] : starts[i] + along[i] * scales[i] + (into - along[i])
            break
        }
        let shift = pointer == nil ? 0 : at - landed

        return along.indices.map { i in
            let length = along[i] * scales[i], thickness = across[i] * scales[i]
            let a = start + starts[i] + shift
            let c = growsTowardStart ? resting.maxEdge(vertical: vertical) - thickness : resting.minEdge(vertical: vertical)
            return vertical ? CGRect(x: c, y: a, width: thickness, height: length)
                            : CGRect(x: a, y: c, width: length, height: thickness)
        }
    }

    func backdrop(_ frames: [CGRect]) -> CGRect {
        frames.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -backdropPadding, dy: -backdropPadding)
    }
}

private extension CGRect {
    /// The cross-axis edges: x for a column, y for a row.
    func minEdge(vertical: Bool) -> CGFloat { vertical ? minX : minY }
    func maxEdge(vertical: Bool) -> CGFloat { vertical ? maxX : maxY }
}

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var hover: AppmarkHover
    @ObservedObject var settings = Settings.shared
    let onSelect: (CGWindowID) -> Void

    var body: some View {
        let style = settings.style
        let layout = AppmarkLayout(items: model.items, style: style)
        let frames = layout.frames(pointer: hover.pointer)
        let backdrop = layout.backdrop(frames)
        ZStack(alignment: .topLeading) {
            Group {
                if style.switcherBackground {
                    Backdrop(cornerRadius: layout.cornerRadius + 4)
                        .overlay(RoundedRectangle(cornerRadius: layout.cornerRadius + 4).strokeBorder(.primary.opacity(0.1)))
                }
            }
            .frame(width: backdrop.width, height: backdrop.height)
            .offset(x: backdrop.minX, y: backdrop.minY)
            ForEach(Array(zip(model.items, frames)), id: \.0.id) { item, frame in
                SwitcherChip(item: item, style: style, size: frame.size)
                    .offset(x: frame.minX, y: frame.minY)
                    .onTapGesture { onSelect(item.id) }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .animation(.spring(response: 0.2, dampingFraction: 0.9), value: hover.pointer)
    }
}

private struct SwitcherChip: View {
    let item: SwitcherItem
    let style: Style
    let size: CGSize

    var body: some View {
        let badge = min(size.height * 0.5, 32)
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail).resizable()
                } else {
                    RoundedRectangle(cornerRadius: style.switcherCornerRadius).fill(.regularMaterial)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: style.switcherCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: style.switcherCornerRadius).stroke(.primary.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            if style.showIcon, style.switcherShowIcon, let icon = item.icon {
                Image(nsImage: icon).resizable()
                    .frame(width: badge, height: badge)
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: size.width, height: size.height)
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
