import Carbon
import CoreGraphics
import Foundation

/// Active event taps for what SideStage has to see before the target app does: the minimize button and
/// ⌘M, so a window goes to the strip without the Dock's genie, and the Mission Control key, so parked
/// windows are back on screen before Mission Control lays them out. Mouse and keyboard get separate
/// taps so that if the keyboard one is refused the click path still works.
@MainActor
final class EventInterceptor {
    private static let missionControlKey: Int64 = 160
    private static let replayMark: Int64 = 0x5344_5354
    private static let missionControlExitKeys: Set<Int64> = [Int64(kVK_Escape), Int64(kVK_Return), missionControlKey]

    private let manager: StageManager
    private var taps: [CFMachPort] = []
    private var swallowMouseUp = false
    private var mouseDownAt: CGPoint?
    private var draggedWindow: CGWindowID?
    private var dragChecked = false

    init(manager: StageManager) {
        self.manager = manager
    }

    func start() {
        guard taps.isEmpty else { return }
        addTap(for: [.leftMouseDown, .leftMouseUp, .leftMouseDragged])
        addTap(for: [.keyDown])
    }

    private func addTap(for types: [CGEventType]) {
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            let interceptor = Unmanaged<EventInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
            return MainActor.assumeIsolated { interceptor.handle(type, event) }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Log.write("event tap for \(types.map(\.rawValue)) refused; minimize will use the Dock fallback")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        taps.append(tap)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            taps.forEach { CGEvent.tapEnable(tap: $0, enable: true) }
        case .keyDown where event.getIntegerValueField(.eventSourceUserData) == Self.replayMark:
            break
        case .leftMouseDown where manager.isInMissionControl:
            manager.scheduleMissionControlEnd()
        case .keyDown where manager.isInMissionControl:
            if Self.missionControlExitKeys.contains(key) || isControlUp(event) { manager.scheduleMissionControlEnd() }
        case .keyDown where (key == Self.missionControlKey || isControlUp(event)) && manager.beginMissionControl():
            replay(event)
            return nil
        case .leftMouseDown where manager.parkIfMinimizeButton(at: event.location):
            swallowMouseUp = true
            return nil
        case .leftMouseUp where swallowMouseUp:
            swallowMouseUp = false
            return nil
        case .leftMouseDown:
            mouseDownAt = event.location
            draggedWindow = nil
            dragChecked = false
        case .leftMouseDragged:
            trackWindowDrag(to: event.location)
        case .leftMouseUp:
            if let id = draggedWindow, let start = mouseDownAt {
                manager.windowDragEnded(id, at: event.location,
                                        movedBy: CGVector(dx: event.location.x - start.x, dy: event.location.y - start.y))
            }
            mouseDownAt = nil
            draggedWindow = nil
        case .keyDown where isCommandM(event) && manager.parkFocusedIfMinimizeShortcut():
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Drag events arrive at pointer rate, so the one Accessibility lookup (is this a title-bar drag?)
    /// happens once per drag, after the pointer has travelled far enough to rule out a click.
    private func trackWindowDrag(to point: CGPoint) {
        guard let start = mouseDownAt else { return }
        if !dragChecked, hypot(point.x - start.x, point.y - start.y) > 6 {
            dragChecked = true
            draggedWindow = manager.stageWindowTitleBar(at: start)
        }
        if draggedWindow != nil { manager.setDropTarget(point.x < Geometry.stripWidth) }
    }

    /// Re-sends the Mission Control key once the parked windows are back on screen, marked so it passes.
    private func replay(_ event: CGEvent) {
        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for down in [true, false] {
                guard let copy = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
                copy.flags = flags
                copy.setIntegerValueField(.eventSourceUserData, value: Self.replayMark)
                copy.post(tap: .cghidEventTap)
            }
        }
    }

    private func isControlUp(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == kVK_UpArrow
            && event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]) == .maskControl
    }

    private func isCommandM(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == kVK_ANSI_M
            && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            && event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]) == .maskCommand
    }
}
