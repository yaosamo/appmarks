import AppKit
@preconcurrency import ApplicationServices
import SwiftUI

/// Windows dropped edge to edge glue together and move as one: drag either and the other comes along,
/// bring either forward and the other comes up behind it. A lock on the seam unglues them.
///
/// The window server drags a window by its title bar on its own, so the dragged one moves every refresh;
/// its partners can only be moved through Accessibility, which waits on their app. Their moves go out on
/// a queue of their own, one at a time per window with only the latest position kept, so a slow app
/// trails a little instead of stalling the drag.
@MainActor
final class WindowGlue {
    private let element: (CGWindowID) -> AXUIElement?
    /// The windows that can glue: open, on this Space and not minimized.
    private let candidates: () -> Set<CGWindowID>
    private(set) var seams: Set<GlueSeam> = []
    var isEnabled = true {
        didSet { if !isEnabled { unglueAll() } }
    }

    /// Where each glued window was last seen, or sent.
    private var known: [CGWindowID: CGRect] = [:]
    /// Partners on their way to a position, until the window server shows them there.
    private var pending: [CGWindowID: (target: CGPoint, since: CFTimeInterval)] = [:]
    private var inFlight: Set<CGWindowID> = []
    private var queued: [CGWindowID: CGPoint] = [:]
    private let moveQueue = DispatchQueue(label: "Bubbleg.glue", qos: .userInteractive)

    private var pressFrames: [CGWindowID: CGRect]?
    private var monitors: [Any] = []
    private var timer: Timer?
    private var lastChange: CFTimeInterval = 0
    private var buttons: [GlueSeam: GlueButton] = [:]

    init(element: @escaping (CGWindowID) -> AXUIElement?, candidates: @escaping () -> Set<CGWindowID>) {
        self.element = element
        self.candidates = candidates
    }

    func start() {
        guard monitors.isEmpty else { return }
        let down = { [weak self] in MainActor.assumeIsolated { self?.pressed() } }
        let up = { [weak self] in MainActor.assumeIsolated { self?.released() } }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in down() },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in up() },
        ].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        stopTicking()
        buttons.values.forEach { $0.orderOut(nil) }
    }

    func group(of id: CGWindowID) -> Set<CGWindowID> { GlueGeometry.group(of: id, in: seams) }

    /// A glued window moved, by its app or by anything else: its partners follow.
    func windowMoved(_ id: CGWindowID) {
        guard seams.contains(where: { $0.contains(id) }) else { return }
        startTicking()
    }

    /// The window closed.
    func forget(_ id: CGWindowID) {
        for seam in seams where seam.contains(id) { remove(seam) }
        known[id] = nil
        pending[id] = nil
    }

    /// Partners of `id` with some other window over them, which bringing `id` forward should raise too.
    func coveredPartners(of id: CGWindowID) -> [CGWindowID] {
        let group = group(of: id)
        guard group.count > 1 else { return [] }
        let order = WindowServer.onScreen(candidates())
        return order.enumerated().compactMap { index, window in
            guard window.id != id, group.contains(window.id) else { return nil }
            let covered = order[..<index].contains { !group.contains($0.id) && $0.frame.intersects(window.frame) }
            return covered ? window.id : nil
        }
    }

    // MARK: Gluing

    private func pressed() {
        guard isEnabled else { return }
        pressFrames = Dictionary(WindowServer.onScreen(candidates()).map { ($0.id, $0.frame) }) { first, _ in first }
        if !seams.isEmpty { startTicking() }
    }

    /// A window dropped within reach of another's side glues onto it, flush.
    private func released() {
        guard let before = pressFrames else { return }
        pressFrames = nil
        // The window server lands the drop a moment after the button comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.glueDropped(since: before) }
        }
    }

    private func glueDropped(since before: [CGWindowID: CGRect]) {
        guard isEnabled else { return }
        let now = WindowServer.onScreen(candidates())
        let moved = now.filter { window in
            guard let was = before[window.id] else { return false }
            return was.size == window.frame.size && hypot(was.minX - window.frame.minX, was.minY - window.frame.minY) > 1
        }
        for dropped in moved {
            let group = group(of: dropped.id)
            for other in now where !group.contains(other.id) && !moved.contains(where: { $0.id == other.id }) {
                guard let snap = GlueGeometry.snap(dropped.frame, to: other.frame) else { continue }
                let seam = snap.movingFirst ? GlueSeam(first: dropped.id, second: other.id, beside: snap.beside)
                                            : GlueSeam(first: other.id, second: dropped.id, beside: snap.beside)
                glue(seam, shifting: group, by: snap.offset, frames: now)
                return
            }
        }
    }

    private func glue(_ seam: GlueSeam, shifting group: Set<CGWindowID>, by offset: CGVector, frames: [(id: CGWindowID, frame: CGRect)]) {
        let time = CACurrentMediaTime()
        for window in frames where group.contains(window.id) || seam.contains(window.id) {
            known[window.id] = window.frame
            guard group.contains(window.id), offset != .zero else { continue }
            let target = window.frame.offsetBy(dx: offset.dx, dy: offset.dy)
            known[window.id] = target
            move(window.id, to: target.origin, at: time)
        }
        seams.insert(seam)
        Click.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        lastChange = time
        startTicking()
    }

    func unglue(_ seam: GlueSeam) {
        remove(seam)
        Click.play()
    }

    private func unglueAll() {
        for seam in seams { remove(seam) }
    }

    private func remove(_ seam: GlueSeam) {
        seams.remove(seam)
        buttons.removeValue(forKey: seam)?.orderOut(nil)
        let glued = Set(seams.flatMap { [$0.first, $0.second] })
        for id in [seam.first, seam.second] where !glued.contains(id) {
            known[id] = nil
            pending[id] = nil
        }
    }

    // MARK: Following

    private func startTicking() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        lastChange = CACurrentMediaTime()
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    /// Finds the glued window that moved on its own since the last refresh, the one being dragged, and
    /// sends its partners the same distance.
    private func tick() {
        let time = CACurrentMediaTime()
        let members = Set(seams.flatMap { [$0.first, $0.second] })
        let frames = Dictionary(WindowServer.onScreen(members).map { ($0.id, $0.frame) }) { first, _ in first }

        for (id, move) in pending {
            // Still on its way: never read as the window being dragged, or it would pull that one back.
            guard !inFlight.contains(id), queued[id] == nil else { continue }
            guard let frame = frames[id] else { pending[id] = nil; continue }
            // There, or the app put it somewhere else (a screen edge, a minimum size): take where it is.
            if hypot(frame.minX - move.target.x, frame.minY - move.target.y) <= 1 || time - move.since > 0.5 {
                pending[id] = nil
                known[id] = frame
            }
        }

        let changed = frames.filter { id, frame in
            guard pending[id] == nil else { return false }
            guard let was = known[id] else { known[id] = frame; return false }
            return abs(was.minX - frame.minX) > 0.5 || abs(was.minY - frame.minY) > 0.5 || was.size != frame.size
        }
        var handled: Set<CGWindowID> = []
        for (id, frame) in changed where !handled.contains(id) {
            let group = group(of: id)
            handled.formUnion(group)
            let was = known[id]!
            known[id] = frame
            // Resized, or two of them moved at once by something else: nothing to follow.
            guard was.size == frame.size, changed.keys.filter(group.contains).count == 1 else { continue }
            let (dx, dy) = (frame.minX - was.minX, frame.minY - was.minY)
            for partner in group where partner != id {
                guard let from = known[partner] else { continue }
                let target = from.offsetBy(dx: dx, dy: dy)
                known[partner] = target
                move(partner, to: target.origin, at: time)
            }
        }

        if !changed.isEmpty {
            lastChange = time
            // The locks wait for the windows to settle rather than chase them.
            buttons.values.forEach { $0.orderOut(nil) }
        }
        let held = NSEvent.pressedMouseButtons & 1 != 0
        if !held, pending.isEmpty, inFlight.isEmpty, time - lastChange > 0.3 {
            stopTicking()
            dropPulledApart()
            refresh()
        }
    }

    /// Resized or moved apart some way the glue couldn't follow: no longer a seam.
    private func dropPulledApart() {
        let frames = Dictionary(WindowServer.onScreen(Set(seams.flatMap { [$0.first, $0.second] })).map { ($0.id, $0.frame) }) { a, _ in a }
        for seam in seams {
            guard let first = frames[seam.first], let second = frames[seam.second] else { continue }
            if !GlueGeometry.touching(first, second, beside: seam.beside) { remove(seam) }
        }
    }

    private func move(_ id: CGWindowID, to origin: CGPoint, at time: CFTimeInterval) {
        pending[id] = (origin, time)
        guard !inFlight.contains(id) else { queued[id] = origin; return }
        send(id, origin)
    }

    private func send(_ id: CGWindowID, _ origin: CGPoint) {
        guard let element = element(id) else { pending[id] = nil; return }
        inFlight.insert(id)
        moveQueue.async { [weak self] in
            element.setPosition(origin)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight.remove(id)
                    if let next = self.queued.removeValue(forKey: id) { return self.send(id, next) }
                    // The window server gets half a second from here to show it there.
                    if let move = self.pending[id] { self.pending[id] = (move.target, CACurrentMediaTime()) }
                }
            }
        }
    }

    // MARK: Locks

    /// One lock on each seam whose windows are both on screen, just above the front one, so a window in
    /// front of both covers it too.
    func refresh() {
        guard isEnabled, timer == nil else { return }
        let order = WindowServer.onScreen(Set(seams.flatMap { [$0.first, $0.second] }))
        for seam in seams {
            guard let a = order.firstIndex(where: { $0.id == seam.first }),
                  let b = order.firstIndex(where: { $0.id == seam.second })
            else { buttons[seam]?.orderOut(nil); continue }
            let point = GlueGeometry.seamPoint(order[a].frame, order[b].frame, beside: seam.beside)
            let button = buttons[seam] ?? GlueButton { [weak self] in self?.unglue(seam) }
            buttons[seam] = button
            button.show(at: point, above: order[min(a, b)].id)
        }
    }
}

/// The lock on a seam; a click unglues the two windows.
final class GlueButton: NSPanel {
    private static let size: CGFloat = 24

    init(onUnglue: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        level = .normal
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = FirstClickHostingView(rootView: GlueLock(size: Self.size, onUnglue: onUnglue))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `point` in Accessibility coordinates.
    func show(at point: CGPoint, above window: CGWindowID) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        setFrameOrigin(NSPoint(x: point.x - Self.size / 2, y: primaryHeight - point.y - Self.size / 2))
        order(.above, relativeTo: Int(window))
    }
}

private struct GlueLock: View {
    let size: CGFloat
    let onUnglue: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onUnglue) {
            Image(systemName: hovered ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(hovered ? 0.9 : 0.6))
                .frame(width: size, height: size)
                .background(Backdrop(cornerRadius: size / 2))
                .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Unglue windows")
    }
}
