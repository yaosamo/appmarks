import AppKit
import AVFoundation
import SwiftUI

/// Where the floating appmarks rest: anywhere, on one of the screen's eight sticky points, or on a side
/// of a window, which they then follow like the attached appmarks do.
enum WidgetAnchor: Equatable {
    /// The appmarks' top-left, in Accessibility coordinates, as a column or a row.
    case free(CGPoint, vertical: Bool)
    case screen(WindowSpot)
    /// On `side` (`.top`, `.right`, `.bottom` or `.left`) of the active window, moving to each window
    /// that becomes active; `offset` is how far along that side, from 0 at its start to 1 at its end.
    case window(CGWindowID, side: WindowSpot, offset: CGFloat)

    /// What it is snapped to, ignoring the slide along a window's side, so a new value is a new snap.
    var snap: String? {
        switch self {
        case .free: nil
        case .screen(let spot): "screen \(spot)"
        case .window(let id, let side, _): "\(id) \(side)"
        }
    }
}

final class WidgetModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
    @Published var vertical = false
    @Published var growsTowardStart = false
    /// Tucked inside a window with no room outside it, the appmarks fold into a line until hovered.
    @Published var collapsed = false

    func layout(_ style: Style) -> AppmarkLayout {
        AppmarkLayout(items: items, style: style, vertical: vertical, growsTowardStart: growsTowardStart)
    }

    /// The folded line, centred on the appmarks and against the window edge they are tucked inside.
    func line(in resting: CGRect) -> CGRect {
        let thickness: CGFloat = 6
        if vertical {
            let length = min(resting.height, 56)
            return CGRect(x: growsTowardStart ? resting.maxX - thickness : resting.minX, y: resting.midY - length / 2,
                          width: thickness, height: length)
        }
        let length = min(resting.width, 56)
        return CGRect(x: resting.midX - length / 2, y: growsTowardStart ? resting.maxY - thickness : resting.minY,
                      width: length, height: thickness)
    }
}

/// Every open window as an appmark in one panel that floats on screen. Drag it anywhere; near a screen
/// edge's middle or a corner it sticks there, and near a window's side it clicks onto it, slides along
/// it and follows the window around.
final class WidgetPanel: NSPanel {
    private static let margin: CGFloat = 8
    /// How close the appmarks have to come to a sticky point, and to a window's side, to snap.
    private static let pointReach: CGFloat = 40
    /// How close the pointer has to come to a display edge for the appmarks to turn along it.
    private static let turnReach: CGFloat = 120
    private static let edgeReach: CGFloat = 24
    /// How far they have to be pulled off a snap to come free again.
    private static let release: CGFloat = 64
    private static let defaultsKey = "widgetAnchor"

    private struct Placement {
        var body: CGRect
        var vertical: Bool
        var growsTowardStart: Bool
        var host: CGWindowID?
        var hostFrame: CGRect?
        var tucked = false
    }

    private struct Drag {
        let start: CGPoint
        /// Where on the appmarks they were grabbed, as fractions along and across the stack, so the
        /// grab point stays under the pointer when a snap turns a row into a column.
        let grab: (along: CGFloat, across: CGFloat)
        /// Snap targets, front to back; nothing else moves while the appmarks are dragged.
        let windows: [(id: CGWindowID, frame: CGRect)]
        var moved = false
    }

    private let model = WidgetModel()
    private let hover = AppmarkHover()
    private let onSelect: (CGWindowID) -> Void
    private let snapTargets: () -> [(id: CGWindowID, frame: CGRect)]
    private var style = Style()
    private var layout = AppmarkLayout(items: [], style: Style())
    private var anchor: WidgetAnchor
    private var placement: Placement?
    private var drag: Drag?
    private var monitors: [Any] = []
    private var link: CADisplayLink?
    private var lastChange = Date.distantPast
    private var target = NSRect.zero
    private var audioAwake = false

    init(onSelect: @escaping (CGWindowID) -> Void, snapTargets: @escaping () -> [(id: CGWindowID, frame: CGRect)]) {
        self.onSelect = onSelect
        self.snapTargets = snapTargets
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

    func update(items: [SwitcherItem], focused: CGWindowID?, style: Style) {
        guard !items.isEmpty else { return orderOut(nil) }
        var moved = false
        if case .window(let host, let side, let offset) = anchor, drag == nil {
            if let focused, focused != host, items.contains(where: { $0.id == focused && !$0.isMinimized }) {
                anchor = .window(focused, side: side, offset: offset)
                moved = true
            } else if !items.contains(where: { $0.id == host && !$0.isMinimized }) {
                // The window closed or minimized and no other is active: out of sight until one is.
                return orderOut(nil)
            }
        }
        let changed = moved || items != model.items || style != self.style || !isVisible
        if items != model.items { model.items = items }
        self.style = style
        if changed {
            relayout()
        } else {
            // Focusing the host window raises it over the appmarks.
            stack(above: placement?.host)
        }
        trackPointer()
    }

    /// The host window moved or resized: glide after it, as `SwitcherPanel.follow` does.
    func follow() {
        guard case .window = anchor else { return }
        lastChange = Date()
        startLink()
    }

    override func orderOut(_ sender: Any?) {
        link?.invalidate()
        link = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hover.hovered = nil
        drag = nil
        keepAudioAwake(false)
        super.orderOut(sender)
    }

    // MARK: Placement

    private func relayout(glide: Bool = false) {
        // The window closed under them: hidden until the next active window, which `update` brings.
        if case .window(let id, _, _) = anchor, WindowServer.frames(of: [id]).isEmpty { return orderOut(nil) }
        apply(resolve(anchor), glide: glide)
    }

    private func resolve(_ anchor: WidgetAnchor) -> Placement {
        switch anchor {
        case .free(let origin, let vertical):
            let screen = Geometry.belowMenuBar
            let body = clamped(CGRect(origin: origin, size: bodySize(vertical: vertical)), to: screen)
            // Hovered appmarks grow toward the middle of the screen.
            return Placement(body: body, vertical: vertical,
                             growsTowardStart: vertical ? body.midX > screen.midX : body.midY > screen.midY)
        case .screen(let spot):
            let vertical = isVertical(spot)
            let body = spot.frame(bodySize(vertical: vertical), on: area(of: spot), inside: true, gap: Self.margin, inset: Self.margin)
            return Placement(body: body, vertical: vertical, growsTowardStart: (vertical ? spot.unit.x : spot.unit.y) == 1)
        case .window(let id, let side, let offset):
            // Nothing else moves during a drag, and asking the window server right after moving the panel
            // waits out the move, about a frame, on every mouse event.
            guard let window = drag?.windows.first(where: { $0.id == id })?.frame ?? WindowServer.frames(of: [id]).first
            else { return resolve(.free(placement?.body.origin ?? .zero, vertical: model.vertical)) }
            return onWindow(window, id: id, side: side, offset: offset)
        }
    }

    /// Outside `side` of the window, `offset` of the way along it; inside, tucked, when the
    /// window leaves no room on the screen outside that side.
    private func onWindow(_ window: CGRect, id: CGWindowID, side: WindowSpot, offset: CGFloat) -> Placement {
        let vertical = side.isVertical
        let size = bodySize(vertical: vertical)
        let screen = Geometry.visibleArea
        let gap = style.switcherOffsetX

        let (start, length, own) = vertical ? (window.minY, window.height, size.height) : (window.minX, window.width, size.width)
        var along = start + (length - own) * (own > length ? 0.5 : min(max(offset, 0), 1))
        let (screenStart, screenEnd) = vertical ? (screen.minY, screen.maxY) : (screen.minX, screen.maxX)
        along = max(screenStart, min(along, screenEnd - own))

        let before = side == .left || side == .top
        let (edgeMin, edgeMax, thickness) = vertical ? (window.minX, window.maxX, size.width) : (window.minY, window.maxY, size.height)
        let (crossStart, crossEnd) = vertical ? (screen.minX, screen.maxX) : (screen.minY, screen.maxY)
        let outside = before ? edgeMin - gap - thickness : edgeMax + gap
        let fits = outside >= crossStart && outside + thickness <= crossEnd
        let across = fits ? outside : before ? edgeMin + gap : edgeMax - gap - thickness

        let body = vertical ? CGRect(x: across, y: along, width: size.width, height: size.height)
                            : CGRect(x: along, y: across, width: size.width, height: size.height)
        // Hovered appmarks grow away from the window outside it, and into it when tucked.
        return Placement(body: body, vertical: vertical, growsTowardStart: before == fits,
                         host: id, hostFrame: window, tucked: !fits)
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

    /// The resting appmarks and their backdrop: what snaps, as opposed to the panel's room to grow.
    private func bodySize(vertical: Bool) -> CGSize {
        let layout = AppmarkLayout(items: model.items, style: style, vertical: vertical, growsTowardStart: false)
        return layout.resting.insetBy(dx: -layout.backdropPadding, dy: -layout.backdropPadding).size
    }

    private func clamped(_ rect: CGRect, to area: CGRect) -> CGRect {
        var rect = rect
        rect.origin.x = max(area.minX, min(rect.minX, area.maxX - rect.width))
        rect.origin.y = max(area.minY, min(rect.minY, area.maxY - rect.height))
        return rect
    }

    private func apply(_ next: Placement, glide: Bool) {
        let restack = drag == nil || next.host != placement?.host
        if model.vertical != next.vertical { model.vertical = next.vertical }
        if model.growsTowardStart != next.growsTowardStart { model.growsTowardStart = next.growsTowardStart }
        if !next.tucked {
            setCollapsed(false)
        } else if placement?.tucked != true, drag == nil {
            setCollapsed(true)
        }
        placement = next
        layout = model.layout(style)
        let pinned = layout.resting.insetBy(dx: -layout.backdropPadding, dy: -layout.backdropPadding)
        let primaryHeight = NSScreen.screens[0].frame.height
        target = NSRect(x: next.body.minX - pinned.minX, y: primaryHeight - (next.body.minY - pinned.minY) - layout.size.height,
                        width: layout.size.width, height: layout.size.height)
        if glide, isVisible {
            startLink()
        } else {
            setFrame(target, display: true)
        }
        if restack { stack(above: next.host) }
    }

    /// On a window, directly above it at normal level, so windows in front of it cover the appmarks too;
    /// anywhere else, above every window and on every Space.
    private func stack(above host: CGWindowID?) {
        let behavior: NSWindow.CollectionBehavior = host == nil ? [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
                                                                : [.ignoresCycle, .fullScreenAuxiliary]
        if collectionBehavior != behavior { collectionBehavior = behavior }
        if let host {
            if level != .normal { level = .normal }
            order(.above, relativeTo: Int(host))
        } else {
            if level != .floating { level = .floating }
            orderFrontRegardless()
        }
    }

    private func keepAudioAwake(_ awake: Bool) {
        guard awake != audioAwake else { return }
        audioAwake = awake
        Click.keepAwake(awake)
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard model.collapsed != collapsed else { return }
        model.collapsed = collapsed
        if collapsed { hover.hovered = nil }
    }

    // MARK: Gliding

    private func startLink() {
        guard link == nil, isVisible else { return }
        link = NSScreen.screens[0].displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        if case .window(let id, _, _) = anchor, drag == nil {
            guard let window = WindowServer.frames(of: [id]).first else { return relayout() }
            if window != placement?.hostFrame {
                apply(resolve(anchor), glide: true)
                lastChange = Date()
            }
        }
        step(seconds: link.targetTimestamp - link.timestamp)
        if frame.origin == target.origin, Date().timeIntervalSince(lastChange) > 0.3 {
            link.invalidate()
            self.link = nil
        }
    }

    private func step(seconds: Double) {
        let pull = 1 - exp(-max(seconds, 1 / 240) / 0.035)
        var origin = frame.origin
        origin.x += (target.minX - origin.x) * pull
        origin.y += (target.minY - origin.y) * pull
        if abs(target.minX - origin.x) < 0.5, abs(target.minY - origin.y) < 0.5 { origin = target.origin }
        setFrame(NSRect(origin: origin, size: target.size), display: true)
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

    /// As in `SwitcherPanel`: the clear room to grow belongs to the window underneath, so every move is
    /// checked against the appmarks' outline rather than left to SwiftUI hover.
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
        // A drag starts with the pointer over the appmarks, so that is when the audio output wakes for its click.
        keepAudioAwake(layout.backdrop(layout.frames(hovered: hover.hovered)).insetBy(dx: -24, dy: -24).contains(local))
        if model.collapsed {
            if model.line(in: layout.resting).insetBy(dx: -8, dy: -8).contains(local) { setCollapsed(false) }
            return
        }
        if placement?.tucked == true,
           !layout.backdrop(layout.frames(hovered: hover.hovered)).insetBy(dx: -16, dy: -16).contains(local) {
            return setCollapsed(true)
        }
        let hovered = layout.item(at: local, hovered: hover.hovered)
        if hovered != hover.hovered { hover.hovered = hovered }
    }

    // MARK: Dragging

    /// The panel takes the mouse itself rather than leaving it to SwiftUI, so one press is either a
    /// click on an appmark or a drag of the whole set, never both.
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
        let ids = Set(model.items.map(\.id))
        drag = Drag(start: pointer, grab: placement.vertical ? (y, x) : (x, y),
                    windows: snapTargets().filter { ids.contains($0.id) })
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
            setCollapsed(false)
        }
        let next = snap(pointer, drag)
        if let snap = next.snap, snap != anchor.snap {
            Click.play()
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        anchor = next
        // Under the pointer at once: easing after it here only reads as lag.
        apply(resolve(anchor), glide: false)
    }

    private func released() {
        guard let drag else { return }
        self.drag = nil
        if drag.moved { return save() }
        if model.collapsed { return setCollapsed(false) }
        if let id = layout.item(at: localPointer, hovered: hover.hovered) { onSelect(id) }
    }

    /// Where the pointer takes the appmarks: held on the current snap until pulled clearly off it, then
    /// onto the nearest sticky point, the side of the frontmost window it reaches, or nowhere in particular.
    private func snap(_ pointer: CGPoint, _ drag: Drag) -> WidgetAnchor {
        switch anchor {
        case .screen(let spot):
            if distance(from: point(of: spot), to: freeBody(pointer, vertical: isVertical(spot), drag)) < Self.release {
                return anchor
            }
        case .window(let id, let side, _):
            if let window = drag.windows.first(where: { $0.id == id }),
               let offset = offset(pointer, drag, along: side, of: window.frame, reach: Self.release) {
                return .window(id, side: side, offset: offset)
            }
        case .free:
            break
        }
        for spot in WindowSpot.allCases
        where distance(from: point(of: spot), to: freeBody(pointer, vertical: isVertical(spot), drag)) < Self.pointReach {
            return .screen(spot)
        }
        for (index, window) in drag.windows.enumerated() {
            for side in [WindowSpot.top, .right, .bottom, .left] {
                guard let offset = offset(pointer, drag, along: side, of: window.frame, reach: Self.edgeReach) else { continue }
                // Not onto the side of a window hidden behind another one.
                let spot = onWindow(window.frame, id: window.id, side: side, offset: offset).body
                if drag.windows[..<index].contains(where: { $0.frame.contains(CGPoint(x: spot.midX, y: spot.midY)) }) { continue }
                return .window(window.id, side: side, offset: offset)
            }
        }
        let vertical = facing(pointer) ?? model.vertical
        return .free(freeBody(pointer, vertical: vertical, drag).origin, vertical: vertical)
    }

    /// With the pointer near a display edge, the appmarks turn to lie along it: a column by the left and
    /// right edges, a row by the top and bottom. Nil away from every edge, where they keep their shape.
    private func facing(_ pointer: CGPoint) -> Bool? {
        let screen = Geometry.belowMenuBar
        let side = min(pointer.x - screen.minX, screen.maxX - pointer.x)
        let end = min(pointer.y - screen.minY, screen.maxY - pointer.y)
        guard min(side, end) < Self.turnReach else { return nil }
        // In a corner, the shape they already have wins a near tie, so they don't flicker between the two.
        return model.vertical ? side < end + 24 : side + 24 < end
    }

    /// Where along `side` the appmarks would start, if the pointer has them within `reach` of it.
    private func offset(_ pointer: CGPoint, _ drag: Drag, along side: WindowSpot, of window: CGRect, reach: CGFloat) -> CGFloat? {
        let vertical = side.isVertical
        let body = freeBody(pointer, vertical: vertical, drag)
        let snapped = onWindow(window, id: 0, side: side, offset: 0).body
        let gap = vertical ? abs(body.minX - snapped.minX) : abs(body.minY - snapped.minY)
        let overlaps = vertical ? body.maxY > window.minY && body.minY < window.maxY
                                : body.maxX > window.minX && body.minX < window.maxX
        guard gap < reach, overlaps else { return nil }
        let (start, room) = vertical ? (body.minY - window.minY, window.height - body.height)
                                     : (body.minX - window.minX, window.width - body.width)
        return room > 0 ? min(max(start / room, 0), 1) : 0.5
    }

    /// The appmarks under the pointer, as a row or a column, held where they were grabbed.
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
        case .window(_, let side, let offset):
            saved["side"] = side.rawValue
            saved["offset"] = offset
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
        // Picked up by the first active window.
        if let raw = saved?["side"] as? String, let side = WindowSpot(rawValue: raw) {
            return (.window(0, side: side, offset: saved?["offset"] as? Double ?? 0.5), vertical)
        }
        if let x = saved?["x"] as? Double, let y = saved?["y"] as? Double { return (.free(CGPoint(x: x, y: y), vertical: vertical), vertical) }
        return (.screen(.bottom), false)
    }
}

/// A short, dry tick for every snap, made here because macOS ships no plain click sound.
/// It plays on its own queue: starting the audio output can take most of a second, which on the main
/// thread froze the drag at the very moment of the snap.
private enum Click {
    private static let queue = DispatchQueue(label: "Appmarks.click", qos: .userInteractive)
    private static var player: AVAudioPlayer?
    /// Silence on a loop, so the audio output, which sleeps when idle and takes up to half a second
    /// to wake, is already running when the appmarks snap.
    private static var silence: AVAudioPlayer?

    static func prepare() {
        queue.async {
            player = try? AVAudioPlayer(data: wav)
            player?.prepareToPlay()
            silence = try? AVAudioPlayer(data: wav)
            silence?.volume = 0
            silence?.numberOfLoops = -1
        }
    }

    /// Wakes the audio output while the pointer is on the appmarks or dragging them.
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

    private static let wav: Data = {
        let rate = 44_100, count = rate * 15 / 1000
        var samples = [Int16]()
        var noise: UInt32 = 0x1234_5678
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            noise = noise &* 1_664_525 &+ 1_013_904_223
            let hiss = Double(noise >> 8) / Double(1 << 24) * 2 - 1
            let value = (sin(2 * .pi * 2_400 * t) * 0.7 + hiss * 0.3) * exp(-t / 0.0022)
            samples.append(Int16(value * 0.6 * Double(Int16.max)))
        }
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        let bytes = UInt32(count * 2)
        wav.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(bytes)
        samples.forEach(append)
        return wav
    }()
}

private struct WidgetView: View {
    @ObservedObject var model: WidgetModel
    @ObservedObject var hover: AppmarkHover
    @ObservedObject var settings = Settings.shared

    var body: some View {
        let style = settings.style
        let layout = model.layout(style)
        let frames = layout.frames(hovered: hover.hovered)
        let backdrop = layout.backdrop(frames)
        let line = model.line(in: layout.resting)
        ZStack(alignment: .topLeading) {
            if model.collapsed {
                Backdrop(cornerRadius: min(line.width, line.height) / 2)
                    .overlay(Capsule().fill(.primary.opacity(0.35)))
                    .frame(width: line.width, height: line.height)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .offset(x: line.minX, y: line.minY)
                    .transition(.opacity)
            } else {
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
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .animation(.spring(response: 0.2, dampingFraction: 0.9), value: hover.hovered)
        .animation(.snappy(duration: 0.2), value: model.collapsed)
    }
}
