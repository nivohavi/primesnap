import Carbon.HIToolbox
import Foundation

/// Minimal global hotkey via Carbon (no third-party dependency, no Accessibility permission needed).
@MainActor
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) {
        HotKey.installHandlerIfNeeded()
        HotKey.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x5052_534E), id: id) // 'PRSN'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
