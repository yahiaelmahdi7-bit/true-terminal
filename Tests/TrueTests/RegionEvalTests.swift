import Testing
import Foundation
import AppKit
@testable import True

/// Labelled region eval. Enabled only with `TRUE_REGION_EVAL=<dir>` holding `labels.json` + images:
/// `{"images":[{"file":"x.png","window":[x,y,w,h],"scale":1,"probes":[{"name":"…","p":[x,y],"accept":[[x,y,w,h],…]}]}]}`
/// (points; `scale` optional, default 1). Runs the OLD pipeline (ImageBoxDetector + filterBoxes + legacy chain) and the
/// NEW one (LayoutRegions + merged chain). Never fails on findings — only on setup errors.
private struct Labels: Decodable {
    struct Probe: Decodable { var name: String; var p: [CGFloat]; var accept: [[CGFloat]] }
    struct Img: Decodable { var file: String; var window: [CGFloat]; var scale: CGFloat?; var probes: [Probe] }
    var images: [Img]
}

private func rect(_ a: [CGFloat]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }

@Suite struct RegionEvalTests {
    static let dir = ProcessInfo.processInfo.environment["TRUE_REGION_EVAL"]

    @Test(.enabled(if: RegionEvalTests.dir != nil))
    func evaluate() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: try #require(Self.dir), isDirectory: true)
        let outDir = URL(fileURLWithPath: env["TRUE_REGION_EVAL_OUT"] ?? dir.path, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let labels = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: dir.appendingPathComponent("labels.json")))
        let modes = (env["TRUE_REGION_EVAL_MODE"] ?? "old,new").split(separator: ",").map(String.init)

        for mode in modes {
            var pass = 0, total = 0, levels: [Int] = [], ms: [Double] = []
            print("=== region eval — \(mode.uppercased()) pipeline ===")
            for im in labels.images {
                let url = dir.appendingPathComponent(im.file)
                let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(im.file)")
                let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
                let scale = im.scale ?? 1, window = rect(im.window)
                let t0 = Date()
                let boxes: [CGRect]
                if mode == "old" {
                    boxes = SmartPickLogic.filterBoxes(ImageBoxDetector.detect(img).map { CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale) },
                                                        screen: CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
                } else {
                    boxes = SmartPickLogic.filterBoxes(LayoutRegions.detect(img, scale: scale).map { CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale) },
                                                        screen: CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale), minSide: 20)
                }
                let dt = Date().timeIntervalSince(t0) * 1000
                ms.append(dt)
                print("\(im.file): \(boxes.count) regions, detector \(Int(dt)) ms")
                var marks: [(p: CGPoint, l0: CGRect?, match: CGRect?, ok: Bool)] = []
                for pr in im.probes {
                    let p = CGPoint(x: pr.p[0], y: pr.p[1]), accept = pr.accept.map(rect)
                    let chain = mode == "old" ? SmartPickLogic.legacyChain(ax: [], window: window, boxes: boxes, at: p)
                                              : SmartPickLogic.chain(ax: [], window: window, boxes: boxes, at: p)
                    var hit: (Int, CGRect)?
                    for (i, e) in chain.enumerated() { if let a = accept.first(where: { SmartPickLogic.iou(e.frame, $0) >= 0.8 }) { hit = (i, a); break } }
                    total += 1; if let h = hit { pass += 1; levels.append(h.0) }
                    let l0 = chain.first.map { "\($0.kind.rawValue) (\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height)))" } ?? "none"
                    print("  \(hit != nil ? "PASS" : "FAIL") \(pr.name) level=\(hit.map { String($0.0) } ?? "-") chain=\(chain.count) l0=\(l0)" + (env["TRUE_REGION_EVAL_CHAIN"] != nil ? " | " + chain.map { "\($0.kind.rawValue)(\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height)))" }.joined(separator: " > ") : ""))
                    marks.append((p, chain.first?.frame, hit.map { chain[$0.0].frame }, hit != nil))
                }
                try draw(img, scale: scale, boxes: boxes, marks: marks, to: outDir.appendingPathComponent("eval-\(mode)-\((im.file as NSString).deletingPathExtension).png"))
            }
            let med = levels.sorted().isEmpty ? -1 : levels.sorted()[levels.count / 2]
            print("TOTALS \(mode.uppercased()): pass \(pass)/\(total) = \(total == 0 ? 0 : Int(Double(pass) / Double(total) * 100))%  median matched level \(med)  mean detector \(Int(ms.reduce(0, +) / Double(max(ms.count, 1)))) ms")
        }
    }

    private func draw(_ img: CGImage, scale: CGFloat, boxes: [CGRect], marks: [(p: CGPoint, l0: CGRect?, match: CGRect?, ok: Bool)], to url: URL) throws {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.translateBy(x: 0, y: CGFloat(img.height)); ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.systemCyan.withAlphaComponent(0.8).setStroke()
        for r in boxes { let b = NSBezierPath(rect: r); b.lineWidth = 1; b.stroke() }
        for m in marks {
            if let r = m.l0 { let b = NSBezierPath(rect: r); b.lineWidth = 2; NSColor.systemRed.setStroke(); b.stroke() }
            if let r = m.match { let b = NSBezierPath(rect: r); b.lineWidth = 3; NSColor.systemGreen.setStroke(); b.stroke() }
            (m.ok ? NSColor.systemGreen : NSColor.systemRed).setFill()
            NSBezierPath(ovalIn: CGRect(x: m.p.x - 5, y: m.p.y - 5, width: 10, height: 10)).fill()
        }
        guard let out = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
