import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// On-device OCR + pattern matching for secrets, and the pixel ops to hide them.
/// All rects are in source-image pixels with a bottom-left origin (Vision / CoreImage convention).
enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,                                   // email
        #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,                                              // IPv4
        #"\+?\d[\d\s().-]{7,}\d"#,                                                    // phone / card numbers
        #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}"#,                            // Stripe
        #"\bsk-[A-Za-z0-9_-]{16,}"#,                                                  // OpenAI/Anthropic-style keys
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,                                             // GitHub tokens
        #"\bAKIA[0-9A-Z]{16}\b"#,                                                     // AWS access key id
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,                                           // Slack tokens
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,             // JWT
        #"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{32,}\b"#,  // long opaque tokens
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let ciContext = CIContext(options: [.workingColorSpace: Renderer.colorSpace, .cacheIntermediates: false])

    /// Returns nil when the scan itself failed — callers must treat that as "unknown", never as "nothing found".
    static func detect(_ image: CGImage) -> [CGRect]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // CPU, not the Neural Engine: for screenshot-sized images it's ~75 ms vs a ~28 s cold model load,
        // and the ANE path intermittently fails outright (e5rt error 13).
        if let devices = try? request.supportedComputeStageDevices[.main],
           let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
            request.setComputeDevice(cpu, for: .main)
        }
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }

        let w = image.width, h = image.height
        var rects: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            let full = NSRange(text.startIndex..., in: text)
            for regex in patterns {
                for match in regex.matches(in: text, range: full) {
                    guard let range = Range(match.range, in: text),
                          let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                    let px = VNImageRectForNormalizedRect(box, w, h).insetBy(dx: -4, dy: -3).integral
                    if !rects.contains(where: { $0.contains(px) }) { rects.append(px) }
                }
            }
        }
        return rects
    }

    static func apply(_ image: CGImage, rects: [CGRect], style: RedactStyle) -> CGImage {
        guard !rects.isEmpty else { return image }
        let base = CIImage(cgImage: image)
        let clamped = base.clampedToExtent()
        var out = base

        for raw in rects {
            let r = raw.intersection(base.extent)
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            let piece: CIImage?
            switch style {
            case .pixelate:
                let f = CIFilter.pixellate()
                f.inputImage = clamped
                f.scale = Float(max(8, r.height / 3))
                f.center = CGPoint(x: r.minX, y: r.minY)
                piece = f.outputImage
            case .blur:
                let f = CIFilter.gaussianBlur()
                f.inputImage = clamped
                f.radius = Float(max(8, r.height / 2))
                piece = f.outputImage
            case .solid:
                piece = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.09))
            }
            if let piece { out = piece.cropped(to: r).composited(over: out) }
        }

        return ciContext.createCGImage(out, from: base.extent, format: .RGBA8, colorSpace: image.colorSpace ?? Renderer.colorSpace) ?? image
    }
}
