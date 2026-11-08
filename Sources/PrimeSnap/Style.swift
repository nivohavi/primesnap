import AppKit
import CoreGraphics

struct RGBA: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }

    static func hex(_ v: UInt32) -> RGBA {
        RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    static let white = RGBA(r: 1, g: 1, b: 1)
    static let palette: [RGBA] = [
        hex(0xFF3B30), hex(0xFF9500), hex(0xFFCC00), hex(0x34C759),
        hex(0x0A84FF), hex(0xAF52DE), hex(0xFFFFFF), hex(0x1C1C1E),
    ]
}

extension RGBA {
    init?(nsColor: NSColor) {
        guard let c = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }
}

enum Background: Codable, Equatable, Hashable {
    case none
    case desktop
    case gradient(Int)
    case image(String)
}

struct GradientPreset {
    let name: String
    let colors: [RGBA]

    static let all: [GradientPreset] = [
        .init(name: "Ocean", colors: [.hex(0x2193B0), .hex(0x6DD5ED)]),
        .init(name: "Lagoon", colors: [.hex(0x11998E), .hex(0x38EF7D)]),
        .init(name: "Violet", colors: [.hex(0x8E2DE2), .hex(0x4A00E0)]),
        .init(name: "Sunset", colors: [.hex(0xFF7E5F), .hex(0xFEB47B)]),
        .init(name: "Berry", colors: [.hex(0xDA22FF), .hex(0x9733EE)]),
        .init(name: "Candy", colors: [.hex(0xFF9A9E), .hex(0xFECFEF)]),
        .init(name: "Sky", colors: [.hex(0xA1C4FD), .hex(0xC2E9FB)]),
        .init(name: "Fire", colors: [.hex(0xF12711), .hex(0xF5AF19)]),
        .init(name: "Slate", colors: [.hex(0x232526), .hex(0x414345)]),
        .init(name: "Paper", colors: [.hex(0xF5F5F7)]),
    ]
}

enum AspectPreset: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto", r4x3 = "4:3", r3x2 = "3:2", r16x9 = "16:9", r1x1 = "1:1"
    case twitter = "Twitter", facebook = "Facebook", instagram = "Instagram", linkedin = "LinkedIn"
    case youtube = "YouTube", pinterest = "Pinterest", reddit = "Reddit", story = "Story"

    var id: String { rawValue }

    var ratio: CGFloat? {
        switch self {
        case .auto: return nil
        case .r4x3, .reddit: return 4.0 / 3.0
        case .r3x2: return 3.0 / 2.0
        case .r16x9, .twitter, .youtube: return 16.0 / 9.0
        case .r1x1: return 1
        case .facebook, .linkedin: return 1.91
        case .instagram: return 4.0 / 5.0
        case .pinterest: return 2.0 / 3.0
        case .story: return 9.0 / 16.0
        }
    }
}

enum RedactStyle: String, Codable, CaseIterable, Identifiable {
    case pixelate = "Pixelate", blur = "Blur", solid = "Solid"
    var id: String { rawValue }
}

struct Style: Codable, Equatable {
    var background: Background = .gradient(0)
    var padding: Double = 64
    var inset: Double = 0
    var balance = true
    /// nil = use the color detected at the screenshot's edges.
    var insetColor: RGBA?
    var cornerRadius: Double = 12
    var shadow: Double = 0.6
    var aspect: AspectPreset = .auto
    var autoRedact = false // OCR is slow; opt in per capture or keep it on via the toggle
    var redactStyle: RedactStyle = .solid
    var watermarkEnabled = false
    var watermarkText = ""

    init() {}

    /// Tolerant decoding: missing/unknown fields fall back to defaults, so adding options never wipes saved styles.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Style()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        background = v(.background, d.background)
        padding = v(.padding, d.padding)
        inset = v(.inset, d.inset)
        balance = v(.balance, d.balance)
        insetColor = (try? c.decodeIfPresent(RGBA.self, forKey: .insetColor)) ?? nil
        cornerRadius = v(.cornerRadius, d.cornerRadius)
        shadow = v(.shadow, d.shadow)
        aspect = v(.aspect, d.aspect)
        autoRedact = v(.autoRedact, d.autoRedact)
        redactStyle = v(.redactStyle, d.redactStyle)
        watermarkEnabled = v(.watermarkEnabled, d.watermarkEnabled)
        watermarkText = v(.watermarkText, d.watermarkText)
        if case .gradient(let i) = background, !GradientPreset.all.indices.contains(i) { background = d.background }
    }

    private static let key = "style.v2"

    static func load() -> Style {
        guard let data = UserDefaults.standard.data(forKey: key),
              var style = try? JSONDecoder().decode(Style.self, from: data) else { return Style() }
        // One-time: auto-redact used to default to on; switch existing saved styles off once.
        let migration = "migration.autoRedactOff.v1"
        if !UserDefaults.standard.bool(forKey: migration) {
            UserDefaults.standard.set(true, forKey: migration)
            style.autoRedact = false
            style.save()
        }
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Style.key)
        }
    }
}

/// Wallpaper / custom background images, downsampled and cached.
@MainActor
enum BackgroundImages {
    private static var cache: [String: CGImage] = [:]

    static func image(for background: Background) -> CGImage? {
        let url: URL?
        switch background {
        case .desktop: url = (NSScreen.main ?? NSScreen.screens.first).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        case .image(let path): url = URL(fileURLWithPath: path)
        case .none, .gradient: return nil
        }
        guard let url else { return nil }
        if let cached = cache[url.path] { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 3200,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        cache[url.path] = img
        return img
    }
}
