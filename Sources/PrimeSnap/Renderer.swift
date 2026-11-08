import AppKit
import CoreGraphics

struct ImageAnalysis {
    /// Dominant color along the screenshot's edges (used for inset fill).
    let edgeColor: RGBA
    /// Region inside uniform edge-colored margins, source pixels top-left origin (used by Balance).
    let contentBounds: CGRect
}

struct RenderInput {
    let image: CGImage
    let style: Style
    let scale: CGFloat
    let analysis: ImageAnalysis?
    let annotations: [Annotation]
    let backgroundImage: CGImage?
}

struct RenderResult {
    let image: CGImage
    /// canvas point = source point + offset (pixels, top-left origin).
    let offset: CGPoint
    let canvasSize: CGSize
}

/// Pure CoreGraphics compositing. Works in a y-down context so everything shares the top-left convention.
enum Renderer {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func render(_ input: RenderInput) -> RenderResult? {
        let style = input.style, scale = input.scale, img = input.image
        let full = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        let insetPx = (CGFloat(style.inset) * scale).rounded()

        var crop = full
        if insetPx > 0, style.balance, let b = input.analysis?.contentBounds, b.width > 0, b.height > 0 { crop = b }
        guard let content = crop == full ? img : img.cropping(to: crop) else { return nil }

        let cardW = crop.width + insetPx * 2, cardH = crop.height + insetPx * 2
        let hasBG = style.background != .none
        let pad = hasBG ? (CGFloat(style.padding) * scale).rounded() : 0
        var cw = cardW + pad * 2, ch = cardH + pad * 2
        if hasBG, let ratio = style.aspect.ratio {
            if cw / ch < ratio { cw = ch * ratio } else { ch = cw / ratio }
        }
        cw = cw.rounded()
        ch = ch.rounded()

        guard let ctx = CGContext(
            data: nil, width: Int(cw), height: Int(ch), bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: ch)
        ctx.scaleBy(x: 1, y: -1)

        drawBackground(style.background, image: input.backgroundImage, in: CGRect(x: 0, y: 0, width: cw, height: ch), ctx)

        let card = CGRect(x: ((cw - cardW) / 2).rounded(), y: ((ch - cardH) / 2).rounded(), width: cardW, height: cardH)
        let radius = min(CGFloat(style.cornerRadius) * scale, min(cardW, cardH) / 2)
        let path = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if hasBG && style.shadow > 0 {
            let s = CGFloat(style.shadow)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale * s), blur: 50 * scale * s, color: CGColor(gray: 0, alpha: 0.5 * s))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if insetPx > 0 {
            ctx.setFillColor((style.insetColor ?? input.analysis?.edgeColor ?? .white).cgColor)
            ctx.fill(card)
        }
        ctx.interpolationQuality = .none
        drawImage(content, in: card.insetBy(dx: insetPx, dy: insetPx), ctx)
        ctx.restoreGState()

        let offset = CGPoint(x: card.minX + insetPx - crop.minX, y: card.minY + insetPx - crop.minY)
        if !input.annotations.isEmpty {
            ctx.saveGState()
            ctx.translateBy(x: offset.x, y: offset.y)
            for a in input.annotations { AnnotationDrawer.draw(a, in: ctx) }
            ctx.restoreGState()
        }

        let mark = style.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if style.watermarkEnabled && !mark.isEmpty {
            let font = AnnotationDrawer.font(size: 13 * scale, weight: .semibold)
            let size = AnnotationDrawer.measure(mark, font: font)
            let margin = max(10 * scale, pad * 0.22)
            let origin = CGPoint(x: cw - margin - size.width, y: ch - margin - size.height)
            AnnotationDrawer.drawString(mark, font: font, color: CGColor(gray: 1, alpha: 0.92), halo: CGColor(gray: 0, alpha: 0.25), at: origin, in: ctx)
        }

        guard let out = ctx.makeImage() else { return nil }
        return RenderResult(image: out, offset: offset, canvasSize: CGSize(width: cw, height: ch))
    }

    /// Draws an image upright inside a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func drawBackground(_ bg: Background, image: CGImage?, in canvas: CGRect, _ ctx: CGContext) {
        switch bg {
        case .none:
            return
        case .gradient(let i):
            drawGradient(GradientPreset.all[GradientPreset.all.indices.contains(i) ? i : 0], in: canvas, ctx)
        case .desktop, .image:
            guard let image else {
                drawGradient(GradientPreset.all[0], in: canvas, ctx)
                return
            }
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let s = max(canvas.width / iw, canvas.height / ih)
            let rect = CGRect(x: (canvas.width - iw * s) / 2, y: (canvas.height - ih * s) / 2, width: iw * s, height: ih * s)
            ctx.saveGState()
            ctx.clip(to: canvas)
            ctx.interpolationQuality = .high
            drawImage(image, in: rect, ctx)
            ctx.restoreGState()
        }
    }

    private static func drawGradient(_ preset: GradientPreset, in canvas: CGRect, _ ctx: CGContext) {
        if preset.colors.count == 1 {
            ctx.setFillColor(preset.colors[0].cgColor)
            ctx.fill(canvas)
            return
        }
        let gradient = CGGradient(colorsSpace: colorSpace, colors: preset.colors.map(\.cgColor) as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: canvas.width, y: canvas.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
}

enum ImageAnalyzer {
    /// Finds the dominant edge color and the content area inside uniform margins of that color.
    static func analyze(_ image: CGImage) -> ImageAnalysis {
        let w = image.width, h = image.height
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        guard w > 2, h > 2,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: Renderer.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else {
            return ImageAnalysis(edgeColor: .white, contentBounds: full)
        }
        ctx.draw(image, in: full)
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }

        var counts: [Int: Int] = [:]
        var sums: [Int: (Int, Int, Int, Int)] = [:]
        func sample(_ x: Int, _ y: Int) {
            let c = rgb(x, y)
            let key = (c.0 >> 4) << 8 | (c.1 >> 4) << 4 | (c.2 >> 4)
            counts[key, default: 0] += 1
            let s = sums[key] ?? (0, 0, 0, 0)
            sums[key] = (s.0 + c.0, s.1 + c.1, s.2 + c.2, s.3 + 1)
        }
        for x in stride(from: 0, to: w, by: max(1, w / 512)) { sample(x, 0); sample(x, h - 1) }
        for y in stride(from: 0, to: h, by: max(1, h / 512)) { sample(0, y); sample(w - 1, y) }

        guard let dominant = counts.max(by: { $0.value < $1.value })?.key, let s = sums[dominant], s.3 > 0 else {
            return ImageAnalysis(edgeColor: .white, contentBounds: full)
        }
        let edge = (s.0 / s.3, s.1 / s.3, s.2 / s.3)
        let edgeColor = RGBA(r: Double(edge.0) / 255, g: Double(edge.1) / 255, b: Double(edge.2) / 255)

        let tol = 6 // tight: subtle UI panels (e.g. #F5F5F7 on white) must count as content
        func matches(_ x: Int, _ y: Int) -> Bool {
            let c = rgb(x, y)
            return abs(c.0 - edge.0) <= tol && abs(c.1 - edge.1) <= tol && abs(c.2 - edge.2) <= tol
        }
        func rowUniform(_ y: Int) -> Bool {
            for x in 0..<w where !matches(x, y) { return false }
            return true
        }
        func colUniform(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
            for y in y0...y1 where !matches(x, y) { return false }
            return true
        }

        var top = 0
        while top < h && rowUniform(top) { top += 1 }
        guard top < h else { return ImageAnalysis(edgeColor: edgeColor, contentBounds: full) }
        var bottom = h - 1
        while bottom > top && rowUniform(bottom) { bottom -= 1 }
        var left = 0
        while left < w - 1 && colUniform(left, top, bottom) { left += 1 }
        var right = w - 1
        while right > left && colUniform(right, top, bottom) { right -= 1 }

        return ImageAnalysis(
            edgeColor: edgeColor,
            contentBounds: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        )
    }
}
