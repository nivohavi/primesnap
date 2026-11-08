import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey | shiftKey | optionKey | controlKey).
    var carbonModifiers: UInt32
    /// Key label captured at record time (from the ASCII layout, so Hebrew etc. layouts still show "2", "S").
    var key: String

    var display: String { modifierSymbols + key }

    var modifierSymbols: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    var eventModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    /// Single printable character usable as an NSMenuItem keyEquivalent, if any.
    var menuKeyEquivalent: String? {
        Shortcut.specialKeys[UInt16(keyCode)] == nil && key.count == 1 ? key.lowercased() : nil
    }

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = UInt32(keyCode)
        carbonModifiers = UInt32(modifiers)
        self.key = key
    }

    /// nil if the combo isn't usable as a global shortcut (needs ⌘, ⌃ or ⌥ — except function keys).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isFunctionKey = Shortcut.functionKeys.contains(Int(event.keyCode))
        guard isFunctionKey || !flags.isDisjoint(with: [.command, .control, .option]) else { return nil }

        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        self.init(keyCode: Int(event.keyCode), modifiers: mods, key: Shortcut.keyName(event.keyCode))
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
    ]

    private static let specialKeys: [UInt16: String] = {
        var m: [UInt16: String] = [
            UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
            UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘", UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        for (i, code) in fKeys.enumerated() { m[UInt16(code)] = "F\(i + 1)" }
        return m
    }()

    static func keyName(_ keyCode: UInt16) -> String {
        if let special = specialKeys[keyCode] { return special }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
