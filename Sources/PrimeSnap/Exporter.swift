import AppKit
import UniformTypeIdentifiers

enum Exporter {
    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        // Point size => PNG carries 144 DPI on Retina, so it pastes at the right size.
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }

    static func copy(_ image: CGImage, scale: CGFloat) {
        guard let png = pngData(image, scale: scale) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }

    static var defaultFileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "PrimeSnap \(f.string(from: Date())).png"
    }

    /// ⌘S: straight into the folder chosen in Settings (Desktop by default).
    static func quickSave(_ image: CGImage, scale: CGFloat) -> URL? {
        guard let png = pngData(image, scale: scale) else { return nil }
        let url = Prefs.saveFolder.appendingPathComponent(defaultFileName)
        return (try? png.write(to: url)) != nil ? url : nil
    }

    @MainActor
    static func save(_ image: CGImage, scale: CGFloat, from window: NSWindow?, completion: @escaping (URL) -> Void) {
        guard let png = pngData(image, scale: scale) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url)
                completion(url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    /// Temp file for drag-out.
    static func tempFile(_ image: CGImage, scale: CGFloat) -> URL? {
        guard let png = pngData(image, scale: scale) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("primesnap-drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(defaultFileName)
        return (try? png.write(to: url)) != nil ? url : nil
    }
}
