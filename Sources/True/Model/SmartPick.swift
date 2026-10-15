import CoreGraphics
import Vision

/// Plain human names for what is under the cursor. Never a raw Accessibility role string.
enum PickKind: String, Sendable {
    case button = "Button", text = "Text", image = "Image", toolbar = "Toolbar", sidebar = "Sidebar", list = "List"
    case tabs = "Tabs", menu = "Menu", section = "Section", page = "Page", window = "Window", area = "Area"
    case pane = "Pane", bar = "Bar"   // image regions only: a full-height column / a full-width strip

    static func from(role: String?, subrole: String? = nil) -> PickKind {
        let r = role ?? "", sub = subrole ?? ""
        if r.contains("Sidebar") || sub.contains("Sidebar") { return .sidebar }
        switch r {
        case "AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXDisclosureTriangle", "AXSwitch": return .button
        case "AXStaticText", "AXTextField", "AXTextArea", "AXLink", "AXHeading", "AXComboBox", "AXSearchField": return .text
        case "AXImage": return .image
        case "AXToolbar": return .toolbar
        case "AXList", "AXTable", "AXOutline", "AXRow", "AXCell", "AXColumn", "AXBrowser": return .list
        case "AXTabGroup": return .tabs
        case "AXMenu", "AXMenuBar", "AXMenuItem", "AXMenuBarItem": return .menu
        case "AXWebArea": return .page
        case "AXWindow", "AXSheet", "AXDrawer": return .window
        default: return .section
        }
    }
}

struct PickElement: Equatable, Sendable {
    var frame: CGRect
    var kind: PickKind
}

/// Pure logic behind "hover an element, click to capture just that": chain cleaning, coordinate flip,
/// choosing between Accessibility and image candidates, and the grow/shrink cursor. Testable without a window.
enum SmartPickLogic {
    /// Drag threshold: ≥ this many points between mouse-down and mouse-up is a drag; less is a click.
    static let dragThreshold: CGFloat = 4

    static func isClick(down: CGPoint, up: CGPoint) -> Bool { hypot(up.x - down.x, up.y - down.y) < dragThreshold }

    /// Global (AX / CGWindowList, top-left of the primary display) → the overlay's view space for the screen
    /// whose top-left sits at `displayOrigin` in that same global space. Both are points, so scale never enters.
    static func toOverlay(_ r: CGRect, displayOrigin: CGPoint) -> CGRect { r.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y) }
    static func toGlobal(_ p: CGPoint, displayOrigin: CGPoint) -> CGPoint { CGPoint(x: p.x + displayOrigin.x, y: p.y + displayOrigin.y) }

    /// `chain` is innermost → outermost. Drops zero/1-pt frames, clamps each to the window, and merges
    /// near-duplicates (every edge within 2 pt of the previous kept one) — the outer one's name wins unless it is
    /// only a generic Section. The window itself is always last.
    static func clean(_ chain: [PickElement], window: CGRect) -> [PickElement] {
        var out: [PickElement] = []
        for e in chain {
            let f = e.frame.standardized.intersection(window)
            guard !f.isNull, f.width > 1, f.height > 1 else { continue }
            if let last = out.last, nearlyEqual(last.frame, f) {
                if last.kind == .section && e.kind != .section { out[out.count - 1].kind = e.kind }
                continue
            }
            out.append(PickElement(frame: f, kind: e.kind))
        }
        if let last = out.last, nearlyEqual(last.frame, window) { out[out.count - 1].kind = .window }
        else { out.append(PickElement(frame: window, kind: .window)) }
        return out
    }

    static func nearlyEqual(_ a: CGRect, _ b: CGRect, tol: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol && abs(a.maxX - b.maxX) <= tol && abs(a.maxY - b.maxY) <= tol
    }

    /// The final chain for the cursor, innermost → outermost, window last. Merges the Accessibility elements and the
    /// image-detected layout regions that contain `p` into ONE nested chain, so a coarse AX element never hides finer
    /// image regions. Near-duplicates (every edge within 3 pt) merge and the AX name wins over "Area"; a box that does
    /// not contain the previous kept one (within ~3 pt) is dropped, so every level nests in the next.
    static func chain(ax: [PickElement], window: CGRect?, boxes: [CGRect], at p: CGPoint) -> [PickElement] {
        guard let w = window ?? ax.last?.frame else {
            return containing(p, in: boxes).map { PickElement(frame: $0, kind: .area) }
        }
        let slack: CGFloat = 3
        let wide = w.insetBy(dx: -2, dy: -2)
        var cands: [PickElement] = ax.filter { $0.frame.insetBy(dx: -1, dy: -1).contains(p) && wide.contains($0.frame) && !nearlyEqual($0.frame, w, tol: slack) }
        for b in containing(p, in: boxes) where wide.contains(b) && !nearlyEqual(b, w, tol: slack) {
            cands.append(PickElement(frame: b, kind: regionKind(b, window: w)))
        }
        // Smallest first; on equal size the AX element sorts ahead of the image region.
        let axFrames = Set(ax.map { FrameKey($0.frame) })
        cands.sort {
            let a0 = $0.frame.width * $0.frame.height, a1 = $1.frame.width * $1.frame.height
            if abs(a0 - a1) > 1 { return a0 < a1 }
            return axFrames.contains(FrameKey($0.frame)) && !axFrames.contains(FrameKey($1.frame))
        }
        var out: [PickElement] = []
        for c in cands {
            guard let last = out.last else { out.append(c); continue }
            if nearlyEqual(last.frame, c.frame, tol: slack) {
                if isGeneric(last.kind) && !isGeneric(c.kind) || last.kind == .section && c.kind != .section { out[out.count - 1].kind = c.kind }
            } else if c.frame.insetBy(dx: -slack, dy: -slack).contains(last.frame) {
                out.append(c)
            }
        }
        out.append(PickElement(frame: w, kind: .window))
        return out
    }

    private struct FrameKey: Hashable {
        var x, y, w, h: Int
        init(_ r: CGRect) { x = Int(r.minX.rounded()); y = Int(r.minY.rounded()); w = Int(r.width.rounded()); h = Int(r.height.rounded()) }
    }
    private static func isGeneric(_ k: PickKind) -> Bool { k == .area || k == .pane || k == .bar }

    /// Plain label for an image region, from its shape against the window: a full-height column is a Pane,
    /// a full-width strip is a Bar, everything else is an Area.
    static func regionKind(_ r: CGRect, window w: CGRect) -> PickKind {
        if r.height >= w.height * 0.85 && r.width <= w.width * 0.85 { return .pane }
        if r.width >= w.width * 0.85 && r.height <= w.height * 0.3 { return .bar }
        return .area
    }

    /// The pre-Run-28 chain (Accessibility replaces image boxes whenever it found anything finer than the window).
    /// Kept only as the baseline for the region eval.
    static func legacyChain(ax: [PickElement], window: CGRect?, boxes: [CGRect], at p: CGPoint) -> [PickElement] {
        if ax.count > 1 { return ax }
        let inside = containing(p, in: boxes).filter { b in window.map { $0.insetBy(dx: -2, dy: -2).contains(b) } ?? true }
        let areas = inside.map { PickElement(frame: $0, kind: .area) }
        guard let w = window ?? ax.last?.frame else { return areas }
        return clean(areas, window: w)
    }

    /// Boxes containing `p`, smallest first.
    static func containing(_ p: CGPoint, in boxes: [CGRect]) -> [CGRect] {
        boxes.filter { $0.contains(p) }.sorted { $0.width * $0.height < $1.width * $1.height }
    }
    static func smallestContaining(_ p: CGPoint, in boxes: [CGRect]) -> CGRect? { containing(p, in: boxes).first }

    // MARK: image fallback candidates

    /// Detector output → usable boxes: nothing tiny, nothing that is the whole screen, near-duplicates merged.
    static func filterBoxes(_ boxes: [CGRect], screen: CGSize, minSide: CGFloat = 24, maxCover: CGFloat = 0.92, cap: Int = 160) -> [CGRect] {
        let area = screen.width * screen.height
        func size(_ r: CGRect) -> CGFloat { r.width * r.height }
        var sorted: [CGRect] = []
        for b in boxes.map({ $0.standardized }) where b.width >= minSide && b.height >= minSide && size(b) <= area * maxCover { sorted.append(b) }
        sorted.sort { size($0) > size($1) }
        var kept: [CGRect] = []
        for b in sorted where !kept.contains(where: { nearlyEqual($0, b, tol: 3) || iou($0, b) > 0.9 }) { kept.append(b) }
        return Array(kept.prefix(cap))
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let ia = i.width * i.height
        return ia / (a.width * a.height + b.width * b.height - ia)
    }
}

/// Which level of the chain is picked: 0 = the element under the cursor, last = the window.
struct SmartPicker: Equatable, Sendable {
    private(set) var elements: [PickElement] = []
    private(set) var level = 0

    init(_ elements: [PickElement] = [], level: Int = 0) { self.elements = elements; self.level = min(max(level, 0), max(elements.count - 1, 0)) }
    var current: PickElement? { elements.indices.contains(level) ? elements[level] : nil }
    mutating func grow() { if level < elements.count - 1 { level += 1 } }
    mutating func shrink() { if level > 0 { level -= 1 } }
    mutating func jumpToWindow() { level = max(elements.count - 1, 0) }

    /// A new chain keeps the user on the same FRAME when it is still in it (so an Accessibility answer never makes the
    /// box jump), otherwise the smallest level.
    mutating func replace(_ new: [PickElement]) {
        let cur = current?.frame
        elements = new
        level = cur.flatMap { c in new.firstIndex { SmartPickLogic.nearlyEqual($0.frame, c, tol: 2) } } ?? 0
    }
}

/// Finds rectangular regions in a frozen screenshot: Vision's rectangle detector plus its contour pass (which
/// catches borderless panels). Pixel space, top-left origin. Heavy — call off the main thread.
enum ImageBoxDetector {
    static func detect(_ image: CGImage, maxSide: Int = 1280) -> [CGRect] {
        let k = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * k)), h = max(1, Int(CGFloat(image.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return [] }

        let rects = VNDetectRectanglesRequest()
        rects.maximumObservations = 60; rects.minimumConfidence = 0.4; rects.minimumSize = 0.02
        rects.minimumAspectRatio = 0.05; rects.quadratureTolerance = 20
        let contours = VNDetectContoursRequest()
        contours.contrastAdjustment = 1.5; contours.maximumImageDimension = 512
        let handler = VNImageRequestHandler(cgImage: small, options: [:])
        try? handler.perform([rects, contours])

        var boxes: [CGRect] = []
        func add(_ n: CGRect) {   // normalized bottom-left → image pixels top-left
            boxes.append(CGRect(x: n.minX * CGFloat(image.width), y: (1 - n.maxY) * CGFloat(image.height),
                                width: n.width * CGFloat(image.width), height: n.height * CGFloat(image.height)))
        }
        for o in rects.results ?? [] { add(o.boundingBox) }
        if let top = contours.results?.first {
            func walk(_ c: VNContour, depth: Int) {
                let b = c.normalizedPath.boundingBox
                if c.pointCount >= 4, b.width > 0.02, b.height > 0.02 { add(b) }
                if depth < 2 { for child in c.childContours { walk(child, depth: depth + 1) } }
            }
            for c in top.topLevelContours { walk(c, depth: 0) }
        }
        return boxes
    }
}
