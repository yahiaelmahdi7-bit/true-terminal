import CoreGraphics

/// Reads the layout of a frozen screenshot straight from its pixels: panes, panels, sidebars, bars, cards, media
/// and paragraph blocks. Classical CV (no ML, no network): luminance steps and whitespace gutters feed a
/// recursive XY-cut, and every region is shrink-wrapped to its content. Pure, deterministic, off the main thread.
///
/// Two kinds of cut, strongest first:
///  1. **Rules / fill changes** — a row (or column) where ≥ 60% of the span is a clean luminance step between two
///     flat neighbours: 1–2 px dividers, borders, a band meeting a differently-filled band.
///  2. **Gutters** — runs of rows (or columns) with no ink. The gap needed is adaptive to the region's own line
///     height, so paragraphs split from each other but text lines do not.
enum LayoutRegions {
    /// Pixel space, top-left origin. `scale` = backing scale of the still (min region is 40x20 *points*).
    static func detect(_ image: CGImage, scale: CGFloat = 1) -> [CGRect] {
        let f = max(1, Int((Double(image.width) / 1920).rounded()))
        let w = image.width / f, h = image.height / f
        guard w >= 16, h >= 16, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.interpolationQuality = f > 1 ? .medium : .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return [] }
        let luma = data.bindMemory(to: UInt8.self, capacity: w * h)
        let k = scale / CGFloat(f)
        let engine = Engine(luma: luma, w: w, h: h, minW: max(8, Int(40 * k)), minH: max(6, Int(20 * k)))
        engine.run()
        let px = CGFloat(f)
        var out: [CGRect] = []
        for r in engine.found {
            let rect = CGRect(x: CGFloat(r.x0) * px, y: CGFloat(r.y0) * px, width: CGFloat(r.x1 - r.x0) * px, height: CGFloat(r.y1 - r.y0) * px)
            if rect.width >= image.width.cgf * 0.985 && rect.height >= image.height.cgf * 0.985 { continue }
            if out.contains(where: { SmartPickLogic.nearlyEqual($0, rect, tol: 3 * px) || SmartPickLogic.iou($0, rect) > 0.93 }) { continue }
            out.append(rect)
        }
        return out
    }

    fileprivate struct Region { var x0: Int, y0: Int, x1: Int, y1: Int
        var w: Int { x1 - x0 }; var h: Int { y1 - y0 } }

    /// Edge maps + prefix sums so any row/column profile of any sub-rectangle is O(length), not O(area).
    fileprivate final class Engine {
        let W: Int, H: Int, minW: Int, minH: Int
        var inkRow: [UInt16], inkCol: [UInt16], stepRow: [UInt16], stepCol: [UInt16]   // cumulative sums
        var found: [Region] = []
        static let maxDepth = 9, inkT = 10, stepT = 4, flatT = 2, coverage: Float = 0.6

        init(luma L: UnsafePointer<UInt8>, w: Int, h: Int, minW: Int, minH: Int) {
            W = w; H = h; self.minW = minW; self.minH = minH
            inkRow = [UInt16](repeating: 0, count: h * (w + 1))
            stepRow = inkRow
            inkCol = [UInt16](repeating: 0, count: (h + 1) * w)
            stepCol = inkCol
            let it = Engine.inkT, st = Engine.stepT, ft = Engine.flatT
            @inline(__always) func d(_ a: UInt8, _ b: UInt8) -> Int { abs(Int(a) - Int(b)) }
            inkRow.withUnsafeMutableBufferPointer { ir in stepRow.withUnsafeMutableBufferPointer { sr in
            inkCol.withUnsafeMutableBufferPointer { ic in stepCol.withUnsafeMutableBufferPointer { sc in
                for y in 0..<h {
                    var ri: UInt16 = 0, rs: UInt16 = 0
                    for x in 0..<w {
                        let i = y * w + x, c = L[i]
                        let dx = x > 0 ? d(c, L[i - 1]) : 0
                        let dy = y > 0 ? d(c, L[i - w]) : 0
                        var ink = dx > it || dy > it
                        var sh = false, sv = false
                        if y > 0, dy >= st, dx <= ft, (x == 0 || d(L[i - w], L[i - w - 1]) <= ft) { sh = true }
                        if x > 0, dx >= st, dy <= ft, (y == 0 || d(L[i - 1], L[i - 1 - w]) <= ft) { sv = true }
                        if sh || sv { ink = true }
                        if ink { ri += 1 }
                        if sh { rs += 1 }
                        ir[y * (w + 1) + x + 1] = ri; sr[y * (w + 1) + x + 1] = rs
                        ic[(y + 1) * w + x] = ic[y * w + x] &+ (ink ? 1 : 0)
                        sc[(y + 1) * w + x] = sc[y * w + x] &+ (sv ? 1 : 0)
                    }
                }
            } } } }
        }

        func run() {
            cut(Region(x0: 0, y0: 0, x1: W, y1: H), depth: 0)
        }

        // MARK: profiles

        /// rows == true: one entry per row (for cuts along y). Returns ink counts and step coverage per entry.
        func profile(_ r: Region, rows: Bool) -> (ink: [Int], step: [Float]) {
            if rows {
                var ink = [Int](repeating: 0, count: r.h), step = [Float](repeating: 0, count: r.h)
                let span = Float(r.w)
                for y in r.y0..<r.y1 {
                    let b = y * (W + 1)
                    ink[y - r.y0] = Int(inkRow[b + r.x1]) - Int(inkRow[b + r.x0])
                    step[y - r.y0] = Float(Int(stepRow[b + r.x1]) - Int(stepRow[b + r.x0])) / span
                }
                return (ink, step)
            }
            var ink = [Int](repeating: 0, count: r.w), step = [Float](repeating: 0, count: r.w)
            let span = Float(r.h)
            for x in r.x0..<r.x1 {
                ink[x - r.x0] = Int(inkCol[r.y1 * W + x]) - Int(inkCol[r.y0 * W + x])
                step[x - r.x0] = Float(Int(stepCol[r.y1 * W + x]) - Int(stepCol[r.y0 * W + x])) / span
            }
            return (ink, step)
        }

        func shrink(_ r: Region) -> Region? {
            let rows = profile(r, rows: true).ink, cols = profile(r, rows: false).ink
            // Index 0 is skipped: after a cut it is the step row/column that produced this region, not content.
            guard let ty = rows.indices.dropFirst().first(where: { rows[$0] > 0 }), let by = rows.lastIndex(where: { $0 > 0 }),
                  let lx = cols.indices.dropFirst().first(where: { cols[$0] > 0 }), let rx = cols.lastIndex(where: { $0 > 0 }) else { return nil }
            return Region(x0: r.x0 + lx, y0: r.y0 + ty, x1: r.x0 + rx + 1, y1: r.y0 + by + 1)
        }

        // MARK: cuts

        /// Exclusion bands [start, end) along one axis, in region-local offsets, and how strong they are.
        /// Two rule groups a few px apart with nothing between them are the edges of two boxes with a gutter between
        /// (cards, panels). When any exist, cut ONLY there so each box stays whole; its inner rules wait for recursion.
        func ruleBands(_ step: [Float], ink: [Int], coverage: Float = Engine.coverage) -> (bands: [(Int, Int)], score: Float) {
            var hits: [Int] = []
            for i in 1..<max(step.count, 1) where step[i] >= coverage { hits.append(i) }
            guard !hits.isEmpty else { return ([], 0) }
            var groups: [(Int, Int)] = []
            var a = hits[0], b = hits[0]
            for i in hits.dropFirst() {
                if i - b <= 4 { b = i } else { groups.append((a, b)); a = i; b = i }
            }
            groups.append((a, b))
            let score = hits.map { step[$0] }.max() ?? 0
            var pairs: [(Int, Int)] = []
            for k in 0..<max(groups.count - 1, 0) {
                let g1 = groups[k], g2 = groups[k + 1], gap = g2.0 - g1.1
                guard gap >= 3, gap <= 40, g1.1 + 1 < g2.0 else { continue }
                if (g1.1 + 1..<g2.0).allSatisfy({ ink[$0] <= 1 }) { pairs.append((g1.0, g2.1)) }
            }
            return (pairs.isEmpty ? groups : pairs, pairs.isEmpty ? score : score + 1)
        }

        /// Text-line height of the region from its row profile (runs of inked rows up to 40 px), default 12.
        func lineHeight(_ rowInk: [Int], tol: Int) -> Int {
            var runs: [Int] = [], cur = 0
            for v in rowInk { if v > tol { cur += 1 } else { if cur > 0 { runs.append(cur) }; cur = 0 } }
            if cur > 0 { runs.append(cur) }
            let small = runs.filter { $0 <= 40 }.sorted()
            return small.isEmpty ? 12 : small[small.count / 2]
        }

        func gutterBands(_ ink: [Int], span: Int, minGap: Int) -> (bands: [(Int, Int)], score: Float) {
            let tol = max(2, Int(0.015 * Double(span)))
            var bands: [(Int, Int)] = [], best = 0, i = 0
            while i < ink.count {
                if ink[i] <= tol {
                    var j = i
                    while j < ink.count, ink[j] <= tol { j += 1 }
                    if j - i >= minGap { bands.append((i, j)); best = max(best, j - i) }   // edge margins too: trims a block off a blank page
                    i = j
                } else { i += 1 }
            }
            return (bands, Float(best))
        }

        /// Split `r` along bands; the children are the shrink-wrapped, big-enough segments between them.
        func children(of r: Region, rows: Bool, bands: [(Int, Int)], keepBand: Bool = false, fullSpan: Bool = false) -> [Region] {
            var out: [Region] = []
            var start = 0
            let len = rows ? r.h : r.w
            func seg(_ a: Int, _ b: Int) {
                guard b > a else { return }
                let s = rows ? Region(x0: r.x0, y0: r.y0 + a, x1: r.x1, y1: r.y0 + b) : Region(x0: r.x0 + a, y0: r.y0, x1: r.x0 + b, y1: r.y1)
                guard var t = shrink(s) else { return }
                // A band cut by a rule or fill change IS the box (a toolbar, a pane): keep its edges, don't wrap its labels.
                // Along the cut axis only the sides that touch a rule/fill change; and when the step runs (almost) edge to edge
                // the whole segment is the box.
                if keepBand {
                    if rows { if a > 0 { t.y0 = s.y0 }; if b < len { t.y1 = s.y1 }; if fullSpan { t = s } }
                    else { if a > 0 { t.x0 = s.x0 }; if b < len { t.x1 = s.x1 }; if fullSpan { t = s } }
                }
                if t.w >= minW, t.h >= minH { out.append(t) }
            }
            for (a, b) in bands { seg(start, a); start = b }
            seg(start, len)
            return out
        }

        func cut(_ region: Region, depth: Int) {
            guard depth < Engine.maxDepth, region.w >= minW, region.h >= minH * 2 || region.w >= minW * 2 else { return }
            let pr = profile(region, rows: true), pc = profile(region, rows: false)
            let lh = lineHeight(pr.ink, tol: max(2, Int(0.015 * Double(region.w))))

            // Tier 1 — rules and fill changes. Stronger axis first.
            let rr = ruleBands(pr.step, ink: pr.ink), rc = ruleBands(pc.step, ink: pc.ink, coverage: 0.5)   // short strips: a rounded box edge covers ~half the bar height
            let tier1: [(Bool, [(Int, Int)], Float)] = [(true, rr.bands, rr.score), (false, rc.bands, rc.score)]
                .filter { !$0.1.isEmpty }.sorted { $0.2 > $1.2 }
            // Tier 2 — gutters, with gaps adaptive to the text line height.
            let gr = gutterBands(pr.ink, span: region.w, minGap: min(40, max(8, lh)))
            let gc = gutterBands(pc.ink, span: region.h, minGap: min(40, max(6, Int(0.7 * Double(lh)))))
            let tier2: [(Bool, [(Int, Int)], Float)] = [(true, gr.bands, gr.score), (false, gc.bands, gc.score)]
                .filter { !$0.1.isEmpty }.sorted { $0.2 > $1.2 }

            for (rows, bands, _, ruled) in tier1.map({ ($0.0, $0.1, $0.2, true) }) + tier2.map({ ($0.0, $0.1, $0.2, false) }) {
                let kids = children(of: region, rows: rows, bands: bands, keepBand: ruled, fullSpan: ruled && (rows ? pr.step : pc.step).max() ?? 0 >= 0.9)
                // Two or more pieces, or one piece that is clearly smaller than what it was cut from.
                guard kids.count >= 2 || (kids.count == 1 && kids[0].w * kids[0].h * 100 <= region.w * region.h * 85) else { continue }
                for k in kids { found.append(k) }
                for k in kids { cut(k, depth: depth + 1) }
                return
            }
        }
    }
}

private extension Int { var cgf: CGFloat { CGFloat(self) } }
