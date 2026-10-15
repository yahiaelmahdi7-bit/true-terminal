import AppKit
import Observation
import SwiftUI

enum AnnotationTool: String, CaseIterable, Sendable {
    case select, arrow, line, rect, ellipse, pen, highlight, text, step, censor, crop

    var key: Character {
        switch self {
        case .select: "v"; case .arrow: "a"; case .line: "l"; case .rect: "r"; case .ellipse: "e"; case .pen: "p"
        case .highlight: "h"; case .text: "t"; case .step: "n"; case .censor: "x"; case .crop: "c"
        }
    }
    var label: String {
        switch self {
        case .select: "Select"; case .arrow: "Arrow"; case .line: "Line"; case .rect: "Rectangle"; case .ellipse: "Ellipse"
        case .pen: "Pen"; case .highlight: "Highlighter"; case .text: "Text"; case .step: "Steps"; case .censor: "Censor"; case .crop: "Crop"
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"; case .arrow: "arrow.up.right"; case .line: "line.diagonal"; case .rect: "rectangle"
        case .ellipse: "circle"; case .pen: "pencil.tip"; case .highlight: "highlighter"; case .text: "textformat"
        case .step: "1.circle"; case .censor: "squareshape.split.3x3"; case .crop: "crop"
        }
    }
}

/// Everything the annotation editor knows: the image, the layers, the active tool and style, and the pointer
/// state machine. Views (canvas, toolbar) only read it and forward input in IMAGE PIXELS.
@MainActor @Observable
final class AnnotationState {
    struct TextEdit: Equatable { var at: CGPoint; var value: String; var index: Int? }
    private enum Drag {
        case draw(start: CGPoint), move(index: Int, original: Stroke, start: CGPoint)
        case resize(index: Int, original: Stroke, handle: Int)
        case cropResize(RectHandle, original: CGRect)
    }

    let image: CGImage
    var doc = MarkupDoc()
    var tool: AnnotationTool = .arrow { didSet { if tool != oldValue { toolChanged() } } }
    var color: MarkupColor = .red { didSet { restyle() } }
    var custom: RGBA? { didSet { restyle() } }
    var strokeWidth: CGFloat { didSet { restyle() } }
    var fontSize: CGFloat { didSet { restyle() } }
    var filled = false { didSet { restyle() } }
    var censorMode: CensorMode = .pixelate { didSet { restyle() } }
    var selected: Int?
    var textEdit: TextEdit?
    /// Points per image pixel in the canvas (set by the view) — handle and hit sizes are in points.
    var viewScale: CGFloat = 1

    private var drag: Drag?
    private var draft: Stroke?
    private var draftCrop: CGRect?
    private var pen: [CGPoint] = []

    init(image: CGImage) {
        self.image = image
        let base = MarkupDoc.defaultWidth(forImage: CGSize(width: image.width, height: image.height))
        strokeWidth = base; fontSize = base * 5
    }

    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    var hasMarks: Bool { !doc.isEmpty }

    // MARK: style

    private func currentStyle() -> Stroke {
        Stroke(mark: .pen([]), color: color, width: tool == .text ? fontSize : strokeWidth, custom: custom, filled: filled, censor: censorMode)
    }

    private func restyle() {
        guard let i = selected, doc.strokes.indices.contains(i) else { return }
        var s = doc.strokes[i]
        s.color = color; s.custom = custom
        s.width = s.isText ? fontSize : strokeWidth
        s.filled = filled; s.censor = censorMode
        doc.replace(at: i, with: s)
    }

    private func toolChanged() {
        commitText()
        if tool != .select { selected = nil }
    }

    /// Adopt a layer's style into the controls (selection changed) without writing back to it.
    private func adopt(_ s: Stroke) {
        let sel = selected; selected = nil
        color = s.color; custom = s.custom; filled = s.filled; censorMode = s.censor
        if s.isText { fontSize = s.width } else { strokeWidth = s.width }
        selected = sel
    }

    // MARK: pointer (image pixels)

    func begin(_ p: CGPoint) {
        let slop = 6 / max(viewScale, 0.01)
        switch tool {
        case .select:
            if let i = selected, doc.strokes.indices.contains(i), let h = handle(at: p, of: doc.strokes[i]) {
                drag = .resize(index: i, original: doc.strokes[i], handle: h); return
            }
            if let i = doc.strokes.indices.last(where: { doc.strokes[$0].hit(p, slop: slop) }) {
                selected = i; adopt(doc.strokes[i])
                drag = .move(index: i, original: doc.strokes[i], start: p)
            } else { selected = nil }
        case .text:
            let slopT = 4 / max(viewScale, 0.01)
            if let i = doc.strokes.indices.last(where: { doc.strokes[$0].isText && doc.strokes[$0].hit(p, slop: slopT) }) {
                commitText()
                if case .text(let v, let at) = doc.strokes[i].mark {
                    fontSize = doc.strokes[i].width
                    textEdit = TextEdit(at: at, value: v, index: i)
                }
            } else {
                commitText()
                textEdit = TextEdit(at: p, value: "", index: nil)
            }
        case .step:
            doc.add(Stroke(mark: .step(at: p), color: color, width: strokeWidth, custom: custom))
        case .pen, .highlight:
            pen = [p]; drag = .draw(start: p); updateDraft(to: p)
        case .crop where doc.crop.flatMap({ RectHandle.hit(p, in: $0, slop: 10 / max(viewScale, 0.01)) }) != nil:
            let c = doc.crop!
            drag = .cropResize(RectHandle.hit(p, in: c, slop: 10 / max(viewScale, 0.01))!, original: c)
        case .arrow, .line, .rect, .ellipse, .censor, .crop:
            drag = .draw(start: p); updateDraft(to: p)
        }
    }

    func move(_ p: CGPoint) {
        switch drag {
        case .draw: if tool == .pen || tool == .highlight { pen.append(p) }; updateDraft(to: p)
        case .move(let i, let o, let start):
            draft = o.translated(by: CGSize(width: p.x - start.x, height: p.y - start.y)); selected = i
        case .resize(_, let o, let h):
            draft = o.fitted(from: o.bounds, to: Self.resize(o.bounds, handle: h, to: p))
        case .cropResize(let h, let o):
            draftCrop = h.resized(o, to: p, bounds: CGRect(origin: .zero, size: imageSize))
        case nil: break
        }
    }

    func end(_ p: CGPoint) {
        move(p)
        defer { drag = nil; draft = nil; draftCrop = nil; pen = [] }
        switch drag {
        case .draw(let start):
            if tool == .crop {
                if hypot(p.x - start.x, p.y - start.y) > 4, let c = draftCrop { doc.setCrop(CropMath.clamp(c, to: imageSize)) }
            } else if let d = draft, isMeaningful(d) { doc.add(d) }
        case .move(let i, _, _), .resize(let i, _, _):
            if let d = draft, d != doc.strokes[i] { doc.replace(at: i, with: d) }
        case .cropResize:
            if let c = draftCrop { doc.setCrop(CropMath.clamp(c, to: imageSize)) }
        case nil: break
        }
    }

    private func isMeaningful(_ s: Stroke) -> Bool {
        switch s.mark {
        case .pen, .highlight: return true
        case .arrow(let a, let b), .line(let a, let b): return hypot(a.x - b.x, a.y - b.y) > 4
        case .rect(let r), .ellipse(let r), .censor(let r): return r.width > 3 && r.height > 3
        default: return true
        }
    }

    private func updateDraft(to p: CGPoint) {
        guard case .draw(let a) = drag else { return }
        let r = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y))
        var s = currentStyle()
        switch tool {
        case .pen: s.mark = .pen(pen)
        case .highlight: s.mark = .highlight(pen)
        case .arrow: s.mark = .arrow(from: a, to: p)
        case .line: s.mark = .line(from: a, to: p)
        case .rect: s.mark = .rect(r)
        case .ellipse: s.mark = .ellipse(r)
        case .censor: s.mark = .censor(r)
        case .crop: draftCrop = r.intersection(CGRect(origin: .zero, size: imageSize)); draft = nil; return
        default: return
        }
        draft = s
    }

    // MARK: text

    func commitText() {
        guard let t = textEdit else { return }
        textEdit = nil
        let blank = t.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let i = t.index, doc.strokes.indices.contains(i) {
            if blank { doc.remove(at: i); return }
            var s = doc.strokes[i]; s.mark = .text(t.value, at: t.at); s.width = fontSize; s.color = color; s.custom = custom
            doc.replace(at: i, with: s)
        } else if !blank {
            doc.add(Stroke(mark: .text(t.value, at: t.at), color: color, width: fontSize, custom: custom))
        }
    }

    // MARK: edits

    func deleteSelected() {
        guard let i = selected, doc.strokes.indices.contains(i) else { return }
        doc.remove(at: i); selected = nil
    }

    func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard let i = selected, doc.strokes.indices.contains(i) else { return }
        doc.replace(at: i, with: doc.strokes[i].translated(by: CGSize(width: dx, height: dy)))
    }

    func undo() { commitText(); doc.undo(); clampSelection() }
    func redo() { doc.redo(); clampSelection() }
    private func clampSelection() { if let i = selected, !doc.strokes.indices.contains(i) { selected = nil } }

    // MARK: render

    /// What the canvas shows: committed layers plus the in-progress one (and without the text being edited).
    var liveDoc: MarkupDoc {
        var d = doc
        if let t = textEdit, let i = t.index { d.remove(at: i) }
        if let s = draft {
            if case .move(let i, _, _) = drag, d.strokes.indices.contains(i) { d.replace(at: i, with: s) }
            else if case .resize(let i, _, _) = drag, d.strokes.indices.contains(i) { d.replace(at: i, with: s) }
            else { d.add(s) }
        }
        return d
    }

    /// The crop to show (committed, or being dragged now).
    var cropShown: CGRect? { draftCrop ?? doc.crop }

    func export() -> (png: Data, width: Int, height: Int)? {
        commitText()
        guard let out = MarkupRender.render(base: image, doc: doc), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { return nil }
        return (png, out.width, out.height)
    }

    // MARK: handles (8: tl t tr r br b bl l)

    func handlePoints(of s: Stroke) -> [CGPoint] {
        let b = s.bounds
        return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.midX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX, y: b.midY),
                CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.midX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.minX, y: b.midY)]
    }

    func resizable(_ s: Stroke) -> Bool { switch s.mark { case .text, .step: false; default: true } }

    private func handle(at p: CGPoint, of s: Stroke) -> Int? {
        guard resizable(s) else { return nil }
        let r = 9 / max(viewScale, 0.01)
        return handlePoints(of: s).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= r }
    }

    static func resize(_ b: CGRect, handle h: Int, to p: CGPoint) -> CGRect {
        var l = b.minX, t = b.minY, r = b.maxX, bt = b.maxY
        if [0, 6, 7].contains(h) { l = min(p.x, r - 2) }
        if [2, 3, 4].contains(h) { r = max(p.x, l + 2) }
        if [0, 1, 2].contains(h) { t = min(p.y, bt - 2) }
        if [4, 5, 6].contains(h) { bt = max(p.y, t + 2) }
        return CGRect(x: l, y: t, width: r - l, height: bt - t)
    }
}
