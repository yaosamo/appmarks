import CoreGraphics

enum WindowServer {
    /// Frames (top-left origin) straight from the window server: no round trip to the owning app,
    /// so it is cheap enough for per-click and per-frame use.
    static func frames(of ids: [CGWindowID]) -> [CGRect] {
        guard !ids.isEmpty else { return [] }
        var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = values.withUnsafeMutableBufferPointer({ CFArrayCreate(nil, $0.baseAddress, ids.count, nil) }),
              let info = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        else { return [] }
        return info.compactMap { ($0[kCGWindowBounds as String] as! CFDictionary?).flatMap { CGRect(dictionaryRepresentation: $0) } }
    }

    /// Mission Control shows each window as a scaled-down tile, and the window server reports the tile's
    /// frame, not the window's. macOS 27 has no API for it being open, but WindowManager keeps its shield
    /// window on screen behind the tiles the whole time; its name needs Screen Recording.
    static var isMissionControlOpen: Bool {
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        return info.contains { $0[kCGWindowName as String] as? String == "ExposeShieldWindow" }
    }

    /// The on-screen frames of `ids`, front to back.
    static func onScreen(_ ids: Set<CGWindowID>) -> [(id: CGWindowID, frame: CGRect)] {
        guard !ids.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID, ids.contains(id),
                  let bounds = entry[kCGWindowBounds as String], let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
            else { return nil }
            return (id, frame)
        }
    }
}
