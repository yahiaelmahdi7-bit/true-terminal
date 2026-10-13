import CoreGraphics
import Foundation

/// Which corner of the visible frame the screenshot chip rests in.
enum PanelCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    static let defaultsKey = "screenshotTray.corner"
    static let fallback: PanelCorner = .topRight

    /// Remembered corner (not raw coordinates, so it survives a changed display setup). Unknown → top-right.
    static func load(_ defaults: UserDefaults = .standard) -> PanelCorner {
        defaults.string(forKey: defaultsKey).flatMap(PanelCorner.init(rawValue:)) ?? fallback
    }

    func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }

    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

/// Pure geometry for the floating screenshot panel. AppKit coordinates: origin bottom-left, so "top" is maxY.
enum TrayPanelFrame {
    /// Pinned to the top-right corner of `visible` (menu bar and Dock already excluded), `inset` from both
    /// edges. A size larger than the room is clamped so the panel never leaves the screen.
    static func topRight(visible: CGRect, size: CGSize, inset: CGFloat) -> CGRect {
        frame(corner: .topRight, visible: visible, size: size, inset: inset)
    }

    /// Anchored to `corner` of `visible`, `inset` from both edges; larger sizes are clamped. A bigger panel
    /// (grid, zoom) keeps that corner fixed and so grows toward the screen centre.
    static func frame(corner: PanelCorner, visible: CGRect, size: CGSize, inset: CGFloat) -> CGRect {
        let w = min(size.width, max(0, visible.width - 2 * inset))
        let h = min(size.height, max(0, visible.height - 2 * inset))
        let x = corner.isRight ? visible.maxX - inset - w : visible.minX + inset
        let y = corner.isTop ? visible.maxY - inset - h : visible.minY + inset
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The corner whose quadrant of `visible` contains `point`; exact ties on either axis go to the right / top.
    static func nearestCorner(to point: CGPoint, in visible: CGRect) -> PanelCorner {
        let right = point.x >= visible.midX
        let top = point.y >= visible.midY
        switch (top, right) {
        case (true, true): return .topRight
        case (true, false): return .topLeft
        case (false, true): return .bottomRight
        case (false, false): return .bottomLeft
        }
    }

    /// Below this much pointer travel (pt) a press-and-release is a click, not a drag.
    static let dragThreshold: CGFloat = 4

    static func isDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= dragThreshold
    }

    /// Zoom: ~55% of the screen width, height from the image's aspect plus `chrome` (toolbar), shrunk
    /// proportionally if it would not fit the visible height.
    static func zoomSize(visible: CGRect, imageSize: CGSize, chrome: CGFloat, inset: CGFloat) -> CGSize {
        let aspect = imageSize.width > 0 && imageSize.height > 0 ? imageSize.height / imageSize.width : 0.625
        var w = (visible.width * 0.55).rounded()
        let maxH = max(0, visible.height - 2 * inset)
        if w * aspect + chrome > maxH { w = max(0, (maxH - chrome) / aspect).rounded() }
        return CGSize(width: w, height: (w * aspect + chrome).rounded())
    }
}
