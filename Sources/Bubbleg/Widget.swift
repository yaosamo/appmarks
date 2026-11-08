import AppKit
import AVFoundation
import SwiftUI

/// Where the floating bubbles rest: anywhere, or on one of the screen's eight sticky points.
enum WidgetAnchor: Equatable {
    /// The bubbles' top-left, in Accessibility coordinates, as a column or a row.
    case free(CGPoint, vertical: Bool)
    case screen(WindowSpot)

    /// The sticky point it is on, if any.
    var spot: WindowSpot? {
        if case .screen(let spot) = self { spot } else { nil }
    }
}

/// One of the screen's eight sticky points, a corner or the middle of an edge.
enum WindowSpot: String, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// 0, 0.5 or 1 along each axis.
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
    /// The frame of something `size` big at this spot of `area`, `margin` in from its edges, in
    /// top-left-origin coordinates.
    func frame(_ size: CGSize, in area: CGRect, margin: CGFloat) -> CGRect {
        let x: CGFloat = switch unit.x {
        case 0: area.minX + margin
        case 1: area.maxX - margin - size.width
        default: area.midX - size.width / 2
        }
        let y: CGFloat = switch unit.y {
        case 0: area.minY + margin
        case 1: area.maxY - margin - size.height
        default: area.midY - size.height / 2
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

final class WidgetModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
    @Published var vertical = false
    @Published var growsTowardStart = false
    func layout(_ style: Style) -> BubbleLayout {
        BubbleLayout(items: items, style: style, vertical: vertical, growsTowardStart: growsTowardStart)
    }

}

/// Every open window as a bubble in one panel that floats above other windows. Drag it anywhere; near a
/// screen edge's middle or a corner it sticks there.
final class WidgetPanel: NSPanel {
    private static let margin: CGFloat = 8
    /// How close the bubbles have to come to a sticky point to snap.
    private static let pointReach: CGFloat = 40
    /// How close the pointer has to come to a display edge for the bubbles to turn along it.
    private static let turnReach: CGFloat = 120
    /// How far they have to be pulled off a snap to come free again.
    private static let release: CGFloat = 64
    private static let defaultsKey = "widgetAnchor"

    private struct Placement {
        var body: CGRect
        var vertical: Bool
        var growsTowardStart: Bool
    }

    private struct Drag {
        let start: CGPoint
        /// Where on the bubbles they were grabbed, as fractions along and across the stack, so the
        /// grab point stays under the pointer when a snap turns a row into a column.
        let grab: (along: CGFloat, across: CGFloat)
        var moved = false
    }

    private let model = WidgetModel()
    private let hover = BubbleHover()
    private let transfers = Transfers.shared
    private let tip = TransferTip()
    private let onSelect: (CGWindowID) -> Void
    private var style = Style()
    private var layout = BubbleLayout(items: [], style: Style(), vertical: false, growsTowardStart: false)
    private var anchor: WidgetAnchor
    private var placement: Placement?
    private var drag: Drag?
    private var monitors: [Any] = []
    private var audioAwake = false

    init(onSelect: @escaping (CGWindowID) -> Void) {
        self.onSelect = onSelect
        let (anchor, vertical) = Self.restore()
        self.anchor = anchor
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        model.vertical = vertical
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        contentView = FirstClickHostingView(rootView: WidgetView(model: model, hover: hover))
        Click.prepare()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(items: [SwitcherItem], style: Style) {
        guard !items.isEmpty else { return orderOut(nil) }
        let changed = items != model.items || style != self.style || !isVisible
        if items != model.items { model.items = items }
        self.style = style
        if changed { relayout() }
        trackPointer()
    }

    override func orderOut(_ sender: Any?) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hover.hovered = nil
        hover.transfer = nil
        tip.hide()
        drag = nil
        keepAudioAwake(false)
        super.orderOut(sender)
    }

    // MARK: Placement

    private func relayout() {
        apply(resolve(anchor))
    }

    private func resolve(_ anchor: WidgetAnchor) -> Placement {
        switch anchor {
        case .free(let origin, let vertical):
            let screen = Geometry.belowMenuBar
            let body = clamped(CGRect(origin: origin, size: bodySize(vertical: vertical)), to: screen)
            // Hovered bubbles grow toward the middle of the screen.
            return Placement(body: body, vertical: vertical,
                             growsTowardStart: vertical ? body.midX > screen.midX : body.midY > screen.midY)
        case .screen(let spot):
            let vertical = isVertical(spot)
            let body = spot.frame(bodySize(vertical: vertical), in: area(of: spot), margin: Self.margin)
            return Placement(body: body, vertical: vertical, growsTowardStart: (vertical ? spot.unit.x : spot.unit.y) == 1)
        }
    }

    /// The middle of an edge sits clear of the Dock, on top of it at the bottom; a corner goes right
    /// into the screen's corner, beside the Dock.
    private func area(of spot: WindowSpot) -> CGRect {
        spot.unit.x != 0.5 && spot.unit.y != 0.5 ? Geometry.belowMenuBar : Geometry.visibleArea
    }

    /// A column on the screen's left and right, a row on its top and bottom; a corner keeps either.
    private func isVertical(_ spot: WindowSpot) -> Bool {
        spot.unit.x == 0.5 ? false : spot.unit.y == 0.5 ? true : model.vertical
    }

    /// The resting bubbles and their backdrop: what snaps, as opposed to the panel's room to grow.
    private func bodySize(vertical: Bool) -> CGSize {
        let layout = BubbleLayout(items: model.items, style: style, vertical: vertical, growsTowardStart: false)
        return layout.resting.insetBy(dx: -layout.backdropPadding, dy: -layout.backdropPadding).size
    }

    private func clamped(_ rect: CGRect, to area: CGRect) -> CGRect {
        var rect = rect
        rect.origin.x = max(area.minX, min(rect.minX, area.maxX - rect.width))
        rect.origin.y = max(area.minY, min(rect.minY, area.maxY - rect.height))
        return rect
    }

    private func apply(_ next: Placement) {
        if model.vertical != next.vertical { model.vertical = next.vertical }
        if model.growsTowardStart != next.growsTowardStart { model.growsTowardStart = next.growsTowardStart }
        placement = next
        layout = model.layout(style)
        let pinned = layout.resting.insetBy(dx: -layout.backdropPadding, dy: -layout.backdropPadding)
        let primaryHeight = NSScreen.screens[0].frame.height
        setFrame(NSRect(x: next.body.minX - pinned.minX, y: primaryHeight - (next.body.minY - pinned.minY) - layout.size.height,
                        width: layout.size.width, height: layout.size.height), display: true)
        stack()
    }

    /// Above every window and on every Space, never a tile of its own in Mission Control.
    private func stack() {
        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        if collectionBehavior != behavior { collectionBehavior = behavior }
        if level != .floating { level = .floating }
        orderFrontRegardless()
    }

    private func keepAudioAwake(_ awake: Bool) {
        guard awake != audioAwake else { return }
        audioAwake = awake
        Click.keepAwake(awake)
    }

    // MARK: Pointer

    private static var pointer: CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x, y: NSScreen.screens[0].frame.height - mouse.y)
    }

    private var localPointer: CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }

    /// Most of the panel is clear room to grow, and the pointer over a clear pixel belongs to the window
    /// underneath, so SwiftUI hover would miss it leaving. Every move is checked against the bubbles'
    /// outline instead.
    private func trackPointer() {
        guard monitors.isEmpty else { return }
        let moved = { [weak self] in MainActor.assumeIsolated { self?.pointerMoved() } }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in moved() },
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in moved(); return event },
        ].compactMap { $0 }
    }

    private func pointerMoved() {
        guard drag == nil else { return }
        let local = localPointer
        // A drag starts with the pointer over the bubbles, so that is when the audio output wakes for its click.
        keepAudioAwake(layout.backdrop(layout.frames(hovered: hover.hovered)).insetBy(dx: -24, dy: -24).contains(local))
        let bars = TransferBars.frames(count: transfers.items.count, on: layout.backdrop(layout.frames(hovered: hover.hovered)),
                                       cornerRadius: layout.cornerRadius + 4)
        let index = TransferBars.index(at: local, in: bars)
        let bar = index.map { transfers.items[$0].id }
        if bar != hover.transfer {
            hover.transfer = bar
            if let bar, let index {
                let rect = bars[index]
                tip.show(bar, above: CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height),
                         level: level)
            } else {
                tip.hide()
            }
        }
        let hovered = bar == nil ? layout.item(at: local, hovered: hover.hovered) : nil
        if hovered != hover.hovered { hover.hovered = hovered }
    }

    // MARK: Dragging

    /// The panel takes the mouse itself rather than leaving it to SwiftUI, so one press is either a
    /// click on a bubble or a drag of the whole set, never both.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: pressed()
        case .leftMouseDragged: dragged()
        case .leftMouseUp: released()
        default: super.sendEvent(event)
        }
    }

    private func pressed() {
        guard let placement else { return }
        let pointer = Self.pointer, body = placement.body
        let x = min(max((pointer.x - body.minX) / body.width, 0), 1)
        let y = min(max((pointer.y - body.minY) / body.height, 0), 1)
        drag = Drag(start: pointer, grab: placement.vertical ? (y, x) : (x, y))
    }

    private func dragged() {
        guard var drag else { return }
        let pointer = Self.pointer
        if !drag.moved {
            guard hypot(pointer.x - drag.start.x, pointer.y - drag.start.y) > 3 else { return }
            drag.moved = true
            self.drag = drag
            keepAudioAwake(true)
            hover.hovered = nil
            hover.transfer = nil
            tip.hide()
        }
        let next = snap(pointer, drag)
        if let spot = next.spot, spot != anchor.spot {
            Click.play()
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        anchor = next
        // Under the pointer at once: easing after it here only reads as lag.
        apply(resolve(anchor))
    }

    private func released() {
        guard let drag else { return }
        self.drag = nil
        if drag.moved { return save() }
        // A bar shows its file in Finder.
        if let id = hover.transfer {
            if let url = transfers.items.first(where: { $0.id == id })?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return
        }
        if let id = layout.item(at: localPointer, hovered: hover.hovered) { onSelect(id) }
    }

    /// Where the pointer takes the bubbles: held on the current snap until pulled clearly off it, then
    /// onto the nearest sticky point or nowhere in particular.
    private func snap(_ pointer: CGPoint, _ drag: Drag) -> WidgetAnchor {
        switch anchor {
        case .screen(let spot):
            if distance(from: point(of: spot), to: freeBody(pointer, vertical: isVertical(spot), drag)) < Self.release {
                return anchor
            }
        case .free:
            break
        }
        for spot in WindowSpot.allCases
        where distance(from: point(of: spot), to: freeBody(pointer, vertical: isVertical(spot), drag)) < Self.pointReach {
            return .screen(spot)
        }
        let vertical = facing(pointer) ?? model.vertical
        return .free(freeBody(pointer, vertical: vertical, drag).origin, vertical: vertical)
    }

    /// With the pointer near a display edge, the bubbles turn to lie along it: a column by the left and
    /// right edges, a row by the top and bottom. Nil away from every edge, where they keep their shape.
    private func facing(_ pointer: CGPoint) -> Bool? {
        let screen = Geometry.belowMenuBar
        let side = min(pointer.x - screen.minX, screen.maxX - pointer.x)
        let end = min(pointer.y - screen.minY, screen.maxY - pointer.y)
        guard min(side, end) < Self.turnReach else { return nil }
        // In a corner, the shape they already have wins a near tie, so they don't flicker between the two.
        return model.vertical ? side < end + 24 : side + 24 < end
    }

    /// The bubbles under the pointer, as a row or a column, held where they were grabbed.
    private func freeBody(_ pointer: CGPoint, vertical: Bool, _ drag: Drag) -> CGRect {
        let size = bodySize(vertical: vertical)
        let (x, y) = vertical ? (drag.grab.across, drag.grab.along) : (drag.grab.along, drag.grab.across)
        return CGRect(x: pointer.x - x * size.width, y: pointer.y - y * size.height, width: size.width, height: size.height)
    }

    private func point(of spot: WindowSpot) -> CGPoint {
        let screen = area(of: spot)
        return CGPoint(x: screen.minX + screen.width * spot.unit.x, y: screen.minY + screen.height * spot.unit.y)
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }

    // MARK: Saving

    private func save() {
        guard let placement else { return }
        var saved: [String: Any] = ["vertical": model.vertical]
        switch anchor {
        case .screen(let spot):
            saved["spot"] = spot.rawValue
        case .free:
            saved["x"] = placement.body.minX
            saved["y"] = placement.body.minY
        }
        UserDefaults.standard.set(saved, forKey: Self.defaultsKey)
    }

    private static func restore() -> (WidgetAnchor, Bool) {
        let saved = UserDefaults.standard.dictionary(forKey: defaultsKey)
        let vertical = saved?["vertical"] as? Bool ?? false
        if let raw = saved?["spot"] as? String, let spot = WindowSpot(rawValue: raw) { return (.screen(spot), vertical) }
        if let x = saved?["x"] as? Double, let y = saved?["y"] as? Double { return (.free(CGPoint(x: x, y: y), vertical: vertical), vertical) }
        return (.screen(.bottom), false)
    }
}

/// The click for every snap, `Resources/click.wav` in the app bundle. It plays on its own queue:
/// starting the audio output can take most of a second, which on the main thread froze the drag at
/// the very moment of the snap.
private enum Click {
    private static let queue = DispatchQueue(label: "Bubbleg.click", qos: .userInteractive)
    private static var player: AVAudioPlayer?
    /// The click on a silent loop, so the audio output, which sleeps when idle and takes up to half a
    /// second to wake, is already running when the bubbles snap.
    private static var silence: AVAudioPlayer?

    static func prepare() {
        queue.async {
            guard let url = Bundle.main.url(forResource: "click", withExtension: "wav") else {
                return Log.write("click.wav missing from the app bundle")
            }
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            silence = try? AVAudioPlayer(contentsOf: url)
            silence?.volume = 0
            silence?.numberOfLoops = -1
        }
    }

    /// Wakes the audio output while the pointer is on the bubbles or dragging them.
    static func keepAwake(_ awake: Bool) {
        queue.async {
            if awake { silence?.play() } else { silence?.stop() }
        }
    }

    static func play() {
        queue.async {
            player?.currentTime = 0
            player?.play()
        }
    }
}

private struct WidgetView: View {
    @ObservedObject var model: WidgetModel
    @ObservedObject var hover: BubbleHover
    @ObservedObject var settings = Settings.shared
    @ObservedObject var transfers = Transfers.shared

    var body: some View {
        let style = settings.style
        let layout = model.layout(style)
        let frames = layout.frames(hovered: hover.hovered)
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
            }
            let bars = TransferBars.frames(count: transfers.items.count, on: backdrop, cornerRadius: layout.cornerRadius + 4)
            ForEach(Array(zip(transfers.items, bars)), id: \.0.id) { transfer, bar in
                TransferBar(fraction: transfer.fraction, size: bar.size, highlighted: hover.transfer == transfer.id)
                    .offset(x: bar.minX, y: bar.minY)
                    .transition(.opacity)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .animation(.spring(response: 0.2, dampingFraction: 0.9), value: hover.hovered)
        .animation(.easeOut(duration: 0.15), value: hover.transfer)
        .animation(.easeOut(duration: 0.25), value: transfers.items.map(\.id))
    }
}
