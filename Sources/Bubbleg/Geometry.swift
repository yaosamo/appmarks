import AppKit

/// Everything here is in Accessibility coordinates: origin at the top-left of the primary screen, so
/// a display left of or above the primary one has negative coordinates.
enum Geometry {
    struct Display {
        let id: CGDirectDisplayID
        let frame: CGRect
        /// Clear of the menu bar and the Dock.
        let visibleArea: CGRect

        /// The whole display below the menu bar, Dock included: the menu bar spans the display, the Dock rarely does.
        var belowMenuBar: CGRect {
            CGRect(x: frame.minX, y: visibleArea.minY, width: frame.width, height: frame.maxY - visibleArea.minY)
        }
    }

    static var displays: [Display] {
        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.height else { return [] }
        func toAX(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Display(id: id, frame: toAX(screen.frame), visibleArea: toAX(screen.visibleFrame))
        }
    }

    /// The display with that id, or the primary one once it is unplugged.
    static func display(_ id: CGDirectDisplayID) -> Display {
        let all = displays
        return all.first { $0.id == id } ?? all.first ?? fallback
    }

    static func display(at point: CGPoint) -> Display {
        display(around: CGRect(origin: point, size: .zero))
    }

    /// The display showing most of `rect`, or the nearest one when it is on none, as a window
    /// dragged past the edge of the desktop or a position saved on a display since unplugged.
    static func display(around rect: CGRect) -> Display {
        let all = displays
        guard !all.isEmpty else { return fallback }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        if let holding = all.first(where: { $0.frame.contains(centre) }) { return holding }
        let overlap = { (display: Display) -> CGFloat in
            let shared = display.frame.intersection(rect)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        if let most = all.max(by: { overlap($0) < overlap($1) }), overlap(most) > 0 { return most }
        let distance = { (display: Display) -> CGFloat in
            hypot(max(display.frame.minX - centre.x, 0, centre.x - display.frame.maxX),
                  max(display.frame.minY - centre.y, 0, centre.y - display.frame.maxY))
        }
        return all.min { distance($0) < distance($1) }!
    }

    static var primary: Display { displays.first ?? fallback }

    /// No screen at all, briefly, while displays reconfigure.
    private static let fallback = Display(id: CGMainDisplayID(), frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                          visibleArea: CGRect(x: 0, y: 25, width: 1440, height: 875))
}
