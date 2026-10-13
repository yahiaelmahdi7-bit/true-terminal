import Testing
import Foundation
@testable import True

@Suite struct TerminalDropTests {
    @Test func screenshotNameEscapesSpacesButNotNarrowNoBreakSpace() {
        let name = "/Users/example/Desktop/Screenshot 2026-09-30 at 11.43.14\u{202F}AM.png"
        #expect(TerminalDrop.shellEscaped(name)
                == "/Users/example/Desktop/Screenshot\\ 2026-09-30\\ at\\ 11.43.14\u{202F}AM.png")
    }

    @Test func everyMetacharacterIsEscaped() {
        for ch in " \t\\'\"()[]{}<>|&;$`!*?#~=" {
            #expect(TerminalDrop.shellEscaped("a\(ch)b") == "a\\\(ch)b")
        }
        #expect(TerminalDrop.shellEscaped("/plain/path-1_2.png") == "/plain/path-1_2.png")
    }

    @Test func pathsJoinWithOneSpaceAndOneTrailingSpace() {
        #expect(TerminalDrop.pasteText(forPaths: ["/a b", "/c"]) == "/a\\ b /c ")
        #expect(TerminalDrop.pasteText(forPaths: ["/x"]) == "/x ")
    }

    @Test func uniqueNamingAddsCounterBeforeExtension() {
        let dir = URL(fileURLWithPath: "/d")
        #expect(TerminalDrop.uniqueURL(for: "a.png", in: dir) { _ in false }.path == "/d/a.png")
        #expect(TerminalDrop.uniqueURL(for: "a.png", in: dir) { $0 == "/d/a.png" }.path == "/d/a 2.png")
        let two: Set<String> = ["/d/a.png", "/d/a 2.png"]
        #expect(TerminalDrop.uniqueURL(for: "a.png", in: dir) { two.contains($0) }.path == "/d/a 3.png")
        #expect(TerminalDrop.uniqueURL(for: "noext", in: dir) { $0 == "/d/noext" }.path == "/d/noext 2")
    }

    @Test func dropImageNameFormat() {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 30; c.hour = 11; c.minute = 43; c.second = 14
        let date = Calendar.current.date(from: c)!
        #expect(TerminalDrop.dropImageName(date: date) == "drop-2026-09-30-114314.png")
    }

    @Test func expiredSelectsOnlyFilesOlderThanMaxAge() {
        let now = Date()
        let old = (URL(fileURLWithPath: "/old"), now.addingTimeInterval(-8 * 86400))
        let fresh = (URL(fileURLWithPath: "/fresh"), now.addingTimeInterval(-6 * 86400))
        let urls = TerminalDrop.expired([old, fresh], now: now, maxAge: 7 * 86400)
        #expect(urls == [old.0])
    }

    @Test func sanitizedPasteStripsEscapeAndFlattensNewlinesOnlyWhenNotBracketed() {
        let evil = "a\u{1B}[201~b\nc\r\nd"
        #expect(TerminalDrop.sanitizedPaste(evil, bracketed: true) == "a[201~b\nc\r\nd")
        #expect(TerminalDrop.sanitizedPaste(evil, bracketed: false) == "a[201~b c d")
    }

    @Test func sanitizedPasteDropsOtherControlCharactersButKeepsTabAndText() {
        let s = "x\u{03}y\u{04}\tz\u{7F}\u{9B}31m\u{202F}é"
        #expect(TerminalDrop.sanitizedPaste(s, bracketed: true) == "xy\tz31m\u{202F}é")
    }
}
