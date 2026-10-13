import Testing
import Foundation
@testable import True

func cleanerTemp() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("true-cleaner-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@discardableResult
func cleanerWrite(_ url: URL, _ text: String, age: TimeInterval = 3600) -> URL {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    return url
}

let bigText = "# Title\n" + String(repeating: "line of text that is long enough\n", count: 20)

@Suite struct CleanerScanTests {
    @Test func findsEveryKindGlobalFirstAndUnchecked() {
        let home = cleanerTemp()
        let proj = home.appendingPathComponent("Projects/alpha")
        cleanerWrite(home.appendingPathComponent(".claude/CLAUDE.md"), bigText)
        cleanerWrite(proj.appendingPathComponent("CLAUDE.md"), bigText + "a")
        cleanerWrite(proj.appendingPathComponent(".claude/CLAUDE.md"), bigText + "b")
        cleanerWrite(proj.appendingPathComponent(".claude/HANDOFF.md"), bigText + "c")
        cleanerWrite(proj.appendingPathComponent(".claude/HANDOFF-abc.md"), bigText + "d")
        cleanerWrite(proj.appendingPathComponent("HANDOFF.md"), bigText + "e")
        cleanerWrite(proj.appendingPathComponent("studio-docs/HANDOFF-x.md"), bigText + "f")
        cleanerWrite(proj.appendingPathComponent("notes.md"), bigText + "g")
        let files = ContextScanner(home: home.path).scan(roots: [proj.path, home.path])
        #expect(files.count == 7)
        #expect(files[0].kind == .global)
        #expect(files[0].defaultChecked == false)
        #expect(files.dropFirst().allSatisfy { $0.defaultChecked })
        #expect(files.filter { $0.kind == .handoff }.count == 4)
        #expect(files.filter { $0.kind == .claudeMd }.count == 2)
        #expect(files[1].project == "~/Projects/alpha")
    }

    @Test func skipsSmallFilesAndDedupesRealPaths() {
        let home = cleanerTemp()
        let proj = home.appendingPathComponent("p")
        cleanerWrite(proj.appendingPathComponent("CLAUDE.md"), "tiny")
        let real = cleanerWrite(proj.appendingPathComponent(".claude/CLAUDE.md"), bigText)
        try? FileManager.default.createSymbolicLink(at: proj.appendingPathComponent("HANDOFF.md"), withDestinationURL: real)
        // home is also a root and holds the global file: it must not appear twice.
        cleanerWrite(home.appendingPathComponent(".claude/CLAUDE.md"), bigText + "g")
        let files = ContextScanner(home: home.path).scan(roots: [proj.path, proj.path, home.path])
        #expect(files.count == 2)
        #expect(Set(files.map(\.path)).count == 2)
        #expect(files.contains { $0.path == real.path && $0.kind == .claudeMd })
    }

    @Test func liveHandoffIsLockedDeadIsNot() {
        let home = cleanerTemp()
        let proj = home.appendingPathComponent("p")
        cleanerWrite(proj.appendingPathComponent(".claude/HANDOFF-live1.md"), bigText + "1")
        cleanerWrite(proj.appendingPathComponent(".claude/HANDOFF-dead1.md"), bigText + "2")
        cleanerWrite(proj.appendingPathComponent(".claude/HANDOFF-none.md"), bigText + "3")
        cleanerWrite(home.appendingPathComponent(".claude/state/live-live1"), "\(getpid()) extra\n")
        cleanerWrite(home.appendingPathComponent(".claude/state/live-dead1"), "999999 x\n")
        let files = ContextScanner(home: home.path).scan(roots: [proj.path])
        func f(_ n: String) -> ContextFile? { files.first { $0.path.hasSuffix(n) } }
        #expect(f("HANDOFF-live1.md")?.lock == .live)
        #expect(f("HANDOFF-live1.md")?.defaultChecked == false)
        #expect(f("HANDOFF-dead1.md")?.lock == nil)
        #expect(f("HANDOFF-none.md")?.lock == nil)
    }

    @Test func recentlyModifiedIsInUseWithInjectedClock() {
        let home = cleanerTemp()
        let proj = home.appendingPathComponent("p")
        cleanerWrite(proj.appendingPathComponent("CLAUDE.md"), bigText, age: 300)
        var s = ContextScanner(home: home.path)
        #expect(s.scan(roots: [proj.path]).first?.lock == .inUse)
        s.now = { Date().addingTimeInterval(3600) }
        #expect(s.scan(roots: [proj.path]).first?.lock == nil)
    }
}
