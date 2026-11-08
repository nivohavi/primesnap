import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One capture in the sidebar. Stored as `item.json` next to `capture.png` / `thumb.png`.
struct HistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    var title: String
    let width: Int
    let height: Int
    let scale: CGFloat
    var copied = false
    /// Running capture number shown in the sidebar (#1 is the first capture ever). Never reused.
    var number: Int?

    var dimensions: String { "\(width)×\(height)" }
}

/// Per-capture edits, so going back to a capture restores its arrows, text, redactions and style.
struct HistoryEdits: Codable {
    var style: Style
    var presetID: UUID?
    var annotations: [Annotation]
    var manual: [CGRect]
}

/// Recent captures on disk: ~/Library/Application Support/PrimeSnap/History/<id>/.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static var limit: Int { Prefs.historyLimit }

    /// Newest first.
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]

    /// Captures whose PNG is still being written; served from memory until the write lands.
    private var pending: [UUID: LoadedImage] = [:]
    private let root: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("PrimeSnap/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        items = loadItems()
        numberUnnumbered()
    }

    private static let nextNumberKey = "history.nextNumber"

    private func takeNumber() -> Int {
        let defaults = UserDefaults.standard
        let n = max(1, defaults.integer(forKey: Self.nextNumberKey))
        defaults.set(n + 1, forKey: Self.nextNumberKey)
        return n
    }

    /// Captures saved before numbering existed get numbers in date order.
    private func numberUnnumbered() {
        let highest = items.compactMap(\.number).max() ?? 0
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: Self.nextNumberKey) <= highest { defaults.set(highest + 1, forKey: Self.nextNumberKey) }
        for i in items.indices.reversed() where items[i].number == nil { // oldest first
            items[i].number = takeNumber()
            writeItem(items[i])
        }
    }

    // MARK: Paths

    private func dir(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func imageURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("capture.png") }
    private func thumbURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("thumb.png") }
    private func itemURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("item.json") }
    private func editsURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("edits.json") }

    // MARK: Read

    private func loadItems() -> [HistoryItem] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return dirs
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent("item.json")) }
            .compactMap { try? decoder.decode(HistoryItem.self, from: $0) }
            .sorted { $0.date > $1.date }
    }

    func item(_ id: UUID) -> HistoryItem? { items.first { $0.id == id } }

    func thumbnail(_ id: UUID) -> NSImage? {
        if let cached = thumbnails[id] { return cached }
        guard pending[id] == nil, let img = NSImage(contentsOf: thumbURL(id)) else { return nil }
        // Cache without publishing: we're inside a view update here.
        DispatchQueue.main.async { [weak self] in self?.thumbnails[id] = img }
        return img
    }

    /// Decodes the capture off the main thread.
    func loadImage(_ id: UUID) async -> LoadedImage? {
        if let p = pending[id] { return p }
        guard let item = item(id) else { return nil }
        let url = imageURL(id), scale = item.scale
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            return LoadedImage(image: img, scale: scale)
        }.value
    }

    func loadEdits(_ id: UUID) -> HistoryEdits? {
        guard let data = try? Data(contentsOf: editsURL(id)) else { return nil }
        return try? JSONDecoder().decode(HistoryEdits.self, from: data)
    }

    // MARK: Write

    @discardableResult
    func add(_ loaded: LoadedImage, title: String) -> HistoryItem {
        let item = HistoryItem(
            id: UUID(), date: Date(), title: title,
            width: loaded.image.width, height: loaded.image.height, scale: loaded.scale,
            number: takeNumber()
        )
        try? FileManager.default.createDirectory(at: dir(item.id), withIntermediateDirectories: true)
        writeItem(item)
        items.insert(item, at: 0)
        pending[item.id] = loaded

        let id = item.id, imageURL = imageURL(id), thumbURL = thumbURL(id), image = loaded.image
        Task.detached(priority: .utility) {
            Self.writePNG(image, to: imageURL)
            let thumb = Self.makeThumbnail(image, maxSide: 240)
            if let thumb { Self.writePNG(thumb, to: thumbURL) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                pending[id] = nil
                if let thumb { thumbnails[id] = NSImage(cgImage: thumb, size: .zero) }
            }
        }

        prune()
        return item
    }

    func saveEdits(_ id: UUID, _ edits: HistoryEdits) {
        guard item(id) != nil, let data = try? JSONEncoder().encode(edits) else { return }
        try? data.write(to: editsURL(id), options: .atomic)
    }

    func markCopied(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].copied else { return }
        items[i].copied = true
        writeItem(items[i])
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        thumbnails[id] = nil
        pending[id] = nil
        try? FileManager.default.removeItem(at: dir(id))
    }

    var folder: URL { root }

    /// Bytes used on disk by all captures.
    func diskUsage() -> Int64 {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = files?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func clear(keeping keep: UUID? = nil) {
        for item in items where item.id != keep { delete(item.id) }
    }

    func prune() {
        while items.count > Self.limit, let oldest = items.last { delete(oldest.id) }
    }

    private func writeItem(_ item: HistoryItem) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        if let data = try? encoder.encode(item) { try? data.write(to: itemURL(item.id), options: .atomic) }
    }

    // MARK: Image helpers

    nonisolated private static func writePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    nonisolated private static func makeThumbnail(_ image: CGImage, maxSide: CGFloat) -> CGImage? {
        let s = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * s)), h = max(1, Int(CGFloat(image.height) * s))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
