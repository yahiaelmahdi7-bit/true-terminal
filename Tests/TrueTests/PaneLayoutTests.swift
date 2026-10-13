import Testing
import Foundation
import CoreGraphics
@testable import True

/// Even tiling + move/swap: pure SplitTree behaviour, no window.
@Suite struct PaneLayoutTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let size = CGSize(width: 1201, height: 801)   // 1201 = 3 panes + 2 dividers of 1pt → 1199/3 not integral; use tolerance

    func w(_ t: SplitTree, _ p: UUID) -> CGFloat { t.layout(in: size).panes[p]!.width }
    func h(_ t: SplitTree, _ p: UUID) -> CGFloat { t.layout(in: size).panes[p]!.height }

    /// a | b | c built the way the model does it: split beside the last pane.
    func row3() -> SplitTree {
        SplitTree.leaf(a)
            .insertingEvened(b, beside: a, axis: .horizontal)
            .insertingEvened(c, beside: b, axis: .horizontal)
    }

    @Test func threeInARowAreEven() {
        let two = SplitTree.leaf(a).insertingEvened(b, beside: a, axis: .horizontal)
        #expect(abs(w(two, a) - w(two, b)) < 1)
        let t = row3()
        #expect(t.leafIDs == [a, b, c])
        #expect(abs(w(t, a) - w(t, b)) < 1 && abs(w(t, b) - w(t, c)) < 1)
        #expect(abs(w(t, a) - 1199.0 / 3) < 1)
    }

    @Test func fourInARowAreEven() {
        let t = row3().insertingEvened(d, beside: c, axis: .horizontal)
        for p in [a, b, c] { #expect(abs(w(t, p) - w(t, d)) < 1) }
    }

    @Test func closeMiddleOfThreeEvensTheRest() {
        let t = row3().removingEvened(b)!
        #expect(t.leafIDs == [a, c])
        #expect(abs(w(t, a) - w(t, c)) < 1)
    }

    @Test func closeEvensOnlyItsOwnRun() {
        // (a over d) | b | c — the stack's manual 0.8 split belongs to another run and must survive.
        var t = row3().insertingEvened(d, beside: a, axis: .vertical)
        guard case .split(_, _, _, .split(let stack, _, _, _, _), _) = t else { Issue.record("shape"); return }
        t = t.settingFraction(0.8, forSplit: stack)
        let closed = t.removingEvened(b)!
        #expect(abs(w(closed, a) - w(closed, c)) < 1)
        guard case .split(_, _, _, .split(_, _, let f, _, _), _) = closed else { Issue.record("shape"); return }
        #expect(f == 0.8)
    }

    @Test func manualDragPersistsUntilNextChange() {
        var t = row3()
        guard case .split(let root, _, _, _, _) = t else { return }
        t = t.settingFraction(0.7, forSplit: root)
        #expect(w(t, a) > 700)
        // a close in ANOTHER row would not touch it; a new add in this row does re-even
        let t2 = t.insertingEvened(d, beside: c, axis: .horizontal)
        for p in [a, b, c] { #expect(abs(w(t2, p) - w(t2, d)) < 1) }
    }

    @Test func mixedAxesPreserved() {
        // a | (b over c): adding d right of a evens the top-level row: a, d, (b/c column) = 3 slots
        let base = SplitTree.leaf(a).inserting(b, beside: a, axis: .horizontal).inserting(c, beside: b, axis: .vertical)
        let t = base.insertingEvened(d, beside: a, axis: .horizontal)
        #expect(Set(t.leafIDs) == [a, b, c, d])
        #expect(abs(w(t, a) - w(t, d)) < 1 && abs(w(t, d) - w(t, b)) < 1)
        #expect(abs(w(t, b) - w(t, c)) < 0.001)       // stacked pair still one column
        #expect(abs(h(t, b) - h(t, c)) < 2)           // and still split evenly by height
    }

    @Test(arguments: [SplitTree.DropZone.left, .right, .top, .bottom])
    func dropOnEdgesPlacesPaneOnThatSide(zone: SplitTree.DropZone) {
        let base = SplitTree.leaf(a).insertingEvened(b, beside: a, axis: .horizontal).insertingEvened(c, beside: b, axis: .horizontal)
        let t = base.moving(a, onto: c, zone: zone)
        let l = t.layout(in: size).panes
        #expect(Set(t.leafIDs) == [a, b, c])
        #expect(l.count == 3)
        switch zone {
        case .left:   #expect(l[a]!.maxX <= l[c]!.minX && abs(l[a]!.minY - l[c]!.minY) < 1 && l[a]!.minX > l[b]!.minX)
        case .right:  #expect(l[a]!.minX >= l[c]!.maxX)
        case .top:    #expect(l[a]!.maxY <= l[c]!.minY && abs(l[a]!.width - l[c]!.width) < 1)
        case .bottom: #expect(l[a]!.minY >= l[c]!.maxY && abs(l[a]!.width - l[c]!.width) < 1)
        case .center: break
        }
    }

    @Test func leftDropEvensBothRuns() {
        // a|b|c, move a to the left of c → b | a | c, all even (run it left and run it joined are the same row)
        let t = row3().moving(a, onto: c, zone: .left)
        #expect(t.leafIDs == [b, a, c])
        #expect(abs(w(t, a) - w(t, b)) < 1 && abs(w(t, a) - w(t, c)) < 1)
    }

    @Test func topDropLeavesRunEvenAndSharesColumn() {
        // move c above a: column (c over a) | b — the row it left (a|b) and the row it joined re-even
        let t = row3().moving(c, onto: a, zone: .top)
        #expect(Set(t.leafIDs) == [a, b, c])
        #expect(abs(w(t, a) - w(t, b)) < 1)
        #expect(abs(h(t, c) - h(t, a)) < 2)
        #expect(abs(w(t, c) - w(t, a)) < 0.001)
    }

    @Test func swapExchangesPlacesAndKeepsFractions() {
        let base = row3()
        guard case .split(let root, _, _, _, _) = base else { return }
        let lop = base.settingFraction(0.7, forSplit: root)
        let t = lop.swapping(a, c)
        #expect(t.leafIDs == [c, b, a])
        #expect(abs(w(t, c) - w(lop, a)) < 0.001)
        #expect(lop.moving(a, onto: c, zone: .center) == t)
        #expect(t.swapping(a, a) == t)
    }

    @Test func selfDropIsNoOp() {
        let t = row3()
        for z in SplitTree.DropZone.allCases { #expect(t.moving(b, onto: b, zone: z) == t) }
        #expect(SplitTree.leaf(a).moving(a, onto: a, zone: .left) == .leaf(a))
        #expect(t.moving(d, onto: a, zone: .left) == t)   // unknown pane
    }

    @Test func nestedRunsOnlyEvenTheTouchedRun() {
        // a | (b over (c | d)): drop d... close d → c alone under b; top row untouched except slots
        let t = SplitTree.leaf(a).insertingEvened(b, beside: a, axis: .horizontal)
            .insertingEvened(c, beside: b, axis: .vertical)
            .insertingEvened(d, beside: c, axis: .horizontal)
        #expect(abs(w(t, c) - w(t, d)) < 1)
        let closed = t.removingEvened(d)!
        #expect(closed.leafIDs == [a, b, c])
        #expect(abs(w(closed, b) - w(closed, c)) < 0.001)
        #expect(abs(w(closed, a) - w(closed, b)) < 1)    // top row was even (2 slots) and still is
    }

    @Test func moveKeepsLeafUUIDsAndCodableRoundTrips() throws {
        for z in SplitTree.DropZone.allCases {
            let t = row3().moving(b, onto: c, zone: z)
            #expect(Set(t.leafIDs) == [a, b, c])
            let back = try JSONDecoder().decode(SplitTree.self, from: JSONEncoder().encode(t))
            #expect(back == t)
        }
    }

    @Test func layoutStaysExactAfterMoves() {
        let t = row3().moving(a, onto: c, zone: .bottom).moving(b, onto: a, zone: .right)
        let l = t.layout(in: size)
        var area: CGFloat = l.dividers.reduce(0) { $0 + $1.frame.width * $1.frame.height }
        for r in l.panes.values { area += r.width * r.height }
        #expect(abs(area - size.width * size.height) < 0.01)
    }

    @Test func dropZonesFromGeometry() {
        let r = CGRect(x: 100, y: 50, width: 400, height: 200)
        #expect(SplitTree.dropZone(at: CGPoint(x: 300, y: 150), in: r) == .center)
        #expect(SplitTree.dropZone(at: CGPoint(x: 110, y: 150), in: r) == .left)
        #expect(SplitTree.dropZone(at: CGPoint(x: 490, y: 150), in: r) == .right)
        #expect(SplitTree.dropZone(at: CGPoint(x: 300, y: 55), in: r) == .top)
        #expect(SplitTree.dropZone(at: CGPoint(x: 300, y: 245), in: r) == .bottom)
        #expect(SplitTree.previewRect(of: .left, in: r) == CGRect(x: 100, y: 50, width: 200, height: 200))
        #expect(SplitTree.previewRect(of: .bottom, in: r) == CGRect(x: 100, y: 150, width: 400, height: 100))
    }

    @Test func dropTargetFindsPaneUnderPointerAndIgnoresDragged() {
        let t = row3()
        let l = t.layout(in: size).panes
        let inC = CGPoint(x: l[c]!.midX, y: l[c]!.midY)
        #expect(t.dropTarget(at: inC, in: size, excluding: a)?.pane == c)
        #expect(t.dropTarget(at: inC, in: size, excluding: a)?.zone == .center)
        #expect(t.dropTarget(at: inC, in: size, excluding: c) == nil)            // over itself
        #expect(t.dropTarget(at: CGPoint(x: -5, y: -5), in: size, excluding: a) == nil)   // outside
    }
}
