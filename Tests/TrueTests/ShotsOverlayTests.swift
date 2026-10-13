import Testing
import Foundation
import Carbon.HIToolbox
@testable import True

@Suite struct ShotsOverlayTests {
    private func entry(_ id: String, _ date: Date) -> TrayEntry {
        TrayEntry(id: id, file: "shots/\(id).png", created: date, kind: .original, parent: nil,
                  source: nil, width: 10, height: 10)
    }
    private func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: tz)!; return c
    }
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func groupsAcrossMidnight() {
        let c = cal("UTC")
        let now = date("2026-10-08T00:30:00Z")
        let g = ShotsOverlayLogic.group([entry("a", date("2026-10-08T00:10:00Z")),
                                         entry("b", date("2026-10-07T23:50:00Z")),
                                         entry("c", date("2026-10-05T12:00:00Z"))], now: now, calendar: c)
        #expect(g.map(\.title) == ["Today", "Yesterday", "Earlier"])
        #expect(g.map { $0.entries.map(\.id) } == [["a"], ["b"], ["c"]])
    }

    @Test func groupingFollowsTheCalendarTimeZone() {
        // 23:30 UTC on the 7th is already the 8th in Tokyo.
        let e = entry("a", date("2026-10-07T23:30:00Z"))
        let now = date("2026-10-08T05:00:00Z")
        #expect(ShotsOverlayLogic.group([e], now: now, calendar: cal("UTC")).first?.title == "Yesterday")
        #expect(ShotsOverlayLogic.group([e], now: now, calendar: cal("Asia/Tokyo")).first?.title == "Today")
    }

    @Test func emptyGroupsAreDropped() {
        #expect(ShotsOverlayLogic.group([], now: Date(), calendar: cal("UTC")).isEmpty)
        let g = ShotsOverlayLogic.group([entry("a", date("2026-01-01T00:00:00Z"))], now: date("2026-10-08T00:00:00Z"), calendar: cal("UTC"))
        #expect(g.map(\.title) == ["Earlier"])
    }

    @Test func pinchClampsColumns() {
        #expect(ShotsOverlayLogic.columns(base: 5, pinchScale: 1) == 5)
        #expect(ShotsOverlayLogic.columns(base: 5, pinchScale: 2) == 3)      // 2.5 rounds to 3 (floor of range anyway)
        #expect(ShotsOverlayLogic.columns(base: 5, pinchScale: 100) == 3)
        #expect(ShotsOverlayLogic.columns(base: 5, pinchScale: 0.1) == 9)
        #expect(ShotsOverlayLogic.columns(base: 5, pinchScale: 0.5) == 9)    // 10 → clamped
        #expect(ShotsOverlayLogic.columns(base: 5, pinchScale: .nan) == 5)
        #expect(ShotsOverlayLogic.columns(base: 5, pinchScale: 0) == 5)
        #expect(ShotsOverlayLogic.clampColumns(0) == 3 && ShotsOverlayLogic.clampColumns(40) == 9)
    }

    @Test func hotKeyMapsToCarbon() {
        #expect(ShotsHotKey.carbonKeyCode == UInt32(kVK_ANSI_S))
        #expect(ShotsHotKey.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))
        #expect(ShotsHotKey.eventModifiers == [.control, .option, .command])
    }

    @Test func picksTheMouseScreen() {
        let frames = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        #expect(ShotsOverlayLogic.screenIndex(mouse: CGPoint(x: 1500, y: 100), frames: frames) == 1)
        #expect(ShotsOverlayLogic.screenIndex(mouse: CGPoint(x: 10, y: 10), frames: frames) == 0)
        #expect(ShotsOverlayLogic.screenIndex(mouse: CGPoint(x: -5, y: 10), frames: frames) == nil)
        #expect(ShotsOverlayLogic.screenIndex(mouse: .zero, frames: []) == nil)
    }

    @Test func insetsClearMenuBarDockAndNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let visible = CGRect(x: 0, y: 70, width: 1000, height: 700)   // 30 menu bar on top, 70 Dock at the bottom
        let i = ShotsOverlayLogic.contentInsets(frame: frame, visible: visible, safeTop: 0, margin: 20)
        #expect(i.top == 50 && i.bottom == 90 && i.leading == 20 && i.trailing == 20)
        #expect(ShotsOverlayLogic.contentInsets(frame: frame, visible: frame, safeTop: 38, margin: 20).top == 58)
    }

    @Test func dropFilterAcceptsImagesOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.png", "b.JPG", "c.heic", "d.txt", "e.pdf", "f"] {
            try Data([0]).write(to: dir.appendingPathComponent(name))
        }
        let ok = { ShotsOverlayLogic.acceptsDrop(dir.appendingPathComponent($0)) }
        #expect(ok("a.png") && ok("b.JPG") && ok("c.heic"))
        #expect(!ok("d.txt") && !ok("e.pdf") && !ok("f"))
        #expect(!ShotsOverlayLogic.acceptsDrop(dir))
        #expect(!ShotsOverlayLogic.acceptsDrop(URL(string: "https://example.com/a.png")!))
    }

    @Test func viewerStopsAtTheEnds() {
        #expect(ShotsOverlayLogic.neighbor(of: 0, count: 3, step: -1) == nil)
        #expect(ShotsOverlayLogic.neighbor(of: 2, count: 3, step: 1) == nil)
        #expect(ShotsOverlayLogic.neighbor(of: 1, count: 3, step: 1) == 2)
        #expect(ShotsOverlayLogic.neighbor(of: 1, count: 3, step: -1) == 0)
        #expect(ShotsOverlayLogic.neighbor(of: 0, count: 0, step: 1) == nil)
    }

    // MARK: Viewer layout

    private let ins: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) = (60, 28, 28, 28)
    private let screen = CGSize(width: 1512, height: 982)

    @Test func fittedImageStaysInsideAreaAboveToolbarBand() {
        let area = ShotsOverlayLogic.viewerArea(container: screen, insets: ins)
        let toolbarTop = screen.height - ins.bottom - ShotsOverlayLogic.toolbarBand
        for aspect: CGFloat in [0.2, 0.56, 1, 1.6, 3, 8, 21] {
            let r = ShotsOverlayLogic.fittedRect(in: area, aspect: aspect)
            #expect(r.minX >= area.minX - 0.001 && r.maxX <= area.maxX + 0.001)
            #expect(r.minY >= area.minY - 0.001 && r.maxY <= area.maxY + 0.001)
            #expect(r.maxY <= toolbarTop + 0.001, "toolbar overlap at aspect \(aspect)")
            #expect(abs(r.width / r.height - aspect) < 0.001)
            #expect(abs(r.midX - area.midX) < 0.001 && abs(r.midY - area.midY) < 0.001)
        }
    }

    @Test func markupImageNeverUnderBottomBar() {
        let barTop = screen.height - ins.bottom - ShotsOverlayLogic.toolbarBand
        let barCentre = ShotsOverlayLogic.bottomBarCenterY(containerHeight: screen.height, bottomInset: ins.bottom)
        #expect(barCentre > barTop)
        for container in [screen, CGSize(width: 800, height: 1200), CGSize(width: 1512, height: 400), CGSize(width: 100, height: 100)] {
            let area = ShotsOverlayLogic.markupArea(container: container, insets: ins)
            let top = container.height - ins.bottom - ShotsOverlayLogic.toolbarBand
            #expect(area.maxY <= max(top, area.minY + 1) + 0.001)
            for aspect: CGFloat in [0.2, 1, 1.6, 8] {
                let r = ShotsOverlayLogic.fittedRect(in: area, aspect: aspect)
                #expect(r.width > 0 && r.height > 0)
                #expect(r.minX >= area.minX - 0.001 && r.maxX <= area.maxX + 0.001)
                #expect(r.maxY <= area.maxY + 0.001)
            }
        }
        #expect(ShotsOverlayLogic.markupArea(container: screen, insets: ins).maxY == screen.height - ins.bottom - ShotsOverlayLogic.toolbarBand)
        #expect(ShotsOverlayLogic.markupArea(container: screen, insets: ins).minX >= ins.leading + ShotsOverlayLogic.markupSideReserve)
    }

    @Test func fittedImageNeverUnderSideButtons() {
        let area = ShotsOverlayLogic.viewerArea(container: screen, insets: ins)
        let r = ShotsOverlayLogic.fittedRect(in: area, aspect: 5)
        #expect(r.minX >= ins.leading + ShotsOverlayLogic.sideReserve - 0.001)
        #expect(r.maxX <= screen.width - ins.trailing - ShotsOverlayLogic.sideReserve + 0.001)
    }

    @Test func tinyContainerStillYieldsAPositiveRect() {
        let area = ShotsOverlayLogic.viewerArea(container: CGSize(width: 100, height: 100), insets: ins)
        let r = ShotsOverlayLogic.fittedRect(in: area, aspect: 1.6)
        #expect(r.width > 0 && r.height > 0 && r.width.isFinite)
    }

    @Test func tinyImageIsNotBlownUpPastTwiceItsSize() {
        let area = ShotsOverlayLogic.viewerArea(container: screen, insets: ins)
        let r = ShotsOverlayLogic.fittedRect(in: area, aspect: 1, natural: CGSize(width: 16, height: 16))
        #expect(r.width == 32 && r.height == 32)
        let huge = ShotsOverlayLogic.fittedRect(in: area, aspect: 2, natural: CGSize(width: 12000, height: 6000))
        #expect(huge.maxY <= area.maxY + 0.001 && huge.width <= area.width + 0.001)
    }

    @Test func badAspectFallsBack() {
        let area = CGRect(x: 0, y: 0, width: 800, height: 600)
        for a: CGFloat in [0, -1, .nan, .infinity] {
            let r = ShotsOverlayLogic.fittedRect(in: area, aspect: a)
            #expect(abs(r.width / r.height - 1.6) < 0.001)
        }
    }

    @Test func interpolationEndpointsAndMidpoint() {
        let a = CGRect(x: 10, y: 20, width: 100, height: 60), b = CGRect(x: 200, y: 100, width: 800, height: 500)
        #expect(ShotsOverlayLogic.interpolate(from: a, to: b, t: 0) == a)
        #expect(ShotsOverlayLogic.interpolate(from: a, to: b, t: 1) == b)
        #expect(ShotsOverlayLogic.interpolate(from: a, to: b, t: 0.5) == CGRect(x: 105, y: 60, width: 450, height: 280))
    }

    @Test func zoomSourceNeedsTheTileOnScreen() {
        let screen = CGSize(width: 1000, height: 800)
        let on = CGRect(x: 100, y: 100, width: 200, height: 120)
        #expect(ShotsOverlayLogic.zoomSource(tile: on, overlay: screen) == on)
        #expect(ShotsOverlayLogic.zoomSource(tile: CGRect(x: 100, y: 2000, width: 200, height: 120), overlay: screen) == nil)
        #expect(ShotsOverlayLogic.zoomSource(tile: CGRect(x: 100, y: 770, width: 200, height: 120), overlay: screen) == nil)  // <50% visible
        #expect(ShotsOverlayLogic.zoomSource(tile: nil, overlay: screen) == nil)
    }

    @Test func centreShrinkIsCentredAndSmaller() {
        let t = CGRect(x: 100, y: 100, width: 400, height: 200)
        let s = ShotsOverlayLogic.centreShrink(of: t)
        #expect(s.midX == t.midX && s.midY == t.midY && s.width < t.width)
    }
}
