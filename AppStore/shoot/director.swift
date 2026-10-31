// Stage helper for the Bubbleg App Store shoot. Coordinates are global points, top-left origin.
//   director hide-except Finder Safari Bubbleg   → prints hidden app names (for unhide)
//   director unhide Ghostty "Google Chrome" ...
//   director place Safari "<title part>" x y w h
//   director raise Safari "<title part>"
//   director panel                              → Bubbleg panel frames: x y w h
//   director move x y [seconds]                 → glide the pointer with ease-in-out
//   director click [x y]
//   director drag x1 y1 x2 y2 [seconds]         → press, glide, release
//   director pos                                 → current pointer
import AppKit
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())
func copy(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func app(_ name: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
}
func window(_ appName: String, _ part: String) -> AXUIElement? {
    guard let a = app(appName) else { return nil }
    let wins = copy(AXUIElementCreateApplication(a.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
    return wins.first { (copy($0, kAXTitleAttribute) as? String ?? "").contains(part) } ?? (part.isEmpty ? wins.first : nil)
}
var pointer: CGPoint { CGEvent(source: nil)!.location }
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
        .post(tap: .cghidEventTap)
}
func glide(to target: CGPoint, seconds: Double, type: CGEventType = .mouseMoved) {
    let start = pointer
    let steps = max(1, Int(seconds * 120))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        post(type, CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e))
        usleep(UInt32(1_000_000 / 120))
    }
}
func num(_ i: Int) -> Double { Double(args[i])! }

switch args.first {
case "hide-except":
    let keep = Set(args.dropFirst())
    for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular && !a.isHidden && !keep.contains(a.localizedName ?? "") {
        a.hide(); print(a.localizedName ?? "")
    }
case "unhide":
    for name in args.dropFirst() { app(name)?.unhide() }
case "place":
    guard let w = window(args[1], args[2]) else { print("no window"); exit(1) }
    var p = CGPoint(x: num(3), y: num(4)), s = CGSize(width: num(5), height: num(6))
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
case "raise":
    guard let a = app(args[1]), let w = window(args[1], args[2]) else { print("no window"); exit(1) }
    a.activate()
    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
case "panel":
    let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    for e in info where e[kCGWindowOwnerName as String] as? String == "Bubbleg" {
        let r = CGRect(dictionaryRepresentation: e[kCGWindowBounds as String] as! CFDictionary)!
        print(Int(r.minX), Int(r.minY), Int(r.width), Int(r.height), "layer", e[kCGWindowLayer as String] ?? "")
    }
case "move":
    glide(to: CGPoint(x: num(1), y: num(2)), seconds: args.count > 3 ? num(3) : 0.6)
case "click":
    if args.count > 2 { glide(to: CGPoint(x: num(1), y: num(2)), seconds: 0.6) }
    post(.leftMouseDown, pointer); usleep(70_000); post(.leftMouseUp, pointer)
case "drag":
    glide(to: CGPoint(x: num(1), y: num(2)), seconds: 0.5)
    post(.leftMouseDown, pointer); usleep(150_000)
    glide(to: CGPoint(x: num(3), y: num(4)), seconds: args.count > 5 ? num(5) : 1.0, type: .leftMouseDragged)
    usleep(150_000); post(.leftMouseUp, pointer)
case "menu":
    // director menu Bubbleg "Settings…": opens the app's menu bar extra and presses the item.
    guard let a = app(args[1]),
          let bar = copy(AXUIElementCreateApplication(a.processIdentifier), "AXExtrasMenuBar"),
          let item = (copy(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first
    else { print("no extras menu bar"); exit(1) }
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    usleep(400_000)
    let menus = copy(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
    let entries = menus.flatMap { copy($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    guard let entry = entries.first(where: { copy($0, kAXTitleAttribute) as? String == args[2] }) else {
        print("items:", entries.compactMap { copy($0, kAXTitleAttribute) as? String }); exit(1)
    }
    AXUIElementPerformAction(entry, kAXPressAction as CFString)
case "pos":
    print(Int(pointer.x), Int(pointer.y))
default:
    print("unknown command"); exit(1)
}
