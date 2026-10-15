import Testing
import Foundation
import AppKit
@testable import True

/// A busy gradient so pixelate/blur visibly change pixels.
private func busyImage(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    for y in 0..<h { for x in 0..<w {
        ctx.setFillColor(CGColor(srgbRed: CGFloat((x * 7) % 256) / 255, green: CGFloat((y * 13) % 256) / 255,
                                 blue: CGFloat((x ^ y) % 2 == 0 ? 1 : 0), alpha: 1))
        ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
    } }
    return ctx.makeImage()!
}

private func pixels(_ img: CGImage) -> [UInt8] {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}

private func px(_ b: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> [UInt8] { Array(b[(y * w + x) * 4 ..< (y * w + x) * 4 + 4]) }

@Suite struct MarkupModelTests {
    @Test func codableRoundTrip() throws {
        var d = MarkupDoc()
        d.add(Stroke(mark: .arrow(from: .init(x: 1, y: 2), to: .init(x: 30, y: 40)), color: .red, width: 4))
        d.add(Stroke(mark: .text("hi", at: .init(x: 5, y: 6)), color: .blue, width: 18, custom: RGBA(r: 0.1, g: 0.2, b: 0.3)))
        d.add(Stroke(mark: .censor(CGRect(x: 1, y: 1, width: 9, height: 9)), color: .ink, width: 3, censor: .blur))
        d.setCrop(CGRect(x: 0, y: 0, width: 50, height: 40))
        let back = try JSONDecoder().decode(MarkupDoc.self, from: JSONEncoder().encode(d))
        #expect(back.strokes == d.strokes)
        #expect(back.crop == d.crop)
    }

    @Test func stepNumbering() {
        var d = MarkupDoc()
        func step(_ x: CGFloat) { d.add(Stroke(mark: .step(at: .init(x: x, y: 5)), color: .red, width: 4)) }
        #expect(d.nextStepNumber == 1)
        step(1)
        d.add(Stroke(mark: .rect(CGRect(x: 0, y: 0, width: 5, height: 5)), color: .red, width: 4))
        step(20); step(40)
        #expect(d.stepNumber(at: 0) == 1)
        #expect(d.stepNumber(at: 2) == 2)
        #expect(d.stepNumber(at: 3) == 3)
        #expect(d.stepNumber(at: 1) == nil)
        #expect(d.nextStepNumber == 4)
        d.remove(at: 0)
        #expect(d.stepNumber(at: 1) == 1)   // renumbers after delete
    }

    @Test func undoRedoIncludingCrop() {
        var d = MarkupDoc()
        d.add(Stroke(mark: .line(from: .zero, to: .init(x: 5, y: 5)), color: .red, width: 3))
        d.setCrop(CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(d.crop != nil)
        d.undo(); #expect(d.crop == nil); #expect(d.strokes.count == 1)
        d.undo(); #expect(d.strokes.isEmpty)
        d.redo(); d.redo()
        #expect(d.strokes.count == 1 && d.crop != nil)
        d.undo()
        d.add(Stroke(mark: .rect(CGRect(x: 0, y: 0, width: 4, height: 4)), color: .blue, width: 3))
        #expect(!d.canRedo)   // new change drops redo
    }

    @Test func cropClamp() {
        let size = CGSize(width: 100, height: 60)
        #expect(CropMath.clamp(CGRect(x: -10, y: -10, width: 500, height: 500), to: size) == CGRect(x: 0, y: 0, width: 100, height: 60))
        let tiny = CropMath.clamp(CGRect(x: 50, y: 50, width: 1, height: 1), to: size)
        #expect(tiny.width >= CropMath.minSide && tiny.height >= CropMath.minSide)
        #expect(CGRect(origin: .zero, size: size).contains(tiny))
        // dragged backwards
        let back = CropMath.clamp(CGRect(x: 40, y: 30, width: -20, height: -10), to: size)
        #expect(back.minX == 20 && back.minY == 20 && back.width == 20 && back.height == 10)
    }
}

@Suite struct MarkupRenderTests {
    @Test func nativePixelSizeAndAlignment() {
        let base = busyImage(120, 80)
        var d = MarkupDoc()
        d.add(Stroke(mark: .rect(CGRect(x: 10, y: 20, width: 40, height: 30)), color: .red, width: 4, filled: true))
        let out = MarkupRender.render(base: base, doc: d)!
        #expect(out.width == 120 && out.height == 80)
        let p = pixels(out), b = pixels(base)
        // inside the filled rect (top-left origin): solid red; outside: untouched.
        let inside = px(p, 120, 30, 35)
        #expect(inside[1] > 200 || inside[2] > 200 || inside[3] > 200)   // some channel saturated; not the busy base
        #expect(inside != px(b, 120, 30, 35))
        #expect(px(p, 120, 100, 70) == px(b, 120, 100, 70))
        #expect(px(p, 120, 5, 5) == px(b, 120, 5, 5))
    }

    @Test func retinaScaleDoublesSize() {
        let out = MarkupRender.render(base: busyImage(50, 40), doc: MarkupDoc(), scale: 2)!
        #expect(out.width == 100 && out.height == 80)
    }

    @Test(arguments: CensorMode.allCases) func censorOnlyChangesInsideRect(mode: CensorMode) {
        let base = busyImage(100, 80)
        let r = CGRect(x: 30, y: 20, width: 40, height: 30)
        var d = MarkupDoc()
        d.add(Stroke(mark: .censor(r), color: .ink, width: 4, censor: mode))
        let p = pixels(MarkupRender.render(base: base, doc: d)!), b = pixels(base)
        var inChanged = 0
        for y in 0..<80 { for x in 0..<100 {
            let same = px(p, 100, x, y) == px(b, 100, x, y)
            if r.contains(CGPoint(x: x, y: y)) { if !same { inChanged += 1 } }
            else { #expect(same, "pixel \(x),\(y) changed outside the censor rect") }
        } }
        #expect(inChanged > 100)
    }

    @Test func cropOutputSize() {
        var d = MarkupDoc()
        d.setCrop(CGRect(x: 10, y: 10, width: 60, height: 40))
        #expect(MarkupRender.render(base: busyImage(100, 80), doc: d)!.width == 60)
        #expect(MarkupRender.render(base: busyImage(100, 80), doc: d)!.height == 40)
        #expect(MarkupRender.render(base: busyImage(100, 80), doc: d, applyCrop: false)!.width == 100)
    }
}

@Suite struct CaptureLogicTests {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    @Test func squareDrag() {
        let r = CaptureLogic.dragRect(from: .init(x: 100, y: 100), to: .init(x: 160, y: 130), square: true, bounds: bounds)
        #expect(r.width == 60 && r.height == 60)
        let free = CaptureLogic.dragRect(from: .init(x: 100, y: 100), to: .init(x: 60, y: 130), square: false, bounds: bounds)
        #expect(free == CGRect(x: 60, y: 100, width: 40, height: 30))
    }

    @Test func dragClampsToScreen() {
        let r = CaptureLogic.dragRect(from: .init(x: 350, y: 250), to: .init(x: 500, y: 400), square: false, bounds: bounds)
        #expect(r.maxX == 400 && r.maxY == 300)
    }

    @Test func nudgeAndMoveStayOnScreen() {
        let r = CGRect(x: 10, y: 10, width: 50, height: 50)
        #expect(CaptureLogic.moved(r, by: CGSize(width: 1, height: 0), within: bounds).minX == 11)
        let far = CaptureLogic.moved(r, by: CGSize(width: 9999, height: -9999), within: bounds)
        #expect(far.maxX == 400 && far.minY == 0 && far.size == r.size)
    }

    @Test func windowSnapFrontmostWins() {
        let front = CGRect(x: 50, y: 50, width: 100, height: 100), back = CGRect(x: 0, y: 0, width: 300, height: 300)
        #expect(CaptureLogic.windowRect(at: .init(x: 60, y: 60), in: [front, back]) == front)
        #expect(CaptureLogic.windowRect(at: .init(x: 250, y: 250), in: [front, back]) == back)
        #expect(CaptureLogic.windowRect(at: .init(x: 60, y: 60), in: [CGRect(x: 0, y: 0, width: 20, height: 20)]) == nil)
    }

    @Test func pixelRectScalesRetina() {
        let px = CaptureLogic.pixelRect(CGRect(x: 10, y: 10, width: 100, height: 50), viewSize: CGSize(width: 400, height: 300), imageSize: CGSize(width: 800, height: 600))
        #expect(px == CGRect(x: 20, y: 20, width: 200, height: 100))
        #expect(CaptureLogic.sizeLabel(px) == "200 × 100")
    }

    @Test func toolbarFlipsAtEdges() {
        let t = CaptureLogic.toolbarOrigin(selection: CGRect(x: 100, y: 250, width: 100, height: 45), toolbar: CGSize(width: 200, height: 40), in: bounds)
        #expect(t.y + 40 <= 300)
    }
}

@Suite struct CaptureTrayTests {
    func makeStore() throws -> (TrayStore, URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("capturetest-\(UUID().uuidString)", isDirectory: true)
        let trash = tmp.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return (TrayStore(root: tmp.appendingPathComponent("tray", isDirectory: true), trash: { _ in nil }), tmp)
    }

    @Test func captureAndMarkupLandInIndex() throws {
        let (store, tmp) = try makeStore()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let png = MarkupRender.png(base: busyImage(60, 40), doc: MarkupDoc())!
        let cap = try #require(store.addCapture(png: png, width: 60, height: 40))
        #expect(cap.kind == .original && cap.parent == nil && cap.source == nil)
        let mk = try #require(store.addMarkup(png: png, parent: cap.id, width: 60, height: 40))
        #expect(mk.kind == .markup && mk.parent == cap.id)

        let raw = try Data(contentsOf: store.indexURL)
        let json = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let shots = try #require(json["shots"] as? [[String: Any]])
        #expect(shots.count == 2)
        let m = try #require(shots.first { $0["id"] as? String == mk.id })
        #expect(m["kind"] as? String == "markup")
        #expect(m["parent"] as? String == cap.id)
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(mk.file).path))
    }
}

// MARK: - Polish round

@Suite struct SystemShortcutTests {
    @Test func missingEntryMeansMacOSStillOwnsIt() {
        #expect(SystemShortcut.isEnabled(30, in: nil))
        #expect(SystemShortcut.isEnabled(30, in: ["31": ["enabled": false]]))
    }
    @Test func disabledEntryFreesTheShortcut() {
        #expect(!SystemShortcut.isEnabled(30, in: ["30": ["enabled": false, "value": ["type": "standard"]]]))
        #expect(!SystemShortcut.isEnabled(30, in: ["30": ["enabled": NSNumber(value: 0)]]))
    }
    @Test func enabledEntryKeepsMacOSInCharge() {
        #expect(SystemShortcut.isEnabled(30, in: ["30": ["enabled": true]]))
        #expect(SystemShortcut.isEnabled(30, in: ["30": ["enabled": NSNumber(value: 1)]]))
        #expect(SystemShortcut.isEnabled(30, in: ["30": ["value": "x"]]))   // no flag → default on
    }
    @Test func hotkeysAreDistinct() {
        #expect(CaptureHotKey.primary.id != CaptureHotKey.backup.id)
        #expect(CaptureHotKey.all.count == 2)
    }
}

@Suite struct RectHandleTests {
    let r = CGRect(x: 100, y: 100, width: 200, height: 100)
    let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)

    @Test func eightHandlesAtCornersAndMidpoints() {
        #expect(RectHandle.allCases.count == 8)
        #expect(RectHandle.topLeft.point(in: r) == CGPoint(x: 100, y: 100))
        #expect(RectHandle.right.point(in: r) == CGPoint(x: 300, y: 150))
        #expect(RectHandle.bottom.point(in: r) == CGPoint(x: 200, y: 200))
    }
    @Test func hitReachIsGenerous() {
        #expect(RectHandle.hit(CGPoint(x: 108, y: 100), in: r) == .topLeft)   // 8 pt away still grabs
        #expect(RectHandle.hit(CGPoint(x: 200, y: 160), in: r) == nil)
    }
    @Test func cornersAndEdgesResize() {
        #expect(RectHandle.bottomRight.resized(r, to: CGPoint(x: 350, y: 260), bounds: bounds) == CGRect(x: 100, y: 100, width: 250, height: 160))
        #expect(RectHandle.topLeft.resized(r, to: CGPoint(x: 60, y: 80), bounds: bounds) == CGRect(x: 60, y: 80, width: 240, height: 120))
        #expect(RectHandle.right.resized(r, to: CGPoint(x: 400, y: 999), bounds: bounds) == CGRect(x: 100, y: 100, width: 300, height: 100))
        #expect(RectHandle.top.resized(r, to: CGPoint(x: 0, y: 40), bounds: bounds) == CGRect(x: 100, y: 40, width: 200, height: 160))
        #expect(RectHandle.left.resized(r, to: CGPoint(x: 20, y: 0), bounds: bounds) == CGRect(x: 20, y: 100, width: 280, height: 100))
        #expect(RectHandle.bottom.resized(r, to: CGPoint(x: 0, y: 300), bounds: bounds) == CGRect(x: 100, y: 100, width: 200, height: 200))
    }
    @Test func clampsToBounds() {
        let out = RectHandle.bottomRight.resized(r, to: CGPoint(x: 9000, y: -50), bounds: bounds)
        #expect(bounds.contains(out) && out.maxX == 500)
        let tl = RectHandle.topLeft.resized(r, to: CGPoint(x: -80, y: -80), bounds: bounds)
        #expect(tl.minX == 0 && tl.minY == 0)
    }
    @Test func shiftKeepsSquare() {
        let out = RectHandle.bottomRight.resized(r, to: CGPoint(x: 400, y: 160), square: true, bounds: bounds)
        #expect(out.width == out.height && out.minX == 100 && out.minY == 100 && out.width == 300)
        let tl = RectHandle.topLeft.resized(r, to: CGPoint(x: 40, y: 90), square: true, bounds: bounds)
        #expect(tl.width == tl.height && tl.maxX == 300 && tl.maxY == 200)
    }
    @Test func squareStaysInsideBounds() {
        let out = RectHandle.bottomRight.resized(r, to: CGPoint(x: 5000, y: 5000), square: true, bounds: bounds)
        #expect(bounds.contains(out) && out.width == out.height)
    }
    @Test func draggingPastTheOppositeEdgeFlips() {
        let out = RectHandle.right.resized(r, to: CGPoint(x: 40, y: 150), bounds: bounds)
        #expect(out.minX == 40 && out.maxX == 100)
    }
    @Test func neverCollapsesBelowMinimum() {
        let out = RectHandle.right.resized(r, to: CGPoint(x: 100, y: 150), bounds: bounds)
        #expect(out.width >= 8)
    }
}

@Suite struct HighlighterBlendTests {
    private func rendered(_ base: CGColor, mark color: MarkupColor = .amber) -> [UInt8] {
        let ctx = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(base); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        var d = MarkupDoc()
        d.add(Stroke(mark: .highlight([CGPoint(x: 5, y: 20), CGPoint(x: 75, y: 20)]), color: color, width: 4))
        let out = MarkupRender.render(base: ctx.makeImage()!, doc: d)!
        return px(pixels(out), 80, 40, 20)   // A, R, G, B
    }

    @Test func yellowOverDarkStaysYellow() {
        let p = rendered(CGColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1))
        #expect(p[1] > 80 && p[2] > 70)                  // R and G lifted
        #expect(Int(p[1]) > Int(p[3]) * 2 && Int(p[2]) > Int(p[3]) * 2)   // clearly yellow: R,G ≫ B
    }
    @Test func yellowOverLightStaysYellow() {
        let p = rendered(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        #expect(p[1] > 200 && p[2] > 200 && p[3] < p[1] - 30)
    }
}


/// A canvas-like image: a flat dark page with a few drawn panels (no AX tree would describe these).
func syntheticCanvasImage(_ w: Int = 800, _ h: Int = 500) -> (image: CGImage, boxes: [CGRect]) {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // top-left coordinates
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let boxes = [CGRect(x: 60, y: 60, width: 300, height: 180), CGRect(x: 420, y: 80, width: 280, height: 120), CGRect(x: 120, y: 290, width: 520, height: 150)]
    for (i, b) in boxes.enumerated() {
        ctx.setFillColor(CGColor(gray: 0.28 + CGFloat(i) * 0.08, alpha: 1)); ctx.fill(b)
        ctx.setStrokeColor(CGColor(gray: 0.85, alpha: 1)); ctx.setLineWidth(3); ctx.stroke(b)
    }
    return (ctx.makeImage()!, boxes)
}

private func el(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ k: PickKind = .section) -> PickElement {
    PickElement(frame: CGRect(x: x, y: y, width: w, height: h), kind: k)
}

@Suite struct SmartPickTests {
    let win = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test func cleanDropsTinyAndClampsAndEndsWithWindow() {
        let out = SmartPickLogic.clean([el(10, 10, 1, 40), el(20, 20, 0, 0), el(700, 500, 400, 300, .image)], window: win)
        #expect(out.count == 2)
        #expect(out[0].frame == CGRect(x: 700, y: 500, width: 100, height: 100))
        #expect(out[0].kind == .image)
        #expect(out.last?.kind == .window && out.last?.frame == win)
    }
    @Test func cleanMergesNearDuplicatesKeepingSpecificName() {
        let out = SmartPickLogic.clean([el(100, 100, 200, 100), el(101, 99, 199, 101, .button), el(50, 50, 400, 300)], window: win)
        #expect(out.count == 3)
        #expect(out[0].kind == .button)
    }
    @Test func cleanMergesOuterIntoWindow() {
        let out = SmartPickLogic.clean([el(100, 100, 200, 100), el(1, 1, 798, 599)], window: win)
        #expect(out.count == 2 && out[1].kind == .window)
    }
    @Test func coordinateFlipAcrossScreens() {
        let r = CGRect(x: 2000, y: 100, width: 300, height: 200)
        #expect(SmartPickLogic.toOverlay(r, displayOrigin: CGPoint(x: 1440, y: 0)) == CGRect(x: 560, y: 100, width: 300, height: 200))
        // a screen left of / above the primary has a negative origin
        #expect(SmartPickLogic.toOverlay(CGRect(x: -1500, y: -900, width: 100, height: 50), displayOrigin: CGPoint(x: -1920, y: -1080))
                == CGRect(x: 420, y: 180, width: 100, height: 50))
        let p = CGPoint(x: 420, y: 180), o = CGPoint(x: -1920, y: -1080)
        #expect(SmartPickLogic.toOverlay(CGRect(origin: SmartPickLogic.toGlobal(p, displayOrigin: o), size: .zero), displayOrigin: o).origin == p)
    }
    @Test func axNameWinsOverAreaAndChainNests() {
        let ax = [el(100, 100, 50, 20, .button), el(0, 0, 800, 600, .window)]
        let out = SmartPickLogic.chain(ax: ax, window: win, boxes: [CGRect(x: 90, y: 90, width: 200, height: 200), CGRect(x: 99, y: 99, width: 52, height: 22)], at: CGPoint(x: 110, y: 110))
        #expect(out.map(\.kind) == [.button, .area, .window])
        #expect(out[0].frame == ax[0].frame)
        for i in 1..<out.count { #expect(out[i].frame.insetBy(dx: -3, dy: -3).contains(out[i - 1].frame)) }
    }
    @Test func coarseAXPageNeverHidesFinerImageRegions() {
        let page = el(0, 40, 800, 560, .section)
        let boxes = [CGRect(x: 50, y: 50, width: 300, height: 300), CGRect(x: 100, y: 100, width: 100, height: 100)]
        let out = SmartPickLogic.chain(ax: [page, el(0, 0, 800, 600, .window)], window: win, boxes: boxes, at: CGPoint(x: 120, y: 120))
        #expect(out.map(\.frame) == [boxes[1], boxes[0], page.frame, win])
        #expect(out.last?.kind == .window)
    }
    @Test func imageFallbackWhenAXOnlyHasWindow() {
        let boxes = [CGRect(x: 50, y: 50, width: 300, height: 300), CGRect(x: 100, y: 100, width: 100, height: 100)]
        let out = SmartPickLogic.chain(ax: [el(0, 0, 800, 600, .window)], window: win, boxes: boxes, at: CGPoint(x: 120, y: 120))
        #expect(out.map(\.kind) == [.area, .area, .window])
        #expect(out[0].frame == boxes[1])
        let none = SmartPickLogic.chain(ax: [], window: win, boxes: [], at: CGPoint(x: 5, y: 5))
        #expect(none.map(\.kind) == [.window])
    }
    @Test func regionKindsAreLabelledByShape() {
        #expect(SmartPickLogic.regionKind(CGRect(x: 0, y: 0, width: 200, height: 600), window: win) == .pane)
        #expect(SmartPickLogic.regionKind(CGRect(x: 0, y: 0, width: 800, height: 40), window: win) == .bar)
        #expect(SmartPickLogic.regionKind(CGRect(x: 10, y: 10, width: 200, height: 100), window: win) == .area)
    }
    @Test func replaceKeepsTheSameFrameOtherwiseLevelZero() {
        let inner = el(100, 100, 100, 100, .area), mid = el(50, 50, 300, 300, .area), w = el(0, 0, 800, 600, .window)
        var pk = SmartPicker([inner, mid, w], level: 1)
        pk.replace([inner, el(51, 49, 299, 301, .section), w])      // mid reappears named, within tolerance
        #expect(pk.level == 1 && pk.current?.kind == .section)
        pk.replace([el(10, 10, 20, 20, .button), w])                 // frame gone
        #expect(pk.level == 0)
    }
    @Test func pickerGrowShrinkClampAndWindowJump() {
        var p = SmartPicker([el(10, 10, 20, 20, .button), el(0, 0, 100, 100), el(0, 0, 800, 600, .window)])
        p.shrink(); #expect(p.level == 0)
        p.grow(); p.grow(); p.grow(); #expect(p.level == 2 && p.current?.kind == .window)
        p.shrink(); #expect(p.level == 1)
        p.jumpToWindow(); #expect(p.level == 2)
        p.replace([el(10, 10, 20, 20, .button), el(0, 0, 50, 50), el(0, 0, 800, 600, .window)])   // same innermost → keep level
        #expect(p.level == 2)
        p.replace([el(300, 300, 20, 20), el(0, 0, 800, 600, .window)])                               // window frame survives → stays on it
        #expect(p.level == 1 && p.current?.kind == .window)
        p.replace([el(300, 300, 20, 20), el(0, 0, 640, 480, .window)])                               // frame gone → smallest
        #expect(p.level == 0)
    }
    @Test func clickVersusDrag() {
        #expect(SmartPickLogic.isClick(down: CGPoint(x: 10, y: 10), up: CGPoint(x: 12, y: 11)))
        #expect(!SmartPickLogic.isClick(down: CGPoint(x: 10, y: 10), up: CGPoint(x: 14, y: 10)))
    }
    @Test func namesArePlainEnglish() {
        let roles = ["AXButton", "AXStaticText", "AXImage", "AXToolbar", "AXList", "AXTabGroup", "AXMenu", "AXWebArea", "AXWindow", "AXSplitGroup", "AXGroup", "AXWeird", nil]
        for r in roles {
            let n = PickKind.from(role: r).rawValue
            #expect(!n.hasPrefix("AX") && !n.isEmpty)
        }
        #expect(PickKind.from(role: "AXSplitGroup", subrole: "AXSidebar") == .sidebar)
        #expect(PickKind.from(role: "AXGroup") == .section)
    }
    @Test func filterBoxesDropsTinyWholeScreenAndDuplicates() {
        let screen = CGSize(width: 800, height: 600)
        let out = SmartPickLogic.filterBoxes([
            CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 5, y: 5, width: 10, height: 10),
            CGRect(x: 100, y: 100, width: 200, height: 100), CGRect(x: 101, y: 100, width: 199, height: 101),
            CGRect(x: 400, y: 300, width: 100, height: 100),
        ], screen: screen)
        #expect(out.count == 2)
    }
    @Test func detectorFindsDrawnBoxes() {
        let (img, boxes) = syntheticCanvasImage()
        let found = ImageBoxDetector.detect(img)
        // Vision is heuristic: require that most drawn panels are matched, loosely.
        let hits = boxes.filter { b in found.contains { SmartPickLogic.iou($0, b) > 0.7 } }
        #expect(hits.count >= 2, "matched \(hits.count)/3, found \(found)")
    }
}

@Suite struct HighlighterAt55Tests {
    private func run(_ base: CGColor, textGray: CGFloat?) -> (hl: [UInt8], text: [UInt8]) {
        let ctx = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(base); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        if let g = textGray { ctx.setFillColor(CGColor(gray: g, alpha: 1)); ctx.fill(CGRect(x: 30, y: 0, width: 20, height: 40)) }
        var d = MarkupDoc()
        d.add(Stroke(mark: .highlight([CGPoint(x: 5, y: 20), CGPoint(x: 75, y: 20)]), color: .amber, width: 4))
        let out = pixels(MarkupRender.render(base: ctx.makeImage()!, doc: d)!)
        return (px(out, 80, 10, 20), px(out, 80, 40, 20))
    }
    @Test func alphaIsAboutFiftyFivePercent() { #expect(abs(MarkupRender.highlightAlpha - 0.55) < 0.001) }
    @Test func darkReadsYellowNotOlive() {
        let p = run(CGColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1), textGray: nil).hl
        #expect(p[1] > 110 && p[2] > 95 && Int(p[1]) > Int(p[3]) * 3)
    }
    @Test func textStaysVisibleThroughHighlightOnLight() {
        let r = run(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1), textGray: 0.1)
        #expect(Int(r.text[2]) < Int(r.hl[2]) - 80)   // dark text still clearly darker than the highlight around it
    }
}

/// Several screens: the screen the mouse left keeps nothing stale, and a screen that loses the selection to
/// another one goes back to a plain dim.
@MainActor @Suite struct CaptureMultiScreenTests {
    private func view() -> CaptureView {
        CaptureView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), still: busyImage(400, 300), windows: [CGRect(x: 20, y: 20, width: 300, height: 200)])
    }

    @Test func leavingTheScreenClearsTheHoverBox() {
        let v = view()
        v.previewPick(chain: [PickElement(frame: CGRect(x: 40, y: 40, width: 80, height: 30), kind: .button)], level: 0, cursor: CGPoint(x: 50, y: 50))
        #expect(v.hoverWindow != nil && v.cursor != nil)
        v.clearHover()
        #expect(v.hoverWindow == nil && v.hoverName == nil && v.cursor == nil && v.picker.elements.isEmpty)
    }

    @Test func losingTheSelectionResetsTheEditor() {
        let v = view()
        v.previewDrag(selection: CGRect(x: 30, y: 30, width: 120, height: 80), cursor: nil)
        v.beginEditing()
        #expect(v.phase == .editing && !v.subviews.isEmpty)
        v.resetToAiming()
        #expect(v.phase == .aiming && v.selection == nil && v.state == nil && v.subviews.isEmpty)
    }
}
