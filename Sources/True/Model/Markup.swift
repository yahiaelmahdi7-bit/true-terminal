import CoreGraphics

/// One annotation, in IMAGE-PIXEL coordinates (origin top-left), never view points — so a mark drawn on a
/// zoomed panel lands on the same pixel when the markup is rendered at the image's native size.
enum Mark: Equatable, Sendable {
    case pen([CGPoint])
    case arrow(from: CGPoint, to: CGPoint)
    case rect(CGRect)
    case highlight([CGPoint])
    case text(String, at: CGPoint)
}

enum MarkupColor: String, CaseIterable, Sendable { case red, amber, blue }

struct Stroke: Equatable, Sendable {
    var mark: Mark
    var color: MarkupColor
    /// Line width in image pixels (font size for text).
    var width: CGFloat
}

/// The marks on one image, with standard undo semantics: a new mark after an undo drops the redo stack.
struct MarkupDoc: Equatable, Sendable {
    private(set) var strokes: [Stroke] = []
    private var redoStack: [Stroke] = []

    var canUndo: Bool { !strokes.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { strokes.isEmpty }

    mutating func add(_ stroke: Stroke) {
        strokes.append(stroke)
        redoStack.removeAll()
    }

    mutating func undo() {
        guard let s = strokes.popLast() else { return }
        redoStack.append(s)
    }

    mutating func redo() {
        guard let s = redoStack.popLast() else { return }
        strokes.append(s)
    }

    /// Clear is itself undoable-by-nothing: it empties both stacks.
    mutating func clear() {
        strokes.removeAll()
        redoStack.removeAll()
    }

    /// Map a point from a view that shows the image fitted into `viewSize` back to image pixels.
    static func imagePoint(_ p: CGPoint, viewSize: CGSize, imageSize: CGSize) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        return CGPoint(x: p.x * imageSize.width / viewSize.width, y: p.y * imageSize.height / viewSize.height)
    }

    /// The default stroke width for an image: ~0.4% of the long side, never thinner than 3 px.
    static func defaultWidth(forImage size: CGSize) -> CGFloat { max(3, (max(size.width, size.height) * 0.004).rounded()) }
}
