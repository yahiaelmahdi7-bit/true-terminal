import Foundation
import Testing
@testable import True

@Suite struct UsageWindowsTests {
    static func fixture(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-rollouts/\(name).jsonl")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    // 2026-11-07T23:19:06Z = 1794107946 ... resets_at 1794106486 is before that; use an earlier "now".
    let early = Date(timeIntervalSince1970: 1_794_100_000)

    @Test func codexLatestSkipsNullLine() throws {
        let w = try #require(UsageParsing.codex(tail: Self.fixture("rollout-tail-latest"), now: early))
        #expect(w[0].usedPercent == 98 && w[1].usedPercent == 25 && w[0].windowMins == 300)
        #expect(w[0].resetsAt == Date(timeIntervalSince1970: 1_794_106_486))
    }

    @Test func codexMixedTakesNewestRealEvent() throws {
        let w = try #require(UsageParsing.codex(tail: Self.fixture("rollout-tail-mixed"), now: early))
        #expect(w[0].state != .none && w[0].resetsAt != nil)
    }

    @Test func codexNullTailHasNoReading() {
        #expect(UsageParsing.codex(tail: Self.fixture("rollout-tail-null"), now: early) == nil)
    }

    @Test func freshnessStates() throws {
        let base = try #require(UsageParsing.codex(tail: Self.fixture("rollout-tail-latest"), now: early))[0]
        let read = try #require(base.readAt)
        #expect(base.classified(now: read.addingTimeInterval(60)).state == .fresh)
        #expect(base.classified(now: read.addingTimeInterval(31 * 60)).state == .old)
        let past = base.classified(now: base.resetsAt!.addingTimeInterval(5))
        #expect(past.state == .pastReset && past.usedPercent == nil && past.resetsAt != nil)
        #expect(UsageWindow.empty(.codex, .weekly).classified(now: early).state == .none)
        #expect(UsageText.freshness(.empty(.codex, .weekly)) == "No reading yet")
    }

    @Test func claudeReaderJSON() {
        let json = #"{"windows":{"five":null,"seven":{"util":0.37,"resets_at":1794808800,"seen_at":1794209495.4,"status":"allowed"}}}"#
        let w = UsageParsing.claude(Data(json.utf8), now: Date(timeIntervalSince1970: 1_794_209_600))
        #expect(w[0].state == .none)
        #expect(w[1].usedPercent == 37 && w[1].state == .fresh && w[1].windowMins == 10080)
    }

    @Test func codexLatestWalksFilesNewestFirstAndLooksBackSevenDays() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.fixture("rollout-tail-null").write(to: dir.appendingPathComponent("new.jsonl"), atomically: true, encoding: .utf8)
        try Self.fixture("rollout-tail-latest").write(to: dir.appendingPathComponent("older.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: dir.appendingPathComponent("older.jsonl").path)
        let w = UsageParsing.codexLatest(sessions: dir, now: Date())
        #expect(w?[0].usedPercent != nil || w?[0].state == .pastReset)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9 * 86_400)], ofItemAtPath: dir.appendingPathComponent("older.jsonl").path)
        #expect(UsageParsing.codexLatest(sessions: dir, now: Date()) == nil)
    }

    @MainActor @Test func keepLastGoodAndOnlyProbeOnClick() async {
        let store = UsageStore()
        store.resetLog = ResetLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("resets-\(UUID().uuidString).json"))
        let good = UsageParsing.claude(Data(#"{"windows":{"five":null,"seven":{"util":0.5,"resets_at":1794808800,"seen_at":1794209495}}}"#.utf8),
                                       now: Date(timeIntervalSince1970: 1_794_209_500))
        store.apply(claude: good, codex: nil, now: Date(timeIntervalSince1970: 1_794_209_500))
        store.apply(claude: [], codex: nil, now: Date(timeIntervalSince1970: 1_794_212_000))
        let w = store.window(.claude, .weekly)
        #expect(w.usedPercent == 50 && w.state == .old)
    }
}

/// The usage clock follows the Mac's 12 h / 24 h setting (passed in here so the test is the same on every Mac).
@Suite struct UsageClockTests {
    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    static let at = Date(timeIntervalSince1970: 1_794_234_000)   // Mon 2026-11-09 14:20 UTC
    static let gb = Locale(identifier: "en_GB"), us = Locale(identifier: "en_US")

    @Test func todayIsTimeOnlyInTheMacsOwnFormat() {
        #expect(UsageText.clock(Self.at, now: Self.at, calendar: Self.utc, locale: Self.gb) == "14:20")
        let twelve = UsageText.clock(Self.at, now: Self.at, calendar: Self.utc, locale: Self.us)
        #expect(twelve.hasPrefix("2:20") && twelve.hasSuffix("PM"))
    }

    @Test func anotherDayAddsTheWeekdayUnlessTimeOnly() {
        let tomorrow = Self.at.addingTimeInterval(86_400)
        #expect(UsageText.clock(Self.at, now: tomorrow, calendar: Self.utc, locale: Self.gb) == "Mon 14:20")
        #expect(UsageText.clock(Self.at, timeOnly: true, now: tomorrow, calendar: Self.utc, locale: Self.gb) == "14:20")
        let twelve = UsageText.clock(Self.at, now: tomorrow, calendar: Self.utc, locale: Self.us)
        #expect(twelve.hasPrefix("Mon 2:20") && twelve.hasSuffix("PM"))
    }
}
