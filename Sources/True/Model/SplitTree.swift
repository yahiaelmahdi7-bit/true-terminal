import Foundation
import CoreGraphics

/// A tab's pane layout: a binary tree whose leaves are terminal panes.
///
/// Pure value logic (Foundation + CoreGraphics only) so it is fully testable without a window.
/// The tree stores only PROPORTIONS (`fraction`), never pixel sizes. Pixel frames are derived by
/// `layout(in:)` from the live container size on every render, so resizing the window resizes
/// every pane and nothing can ever be clipped — the Axon bug this replaces stored absolute sizes.
indirect enum SplitTree: Codable, Equatable, Sendable {
    case leaf(UUID)
    case split(id: UUID, axis: Axis, fraction: Double, first: SplitTree, second: SplitTree)

    enum Axis: String, Codable, Sendable {
        /// Children sit side by side (a vertical divider) — "split right".
        case horizontal
        /// Children are stacked (a horizontal divider) — "split down".
        case vertical
    }

    enum Direction: Sendable { case left, right, up, down }

    /// Thickness of the divider between two panes, in points.
    static let dividerThickness: CGFloat = 1
    /// No pane may be dragged below this size on either axis (when the container allows it).
    static let minPaneSize: CGFloat = 60

    // MARK: Queries

    /// Leaves in reading order (first child before second) — the order ⌘] style cycling uses.
    var leafIDs: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, _, let a, let b): return a.leafIDs + b.leafIDs
        }
    }

    func contains(_ pane: UUID) -> Bool { leafIDs.contains(pane) }

    // MARK: Editing (all return new values; the tree is immutable)

    /// Split `target` in two, putting `newPane` second (right of / below it). Returns self when
    /// `target` is not in the tree.
    /// `before: true` puts it first instead (left of / above it).
    func inserting(_ newPane: UUID, beside target: UUID, axis: Axis,
                   splitID: UUID = UUID(), fraction: Double = 0.5, before: Bool = false) -> SplitTree {
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            return .split(id: splitID, axis: axis, fraction: fraction,
                          first: before ? .leaf(newPane) : .leaf(id),
                          second: before ? .leaf(id) : .leaf(newPane))
        case .split(let sid, let ax, let f, let a, let b):
            guard contains(target) else { return self }
            return .split(id: sid, axis: ax, fraction: f,
                          first: a.inserting(newPane, beside: target, axis: axis, splitID: splitID, fraction: fraction, before: before),
                          second: b.inserting(newPane, beside: target, axis: axis, splitID: splitID, fraction: fraction, before: before))
        }
    }

    /// Remove `pane`; its sibling takes the whole space. `nil` when the last pane is removed.
    func removing(_ pane: UUID) -> SplitTree? {
        switch self {
        case .leaf(let id):
            return id == pane ? nil : self
        case .split(let sid, let ax, let f, let a, let b):
            guard contains(pane) else { return self }
            let na = a.removing(pane), nb = b.removing(pane)
            switch (na, nb) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let x?, let y?): return .split(id: sid, axis: ax, fraction: f, first: x, second: y)
            }
        }
    }

    /// Set one divider's proportion (clamped to a sane band; pixel minimums are applied in layout).
    func settingFraction(_ fraction: Double, forSplit id: UUID) -> SplitTree {
        switch self {
        case .leaf: return self
        case .split(let sid, let ax, let f, let a, let b):
            if sid == id {
                return .split(id: sid, axis: ax, fraction: Self.clampFraction(fraction), first: a, second: b)
            }
            return .split(id: sid, axis: ax, fraction: f,
                          first: a.settingFraction(fraction, forSplit: id),
                          second: b.settingFraction(fraction, forSplit: id))
        }
    }

    /// Double-click on a divider: every pane in that divider's row (or column) gets an equal share.
    /// The row is the whole unbroken run of same-axis splits, so in a | b | c either divider evens
    /// out all three, not just the two panes it touches.
    func equalizing(split id: UUID) -> SplitTree {
        guard case .split(let sid, let ax, let f, let a, let b) = self else { return self }
        if runContains(id, axis: ax) { return equalized(along: ax) }
        return .split(id: sid, axis: ax, fraction: f,
                      first: a.equalizing(split: id), second: b.equalizing(split: id))
    }

    // MARK: Even tiling (every add / close / drop re-evens the run it touched)

    /// Which side of a target pane a drop lands on; `.center` swaps the two panes.
    enum DropZone: Sendable, CaseIterable { case left, right, top, bottom, center }

    /// `inserting`, then even out the run the new pane joined (a | b → 1/2, then 1/3 each…).
    /// Other rows and columns keep their manual sizes.
    func insertingEvened(_ newPane: UUID, beside target: UUID, axis: Axis, before: Bool = false) -> SplitTree {
        let sid = UUID()
        guard contains(target) else { return self }
        return inserting(newPane, beside: target, axis: axis, splitID: sid, before: before).equalizing(split: sid)
    }

    /// `removing`, then even out the run the closed pane was in — and only that run.
    func removingEvened(_ pane: UUID) -> SplitTree? {
        guard let info = parentInfo(of: pane) else { return removing(pane) }
        let out = removing(pane)
        // The closed pane's parent (axis A) collapses into its sibling. The run that lost a slot is
        // the one the parent belonged to (its own parent, if that also runs along A), or the
        // sibling's own A-run when the sibling is itself an A-split.
        if let gp = parentInfo(ofSplit: info.parent), gp.axis == info.axis { return out?.equalizing(split: gp.id) }
        if case .split(let sid, let ax, _, _, _) = info.sibling, ax == info.axis { return out?.equalizing(split: sid) }
        return out
    }

    /// Exchange two panes' places. Fractions don't change; leaf UUIDs stay with their panes.
    func swapping(_ x: UUID, _ y: UUID) -> SplitTree {
        guard x != y, contains(x), contains(y) else { return self }
        return relabeled(x, y)
    }

    private func relabeled(_ x: UUID, _ y: UUID) -> SplitTree {
        switch self {
        case .leaf(let id): return .leaf(id == x ? y : (id == y ? x : id))
        case .split(let sid, let ax, let f, let a, let b):
            return .split(id: sid, axis: ax, fraction: f, first: a.relabeled(x, y), second: b.relabeled(x, y))
        }
    }

    /// Drag-and-drop: move `pane` to `zone` of `target` (or swap with it for `.center`), re-evening
    /// the run it left and the run it joined. Dropping a pane on itself changes nothing.
    func moving(_ pane: UUID, onto target: UUID, zone: DropZone) -> SplitTree {
        guard pane != target, contains(pane), contains(target) else { return self }
        if zone == .center { return swapping(pane, target) }
        guard let rest = removingEvened(pane) else { return self }
        let axis: Axis = (zone == .left || zone == .right) ? .horizontal : .vertical
        return rest.insertingEvened(pane, beside: target, axis: axis, before: zone == .left || zone == .top)
    }

    private struct ParentInfo { var id: UUID; var axis: Axis; var parent: UUID; var sibling: SplitTree }

    /// The split directly above leaf `pane`, with its sibling subtree. `parent` mirrors `id`.
    private func parentInfo(of pane: UUID) -> ParentInfo? {
        guard case .split(let sid, let ax, _, let a, let b) = self else { return nil }
        if case .leaf(let id) = a, id == pane { return ParentInfo(id: sid, axis: ax, parent: sid, sibling: b) }
        if case .leaf(let id) = b, id == pane { return ParentInfo(id: sid, axis: ax, parent: sid, sibling: a) }
        return a.parentInfo(of: pane) ?? b.parentInfo(of: pane)
    }

    /// The split directly above split `child` (id + axis), if any.
    private func parentInfo(ofSplit child: UUID) -> (id: UUID, axis: Axis)? {
        guard case .split(let sid, let ax, _, let a, let b) = self else { return nil }
        for n in [a, b] { if case .split(let cid, _, _, _, _) = n, cid == child { return (sid, ax) } }
        return a.parentInfo(ofSplit: child) ?? b.parentInfo(ofSplit: child)
    }

    /// Whether split `id` is this split or sits below it through splits of `axis` only.
    private func runContains(_ id: UUID, axis: Axis) -> Bool {
        guard case .split(let sid, let ax, _, let a, let b) = self, ax == axis else { return false }
        return sid == id || a.runContains(id, axis: axis) || b.runContains(id, axis: axis)
    }

    /// Equal slots this subtree fills in a run along `axis`; a split the other way is one slot
    /// (a stacked pair is one column).
    private func slots(along axis: Axis) -> Int {
        guard case .split(_, let ax, _, let a, let b) = self, ax == axis else { return 1 }
        return a.slots(along: axis) + b.slots(along: axis)
    }

    private func equalized(along axis: Axis) -> SplitTree {
        guard case .split(let sid, let ax, _, let a, let b) = self, ax == axis else { return self }
        let wa = Double(a.slots(along: axis)), wb = Double(b.slots(along: axis))
        return .split(id: sid, axis: ax, fraction: wa / (wa + wb),
                      first: a.equalized(along: axis), second: b.equalized(along: axis))
    }

    static func clampFraction(_ f: Double) -> Double {
        guard f.isFinite else { return 0.5 }
        return min(0.95, max(0.05, f))
    }

    // MARK: Layout (the resize-proof part)

    struct DividerFrame: Equatable, Sendable {
        var splitID: UUID
        var axis: Axis
        /// The full region of the split this divider belongs to — drag positions are converted to
        /// a fraction against it.
        var region: CGRect
        var frame: CGRect
    }

    struct Layout: Equatable, Sendable {
        var panes: [UUID: CGRect] = [:]
        var dividers: [DividerFrame] = []
    }

    /// Pane and divider frames for a container of `size`, derived purely from proportions.
    /// Invariants (tested): every pane lies inside the container, panes never overlap, and the
    /// pane areas plus dividers tile the container exactly.
    func layout(in size: CGSize) -> Layout {
        var out = Layout()
        place(CGRect(origin: .zero, size: CGSize(width: max(0, size.width), height: max(0, size.height))), into: &out)
        return out
    }

    private func place(_ rect: CGRect, into out: inout Layout) {
        switch self {
        case .leaf(let id):
            out.panes[id] = rect
        case .split(let sid, let axis, let fraction, let a, let b):
            let total = axis == .horizontal ? rect.width : rect.height
            // A container thinner than the divider can't show one; shrink it so nothing spills outside.
            let d = min(Self.dividerThickness, total)
            let usable = max(0, total - d)
            var first = usable * CGFloat(Self.clampFraction(fraction))
            // Pixel minimums, only when both sides can honour them at once.
            if usable >= Self.minPaneSize * 2 {
                first = min(max(first, Self.minPaneSize), usable - Self.minPaneSize)
            }
            let second = usable - first
            switch axis {
            case .horizontal:
                let r1 = CGRect(x: rect.minX, y: rect.minY, width: first, height: rect.height)
                let dv = CGRect(x: rect.minX + first, y: rect.minY, width: d, height: rect.height)
                let r2 = CGRect(x: rect.minX + first + d, y: rect.minY, width: second, height: rect.height)
                out.dividers.append(DividerFrame(splitID: sid, axis: axis, region: rect, frame: dv))
                a.place(r1, into: &out); b.place(r2, into: &out)
            case .vertical:
                let r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: first)
                let dv = CGRect(x: rect.minX, y: rect.minY + first, width: rect.width, height: d)
                let r2 = CGRect(x: rect.minX, y: rect.minY + first + d, width: rect.width, height: second)
                out.dividers.append(DividerFrame(splitID: sid, axis: axis, region: rect, frame: dv))
                a.place(r1, into: &out); b.place(r2, into: &out)
            }
        }
    }

    // MARK: Focus movement

    /// The pane adjacent to `from` in `direction`, judged on the geometry the user sees. Among
    /// panes that lie fully beyond `from`'s edge and overlap it on the cross axis, the closest
    /// wins (ties: larger overlap). Uses a nominal 1000×1000 layout so results don't depend on
    /// the window; proportions are all that matter.
    func neighbor(of from: UUID, _ direction: Direction) -> UUID? {
        let frames = layout(in: CGSize(width: 1000, height: 1000)).panes
        guard let src = frames[from] else { return nil }
        var best: (id: UUID, gap: CGFloat, overlap: CGFloat)?
        // Top-left first so equal-distance, equal-overlap ties resolve deterministically.
        for (id, r) in frames.sorted(by: { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }) where id != from {
            let gap: CGFloat, overlap: CGFloat
            switch direction {
            case .left:  gap = src.minX - r.maxX
            case .right: gap = r.minX - src.maxX
            case .up:    gap = src.minY - r.maxY
            case .down:  gap = r.minY - src.maxY
            }
            switch direction {
            case .left, .right: overlap = min(src.maxY, r.maxY) - max(src.minY, r.minY)
            case .up, .down:    overlap = min(src.maxX, r.maxX) - max(src.minX, r.minX)
            }
            guard gap >= -0.5, overlap > 0 else { continue }
            if let b = best {
                if gap < b.gap - 0.5 || (abs(gap - b.gap) <= 0.5 && overlap > b.overlap) {
                    best = (id, gap, overlap)
                }
            } else {
                best = (id, gap, overlap)
            }
        }
        return best?.id
    }
}
