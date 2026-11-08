import AppKit
import ImageIO

enum CaptureMode {
    case area, window, screen

    var title: String {
        switch self {
        case .area: return "Area capture"
        case .window: return "Window capture"
        case .screen: return "Full screen"
        }
    }

    var arguments: [String] {
        switch self {
        case .area:
            return ["-i", "-x"] // interactive selection (space toggles window mode)
        case .window:
            // Start in window mode; drop the macOS shadow unless asked for (we draw our own).
            return ["-i", "-W", "-x"] + (Prefs.windowShadow ? [] : ["-o"])
        case .screen:
            var args = ["-m", "-x"] // main display only
            if Prefs.showCursor { args.append("-C") }
            if Prefs.screenDelay > 0 { args += ["-T", String(Prefs.screenDelay)] }
            return args
        }
    }
}

struct LoadedImage {
    let image: CGImage
    /// Pixels per point (2 on Retina).
    let scale: CGFloat

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = max(1, scale)
    }

    init?(url: URL) {
        // Read the bytes and decode *now*: a URL-backed CGImage decodes lazily, and the capture
        // file is deleted right after loading — which left us drawing an empty (black) image.
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = props?[kCGImagePropertyDPIWidth] as? Double ?? 72
        self.init(image: img, scale: CGFloat(dpi / 72))
    }

    init?(nsImage: NSImage) {
        guard let img = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pointWidth = nsImage.size.width
        self.init(image: img, scale: pointWidth > 0 ? CGFloat(img.width) / pointWidth : 1)
    }
}

@MainActor
enum Capture {
    private static var inFlight = false

    static func run(_ mode: CaptureMode, completion: @escaping @MainActor (LoadedImage?) -> Void) {
        guard !inFlight else { return }
        inFlight = true

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("primesnap-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = mode.arguments + [url.path]
        process.terminationHandler = { _ in
            let loaded = LoadedImage(url: url) // nil when the user pressed Esc
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    inFlight = false
                    completion(loaded)
                }
            }
        }
        do {
            try process.run()
        } catch {
            inFlight = false
            completion(nil)
        }
    }
}
