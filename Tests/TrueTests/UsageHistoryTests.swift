import Foundation
import Testing
@testable import True

@Suite struct UsageHistoryTests {
    let utc = TimeZone(identifier: "UTC")!
    let today = ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z")!

    func row(_ day: String, _ p: String = "claude", _ model: String = "claude-opus-5-5", tokens: Int = 100,
             dollars: Double? = 1) -> UsageReply.Row {
        UsageReply.Row(day: day, provider: p, model: model, input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, dollars: dollars)
    }
    func reply(_ rows: [UsageReply.Row], skipped: [String: Int] = [:], unreadable: [String] = []) -> UsageReply {
        UsageReply(days: rows, unpriced: [], skipped: skipped, unreadable: unreadable)
    }
    func make(_ r: UsageReply, _ p: UsagePeriod = .week, resets: [UsageProvider: [Date]] = [:]) -> UsageHistory {
        UsageHistory.make(reply: r, period: p, today: today, timeZone: utc, resetsSeen: resets)
    }

    @Test func oneBarPerDayEmptyDaysIncluded() {
        let h = make(reply([row("2026-11-09", tokens: 300), row("2026-11-09", "codex", "gpt-5.5", tokens: 50, dollars: 0.5), row("2026-11-07", tokens: 10)]))
        #expect(h.days.map(\.day) == ["2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08", "2026-11-09"])
        #expect(h.days.last?.tokens == 350)
        #expect(h.days.last?.claudeTokens == 300 && h.days.last?.codexTokens == 50)
        #expect(h.days[1].tokens == 0)
        #expect(h.totalTokens == 360)
        #expect(h.totalDollars == 2.5)
    }

    @Test func periodFiltersOutOlderDays() {
        let r = reply([row("2026-11-09", tokens: 1), row("2026-11-08", tokens: 2), row("2026-10-20", tokens: 4), row("2026-08-20", tokens: 8)])
        #expect(make(r, .day).totalTokens == 1)
        #expect(make(r, .day).days.count == 1)
        #expect(make(r, .week).totalTokens == 3)
        #expect(make(r, .month).totalTokens == 7)
        #expect(make(r, .quarter).totalTokens == 15)
        #expect(make(r, .quarter).days.count == 90)
    }

    @Test func unpricedModelsAreLeftOutOfCostAndFlagged() {
        let h = make(reply([row("2026-11-09", "claude", "claude-opus-5-5", tokens: 100, dollars: 2), row("2026-11-09", "codex", "gpt-5.3-codex-spark", tokens: 900, dollars: nil)]))
        #expect(h.totalDollars == 2)
        #expect(h.totalTokens == 1000)
        #expect(h.unpriced == ["GPT-5.3 Codex Spark"])
        #expect(h.models.first { $0.unpriced }?.tokens == 900)
        #expect(h.models(for: .cost).map(\.unpriced) == [false, true])
        #expect(h.models(for: .tokens).first?.tokens == 900)
    }

    @Test func aModelPricedOnOneDayButNotAnotherStaysUnpriced() {
        let h = make(reply([row("2026-11-09", "claude", "claude-x-9", tokens: 1, dollars: 1), row("2026-11-08", "claude", "claude-x-9", tokens: 1, dollars: nil)]))
        #expect(h.models.first?.dollars == nil)
        #expect(h.totalDollars == 1)
    }

    @Test func skippedUnreadableAndEmpty() {
        let h = make(reply([], skipped: ["claude: corrupt": 2, "codex: bad_time": 1, "codex: unreadable_folder": 1], unreadable: ["codex"]))
        #expect(h.skippedLines == 3)
        #expect(h.unreadable == [.codex])
        #expect(h.isEmpty)
        #expect(UsageHistoryCopy.skipped(3) == "3 lines skipped")
        #expect(UsageHistoryCopy.skipped(1) == "1 line skipped")
        #expect(UsageHistoryCopy.unreadable(.codex) == "Can't read Codex's history folder")
    }

    @Test func resetsKeepOnlyThisPeriodPerProvider() {
        let inside = today.addingTimeInterval(-3600), old = today.addingTimeInterval(-40 * 86400)
        let h = make(reply([]), .week, resets: [.claude: [inside, old], .codex: [old]])
        #expect(h.resets.count == 1)
        #expect(h.resets.first?.provider == .claude)
        #expect(h.resets.first?.times == [inside])
    }

    @Test func modelNamesAreHuman() {
        #expect(ModelLabel.human("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelLabel.human("claude-fable-5-1") == "Fable 5.1")
        #expect(ModelLabel.human("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelLabel.human("claude-sonnet-4") == "Sonnet 4")
        #expect(ModelLabel.human("gpt-5.6-sol") == "GPT-5.6 Sol")
        #expect(ModelLabel.human("gpt-5.1-codex-mini") == "GPT-5.1 Codex Mini")
        #expect(!ModelLabel.human("brand-new-model").contains("-"))
    }

    @Test func numbersReadShort() {
        #expect(UsageHistoryCopy.tokens(950) == "950")
        #expect(UsageHistoryCopy.tokens(1_500) == "1.5K")
        #expect(UsageHistoryCopy.tokens(48_200) == "48K")
        #expect(UsageHistoryCopy.tokens(12_400_000) == "12.4M")
        #expect(UsageHistoryCopy.dollars(3.456, whole: false) == "$3.46")
        #expect(UsageHistoryCopy.dollars(412.4, whole: true) == "$412")
    }

    @Test func oneMoneyPrecisionPerScreen() {
        #expect(!UsageHistoryCopy.wholeDollars(total: 99.99))
        #expect(UsageHistoryCopy.wholeDollars(total: 100))
        #expect(!UsageHistoryCopy.wholeDollars(total: 0))
        let small = make(reply([row("2026-11-09", dollars: 16.5), row("2026-11-08", "codex", "gpt-5.5", dollars: 4.5)]))
        #expect(small.money(small.totalDollars) == "$21.00" && small.money(4.5) == "$4.50")
        let big = make(reply([row("2026-11-09", dollars: 294.4), row("2026-11-08", "codex", "gpt-5.5", dollars: 59.4)]))
        #expect(big.money(big.totalDollars) == "$354" && big.money(59.4) == "$59")
    }

    @Test func periodsAreWholeLocalDays() {
        #expect(UsagePeriod.allCases.map(\.label) == ["Today", "7 days", "30 days", "90 days"])
        #expect(UsageHistory.dayKeys(period: .day, today: today, timeZone: utc) == ["2026-11-09"])
    }

    // MARK: reset log

    func tempLog() -> ResetLog {
        ResetLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("resets-\(UUID().uuidString)/resets.json"))
    }
    func win(_ p: UsageProvider, _ k: UsageKind, _ at: Date?) -> UsageWindow {
        UsageWindow(provider: p, kind: k, usedPercent: 10, resetsAt: at, windowMins: nil, readAt: today, state: .fresh)
    }

    @Test func resetLogDedupesWithinTenMinutesPerProviderAndKind() {
        let log = tempLog(), t = today.addingTimeInterval(-3600)
        log.record([win(.claude, .fiveHour, t)], now: today)
        log.record([win(.claude, .fiveHour, t.addingTimeInterval(120)), win(.claude, .weekly, t.addingTimeInterval(60)),
                    win(.codex, .fiveHour, t)], now: today)
        log.record([win(.claude, .fiveHour, t.addingTimeInterval(11 * 60)), win(.claude, .fiveHour, nil)], now: today)
        #expect(log.entries().count == 4)
        #expect(log.entries().filter { $0.provider == .claude && $0.kind == .fiveHour }.count == 2)
    }

    @Test func resetLogDropsEntriesOlderThanNinetyTwoDaysAndPersists() {
        let log = tempLog()
        log.record([win(.claude, .weekly, today.addingTimeInterval(-93 * 86400)), win(.claude, .fiveHour, today.addingTimeInterval(-91 * 86400))], now: today)
        #expect(log.entries().map(\.at) == [today.addingTimeInterval(-91 * 86400).timeIntervalSince1970])
        let old = ResetLog.Entry(provider: .codex, kind: .weekly, at: today.addingTimeInterval(-92 * 86400 - 1).timeIntervalSince1970)
        #expect(ResetLog.merged([old], adding: [], now: today).isEmpty)
        #expect(log.seen()[.claude]?.count == 1)
    }

    @Test func limitsShowOnlyPastResetsInThePeriod() {
        let future = today.addingTimeInterval(3600), past = today.addingTimeInterval(-3600)
        let h = make(reply([]), .week, resets: [.claude: [future, past]])
        #expect(h.resets.first?.times == [past])
    }

    @Test func resetsSeenFormatsPerPeriodNewestFirstAndCaps() {
        func nb(_ s: String) -> String { s.replacingOccurrences(of: "\u{00A0}", with: " ") }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let sat = ISO8601DateFormatter().date(from: "2026-11-07T08:00:00Z")!   // a Saturday
        let nov3 = ISO8601DateFormatter().date(from: "2026-11-03T08:00:00Z")!
        #expect(nb(UsageHistoryCopy.resetsSeen([sat], period: .day, calendar: cal)) == "08:00")
        #expect(nb(UsageHistoryCopy.resetsSeen([sat], period: .week, calendar: cal)) == "Sat 08:00")
        #expect(nb(UsageHistoryCopy.resetsSeen([nov3], period: .month, calendar: cal)) == "Nov 3 08:00")
        #expect(nb(UsageHistoryCopy.resetsSeen([nov3], period: .quarter, calendar: cal)) == "Nov 3 08:00")
        #expect(nb(UsageHistoryCopy.resetsSeen([nov3, sat], period: .week, calendar: cal)) == "Sat 08:00  Tue 08:00")
        #expect(nb(UsageHistoryCopy.resetsSeen([], period: .week, calendar: cal)) == "None in this period")
        let eight = (0..<8).map { nov3.addingTimeInterval(Double($0) * 86400) }
        let line = nb(UsageHistoryCopy.resetsSeen(eight, period: .month, calendar: cal))
        #expect(line.hasPrefix("Nov 10 08:00") && line.hasSuffix("+2 more") && line.components(separatedBy: "  ").count == 7)
    }
}
