import AppKit
import CoreGraphics
import CoreImage

/// Paints an image plus its `MarkupDoc` with CoreGraphics. `scale` 1 = the image's native pixels (export);
/// the live editor calls the same code at view scale, so what you see is what is saved.
enum MarkupRender {
    nonisolated(unsafe) private static let ci = CIContext()

    static func rgb(_ s: Stroke) -> RGBA {
        if let c = s.custom { return c }
        switch s.color {
        case .red: return RGBA(r: 1.0, g: 0.27, b: 0.23)
        case .amber: return RGBA(r: 1.0, g: 0.62, b: 0.24)
        case .blue: return RGBA(r: 0.04, g: 0.52, b: 1.0)
        case .green: return RGBA(r: 0.19, g: 0.82, b: 0.40)
        case .white: return RGBA(r: 1, g: 1, b: 1)
        case .ink: return RGBA(r: 0.07, g: 0.07, b: 0.08)
        }
    }

    /// Highlighter is a plain alpha blend of a BRIGHT colour (no multiply/darken), so yellow stays yellow on dark
    /// and light content alike. The house amber is orange; as a marker it becomes a true yellow.
    static let highlightAlpha: CGFloat = 0.55
    static func highlightRGB(_ s: Stroke) -> RGBA {
        if s.custom == nil, s.color == .amber { return RGBA(r: 1.0, g: 0.86, b: 0.10) }
        return rgb(s)
    }

    private static func cg(_ c: RGBA, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * alpha)
    }

    /// Image + layers (+ crop when `applyCrop`) at `scale` × native size. Nil only if a context can't be made.
    static func render(base: CGImage, doc: MarkupDoc, scale: CGFloat = 1, applyCrop: Bool = true) -> CGImage? {
        let W = Int((CGFloat(base.width) * scale).rounded()), H = Int((CGFloat(base.height) * scale).rounded())
        guard W > 0, H > 0, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: scale, y: -scale)   // top-left origin, image pixels
        var n = 0
        for s in doc.strokes {
            if case .step = s.mark { n += 1 }
            draw(s, step: n, in: ctx, scale: scale, size: CGSize(width: W, height: H))
        }
        guard let full = ctx.makeImage() else { return nil }
        guard applyCrop, let c = doc.crop else { return full }
        let r = CGRect(x: c.minX * scale, y: c.minY * scale, width: c.width * scale, height: c.height * scale).integral
        return full.cropping(to: r.intersection(CGRect(x: 0, y: 0, width: W, height: H))) ?? full
    }

    static func png(base: CGImage, doc: MarkupDoc) -> Data? {
        guard let out = render(base: base, doc: doc) else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    // MARK: layers

    private static func draw(_ s: Stroke, step: Int, in ctx: CGContext, scale: CGFloat, size: CGSize) {
        let col = cg(rgb(s))
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(col); ctx.setFillColor(col); ctx.setLineWidth(s.width)
        switch s.mark {
        case .pen(let pts):
            ctx.addPath(smoothPath(pts)); ctx.strokePath()
        case .highlight(let pts):
            ctx.setStrokeColor(cg(highlightRGB(s), alpha: highlightAlpha)); ctx.setLineWidth(s.width * Stroke.highlightFactor)
            ctx.addPath(smoothPath(pts)); ctx.strokePath()
        case .line(let a, let b):
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        case .arrow(let a, let b):
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(s.width * 4, 14)
            let base = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
            ctx.move(to: a); ctx.addLine(to: base); ctx.strokePath()
            let spread = CGFloat.pi / 7
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: b.x - cos(angle - spread) * head, y: b.y - sin(angle - spread) * head))
            ctx.addLine(to: CGPoint(x: b.x - cos(angle + spread) * head, y: b.y - sin(angle + spread) * head))
            ctx.closePath(); ctx.fillPath()
        case .rect(let r):
            let rr = r.standardized
            let p = CGPath(roundedRect: rr, cornerWidth: min(2, rr.width / 2), cornerHeight: min(2, rr.height / 2), transform: nil)
            ctx.addPath(p); s.filled ? ctx.fillPath() : ctx.strokePath()
        case .ellipse(let r):
            s.filled ? ctx.fillEllipse(in: r.standardized) : ctx.strokeEllipse(in: r.standardized)
        case .text(let str, let at):
            drawText(str, at: at, size: s.width, color: col, in: ctx)
        case .step(let c):
            let r = s.stepRadius
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            let c0 = rgb(s)
            let light = (0.299 * c0.r + 0.587 * c0.g + 0.114 * c0.b) > 0.72
            let font = NSFont.systemFont(ofSize: r * 1.15, weight: .bold)
            let label = NSAttributedString(string: "\(step)", attributes: [.font: font, .foregroundColor: light ? NSColor(white: 0.07, alpha: 1) : NSColor.white])
            let ext = label.size()
            withFlipped(ctx) { label.draw(at: NSPoint(x: c.x - ext.width / 2, y: c.y - ext.height / 2)) }
        case .censor(let r):
            censor(r, s: s, in: ctx, scale: scale, size: size)
        }
    }

    /// Quadratic curve through the midpoints of the sampled points: smooth without a fitting pass.
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let f = pts.first else { return p }
        if pts.count < 3 {
            p.move(to: f); p.addLine(to: pts.last ?? f); return p
        }
        p.move(to: f)
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }

    private static func withFlipped(_ ctx: CGContext, _ body: () -> Void) {
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.current = prev
    }

    private static func drawText(_ str: String, at: CGPoint, size: CGFloat, color: CGColor, in ctx: CGContext) {
        let attr = NSAttributedString(string: str, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.red,
        ])
        withFlipped(ctx) { attr.draw(at: NSPoint(x: at.x, y: at.y)) }
    }

    /// Measured text size (what the editor's re-edit box and hit-test use).
    static func textSize(_ str: String, fontSize: CGFloat) -> CGSize {
        let attr = NSAttributedString(string: str.isEmpty ? " " : str, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)])
        let s = attr.size()
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    // MARK: censor — reads the composite so far, touches only whole pixels inside the rect

    private static func censor(_ r: CGRect, s: Stroke, in ctx: CGContext, scale: CGFloat, size: CGSize) {
        let dev = CGRect(x: r.standardized.minX * scale, y: r.standardized.minY * scale,
                         width: r.standardized.width * scale, height: r.standardized.height * scale)
            .integral.intersection(CGRect(origin: .zero, size: size))
        guard dev.width >= 1, dev.height >= 1 else { return }
        let target = CGRect(x: dev.minX / scale, y: dev.minY / scale, width: dev.width / scale, height: dev.height / scale)
        func put(_ img: CGImage, interpolation: CGInterpolationQuality) {
            ctx.saveGState()
            ctx.interpolationQuality = interpolation
            ctx.translateBy(x: target.minX, y: target.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
            ctx.restoreGState()
        }
        switch s.censor {
        case .solid:
            ctx.setFillColor(cg(rgb(s))); ctx.fill(target)
        case .pixelate:
            guard let snap = ctx.makeImage()?.cropping(to: dev) else { return }
            let block = max(s.width * 3, 8) * scale
            let sw = max(1, Int((dev.width / block).rounded(.up))), sh = max(1, Int((dev.height / block).rounded(.up)))
            guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
            small.interpolationQuality = .high
            small.draw(snap, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            if let tiny = small.makeImage() { put(tiny, interpolation: .none) }
        case .blur:
            guard let snap = ctx.makeImage()?.cropping(to: dev) else { return }
            let input = CIImage(cgImage: snap)
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: max(s.width * 2.5, 6) * scale).cropped(to: input.extent)
            if let out = ci.createCGImage(blurred, from: input.extent) { put(out, interpolation: .none) }
        }
    }
}
