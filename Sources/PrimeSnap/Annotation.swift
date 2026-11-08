import AppKit
import CoreText

enum Tool: String, CaseIterable, Identifiable {
    case select, text, arrow, redact, rectangle, highlight

    var id: String { rawValue }

    var key: String {
        switch self {
        case .select: return "V"
        case .text: return "1"
        case .arrow: return "2"
        case .redact: return "3"
        case .rectangle: return "4"
        case .highlight: return "5"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .text: return "textformat"
        case .arrow: return "arrow.up.right"
        case .redact: return "eye.slash"
        case .rectangle: return "rectangle"
        case .highlight: return "highlighter"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .text: return "Text"
        case .arrow: return "Arrow"
        case .redact: return "Redact"
        case .rectangle: return "Box"
        case .highlight: return "Highlight"
        }
    }

    static func forKey(_ key: String) -> Tool? {
        allCases.first { $0.key.lowercased() == key.lowercased() }
    }
}

enum ZoomLevel: String, CaseIterable, Identifiable {
    case fit, p50, p100, p200

    var id: String { rawValue }
    var label: String { ["Fit", "50%", "100%", "200%"][Self.allCases.firstIndex(of: self)!] }
    /// Image pixels per screen pixel; nil = fit to window.
    var value: CGFloat? { [nil, 0.5, 1, 2][Self.allCases.firstIndex(of: self)!] }

    var zoomedIn: ZoomLevel {
        switch self {
        case .fit, .p50: return .p100
        case .p100, .p200: return .p200
        }
    }

    var zoomedOut: ZoomLevel {
        switch self {
        case .p200: return .p100
        case .p100: return .p50
        case .p50, .fit: return .fit
        }
    }
}

enum StrokeSize: Int, CaseIterable, Identifiable {
    case small, medium, large
    var id: Int { rawValue }
    var label: String { ["S", "M", "L"][rawValue] }
    var multiplier: CGFloat { [0.65, 1, 1.6][rawValue] }
}

/// All geometry is in source-image pixels, top-left origin.
struct Annotation: Identifiable, Equatable, Codable {
    enum Kind: String, Equatable, Codable { case arrow, rectangle, highlight, text }

    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: RGBA
    var lineWidth: CGFloat
    var fontSize: CGFloat
    var text = ""

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var isDegenerate: Bool {
        switch kind {
        case .arrow: return hypot(end.x - start.x, end.y - start.y) < 6
        case .rectangle, .highlight: return rect.width < 4 || rect.height < 4
        case .text: return false
        }
    }
}

/// Draws annotations into a **y-down** CGContext (origin top-left).
enum AnnotationDrawer {
    static func draw(_ a: Annotation, in ctx: CGContext, shadowScale: CGFloat = 1) {
        switch a.kind {
        case .arrow: drawArrow(a, ctx, shadowScale)
        case .rectangle: drawBox(a, ctx, shadowScale)
        case .highlight: drawHighlight(a, ctx)
        case .text: drawText(a, ctx)
        }
    }

    // MARK: Shapes

    private static func withShadow(_ ctx: CGContext, _ lw: CGFloat, _ scale: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -lw * 0.35 * scale), blur: lw * 1.4 * scale, color: CGColor(gray: 0, alpha: 0.35))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawArrow(_ a: Annotation, _ ctx: CGContext, _ scale: CGFloat) {
        let s = a.start, e = a.end
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        var headLen = a.lineWidth * 4.2, headW = a.lineWidth * 3.6
        if headLen > len * 0.6 {
            let k = len * 0.6 / headLen
            headLen *= k
            headW *= k
        }
        let base = CGPoint(x: e.x - ux * headLen, y: e.y - uy * headLen)
        let px = -uy, py = ux
        withShadow(ctx, a.lineWidth, scale) {
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setFillColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: s)
            ctx.addLine(to: CGPoint(x: base.x + ux * headLen * 0.2, y: base.y + uy * headLen * 0.2))
            ctx.strokePath()
            ctx.setLineJoin(.round)
            ctx.setLineWidth(a.lineWidth * 0.5)
            ctx.move(to: e)
            ctx.addLine(to: CGPoint(x: base.x + px * headW / 2, y: base.y + py * headW / 2))
            ctx.addLine(to: CGPoint(x: base.x - px * headW / 2, y: base.y - py * headW / 2))
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
        }
    }

    private static func drawBox(_ a: Annotation, _ ctx: CGContext, _ scale: CGFloat) {
        let r = a.rect.insetBy(dx: a.lineWidth / 2, dy: a.lineWidth / 2)
        guard r.width > 0, r.height > 0 else { return }
        let radius = min(a.lineWidth * 1.4, min(r.width, r.height) / 2)
        withShadow(ctx, a.lineWidth, scale) {
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        }
    }

    private static func drawHighlight(_ a: Annotation, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        var c = a.color
        c.a = 0.45
        ctx.setFillColor(c.cgColor)
        let r = a.rect
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(4, r.height / 4), cornerHeight: min(4, r.height / 4), transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: Text

    static func font(size: CGFloat, weight: NSFont.Weight = .bold) -> CTFont {
        NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    }

    private static func lineHeight(_ font: CTFont) -> CGFloat {
        (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * 1.1
    }

    private static func makeLine(_ string: String, font: CTFont, color: CGColor, stroke: CGColor? = nil, strokeWidth: CGFloat = 0) -> CTLine {
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        if let stroke {
            attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = stroke
            attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = strokeWidth
        }
        return CTLineCreateWithAttributedString(NSAttributedString(string: string.isEmpty ? " " : string, attributes: attrs))
    }

    static func measure(_ text: String, font: CTFont) -> CGSize {
        let lines = text.components(separatedBy: "\n")
        let width = lines.map { CGFloat(CTLineGetTypographicBounds(makeLine($0, font: font, color: .black), nil, nil, nil)) }.max() ?? 0
        return CGSize(width: width, height: CGFloat(lines.count) * lineHeight(font))
    }

    /// Draws multi-line text with its top-left at `origin`, optionally with a contrasting halo.
    static func drawString(_ text: String, font: CTFont, color: CGColor, halo: CGColor?, at origin: CGPoint, in ctx: CGContext) {
        let ascent = CTFontGetAscent(font), lh = lineHeight(font)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setLineJoin(.round)
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let pos = CGPoint(x: origin.x, y: origin.y + ascent + CGFloat(i) * lh)
            if let halo {
                ctx.textPosition = pos
                CTLineDraw(makeLine(line, font: font, color: halo, stroke: halo, strokeWidth: 22), ctx)
            }
            ctx.textPosition = pos
            CTLineDraw(makeLine(line, font: font, color: color), ctx)
        }
        ctx.restoreGState()
    }

    private static func drawText(_ a: Annotation, _ ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        let halo: CGColor = a.color.luminance > 0.6 ? CGColor(gray: 0, alpha: 0.85) : CGColor(gray: 1, alpha: 0.95)
        drawString(a.text, font: font(size: a.fontSize), color: a.color.cgColor, halo: halo, at: a.start, in: ctx)
    }

    // MARK: Geometry

    static func bounds(_ a: Annotation) -> CGRect {
        switch a.kind {
        case .arrow: return a.rect.insetBy(dx: -a.lineWidth * 2, dy: -a.lineWidth * 2)
        case .rectangle: return a.rect
        case .highlight: return a.rect
        case .text:
            let size = measure(a.text.isEmpty ? "Text" : a.text, font: font(size: a.fontSize))
            return CGRect(origin: a.start, size: size)
        }
    }

    static func hitTest(_ a: Annotation, point p: CGPoint, tolerance: CGFloat) -> Bool {
        switch a.kind {
        case .arrow:
            return distance(from: p, toSegment: a.start, a.end) <= max(a.lineWidth * 1.5, tolerance)
        case .rectangle, .highlight, .text:
            return bounds(a).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
