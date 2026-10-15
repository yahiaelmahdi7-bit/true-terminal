import Testing
import Foundation
import AppKit
import ScreenCaptureKit
@testable import True

private struct Sample {
    var n: Int; var p: CGPoint; var app: String
    var instant: [PickElement]; var final: [PickElement]
}

private func fmt(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))" }
private func desc(_ e: PickElement) -> String { "\(e.kind.rawValue) \(Int(e.frame.width))x\(Int(e.frame.height))" }

private func render(_ still: CGImage, scale: CGFloat, samples: [Sample], pick: (Sample) -> [PickElement], to url: URL) throws {
    let w = still.width, h = still.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    ctx.draw(still, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
    let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
    defer { NSGraphicsContext.restoreGraphicsState() }
    let colors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal, .systemPink, .systemYellow, .systemIndigo]
    func label(_ s: String, at o: CGPoint, color: NSColor) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white, .backgroundColor: color]
        NSAttributedString(string: " \(s) ", attributes: a).draw(at: o)
    }
    for s in samples {
        let c = colors[(s.n - 1) % colors.count]
        if let e = pick(s).first {
            let bad = !e.frame.contains(s.p)
            let col: NSColor = bad ? .systemRed : c
            let path = NSBezierPath(rect: e.frame); path.lineWidth = 2
            if bad { path.setLineDash([6, 4], count: 2, phase: 0) }
            col.setStroke(); path.stroke()
            label("\(s.n) \(e.kind.rawValue) \(Int(e.frame.width))x\(Int(e.frame.height))" + (bad ? " MISPLACED" : ""),
                  at: CGPoint(x: e.frame.minX + 2, y: e.frame.minY + 2), color: col)
        }
        let dot = NSBezierPath(ovalIn: CGRect(x: s.p.x - 5, y: s.p.y - 5, width: 10, height: 10))
        c.setFill(); dot.fill(); NSColor.white.setStroke(); dot.lineWidth = 1.5; dot.stroke()
        label("\(s.n)", at: CGPoint(x: s.p.x + 7, y: s.p.y - 7), color: c)
    }
    guard let out = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

@Suite struct SmartPickDiagnosticTests {
    static let enabled = ProcessInfo.processInfo.environment["TRUE_PICK_DIAG"] == "1"

    @MainActor
    @Test(.enabled(if: SmartPickDiagnosticTests.enabled))
    func diagnoseSmartPickOnRealDisplays() async throws {
        let env = ProcessInfo.processInfo.environment
        let outPath = try #require(env["TRUE_PICK_DIAG_OUT"], "TRUE_PICK_DIAG_OUT required")
        let dir = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windowList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        struct Win { var rect: CGRect; var owner: String }
        let wins: [Win] = windowList.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return Win(rect: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0),
                       owner: w[kCGWindowOwnerName as String] as? String ?? "?")
        }
        let old = env["TRUE_PICK_DIAG_MODE"] == "old"   // the pre-Run-28 pipeline, for comparison
        let chainOf: ([PickElement], CGRect?, [CGRect], CGPoint) -> [PickElement] = old
            ? { SmartPickLogic.legacyChain(ax: $0, window: $1, boxes: $2, at: $3) }
            : { SmartPickLogic.chain(ax: $0, window: $1, boxes: $2, at: $3) }
        var report = "mode: \(old ? "OLD" : "NEW")\nAX trusted: \(AXPick.trusted())\n"
        var mis = (instant: 0, final: 0), areas: [CGFloat] = [], tiny = 0, total = 0, windowOnly = 0, chainLen = 0
        var n = 0

        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let scale = screen.backingScaleFactor
            let cfg = SCStreamConfiguration()
            cfg.width = Int(screen.frame.width * scale); cfg.height = Int(screen.frame.height * scale)
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
            let bounds = CGDisplayBounds(id), origin = bounds.origin
            let frames = wins.map { $0.rect.offsetBy(dx: -origin.x, dy: -origin.y) }
            let size = screen.frame.size
            let raw = old ? ImageBoxDetector.detect(img) : LayoutRegions.detect(img, scale: scale)
            let boxes = SmartPickLogic.filterBoxes(raw.map {
                CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale)
            }, screen: size, minSide: old ? 24 : 20)
            report += "\ndisplay \(id) bounds=\(fmt(bounds)) screen.frame=\(fmt(screen.frame)) scale=\(scale) still=\(img.width)x\(img.height) windows=\(frames.count) imageBoxes=\(boxes.count)\n"

            var samples: [Sample] = []
            for r in 0..<4 { for c in 0..<5 {
                n += 1
                let p = CGPoint(x: size.width * (0.08 + 0.84 * CGFloat(c) / 4), y: size.height * (0.08 + 0.84 * CGFloat(r) / 3))
                let g = CGPoint(x: p.x + origin.x, y: p.y + origin.y)
                let ax = AXPick.query(at: g, excluding: [])
                let axWin = ax.window.map { SmartPickLogic.toOverlay($0, displayOrigin: origin) }
                let axChain = axWin.map { w in SmartPickLogic.clean(ax.chain.map { PickElement(frame: SmartPickLogic.toOverlay($0.frame, displayOrigin: origin), kind: $0.kind) }, window: w) } ?? []
                let win = CaptureLogic.windowRect(at: p, in: frames)
                let instant = chainOf([], win, boxes, p)
                let final = chainOf(axChain, axWin ?? win, boxes, p)
                let app = wins.first { $0.rect.contains(g) }?.owner ?? "-"
                samples.append(Sample(n: n, p: p, app: app, instant: instant, final: final))
                func l0(_ ch: [PickElement]) -> String {
                    guard let e = ch.first else { return "none" }
                    return "\(e.kind.rawValue) \(fmt(e.frame)) contains=\(e.frame.contains(p))"
                }
                if let e = instant.first, !e.frame.contains(p) { mis.instant += 1 }
                if let e = final.first {
                    if !e.frame.contains(p) { mis.final += 1 }
                    if final.count == 1 { windowOnly += 1 }
                    chainLen += final.count
                    areas.append(e.frame.width * e.frame.height); total += 1
                    if e.frame.width < 60 && e.frame.height < 30 { tiny += 1 }
                }
                report += "\(n) p=(\(Int(p.x)),\(Int(p.y))) app=\(app) instant0=\(l0(instant)) final0=\(l0(final)) chain=[\(final.map(desc).joined(separator: ", "))]\n"
            } }
            try render(img, scale: CGFloat(img.width) / size.width, samples: samples, pick: { $0.final }, to: dir.appendingPathComponent("display-\(id).png"))
            try render(img, scale: CGFloat(img.width) / size.width, samples: samples, pick: { $0.instant }, to: dir.appendingPathComponent("display-\(id)-instant.png"))
        }
        let med = areas.sorted().isEmpty ? 0 : areas.sorted()[areas.count / 2]
        report += "\nTOTALS samples=\(n) misplaced instant=\(mis.instant) final=\(mis.final) level0-median-area=\(Int(med)) pt2 level0-under-60x30=\(tiny)/\(total) window-only-chains=\(windowOnly)/\(total) mean-chain-length=\(total == 0 ? 0 : Double(chainLen) / Double(total))\n"
        try report.write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print("SmartPick diagnostic output: \(dir.path)")
    }
}
