import AppKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    /// Room for the traffic lights when the history sidebar is hidden.
    var leadingInset: CGFloat = 80
    var onToggleSidebar: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                EditorToolbar(model: model, leadingInset: leadingInset, onToggleSidebar: onToggleSidebar)
                CanvasArea(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BottomBar(model: model)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            EditorSidebar(model: model)
                .frame(width: 290)
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 64)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
    }
}

// MARK: - Toolbar

private struct EditorToolbar: View {
    @ObservedObject var model: EditorModel
    let leadingInset: CGFloat
    let onToggleSidebar: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let onToggleSidebar {
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("Show/hide recent captures (⌘\\)")
                Divider().frame(height: 18).padding(.horizontal, 4)
            }
            ForEach(Tool.allCases) { tool in
                ToolButton(tool: tool, selected: model.tool == tool) { model.tool = tool }
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            ColorButton(model: model)
            Picker("", selection: $model.strokeSize) {
                ForEach(StrokeSize.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 84)
            .help("Stroke / text size")
            Text("Keys 1–5 pick a tool · V select · ⌫ delete · ⌘Z undo")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 6)
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset) // traffic lights when the sidebar is hidden
        .padding(.trailing, 12)
        .frame(height: 40)
    }
}

private struct ToolButton: View {
    let tool: Tool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: tool.symbol).font(.system(size: 12, weight: .semibold))
                Text(tool.key).font(.system(size: 10, weight: .semibold, design: .rounded)).opacity(0.7)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title) (\(tool.key))")
    }
}

private struct ColorButton: View {
    @ObservedObject var model: EditorModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(cgColor: model.color.cgColor))
                .frame(width: 30, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .help("Color")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 4), spacing: 8) {
                    ForEach(RGBA.palette, id: \.self) { c in
                        Circle()
                            .fill(Color(cgColor: c.cgColor))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(c == model.color ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: c == model.color ? 3 : 1))
                            .onTapGesture { model.color = c; showing = false }
                    }
                }
                ColorPicker("Custom", selection: Binding(
                    get: { Color(cgColor: model.color.cgColor) },
                    set: { if let c = RGBA(nsColor: NSColor($0)) { model.color = c } }
                ))
            }
            .padding(14)
        }
    }
}

// MARK: - Canvas

/// Maps between view points and source-image pixels.
struct CanvasLayout {
    let frame: CGRect
    let factor: CGFloat
    let offset: CGPoint

    /// zoom nil = fit to the available space; otherwise 1.0 = one image pixel per screen pixel ("100%").
    init(result: RenderResult, in size: CGSize, scale: CGFloat, zoom: CGFloat?, backing: CGFloat) {
        let cw = result.canvasSize.width, ch = result.canvasSize.height
        let f = zoom.map { $0 / backing } ?? min(size.width / cw, size.height / ch, 1 / scale)
        let w = (cw * f).rounded(), h = (ch * f).rounded()
        frame = CGRect(x: max(0, ((size.width - w) / 2).rounded()), y: max(0, ((size.height - h) / 2).rounded()), width: w, height: h)
        factor = f
        offset = result.offset
    }

    /// Scrollable content size: at least the viewport, larger when zoomed in.
    func contentSize(in viewport: CGSize) -> CGSize {
        CGSize(width: max(viewport.width, frame.maxX), height: max(viewport.height, frame.maxY))
    }

    func toSource(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - frame.minX) / factor - offset.x, y: (p.y - frame.minY) / factor - offset.y)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x + offset.x) * factor + frame.minX, y: (p.y + offset.y) * factor + frame.minY)
    }

    func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * factor, height: r.height * factor)
    }
}

private enum DragState {
    case idle, ignore
    case create(UUID)
    case move(UUID, from: CGPoint, start: CGPoint, end: CGPoint)
    case handle(UUID, isStart: Bool)
    case redact(CGPoint)
    case text(CGPoint)
}

private struct CanvasArea: View {
    @ObservedObject var model: EditorModel
    @State private var drag: DragState = .idle
    @State private var redactRect: CGRect?
    @FocusState private var textFocused: Bool

    var body: some View {
        GeometryReader { geo in
            if let result = model.rendered {
                let backing = model.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
                let layout = CanvasLayout(result: result, in: geo.size, scale: model.scale, zoom: model.zoom.value, backing: backing)
                ScrollView([.horizontal, .vertical]) {
                    canvas(result, layout, size: layout.contentSize(in: geo.size), crisp: model.zoom != .fit)
                }
                .scrollDisabled(model.zoom == .fit)
                .scrollIndicators(model.zoom == .fit ? .never : .automatic)
            } else {
                ProgressView().frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(model.zoom == .fit ? 24 : 0)
    }

    private func canvas(_ result: RenderResult, _ layout: CanvasLayout, size: CGSize, crisp: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: result.image, scale: 1)
                .resizable()
                .interpolation(crisp ? .none : .high) // 100%+ = exact pixels, no smoothing
                .frame(width: layout.frame.width, height: layout.frame.height)
                .offset(x: layout.frame.minX, y: layout.frame.minY)

            overlay(layout)
                .allowsHitTesting(false)

            if let r = redactRect {
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
            }

            textEditor(layout)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(dragGesture(layout))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { doubleClick($0.location, layout) })
        .onContinuousHover { phase in
            switch phase {
            case .active: (model.tool == .select ? NSCursor.arrow : NSCursor.crosshair).set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }

    /// Live (being-dragged) annotations + selection chrome, drawn with the same CoreGraphics code as export.
    private func overlay(_ layout: CanvasLayout) -> some View {
        let live = model.overlayAnnotations
        let selected = model.selectedAnnotation.flatMap { $0.id == model.editingTextID ? nil : $0 }
        return Canvas { ctx, _ in
            if !live.isEmpty {
                ctx.withCGContext { cg in
                    cg.translateBy(x: layout.frame.minX, y: layout.frame.minY)
                    cg.scaleBy(x: layout.factor, y: layout.factor)
                    cg.translateBy(x: layout.offset.x, y: layout.offset.y)
                    for a in live { AnnotationDrawer.draw(a, in: cg, shadowScale: layout.factor) }
                }
            }
            if let sel = selected {
                let b = layout.toView(AnnotationDrawer.bounds(sel)).insetBy(dx: -5, dy: -5)
                ctx.stroke(Path(roundedRect: b, cornerRadius: 4), with: .color(.accentColor),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                if sel.kind != .text {
                    for p in [sel.start, sel.end] {
                        let v = layout.toView(p)
                        let dot = Path(ellipseIn: CGRect(x: v.x - 5, y: v.y - 5, width: 10, height: 10))
                        ctx.fill(dot, with: .color(.white))
                        ctx.stroke(dot, with: .color(.accentColor), lineWidth: 1.5)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func textEditor(_ layout: CanvasLayout) -> some View {
        if let id = model.editingTextID, let a = model.annotation(id) {
            let origin = layout.toView(a.start)
            TextField("Type…", text: model.textBinding(id), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: max(9, a.fontSize * layout.factor), weight: .bold))
                .foregroundStyle(Color(cgColor: a.color.cgColor))
                .frame(minWidth: 140, alignment: .topLeading)
                .fixedSize(horizontal: true, vertical: true)
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .offset(x: origin.x - 2, y: origin.y - 2)
                .focused($textFocused)
                .onSubmit { model.finishTextEditing() }
                .onAppear { textFocused = true }
                .onChange(of: textFocused) { _, focused in
                    if !focused { model.finishTextEditing() }
                }
        }
    }

    // MARK: Gestures

    private func dragGesture(_ layout: CanvasLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if case .idle = drag { begin(at: v.startLocation, layout) }
                update(to: v.location, layout)
            }
            .onEnded { v in
                end(at: v.location, layout)
                drag = .idle
            }
    }

    private func begin(at loc: CGPoint, _ layout: CanvasLayout) {
        if model.editingTextID != nil {
            model.finishTextEditing()
            drag = .ignore
            return
        }
        let p = layout.toSource(loc)

        if let sel = model.selectedAnnotation, sel.kind != .text {
            for (point, isStart) in [(sel.start, true), (sel.end, false)] where hypot(layout.toView(point).x - loc.x, layout.toView(point).y - loc.y) < 9 {
                model.beginLive(sel.id)
                drag = .handle(sel.id, isStart: isStart)
                return
            }
        }
        if model.tool != .redact, let hit = model.hitTest(p, tolerance: 6 / layout.factor) {
            model.beginLive(hit.id)
            drag = .move(hit.id, from: p, start: hit.start, end: hit.end)
            return
        }
        switch model.tool {
        case .select:
            model.selectedID = nil
            drag = .ignore
        case .redact:
            model.selectedID = nil
            drag = .redact(loc)
        case .text:
            drag = .text(p)
        case .arrow:
            drag = .create(model.createAnnotation(.arrow, at: p))
        case .rectangle:
            drag = .create(model.createAnnotation(.rectangle, at: p))
        case .highlight:
            drag = .create(model.createAnnotation(.highlight, at: p))
        }
    }

    private func update(to loc: CGPoint, _ layout: CanvasLayout) {
        let p = layout.toSource(loc)
        switch drag {
        case .create(let id):
            model.mutate(id) { $0.end = p }
        case .move(let id, let from, let s, let e):
            let dx = p.x - from.x, dy = p.y - from.y
            model.mutate(id) {
                $0.start = CGPoint(x: s.x + dx, y: s.y + dy)
                $0.end = CGPoint(x: e.x + dx, y: e.y + dy)
            }
        case .handle(let id, let isStart):
            model.mutate(id) { if isStart { $0.start = p } else { $0.end = p } }
        case .redact(let origin):
            redactRect = CGRect(x: min(origin.x, loc.x), y: min(origin.y, loc.y),
                                width: abs(loc.x - origin.x), height: abs(loc.y - origin.y))
        case .idle, .ignore, .text:
            break
        }
    }

    private func end(at loc: CGPoint, _ layout: CanvasLayout) {
        switch drag {
        case .create, .move, .handle:
            model.endLive()
        case .redact:
            if let r = redactRect {
                let a = layout.toSource(r.origin), b = layout.toSource(CGPoint(x: r.maxX, y: r.maxY))
                model.addManualRedaction(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
            }
            redactRect = nil
        case .text(let p):
            model.createText(at: p)
        case .idle, .ignore:
            break
        }
    }

    private func doubleClick(_ loc: CGPoint, _ layout: CanvasLayout) {
        let p = layout.toSource(loc)
        if let hit = model.hitTest(p, tolerance: 6 / layout.factor) {
            if hit.kind == .text { model.beginEditingText(hit.id) }
            return
        }
        if !model.sourceBounds.contains(p) { model.copyAndClose() } // double-click the background
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            Label("Drag Out", systemImage: "hand.draw")
                .font(.callout)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                .onDrag { model.dragItemProvider() }
                .help("Drag the finished image into Slack, Mail, Finder…")
            Button("Copy  ⌘C") { model.copy() }
                .buttonStyle(.borderedProminent)
            Button("Save  ⌘S") { model.quickSave() }
                .help("Save to the folder set in Settings → General")
            Button("Save As…  ⇧⌘S") { model.saveAs() }
            Picker("", selection: $model.zoom) {
                ForEach(ZoomLevel.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 84)
            .help("Zoom — ⌘0 fit · ⌘1 100% · ⌘+ / ⌘−")
            Spacer()
            Text("Double-click background = Copy & Close")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
