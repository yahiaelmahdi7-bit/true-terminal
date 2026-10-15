import Testing
import Foundation
import CoreGraphics
@testable import True

/// Top-left-origin drawing surface for synthetic screens.
private final class Canvas {
    let w: Int, h: Int, ctx: CGContext
    init(_ w: Int, _ h: Int, bg: CGFloat) {
        self.w = w; self.h = h
        ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        fill(CGRect(x: 0, y: 0, width: w, height: h), bg)
    }
    func fill(_ r: CGRect, _ g: CGFloat) { ctx.setFillColor(CGColor(gray: g, alpha: 1)); ctx.fill(r) }
    func round(_ r: CGRect, _ g: CGFloat, radius: CGFloat) {
        ctx.setFillColor(CGColor(gray: g, alpha: 1))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath()
    }
    /// Text-like lines: short ink bars with a clear line gap.
    func text(_ r: CGRect, ink: CGFloat, lineH: CGFloat = 10, gap: CGFloat = 8) {
        var y = r.minY + 6
        while y + lineH < r.maxY - 4 {
            var x = r.minX + 8
            while x < r.maxX - 16 { let ww = min(CGFloat(14 + (Int(x + y) % 5) * 4), r.maxX - 8 - x); var sx = x; while sx < x + ww { fill(CGRect(x: sx, y: y + CGFloat(Int(sx * 7) % 3), width: 2, height: lineH * 0.6 + CGFloat(Int(sx * 5) % 4)), Int(sx) % 4 == 0 ? ink : ink * 0.45); sx += 2 }   // glyph-like, never a flat bar
                x += ww + 5 }
            y += lineH + gap
        }
    }
    var image: CGImage { ctx.makeImage()! }
}

private func found(_ regions: [CGRect], _ want: CGRect, iou min: CGFloat = 0.8) -> Bool {
    regions.contains { SmartPickLogic.iou($0, want) >= min }
}

@Suite struct LayoutRegionsTests {
    @Test func thinDividersSplitTerminalPanes() {
        let c = Canvas(1000, 600, bg: 0.08)
        for i in 0..<4 { c.text(CGRect(x: CGFloat(i) * 250, y: 0, width: 248, height: 600), ink: 0.8) }
        for i in 1..<4 { c.fill(CGRect(x: CGFloat(i) * 250 - 1, y: 0, width: 1, height: 600), 0.45) }
        let r = LayoutRegions.detect(c.image)
        for i in 0..<4 { #expect(found(r, CGRect(x: CGFloat(i) * 250, y: 0, width: 249, height: 600), iou: 0.7), "pane \(i): \(r)") }
    }

    @Test func fullWidthStripIsItsOwnRegion() {
        let c = Canvas(1000, 600, bg: 0.12)
        c.fill(CGRect(x: 0, y: 0, width: 1000, height: 44), 0.3)
        c.fill(CGRect(x: 20, y: 16, width: 70, height: 10), 0.9); c.fill(CGRect(x: 110, y: 16, width: 70, height: 10), 0.9)
        c.text(CGRect(x: 0, y: 44, width: 1000, height: 556), ink: 0.8)
        let r = LayoutRegions.detect(c.image)
        #expect(found(r, CGRect(x: 0, y: 0, width: 1000, height: 44)), "\(r)")
    }

    @Test func darkCardsOnDarkerGutters() {
        let c = Canvas(1000, 600, bg: 0.04)
        let cards = [CGRect(x: 40, y: 40, width: 440, height: 240), CGRect(x: 520, y: 40, width: 440, height: 240), CGRect(x: 40, y: 320, width: 920, height: 240)]
        for k in cards { c.fill(k, 0.16); c.text(k.insetBy(dx: 12, dy: 12), ink: 0.7) }
        let r = LayoutRegions.detect(c.image)
        for k in cards { #expect(found(r, k), "card \(k): \(r)") }
    }

    @Test func videoBlockOnUniformBackground() {
        let c = Canvas(1000, 600, bg: 0.95)
        let video = CGRect(x: 120, y: 80, width: 640, height: 360)
        for cy in 0..<60 { for cx in 0..<106 { c.fill(CGRect(x: video.minX + CGFloat(cx) * 6, y: video.minY + CGFloat(cy) * 6, width: 6, height: 6), 0.1 + CGFloat((cx * 7 + cy * 13) % 9) * 0.09) } }
        let r = LayoutRegions.detect(c.image)
        #expect(found(r, video), "\(r)")
    }

    @Test func roundedInputAndButtonsOnTopBar() {
        let c = Canvas(1000, 600, bg: 0.1)
        c.fill(CGRect(x: 0, y: 0, width: 1000, height: 56), 0.25)
        c.fill(CGRect(x: 20, y: 22, width: 90, height: 12), 0.9)
        let input = CGRect(x: 200, y: 12, width: 420, height: 32), b1 = CGRect(x: 660, y: 12, width: 80, height: 32), b2 = CGRect(x: 760, y: 12, width: 80, height: 32)
        c.round(input, 0.5, radius: 14); c.round(b1, 0.55, radius: 8); c.round(b2, 0.55, radius: 8)
        c.text(CGRect(x: 0, y: 56, width: 1000, height: 544), ink: 0.8)
        let r = LayoutRegions.detect(c.image)
        #expect(found(r, CGRect(x: 0, y: 0, width: 1000, height: 56)), "bar: \(r)")
        #expect(found(r, CGRect(x: 0, y: 56, width: 1000, height: 544), iou: 0.9), "page below the bar: \(r)")
        // Known limit: a rounded input inside a bar is not yet cut out on its own (the bar is the finest level here).
    }

    @Test func blockBetweenTwoRules() {
        let c = Canvas(1000, 600, bg: 0.1)
        c.text(CGRect(x: 0, y: 0, width: 1000, height: 140), ink: 0.8)
        c.fill(CGRect(x: 0, y: 150, width: 1000, height: 1), 0.5)
        c.fill(CGRect(x: 0, y: 430, width: 1000, height: 1), 0.5)
        c.text(CGRect(x: 0, y: 152, width: 1000, height: 278), ink: 0.8)
        c.text(CGRect(x: 0, y: 432, width: 1000, height: 168), ink: 0.8)
        let r = LayoutRegions.detect(c.image)
        #expect(found(r, CGRect(x: 0, y: 151, width: 1000, height: 279), iou: 0.75), "\(r)")
    }

    @Test func paragraphLinesAreNotSplitIntoLines() {
        let c = Canvas(1000, 600, bg: 0.1)
        c.text(CGRect(x: 100, y: 100, width: 600, height: 120), ink: 0.8)
        let r = LayoutRegions.detect(c.image)
        #expect(!r.contains { $0.height < 20 && $0.width > 100 }, "a text line became a region: \(r)")
    }

    @Test func flatScreenHasNoRegions() {
        #expect(LayoutRegions.detect(Canvas(800, 500, bg: 0.3).image).isEmpty)
    }
}
