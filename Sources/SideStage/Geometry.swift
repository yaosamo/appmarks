import AppKit

/// Everything here is in Accessibility coordinates: origin at the top-left of the primary screen.
enum Geometry {
    static let stripWidth: CGFloat = 180

    private static var primary: NSScreen { NSScreen.screens[0] }

    private static func toAX(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    static var stageArea: CGRect {
        var area = toAX(primary.visibleFrame)
        area.origin.x += stripWidth
        area.size.width -= stripWidth
        return area.insetBy(dx: 16, dy: 12)
    }

    /// Off-stage windows sit with their top-left corner on the primary screen's bottom-right pixel,
    /// the same trick AeroSpace uses, because macOS has no public API to hide a single window.
    static var parkPoint: CGPoint {
        let screen = toAX(primary.frame)
        return CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)
    }

    static func isParked(_ frame: CGRect) -> Bool {
        frame.minX >= parkPoint.x - 100 && frame.minY >= parkPoint.y - 100
    }

    static func centered(_ size: CGSize) -> CGRect {
        let area = stageArea
        let fitted = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        return CGRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}
