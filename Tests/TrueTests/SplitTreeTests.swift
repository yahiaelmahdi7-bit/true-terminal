import Testing
import Foundation
import CoreGraphics
@testable import True

@Suite struct SplitTreeTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    /// a | (b over c)
    func sample() -> SplitTree {
        SplitTree.leaf(a)
            .inserting(b, beside: a, axis: .horizontal)
            .inserting(c, beside: b, axis: .vertical)
    }

    @Test func insertAndReadingOrder() {
        #expect(sample().leafIDs == [a, b, c])
        #expect(SplitTree.leaf(a).inserting(b, beside: d, axis: .horizontal) == .leaf(a)) // unknown target: no-op
    }

    @Test func removeGivesSpaceToSibling() {
        let t = sample()
        #expect(t.removing(c)?.leafIDs == [a, b])
        #expect(t.removing(a)?.leafIDs == [b, c])
        #expect(SplitTree.leaf(a).removing(a) == nil)
        #expect(t.removing(d) == t)
    }

    @Test func focusMovesByGeometry() {
        let t = sample()
        #expect(t.neighbor(of: a, .right) == b)
        #expect(t.neighbor(of: b, .down) == c)
        #expect(t.neighbor(of: c, .up) == b)
        #expect(t.neighbor(of: c, .left) == a)
        #expect(t.neighbor(of: a, .left) == nil)
        #expect(t.neighbor(of: c, .down) == nil)
    }

    @Test func doubleClickEvensOutTheWholeRow() {
        // a | b | c built as a | (b | c), dragged lopsided; a (b over c) column stays one slot.
        var t = SplitTree.leaf(a).inserting(b, beside: a, axis: .horizontal)
            .inserting(c, beside: b, axis: .horizontal)
            .inserting(d, beside: c, axis: .vertical)
        guard case .split(let outer, _, _, _, .split(let inner, _, _, _, _)) = t else { Issue.record("shape"); return }
        t = t.settingFraction(0.8, forSplit: outer).settingFraction(0.2, forSplit: inner)
        for id in [outer, inner] {   // either divider evens out all three columns
            let widths = t.equalizing(split: id).layout(in: CGSize(width: 1201, height: 400))
                .panes.filter { $0.key != d }.map(\.value.width)
            #expect(widths.max()! - widths.min()! < 1)
        }
        // The stacked pair's own divider only evens out that pair.
        guard case .split(_, _, _, _, .split(_, _, _, _, .split(let stack, _, _, _, _))) = t else { return }
        let r = t.settingFraction(0.9, forSplit: stack).equalizing(split: stack).layout(in: CGSize(width: 1201, height: 400))
        #expect(abs(r.panes[c]!.height - r.panes[d]!.height) < 1)
        #expect(r.panes[a]!.width > 900)   // the lopsided row was left alone
    }

    @Test func fractionClamps() {
        #expect(SplitTree.clampFraction(-3) == 0.05)
        #expect(SplitTree.clampFraction(9) == 0.95)
        #expect(SplitTree.clampFraction(.nan) == 0.5)
        let t = sample()   // built once: every call to sample() mints fresh split ids
        guard case .split(let id, _, _, _, _) = t else { Issue.record("expected split"); return }
        guard case .split(_, _, let f, _, _) = t.settingFraction(2, forSplit: id) else { return }
        #expect(f == 0.95)
    }

    @Test(arguments: [
        CGSize(width: 1280, height: 820), CGSize(width: 480, height: 300), CGSize(width: 137, height: 91),
        CGSize(width: 50, height: 20), CGSize(width: 3, height: 3), CGSize(width: 0, height: 0),
    ])
    func layoutInvariants(size: CGSize) {
        let t = sample().inserting(d, beside: a, axis: .vertical)
        let l = t.layout(in: size)
        let container = CGRect(origin: .zero, size: size)
        #expect(l.panes.count == 4)
        var area: CGFloat = 0
        let frames = Array(l.panes.values)
        for (i, r) in frames.enumerated() {
            #expect(r.width >= 0 && r.height >= 0)
            #expect(container.insetBy(dx: -0.001, dy: -0.001).contains(r))
            area += r.width * r.height
            for o in frames[(i + 1)...] { #expect(r.intersection(o).width * r.intersection(o).height < 0.001) }
        }
        for dv in l.dividers { area += dv.frame.width * dv.frame.height }
        // Tiling is exact once every split has room for its divider.
        if size.width >= 4 && size.height >= 4 {
            #expect(abs(area - size.width * size.height) < 0.01)
        }
    }
}
