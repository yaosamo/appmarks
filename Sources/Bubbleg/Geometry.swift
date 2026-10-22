import AppKit

/// Everything here is in Accessibility coordinates: origin at the top-left of the primary screen.
enum Geometry {
    private static var primary: NSScreen { NSScreen.screens[0] }

    private static func toAX(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    static var visibleArea: CGRect { toAX(primary.visibleFrame) }

    /// The whole screen below the menu bar, Dock included: the menu bar spans the screen, the Dock rarely does.
    static var belowMenuBar: CGRect {
        let screen = toAX(primary.frame), visible = visibleArea
        return CGRect(x: screen.minX, y: visible.minY, width: screen.width, height: screen.maxY - visible.minY)
    }
}
