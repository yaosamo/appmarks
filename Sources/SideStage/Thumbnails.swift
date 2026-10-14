import AppKit
import ScreenCaptureKit

enum Thumbnails {
    private static let width: CGFloat = 360

    static func capture(_ ids: Set<CGWindowID>) async -> [CGWindowID: NSImage] {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [:] }

        var images: [CGWindowID: NSImage] = [:]
        for window in content.windows where ids.contains(window.windowID) && window.frame.width > 0 {
            let config = SCStreamConfiguration()
            let scale = width / window.frame.width
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                images[window.windowID] = NSImage(cgImage: image, size: NSSize(width: config.width, height: config.height))
            }
        }
        return images
    }
}
