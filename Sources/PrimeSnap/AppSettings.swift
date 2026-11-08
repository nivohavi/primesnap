import Carbon.HIToolbox
import Combine
import SwiftUI

enum CaptureAction: String, CaseIterable, Identifiable, Codable {
    case area, window, screen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .screen: return "Capture Screen"
        }
    }

    var symbol: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .screen: return "display"
        }
    }

    var mode: CaptureMode {
        switch self {
        case .area: return .area
        case .window: return .window
        case .screen: return .screen
        }
    }

    var hotKeyID: UInt32 {
        switch self {
        case .area: return 1
        case .window: return 2
        case .screen: return 3
        }
    }

    var defaultShortcut: Shortcut {
        let mods = controlKey | shiftKey
        switch self {
        case .area: return Shortcut(keyCode: kVK_ANSI_2, modifiers: mods, key: "2")
        case .window: return Shortcut(keyCode: kVK_ANSI_3, modifiers: mods, key: "3")
        case .screen: return Shortcut(keyCode: kVK_ANSI_1, modifiers: mods, key: "1")
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Missing entry = shortcut disabled.
    @Published private(set) var shortcuts: [CaptureAction: Shortcut]
    /// True while a recorder is listening, so global hotkeys are paused and don't fire mid-recording.
    @Published var isRecording = false

    private static let key = "shortcuts.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            var map: [CaptureAction: Shortcut] = [:]
            for (k, v) in stored { if let a = CaptureAction(rawValue: k) { map[a] = v } }
            shortcuts = map
        } else {
            shortcuts = Self.defaults
        }
    }

    private static var defaults: [CaptureAction: Shortcut] {
        Dictionary(uniqueKeysWithValues: CaptureAction.allCases.map { ($0, $0.defaultShortcut) })
    }

    func set(_ shortcut: Shortcut?, for action: CaptureAction) {
        if let shortcut {
            // One combo, one action: take it away from whoever had it.
            for other in CaptureAction.allCases where other != action && shortcuts[other] == shortcut {
                shortcuts[other] = nil
            }
        }
        shortcuts[action] = shortcut
        save()
    }

    func binding(for action: CaptureAction) -> Binding<Shortcut?> {
        Binding(get: { self.shortcuts[action] }, set: { self.set($0, for: action) })
    }

    func resetToDefaults() {
        shortcuts = Self.defaults
        save()
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
