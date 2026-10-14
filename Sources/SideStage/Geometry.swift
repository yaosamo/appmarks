import AppKit

/// Everything here is in Accessibility coordinates: origin at the top-left of the primary screen.
enum Geometry {
    static var stripWidth: CGFloat { Settings.shared.style.stripWidth }

    private static var primary: NSScreen { NSScreen.screens[0] }

    private static func toAX(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toAXPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primary.frame.height - point.y)
    }

    static var stageArea: CGRect {
        var area = toAX(primary.visibleFrame)
        area.origin.x += stripWidth
        area.size.width -= stripWidth
        let style = Settings.shared.style
        return area.insetBy(dx: style.stageMarginX, dy: style.stageMarginY)
    }

    /// Off-stage windows sit with their left edge on the primary screen's last pixel column, the same
    /// trick AeroSpace uses, because macOS has no public API to hide a single window.
    static var parkPoint: CGPoint {
        let screen = toAX(primary.frame)
        return CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)
    }

    /// Judged on x alone: macOS clamps the y of a parked window ~110px up so its title bar clears the
    /// Dock, but keeps the x, and a window whose left edge is at the screen's right edge is invisible.
    static func isParked(_ frame: CGRect) -> Bool {
        frame.minX >= parkPoint.x - 8
    }

    static func centered(_ size: CGSize) -> CGRect {
        let area = stageArea
        let fitted = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        return CGRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}
