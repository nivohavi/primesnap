import Foundation

/// App preferences in UserDefaults. Views bind with `@AppStorage(Prefs.Key.x)`; code reads the statics.
enum Prefs {
    enum Key {
        static let afterCapture = "pref.afterCapture"
        static let playSounds = "pref.playSounds"
        static let windowShadow = "pref.windowShadow"
        static let screenDelay = "pref.screenDelay"
        static let showCursor = "pref.showCursor"
        static let saveFolder = "pref.saveFolder"
        static let historyLimit = "pref.historyLimit"
    }

    enum AfterCapture: String, CaseIterable, Identifiable {
        case editor, copy
        var id: String { rawValue }
        var label: String {
            switch self {
            case .editor: return "Open the editor"
            case .copy: return "Copy with the current style"
            }
        }
    }

    private static var d: UserDefaults { .standard }

    static var afterCapture: AfterCapture { AfterCapture(rawValue: d.string(forKey: Key.afterCapture) ?? "") ?? .editor }
    static var playSounds: Bool { d.object(forKey: Key.playSounds) as? Bool ?? true }
    static var windowShadow: Bool { d.bool(forKey: Key.windowShadow) }
    static var screenDelay: Int { d.integer(forKey: Key.screenDelay) }
    static var showCursor: Bool { d.bool(forKey: Key.showCursor) }
    static let historyLimitRange = 5...1000
    static var historyLimit: Int {
        let v = d.object(forKey: Key.historyLimit) as? Int ?? 50
        return min(max(v, historyLimitRange.lowerBound), historyLimitRange.upperBound)
    }

    static var defaultSaveFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    static var saveFolder: URL {
        if let path = d.string(forKey: Key.saveFolder), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultSaveFolder
    }
}
