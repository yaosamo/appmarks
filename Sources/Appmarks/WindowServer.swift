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
}
