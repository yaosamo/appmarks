import ApplicationServices

#if !APP_STORE
// Private but stable since 10.x; Rectangle, AltTab and yabai all rely on it to map an
// AX window to the CGWindowID that ScreenCaptureKit and the window server use.
// App Review rejects private API, so the App Store build matches windows instead (see WindowIDs).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
#endif

/// Maps one app's AX windows to the CGWindowIDs that ScreenCaptureKit and the window server use.
enum WindowIDs {
    /// `known` carries the pairs from earlier syncs: an element seen before keeps its ID, however it moved.
    static func resolve(_ elements: [AXUIElement], pid: pid_t, known: [(id: CGWindowID, element: AXUIElement)]) -> [CGWindowID?] {
        #if APP_STORE
        return match(elements, pid: pid, known: known)
        #else
        return elements.map { element in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(element, &id) == .success ? id : nil
        }
        #endif
    }

    #if APP_STORE
    /// Public route: the window server lists every window with its owner, frame (top-left origin, as
    /// Accessibility reports it) and, with Screen Recording, its title. A window matches on owner and
    /// frame; windows stacked exactly on top of each other are told apart by title, then by list order.
    private static func match(_ elements: [AXUIElement], pid: pid_t, known: [(id: CGWindowID, element: AXUIElement)]) -> [CGWindowID?] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let listed = info.compactMap { entry -> (id: CGWindowID, frame: CGRect, title: String?)? in
            guard entry[kCGWindowOwnerPID as String] as? pid_t == pid,
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String],
                  let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
            else { return nil }
            return (id, frame, entry[kCGWindowName as String] as? String)
        }
        let alive = Set(listed.map(\.id))
        var claimed = Set<CGWindowID>()
        var ids = elements.map { element -> CGWindowID? in
            guard let id = known.first(where: { CFEqual($0.element, element) })?.id,
                  alive.contains(id), !claimed.contains(id)
            else { return nil }
            claimed.insert(id)
            return id
        }
        for (index, element) in elements.enumerated() where ids[index] == nil {
            guard let frame = element.frame else { continue }
            let free = listed.filter { !claimed.contains($0.id) && $0.frame.isClose(to: frame) }
            let title = element.title
            guard let pick = free.first(where: { title != nil && $0.title == title }) ?? free.first else { continue }
            claimed.insert(pick.id)
            ids[index] = pick.id
        }
        return ids
    }
    #endif
}

private extension CGRect {
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) <= 2 && abs(minY - other.minY) <= 2
            && abs(width - other.width) <= 2 && abs(height - other.height) <= 2
    }
}

extension AXUIElement {
    private func copy(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success ? value : nil
    }

    private func set(_ name: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    var windows: [AXUIElement] { copy(kAXWindowsAttribute) as? [AXUIElement] ?? [] }
    var title: String? { copy(kAXTitleAttribute) as? String }
    var subrole: String? { copy(kAXSubroleAttribute) as? String }
    var isMinimized: Bool { copy(kAXMinimizedAttribute) as? Bool ?? false }

    var focusedWindow: AXUIElement? {
        guard let value = copy(kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Top-left-origin global coordinates, as Accessibility reports them.
    var frame: CGRect? {
        guard let p = copy(kAXPositionAttribute), let s = copy(kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    func setMinimized(_ minimized: Bool) {
        set(kAXMinimizedAttribute, minimized as CFBoolean)
    }

    func focus(appPID: pid_t) {
        AXUIElementCreateApplication(appPID).set(kAXFrontmostAttribute, kCFBooleanTrue)
        set(kAXMainAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(self, kAXRaiseAction as CFString)
    }
}
