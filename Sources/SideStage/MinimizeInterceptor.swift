import Carbon
import CoreGraphics

/// Active event taps that swallow a click on a stage window's minimize button, and ⌘M, so the window
/// goes to the strip without the Dock's genie. Mouse and keyboard get separate taps so that if the
/// keyboard one is refused the click path still works.
@MainActor
final class MinimizeInterceptor {
    private let manager: StageManager
    private var taps: [CFMachPort] = []
    private var swallowMouseUp = false

    init(manager: StageManager) {
        self.manager = manager
    }

    func start() {
        guard taps.isEmpty else { return }
        addTap(for: [.leftMouseDown, .leftMouseUp])
        addTap(for: [.keyDown])
    }

    private func addTap(for types: [CGEventType]) {
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            let interceptor = Unmanaged<MinimizeInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
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
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            taps.forEach { CGEvent.tapEnable(tap: $0, enable: true) }
        case .leftMouseDown where manager.parkIfMinimizeButton(at: event.location):
            swallowMouseUp = true
            return nil
        case .leftMouseUp where swallowMouseUp:
            swallowMouseUp = false
            return nil
        case .keyDown where isCommandM(event) && manager.parkFocusedIfMinimizeShortcut():
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func isCommandM(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventKeycode) == kVK_ANSI_M
            && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            && event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]) == .maskCommand
    }
}
