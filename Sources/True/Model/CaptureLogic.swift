import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

/// The one place the capture shortcuts are defined. Primary ⌘⇧4 (takes over macOS's own, see `SystemShortcut`);
/// backup ⌃⌥⌘A always works because macOS never owns it. Carbon registration, menu item and label all follow.
enum CaptureHotKey {
    struct Combo: Sendable {
        let id: UInt32, carbonKeyCode: UInt32, carbonModifiers: UInt32
        let key: Character, modifiers: SwiftUI.EventModifiers
        var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }
    }
    static let primary = Combo(id: 2, carbonKeyCode: UInt32(kVK_ANSI_4), carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey),
                               key: "4", modifiers: [.command, .shift])
    static let backup = Combo(id: 3, carbonKeyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey),
                              key: "a", modifiers: [.control, .option, .command])
    static var all: [Combo] { [primary, backup] }
}

/// Read-only look at whether macOS still owns a built-in shortcut (`com.apple.symbolichotkeys`). Never written.
enum SystemShortcut {
    /// "Save picture of selected area as a file" = ⌘⇧4.
    static let areaScreenshotID = 30

    /// `AppleSymbolicHotKeys` dictionary → is shortcut `id` on? A missing entry means macOS's default: on.
    static func isEnabled(_ id: Int, in symbolicHotKeys: [String: Any]?) -> Bool {
        guard let entry = symbolicHotKeys?[String(id)] as? [String: Any] else { return true }
        if let b = entry["enabled"] as? Bool { return b }
        if let n = entry["enabled"] as? NSNumber { return n.boolValue }
        return true
    }

    static func areaScreenshotOwnedByMacOS() -> Bool {
        let d = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        return isEnabled(areaScreenshotID, in: d)
    }
}

/// The 8 resize handles of a rectangle (corners + edge midpoints) — one definition for the capture selection
/// and the crop tool, in whatever coordinate space the caller uses.
enum RectHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.minY); case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY); case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY); case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY); case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }
    var isCorner: Bool { switch self { case .topLeft, .topRight, .bottomRight, .bottomLeft: true; default: false } }
    private var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    private var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    private var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    private var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

    /// The handle under `p` (nearest within `slop`, default ≥ 8 pt of reach), or nil.
    static func hit(_ p: CGPoint, in r: CGRect, slop: CGFloat = 10) -> RectHandle? {
        allCases.map { ($0, hypot($0.point(in: r).x - p.x, $0.point(in: r).y - p.y)) }
            .filter { $0.1 <= slop }.min { $0.1 < $1.1 }?.0
    }

    /// `r` with this handle dragged to `p`, clamped to `bounds`; dragging past the opposite edge flips cleanly.
    /// `square` (corners only) keeps the box square, anchored on the opposite corner.
    func resized(_ r: CGRect, to p: CGPoint, square: Bool = false, bounds: CGRect, minSide: CGFloat = 8) -> CGRect {
        let q = CGPoint(x: max(bounds.minX, min(p.x, bounds.maxX)), y: max(bounds.minY, min(p.y, bounds.maxY)))
        var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        if movesLeft { x0 = q.x } else if movesRight { x1 = q.x }
        if movesTop { y0 = q.y } else if movesBottom { y1 = q.y }
        if square && isCorner {
            let ax = movesLeft ? r.maxX : r.minX, ay = movesTop ? r.maxY : r.minY   // fixed opposite corner
            var dx = q.x - ax, dy = q.y - ay
            let side = max(abs(dx), abs(dy))
            let sx: CGFloat = dx < 0 ? -1 : 1, sy: CGFloat = dy < 0 ? -1 : 1
            let room = min(sx > 0 ? bounds.maxX - ax : ax - bounds.minX, sy > 0 ? bounds.maxY - ay : ay - bounds.minY)
            let l = min(side, room)
            dx = sx * l; dy = sy * l
            x0 = ax; x1 = ax + dx; y0 = ay; y1 = ay + dy
        }
        var out = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        if out.width < minSide { out.size.width = min(minSide, bounds.width); out.origin.x = min(out.minX, bounds.maxX - out.width) }
        if out.height < minSide { out.size.height = min(minSide, bounds.height); out.origin.y = min(out.minY, bounds.maxY - out.height) }
        return out
    }
}

/// Pure geometry for the capture overlay (view points, top-left origin) — testable without a window.
enum CaptureLogic {
    /// The rectangle dragged from `a` to `b`; `square` (Shift) makes it the larger side on both axes, growing
    /// toward the cursor. Always clamped to `bounds`.
    static func dragRect(from a: CGPoint, to b: CGPoint, square: Bool, bounds: CGRect) -> CGRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side; dy = dy < 0 ? -side : side
        }
        var r = CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
        r = r.intersection(bounds)
        return r.isNull ? .zero : r
    }

    /// Move a rectangle by `d`, keeping it fully inside `bounds` and the same size.
    static func moved(_ r: CGRect, by d: CGSize, within bounds: CGRect) -> CGRect {
        CGRect(x: max(bounds.minX, min(r.minX + d.width, bounds.maxX - r.width)),
               y: max(bounds.minY, min(r.minY + d.height, bounds.maxY - r.height)),
               width: r.width, height: r.height)
    }

    /// The frontmost window under `p`. `windows` are ordered front to back; tiny ones are never snap targets.
    static func windowRect(at p: CGPoint, in windows: [CGRect]) -> CGRect? {
        windows.first { $0.width >= 40 && $0.height >= 40 && $0.contains(p) }
    }

    /// Selection (view points) → pixel rect in the frozen image, snapped to whole pixels.
    static func pixelRect(_ r: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let sx = imageSize.width / viewSize.width, sy = imageSize.height / viewSize.height
        let px = CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy).integral
        return px.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// "1280 × 720" — the live size readout (in pixels, what will be saved).
    static func sizeLabel(_ px: CGRect) -> String { "\(Int(px.width)) × \(Int(px.height))" }

    /// Toolbar frame under the selection (or above when there is no room), centred and kept on screen.
    static func toolbarOrigin(selection: CGRect, toolbar: CGSize, in bounds: CGRect, gap: CGFloat = 10) -> CGPoint {
        var y = selection.maxY + gap
        if y + toolbar.height > bounds.maxY - 8 { y = selection.minY - gap - toolbar.height }
        if y < bounds.minY + 8 { y = max(bounds.minY + 8, bounds.maxY - toolbar.height - 8) }   // selection fills the screen: float inside
        let x = max(bounds.minX + 8, min(selection.midX - toolbar.width / 2, bounds.maxX - toolbar.width - 8))
        return CGPoint(x: x, y: y)
    }
}
