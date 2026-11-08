import Foundation

struct StylePreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var style: Style
}

@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()

    @Published private(set) var presets: [StylePreset] = []
    private static let key = "presets.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([StylePreset].self, from: data) {
            presets = stored
        }
    }

    @discardableResult
    func add(name: String, style: Style) -> StylePreset {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let preset = StylePreset(name: trimmed.isEmpty ? "Preset \(presets.count + 1)" : trimmed, style: style)
        presets.append(preset)
        save()
        return preset
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    func preset(_ id: UUID?) -> StylePreset? {
        presets.first { $0.id == id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
