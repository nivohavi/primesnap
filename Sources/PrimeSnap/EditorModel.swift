import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    let source: CGImage
    let scale: CGFloat
    weak var window: NSWindow?
    var onClose: (() -> Void)?
    var onCopied: (() -> Void)?

    @Published var style: Style { didSet { styleChanged(from: oldValue) } }
    @Published var presetID: UUID?
    @Published var tool: Tool = .select
    @Published var color: RGBA = RGBA.palette[0] { didSet { applyToSelected { $0.color = self.color } } }
    @Published var strokeSize: StrokeSize = .medium {
        didSet {
            applyToSelected {
                $0.lineWidth = self.lineWidth
                $0.fontSize = self.fontSize
            }
        }
    }
    @Published var selectedID: UUID?
    @Published var toast: String?
    @Published var zoom: ZoomLevel = .fit

    @Published private(set) var annotations: [Annotation] = []
    /// Manual redactions, source pixels, top-left origin.
    @Published private(set) var manual: [CGRect] = []
    /// Auto redactions from OCR, source pixels, bottom-left origin (Vision convention).
    @Published private(set) var detected: [CGRect] = []
    @Published private(set) var detecting = false
    /// OCR errored: we don't know what's in the image, so the UI must warn instead of saying "nothing found".
    @Published private(set) var scanFailed = false
    @Published private(set) var rendered: RenderResult?
    @Published private(set) var analysis: ImageAnalysis?
    /// Annotation being dragged right now: drawn as a live overlay, left out of the (slower) bitmap render.
    @Published private(set) var liveID: UUID?
    /// Overlay keeps drawing these until a render that includes them lands (avoids a one-frame flicker).
    @Published private(set) var overlayIDs: Set<UUID> = []
    @Published private(set) var editingTextID: UUID?
    @Published private(set) var exporting = false
    var isEditingText: Bool { editingTextID != nil }

    private struct Snapshot: Equatable {
        var annotations: [Annotation]
        var manual: [CGRect]
    }

    private var redacted: CGImage
    private var backgroundImage: CGImage?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var detectTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var redactTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(image: CGImage, scale: CGFloat, edits: HistoryEdits? = nil) {
        source = image
        redacted = image
        self.scale = scale
        style = edits?.style ?? Style.load()
        presetID = edits?.presetID
        annotations = edits?.annotations ?? []
        manual = edits?.manual ?? []
        backgroundImage = BackgroundImages.image(for: style.background)
        if manual.isEmpty { scheduleRender() } else { rebuildRedacted() }

        let img = image
        analysisTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { ImageAnalyzer.analyze(img) }.value
            guard let self else { return }
            analysis = result
            scheduleRender()
        }
        if style.autoRedact { startDetection() }
    }

    /// OCR scan for secrets; only runs when auto-redaction is on (it can take a while).
    private func startDetection() {
        guard detectTask == nil else { return }
        detecting = true
        let img = source
        detectTask = Task { [weak self] in
            let rects = await Task.detached(priority: .userInitiated) { Redactor.detect(img) }.value
            guard let self else { return }
            detected = rects ?? []
            scanFailed = rects == nil
            detecting = false
            rebuildRedacted()
        }
    }

    // MARK: Derived

    var lineWidth: CGFloat { 4.5 * scale * strokeSize.multiplier }
    var fontSize: CGFloat { 20 * scale * strokeSize.multiplier }
    var sourceBounds: CGRect { CGRect(x: 0, y: 0, width: source.width, height: source.height) }
    /// What the history store keeps for this capture.
    var edits: HistoryEdits {
        HistoryEdits(style: style, presetID: presetID, annotations: annotations, manual: manual)
    }

    var autoCount: Int { style.autoRedact ? detected.count : 0 }
    var canUndo: Bool { !undoStack.isEmpty }

    func annotation(_ id: UUID?) -> Annotation? {
        guard let id else { return nil }
        return annotations.first { $0.id == id }
    }

    var selectedAnnotation: Annotation? { annotation(selectedID) }

    /// Annotations the canvas overlay should draw itself (not yet in the bitmap).
    var overlayAnnotations: [Annotation] {
        annotations.filter { ($0.id == liveID || overlayIDs.contains($0.id)) && $0.id != editingTextID }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.reversed().first { AnnotationDrawer.hitTest($0, point: p, tolerance: tolerance) }
    }

    // MARK: Annotation editing

    private var snapshot: Snapshot { Snapshot(annotations: annotations, manual: manual) }

    private func pushUndo() {
        undoStack.append(snapshot)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Drops the undo entry if the operation turned out to change nothing (e.g. a click that didn't move).
    private func dropNoopUndo() {
        if undoStack.last == snapshot { undoStack.removeLast() }
    }

    func createAnnotation(_ kind: Annotation.Kind, at p: CGPoint) -> UUID {
        pushUndo()
        let a = Annotation(kind: kind, start: p, end: p, color: color, lineWidth: lineWidth, fontSize: fontSize)
        annotations.append(a)
        selectedID = a.id
        liveID = a.id
        overlayIDs.insert(a.id)
        return a.id
    }

    func beginLive(_ id: UUID) {
        pushUndo()
        selectedID = id
        liveID = id
        overlayIDs.insert(id)
        scheduleRender()
    }

    func mutate(_ id: UUID, _ body: (inout Annotation) -> Void) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        body(&annotations[i])
        if id != liveID && id != editingTextID { scheduleRender() }
    }

    func endLive() {
        guard let id = liveID else { return }
        liveID = nil
        if let a = annotation(id), a.isDegenerate {
            annotations.removeAll { $0.id == id }
            overlayIDs.remove(id)
            if selectedID == id { selectedID = nil }
        }
        dropNoopUndo()
        scheduleRender()
    }

    func createText(at p: CGPoint) {
        finishTextEditing()
        pushUndo()
        var a = Annotation(kind: .text, start: p, end: p, color: color, lineWidth: lineWidth, fontSize: fontSize)
        a.text = ""
        annotations.append(a)
        selectedID = a.id
        editingTextID = a.id
    }

    func beginEditingText(_ id: UUID) {
        guard annotation(id)?.kind == .text else { return }
        finishTextEditing()
        pushUndo()
        selectedID = id
        editingTextID = id
        scheduleRender()
    }

    func textBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.annotation(id)?.text ?? "" },
            set: { new in self.mutate(id) { $0.text = new } }
        )
    }

    func finishTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        if annotation(id)?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            annotations.removeAll { $0.id == id }
            if selectedID == id { selectedID = nil }
        }
        overlayIDs.insert(id) // keep it on screen until the bitmap includes it
        dropNoopUndo()
        scheduleRender()
    }

    @discardableResult
    func deleteSelected() -> Bool {
        guard let id = selectedID, editingTextID == nil else { return false }
        pushUndo()
        annotations.removeAll { $0.id == id }
        selectedID = nil
        scheduleRender()
        return true
    }

    /// Esc: stop editing → deselect → back to Select tool. Returns false when there was nothing to do.
    func handleEscape() -> Bool {
        if editingTextID != nil { finishTextEditing(); return true }
        if selectedID != nil { selectedID = nil; return true }
        if tool != .select { tool = .select; return true }
        return false
    }

    func editSelectedText() -> Bool {
        guard let a = selectedAnnotation, a.kind == .text, editingTextID == nil else { return false }
        beginEditingText(a.id)
        return true
    }

    private func applyToSelected(_ body: @escaping (inout Annotation) -> Void) {
        guard let id = selectedID, annotation(id) != nil else { return }
        pushUndo()
        mutate(id, body)
        dropNoopUndo()
    }

    func undo() {
        finishTextEditing()
        guard let s = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(snapshot)
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(snapshot)
        restore(s)
    }

    private func restore(_ s: Snapshot) {
        let manualChanged = manual != s.manual
        annotations = s.annotations
        manual = s.manual
        selectedID = nil
        if manualChanged { rebuildRedacted() } else { scheduleRender() }
    }

    // MARK: Redaction

    func addManualRedaction(_ rect: CGRect) {
        let r = rect.standardized.intersection(sourceBounds).integral
        guard !r.isNull, r.width > 3, r.height > 3 else { return }
        pushUndo()
        manual.append(r)
        rebuildRedacted()
    }

    func clearManual() {
        guard !manual.isEmpty else { return }
        pushUndo()
        manual.removeAll()
        rebuildRedacted()
    }

    private func rebuildRedacted() {
        redactTask?.cancel()
        let img = source, redactStyle = style.redactStyle, h = CGFloat(source.height)
        let rects = (style.autoRedact ? detected : []) + manual.map { CGRect(x: $0.minX, y: h - $0.maxY, width: $0.width, height: $0.height) }
        redactTask = Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) { Redactor.apply(img, rects: rects, style: redactStyle) }.value
            guard !Task.isCancelled, let self else { return }
            redacted = out
            scheduleRender()
        }
    }

    // MARK: Style

    func applyPreset(_ preset: StylePreset?) {
        presetID = preset?.id
        style = preset?.style ?? Style()
    }

    private func styleChanged(from old: Style) {
        guard style != old else { return }
        style.save()
        if style.background != old.background { backgroundImage = BackgroundImages.image(for: style.background) }
        if style.autoRedact && !old.autoRedact { startDetection() }
        if style.autoRedact != old.autoRedact || style.redactStyle != old.redactStyle {
            rebuildRedacted()
        } else {
            scheduleRender()
        }
    }

    // MARK: Rendering

    private func renderInput(excluding excluded: Set<UUID>) -> RenderInput {
        RenderInput(
            image: redacted, style: style, scale: scale, analysis: analysis,
            annotations: annotations.filter { !excluded.contains($0.id) },
            backgroundImage: backgroundImage
        )
    }

    private func scheduleRender() {
        renderTask?.cancel()
        let excluded = Set([liveID, editingTextID].compactMap { $0 })
        let input = renderInput(excluding: excluded)
        renderTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Renderer.render(input) }.value
            guard !Task.isCancelled, let self, let result else { return }
            rendered = result
            overlayIDs = overlayIDs.intersection(excluded)
        }
    }

    // MARK: Export

    /// Final image; waits for OCR/redaction so a secret can't slip out mid-scan.
    func export() async -> CGImage? {
        finishTextEditing()
        await analysisTask?.value
        if style.autoRedact { await detectTask?.value }
        await redactTask?.value
        return Renderer.render(renderInput(excluding: []))?.image
    }

    /// ⌘C: copy and keep editing.
    func copy() { copy(thenClose: false) }

    /// Double-click on the background: copy and close the editor.
    func copyAndClose() { copy(thenClose: true) }

    private func copy(thenClose: Bool) {
        guard !exporting else { return }
        exporting = true
        if detecting { showToast("Copying after the redaction scan…") }
        Task {
            defer { exporting = false }
            guard let image = await export() else { showToast("Couldn't copy"); return }
            Exporter.copy(image, scale: scale)
            if Prefs.playSounds { NSSound(named: "Pop")?.play() }
            onCopied?()
            if thenClose { onClose?() } else { showToast("Copied to clipboard") }
        }
    }

    func quickSave() {
        guard !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            guard let image = await export(), let url = Exporter.quickSave(image, scale: scale) else {
                showToast("Couldn't save")
                return
            }
            showToast("Saved to \(url.deletingLastPathComponent().lastPathComponent) · \(url.lastPathComponent)")
        }
    }

    func saveAs() {
        guard !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            guard let image = await export() else { return }
            Exporter.save(image, scale: scale, from: window) { [weak self] url in
                self?.showToast("Saved · \(url.lastPathComponent)")
            }
        }
    }

    func dragItemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = Exporter.defaultFileName
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor [weak self] in
                guard let self, let image = await self.export(), let url = Exporter.tempFile(image, scale: self.scale) else {
                    completion(nil, false, nil)
                    return
                }
                completion(url, false, nil)
            }
            return nil
        }
        return provider
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
