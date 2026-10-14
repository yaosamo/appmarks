import Carbon

/// Global shortcut via Carbon: still the only public API that fires while another app is frontmost
/// without needing Input Monitoring permission.
@MainActor
enum HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    static func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotKey = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                let id = hotKey.id
                MainActor.assumeIsolated { HotKey.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x5344_5354), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }
}
