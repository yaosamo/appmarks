import AppKit
import ScreenCaptureKit

@MainActor
enum Thumbnails {
    private static var content: SCShareableContent?
    private static var listedAt = Date.distantPast

    static func capture(_ ids: Set<CGWindowID>, width: CGFloat) async -> [CGWindowID: NSImage] {
        guard CGPreflightScreenCaptureAccess(), !ids.isEmpty else { return [:] }
        // Listing every window on the system is the expensive part. The list only changes when windows
        // open or close, so it is reused until a requested window is missing from it, or for 10s.
        let listed = Set(content?.windows.map(\.windowID) ?? [])
        if content == nil || !ids.isSubset(of: listed) || Date().timeIntervalSince(listedAt) > 10 {
            content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            listedAt = Date()
        }
        let targets = content?.windows.filter { ids.contains($0.windowID) && $0.frame.width > 0 } ?? []

        return await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for window in targets {
                group.addTask {
                    let config = SCStreamConfiguration()
                    let scale = width / window.frame.width
                    config.width = Int(window.frame.width * scale)
                    config.height = Int(window.frame.height * scale)
                    config.showsCursor = false
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return (window.windowID, image.map { NSImage(cgImage: $0, size: NSSize(width: config.width, height: config.height)) })
                }
            }
            var images: [CGWindowID: NSImage] = [:]
            for await (id, image) in group { images[id] = image }
            return images
        }
    }
}
