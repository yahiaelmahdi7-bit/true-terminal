import Foundation
import CoreGraphics

/// Where a dragged pane would land: pure geometry, so the preview and the drop agree and it is testable.
extension SplitTree {
    /// Middle half of a pane (both axes) swaps; outside it, the nearest edge names the side.
    static func dropZone(at p: CGPoint, in r: CGRect) -> DropZone {
        guard r.width > 0, r.height > 0 else { return .center }
        let rx = (p.x - r.minX) / r.width, ry = (p.y - r.minY) / r.height
        if (0.25...0.75).contains(rx), (0.25...0.75).contains(ry) { return .center }
        let edges: [(DropZone, CGFloat)] = [(.left, rx), (.right, 1 - rx), (.top, ry), (.bottom, 1 - ry)]
        return edges.min(by: { $0.1 < $1.1 })?.0 ?? .center
    }

    /// The pane under `p` (never `dragged` itself) and the zone of it `p` is in, for a container of `size`.
    func dropTarget(at p: CGPoint, in size: CGSize, excluding dragged: UUID) -> (pane: UUID, zone: DropZone)? {
        for (id, r) in layout(in: size).panes where id != dragged && r.contains(p) {
            return (id, Self.dropZone(at: p, in: r))
        }
        return nil
    }

    /// The part of `r` the dragged pane would occupy, for the live preview.
    static func previewRect(of zone: DropZone, in r: CGRect) -> CGRect {
        switch zone {
        case .center: return r
        case .left:   return CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
        case .right:  return CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
        case .top:    return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        case .bottom: return CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        }
    }
}
