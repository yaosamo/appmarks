import CoreGraphics

/// An active event tap that swallows a click on a stage window's minimize button, so the window goes to
/// the strip without the Dock's genie. Needs only the Accessibility grant SideStage already has.
@MainActor
final class MinimizeInterceptor {
    private let manager: StageManager
    private var tap: CFMachPort?
    private var swallowMouseUp = false

    init(manager: StageManager) {
        self.manager = manager
    }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, refcon in
            let interceptor = Unmanaged<MinimizeInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
            return MainActor.assumeIsolated { interceptor.handle(type, event) }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            Log.write("event tap could not be created; minimize clicks will use the Dock fallback")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown where manager.parkIfMinimizeButton(at: event.location):
            swallowMouseUp = true
            return nil
        case .leftMouseUp where swallowMouseUp:
            swallowMouseUp = false
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
