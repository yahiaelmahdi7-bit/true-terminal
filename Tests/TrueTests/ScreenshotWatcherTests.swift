import Testing
import Foundation
@testable import True

@Suite struct ScreenshotWatcherTests {
    typealias W = ScreenshotWatcher
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ name: String, _ age: TimeInterval = 0, file: Bool = true, flag: Bool = false) -> W.Entry {
        W.Entry(name: name, url: URL(fileURLWithPath: "/d/\(name)"), date: t0.addingTimeInterval(-age),
                isRegularFile: file, isScreenCaptureFlag: flag)
    }

    @Test func screenshotNames() {
        #expect(W.isScreenshotName("Screenshot 2026-09-30 at 11.43.14\u{202F}AM.png"))
        #expect(W.isScreenshotName("Screen Shot 2019-01-01 at 1.00.00 PM.png"))
        #expect(!W.isScreenshotName("Screenshots.png"))
        #expect(!W.isScreenshotName("photo.png"))
    }

    @Test func imageExtensionsAreCaseInsensitive() {
        for n in ["a.PNG", "a.jpg", "a.JPEG", "a.heic", "a.tiff", "a.tif", "a.gif"] { #expect(W.isImageFile(n)) }
        #expect(!W.isImageFile("a.mov"))
        #expect(!W.isImageFile("png"))
    }

    @Test func selectSkipsHiddenMoviesDirectoriesAndPlainImages() {
        let out = W.select([
            entry(".Screenshot 2026 temp.png"),
            entry("Screenshot 2026-09-30 at 1.00.00\u{202F}PM.mov"),
            entry("Screenshot dir.png", file: false),
            entry("vacation.png"),
            entry("Screenshot a.png"),
        ], limit: 9)
        #expect(out.map(\.url.lastPathComponent) == ["Screenshot a.png"])
    }

    @Test func nonScreenshotNameKeptOnlyWithXattrFlag() {
        let out = W.select([entry("Bildschirmfoto.png", flag: true), entry("Other.png", flag: false)], limit: 9)
        #expect(out.map(\.url.lastPathComponent) == ["Bildschirmfoto.png"])
    }

    @Test func sortsNewestFirstAndLimits() {
        let entries = (0..<12).map { entry("Screenshot \($0).png", TimeInterval($0 * 10)) }.reversed()
        let out = W.select(Array(entries), limit: 9)
        #expect(out.count == 9)
        #expect(out.first?.url.lastPathComponent == "Screenshot 0.png")
        #expect(out.last?.url.lastPathComponent == "Screenshot 8.png")
    }

    @Test func freshLogic() {
        #expect(W.isFresh(newest: t0, lastSeen: t0.addingTimeInterval(-1)))
        #expect(!W.isFresh(newest: t0, lastSeen: t0))
        #expect(!W.isFresh(newest: t0.addingTimeInterval(-5), lastSeen: t0))
        #expect(!W.isFresh(newest: nil, lastSeen: t0))
        #expect(!W.isFresh(newest: t0, lastSeen: nil))   // unknown lastSeen: never fresh
    }

    @Test func folderParsing() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        #expect(W.folder(fromDefaultsValue: nil, home: home).path == "/Users/example/Desktop")
        #expect(W.folder(fromDefaultsValue: "", home: home).path == "/Users/example/Desktop")
        #expect(W.folder(fromDefaultsValue: "~/Pictures/Shots/", home: home).path == "/Users/example/Pictures/Shots")
        #expect(W.folder(fromDefaultsValue: "/Volumes/X/Shots", home: home).path == "/Volumes/X/Shots")
    }

    @Test func folderFollowsTheSetting() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let desktop = URL(fileURLWithPath: "/Users/example/Desktop", isDirectory: true)
        #expect(W.folderChange(from: desktop, defaultsValue: "~/Pictures/Screenshots", home: home)?.path
                == "/Users/example/Pictures/Screenshots")
        #expect(W.folderChange(from: desktop, defaultsValue: nil, home: home) == nil)
        #expect(W.folderChange(from: desktop, defaultsValue: "", home: home) == nil)
        let shots = URL(fileURLWithPath: "/Users/example/Pictures/Screenshots", isDirectory: true)
        #expect(W.folderChange(from: shots, defaultsValue: nil, home: home)?.path == "/Users/example/Desktop")
    }

    @Test func relativeLabels() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15, minute: 0))!
        func label(_ ago: TimeInterval) -> String { W.relativeLabel(for: now.addingTimeInterval(-ago), now: now, calendar: cal) }
        #expect(label(5) == "now")
        #expect(label(120) == "2m")
        #expect(label(3 * 3600) == "3h")
        #expect(label(20 * 3600) == "Yesterday")   // 19:00 the day before
        #expect(label(5 * 86400) == "Sep 25")
    }
}
