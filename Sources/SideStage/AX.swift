import ApplicationServices

// Private but stable since 10.x; Rectangle, AltTab and yabai all rely on it to map an
// AX window to the CGWindowID that ScreenCaptureKit and the window server use.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    private func copy(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success ? value : nil
    }

    private func set(_ name: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success ? id : nil
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

    func setPosition(_ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { set(kAXPositionAttribute, value) }
    }

    func setSize(_ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { set(kAXSizeAttribute, value) }
    }

    func focus(appPID: pid_t) {
        AXUIElementCreateApplication(appPID).set(kAXFrontmostAttribute, kCFBooleanTrue)
        set(kAXMainAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(self, kAXRaiseAction as CFString)
    }
}
