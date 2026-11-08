// Renders docs/social-preview.png (1280×640), the image GitHub shows when the repo link is shared.
// Usage: swift scripts/make-social-preview.swift
import AppKit

let W: CGFloat = 1280, H: CGFloat = 640
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
func load(_ path: String) -> NSImage {
    guard let img = NSImage(contentsOf: root.appendingPathComponent(path)) else { fatalError("missing \(path)") }
    return img
}
let icon = load("docs/icon.png")
let shot = load("docs/screenshot.png") // the editor itself, not just an output

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background: deep blue → violet.
let bg = NSGradient(colors: [
    NSColor(srgbRed: 0.09, green: 0.15, blue: 0.42, alpha: 1),
    NSColor(srgbRed: 0.33, green: 0.20, blue: 0.78, alpha: 1),
])!
bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -25)

// Left column: icon, name, tagline.
let left: CGFloat = 72
icon.draw(in: NSRect(x: left, y: 400, width: 128, height: 128))

func text(_ s: String, _ font: NSFont, _ alpha: CGFloat, at p: NSPoint, width: CGFloat = 520) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.white.withAlphaComponent(alpha), .paragraphStyle: style,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let size = str.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin])
    str.draw(with: NSRect(x: p.x, y: p.y - size.height, width: width, height: size.height), options: [.usesLineFragmentOrigin])
}
text("PrimeSnap", .systemFont(ofSize: 72, weight: .bold), 1, at: NSPoint(x: left - 3, y: 380))
text("Capture, frame, annotate and redact screenshots from your menu bar.", .systemFont(ofSize: 30, weight: .medium), 0.92, at: NSPoint(x: left, y: 282), width: 460)
text("Free  ·  Open source  ·  Native macOS", .systemFont(ofSize: 24, weight: .semibold), 0.7, at: NSPoint(x: left, y: 140))

// Right: a framed result with a soft shadow.
let shotW: CGFloat = 700
let shotH = shotW * shot.size.height / shot.size.width
let shotRect = NSRect(x: W - shotW - 28, y: (H - shotH) / 2, width: shotW, height: shotH)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor.black.setFill()
NSBezierPath(roundedRect: shotRect, xRadius: 14, yRadius: 14).fill()
ctx.restoreGState()
ctx.saveGState()
NSBezierPath(roundedRect: shotRect, xRadius: 14, yRadius: 14).addClip()
shot.draw(in: shotRect)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
let out = root.appendingPathComponent("docs/social-preview.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
