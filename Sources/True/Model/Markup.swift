import CoreGraphics
import Foundation

/// How a censor box hides what is under it.
enum CensorMode: String, Codable, CaseIterable, Sendable { case pixelate, blur, solid }

/// One annotation, in IMAGE-PIXEL coordinates (origin top-left), never view points — so a mark drawn on a
/// zoomed panel lands on the same pixel when the markup is rendered at the image's native size.
enum Mark: Equatable, Codable, Sendable {
    case pen([CGPoint])
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
    case rect(CGRect)
    case ellipse(CGRect)
    case highlight([CGPoint])
    case text(String, at: CGPoint)
    /// A numbered circle centred on the point. The number is NOT stored: it is the layer's rank among steps.
    case step(at: CGPoint)
    case censor(CGRect)
}

/// The house swatches. `custom` on a `Stroke` overrides these.
enum MarkupColor: String, CaseIterable, Codable, Sendable { case red, amber, blue, green, white, ink }

struct RGBA: Equatable, Codable, Sendable {
    var r: Double, g: Double, b: Double, a: Double = 1
}

struct Stroke: Equatable, Codable, Sendable {
    var mark: Mark
    var color: MarkupColor
    /// Line width in image pixels (font size for text, radius/3.5 for steps).
    var width: CGFloat
    var custom: RGBA? = nil
    /// Rectangle / ellipse drawn solid instead of outline.
    var filled: Bool = false
    var censor: CensorMode = .pixelate

    var isText: Bool { if case .text = mark { true } else { false } }
}

/// The marks on one image plus an optional crop, with snapshot undo/redo: a new change after an undo drops the
/// redo stack. Everything is value data (Codable) so Phase 4 can reopen a saved doc.
struct MarkupDoc: Equatable, Codable, Sendable {
    struct Snapshot: Equatable, Codable, Sendable { var strokes: [Stroke] = []; var crop: CGRect? = nil }

    private(set) var now = Snapshot()
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    var strokes: [Stroke] { now.strokes }
    /// Crop rectangle in image pixels; nil = whole image.
    var crop: CGRect? { now.crop }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// True when there is nothing to render beyond the plain image.
    var isEmpty: Bool { now.strokes.isEmpty && now.crop == nil }

    private mutating func commit(_ next: Snapshot) {
        guard next != now else { return }
        undoStack.append(now)
        now = next
        redoStack.removeAll()
    }

    mutating func add(_ stroke: Stroke) { var n = now; n.strokes.append(stroke); commit(n) }
    mutating func replace(at i: Int, with s: Stroke) {
        guard now.strokes.indices.contains(i) else { return }
        var n = now; n.strokes[i] = s; commit(n)
    }
    mutating func remove(at i: Int) {
        guard now.strokes.indices.contains(i) else { return }
        var n = now; n.strokes.remove(at: i); commit(n)
    }
    mutating func setCrop(_ r: CGRect?) { var n = now; n.crop = r; commit(n) }

    mutating func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(now); now = s
    }

    mutating func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(now); now = s
    }

    /// Clear empties everything including history.
    mutating func clear() { now = Snapshot(); undoStack.removeAll(); redoStack.removeAll() }

    /// 1-based number of the step layer at index `i` (its rank among step layers); nil if not a step.
    func stepNumber(at i: Int) -> Int? {
        guard now.strokes.indices.contains(i), case .step = now.strokes[i].mark else { return nil }
        return now.strokes[..<i].filter { if case .step = $0.mark { true } else { false } }.count + 1
    }
    var nextStepNumber: Int { now.strokes.filter { if case .step = $0.mark { true } else { false } }.count + 1 }

    /// Map a point from a view that shows the image fitted into `viewSize` back to image pixels.
    static func imagePoint(_ p: CGPoint, viewSize: CGSize, imageSize: CGSize) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        return CGPoint(x: p.x * imageSize.width / viewSize.width, y: p.y * imageSize.height / viewSize.height)
    }

    /// The default stroke width for an image: ~0.4% of the long side, never thinner than 3 px.
    static func defaultWidth(forImage size: CGSize) -> CGFloat { max(3, (max(size.width, size.height) * 0.004).rounded()) }
}

// MARK: - Geometry of a layer (hit-test, move, resize)

extension Stroke {
    static let highlightFactor: CGFloat = 5
    static let stepRadiusFactor: CGFloat = 3.5

    var stepRadius: CGFloat { max(width * Self.stepRadiusFactor, 12) }

    /// Tight box around the layer in image pixels (text uses a size estimate).
    var bounds: CGRect {
        func box(_ pts: [CGPoint], pad: CGFloat) -> CGRect {
            guard let f = pts.first else { return .zero }
            var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
            for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
        }
        switch mark {
        case .pen(let p): return box(p, pad: width / 2)
        case .highlight(let p): return box(p, pad: width * Self.highlightFactor / 2)
        case .arrow(let a, let b), .line(let a, let b): return box([a, b], pad: width / 2)
        case .rect(let r), .ellipse(let r), .censor(let r): return r.standardized
        case .text(let s, let at): return CGRect(origin: at, size: Self.textSize(s, fontSize: width))
        case .step(let c): let r = stepRadius; return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        }
    }

    /// Estimated text extent (the renderer measures for real; hit-testing only needs close).
    static func textSize(_ s: String, fontSize: CGFloat) -> CGSize {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map(\.count).max() ?? 1
        return CGSize(width: CGFloat(max(longest, 1)) * fontSize * 0.6, height: CGFloat(max(lines.count, 1)) * fontSize * 1.2)
    }

    /// Does a click at `p` (image px) land on this layer? `slop` widens thin marks to a fingertip.
    func hit(_ p: CGPoint, slop: CGFloat) -> Bool {
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { Self.distance(p, toSegment: a, b) <= max(width / 2, 0) + slop }
        switch mark {
        case .arrow(let a, let b), .line(let a, let b): return near(a, b)
        case .pen(let pts):
            if pts.count == 1 { return near(pts[0], pts[0]) }
            return zip(pts, pts.dropFirst()).contains { near($0, $1) }
        case .highlight(let pts):
            let r = width * Self.highlightFactor / 2 + slop
            return zip(pts, pts.dropFirst()).contains { Self.distance(p, toSegment: $0, $1) <= r } || pts.count == 1 && hypot(p.x - pts[0].x, p.y - pts[0].y) <= r
        case .rect(let r):
            let rr = r.standardized
            return filled ? rr.insetBy(dx: -slop, dy: -slop).contains(p)
                : rr.insetBy(dx: -slop - width / 2, dy: -slop - width / 2).contains(p) && !rr.insetBy(dx: slop + width / 2, dy: slop + width / 2).contains(p)
        case .ellipse(let r):
            let rr = r.standardized
            guard rr.width > 0, rr.height > 0 else { return false }
            let dx = (p.x - rr.midX) / (rr.width / 2), dy = (p.y - rr.midY) / (rr.height / 2)
            let d = hypot(dx, dy)
            let tol = (slop + width / 2) / max(min(rr.width, rr.height) / 2, 1)
            return filled ? d <= 1 + tol : abs(d - 1) <= tol
        case .text, .step, .censor: return bounds.insetBy(dx: -slop, dy: -slop).contains(p)
        }
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    func translated(by d: CGSize) -> Stroke {
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.width, y: p.y + d.height) }
        var s = self
        switch mark {
        case .pen(let p): s.mark = .pen(p.map(t))
        case .highlight(let p): s.mark = .highlight(p.map(t))
        case .arrow(let a, let b): s.mark = .arrow(from: t(a), to: t(b))
        case .line(let a, let b): s.mark = .line(from: t(a), to: t(b))
        case .rect(let r): s.mark = .rect(r.offsetBy(dx: d.width, dy: d.height))
        case .ellipse(let r): s.mark = .ellipse(r.offsetBy(dx: d.width, dy: d.height))
        case .censor(let r): s.mark = .censor(r.offsetBy(dx: d.width, dy: d.height))
        case .text(let str, let at): s.mark = .text(str, at: t(at))
        case .step(let c): s.mark = .step(at: t(c))
        }
        return s
    }

    /// Resize: map the layer's box `old` onto `new` (affine, per axis). Text and steps only move.
    func fitted(from old: CGRect, to new: CGRect) -> Stroke {
        guard old.width > 0, old.height > 0 else { return self }
        let sx = new.width / old.width, sy = new.height / old.height
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: new.minX + (p.x - old.minX) * sx, y: new.minY + (p.y - old.minY) * sy) }
        func mr(_ r: CGRect) -> CGRect { CGRect(x: new.minX + (r.minX - old.minX) * sx, y: new.minY + (r.minY - old.minY) * sy, width: r.width * sx, height: r.height * sy) }
        var s = self
        switch mark {
        case .pen(let p): s.mark = .pen(p.map(m))
        case .highlight(let p): s.mark = .highlight(p.map(m))
        case .arrow(let a, let b): s.mark = .arrow(from: m(a), to: m(b))
        case .line(let a, let b): s.mark = .line(from: m(a), to: m(b))
        case .rect(let r): s.mark = .rect(mr(r.standardized))
        case .ellipse(let r): s.mark = .ellipse(mr(r.standardized))
        case .censor(let r): s.mark = .censor(mr(r.standardized))
        case .text, .step: return translated(by: CGSize(width: new.minX - old.minX, height: new.minY - old.minY))
        }
        return s
    }
}

// MARK: - Crop maths

enum CropMath {
    static let minSide: CGFloat = 8

    /// Clamp a requested crop to the image, snapped to whole pixels, never smaller than `minSide`.
    static func clamp(_ r: CGRect, to size: CGSize) -> CGRect {
        let s = r.standardized
        let x0 = max(0, min(s.minX, size.width)).rounded(.down), y0 = max(0, min(s.minY, size.height)).rounded(.down)
        let x1 = max(0, min(s.maxX, size.width)).rounded(.up), y1 = max(0, min(s.maxY, size.height)).rounded(.up)
        var w = max(x1 - x0, min(minSide, size.width)), h = max(y1 - y0, min(minSide, size.height))
        w = min(w, size.width); h = min(h, size.height)
        return CGRect(x: min(x0, size.width - w), y: min(y0, size.height - h), width: w, height: h)
    }

    /// A mark point in the ORIGINAL image → the same point in the cropped output.
    static func toCropped(_ p: CGPoint, crop: CGRect?) -> CGPoint {
        guard let c = crop else { return p }
        return CGPoint(x: p.x - c.minX, y: p.y - c.minY)
    }
}
