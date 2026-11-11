import AppKit
import SwiftUI
import Testing
@testable import True

/// Stills for the Usage history screen and the context meter, from stand-in data. Written to .out/stills/t3-parity/.
@MainActor
@Suite struct UsageHistoryStillsTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let today = ISO8601DateFormatter().date(from: "2026-11-09T08:00:00Z")!   // the stills' stand-in "now"
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = utc; return c }

    func snap<V: View>(_ name: String, width: CGFloat, @ViewBuilder _ content: () -> V) throws {
        try FileManager.default.createDirectory(at: AgentsStillsTests.root, withIntermediateDirectories: true)
        for (tag, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                          ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            let view = content().frame(width: width).background(scheme == .dark ? Theme.Token.bg0 : Color(white: 0.93))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view); r.scale = 2
            let img = try #require(r.nsImage)
            let tiff = try #require(img.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: AgentsStillsTests.root.appendingPathComponent("\(name)-\(tag).png"))
        }
    }

    /// Stand-in days: a steady Claude week, Codex on some days, a quiet weekend.
    func rows(days: Int, unpriced: Bool = false, claude: Bool = true) -> [UsageReply.Row] {
        let keys = UsageHistory.dayKeys(period: .quarter, today: Self.today, timeZone: Self.utc).suffix(days)
        var out: [UsageReply.Row] = []
        for (i, k) in keys.enumerated() {
            let wave = 1 + (i * 7 % 5)
            if claude && i % 7 != 5 && i % 7 != 6 {
                out.append(.init(day: k, provider: "claude", model: "claude-opus-5-5", input: 40_000 * wave, output: 90_000 * wave,
                                 cacheRead: 2_400_000 * wave, cacheWrite: 300_000 * wave, dollars: 1.1 * Double(wave)))
                out.append(.init(day: k, provider: "claude", model: "claude-sonnet-5-5", input: 10_000, output: 30_000 * wave,
                                 cacheRead: 600_000 * wave, cacheWrite: 80_000, dollars: 0.3 * Double(wave)))
            }
            if i % 3 == 0 {
                out.append(.init(day: k, provider: "codex", model: "gpt-5.6-sol", input: 200_000 * wave, output: 40_000, cacheRead: 900_000,
                                 cacheWrite: 0, dollars: 0.9 * Double(wave)))
                if unpriced {
                    out.append(.init(day: k, provider: "codex", model: "gpt-5.3-codex-spark", input: 150_000, output: 20_000, cacheRead: 400_000,
                                     cacheWrite: 0, dollars: nil))
                }
            }
        }
        return out
    }
    func history(_ rows: [UsageReply.Row], _ period: UsagePeriod, skipped: [String: Int] = [:], unreadable: [String] = [],
                 resets: Bool = false) -> UsageHistory {
        var r = UsageReply(days: rows, unpriced: [], skipped: skipped, unreadable: unreadable)
        func w(_ p: UsageProvider, _ k: UsageKind, _ pct: Double) -> UsageWindow {
            UsageWindow(provider: p, kind: k, usedPercent: pct, resetsAt: Self.today.addingTimeInterval(k == .weekly ? 4 * 86_400 + 7200 : 7200), windowMins: nil,
                        readAt: Self.today.addingTimeInterval(-300), state: .fresh)
        }
        r.windows = [w(.claude, .fiveHour, 31), w(.claude, .weekly, 12), w(.codex, .fiveHour, 18), w(.codex, .weekly, 40)]
        var seen: [UsageProvider: [Date]] = [:]
        if resets {
            let offsets: [TimeInterval] = [-86400 * 6, -86400 * 5, -86400 * 2, -3 * 3600]
            seen[.claude] = offsets.map { Self.today.addingTimeInterval($0) }
            seen[.codex] = [Self.today.addingTimeInterval(-86400 * 3)]
        }
        return UsageHistory.make(reply: r, period: period, today: Self.today, timeZone: Self.utc, resetsSeen: seen)
    }
    func screen(_ h: UsageHistory, _ s: UsageSegment) -> some View {
        UsageHistoryView(history: h, segment: s, now: Self.today, calendar: Self.cal)
    }

    @Test func standInDatesAreAroundNov9() {
        let week = UsageHistory.dayKeys(period: .week, today: Self.today, timeZone: Self.utc)
        let quarter = UsageHistory.dayKeys(period: .quarter, today: Self.today, timeZone: Self.utc)
        #expect(week.first == "2026-11-03" && week.last == "2026-11-09")
        #expect(quarter.first == "2026-08-12" && quarter.last == "2026-11-09")
    }

    @Test func unreadableFolderStandInHasNoClaudeUsage() {
        let h = history(rows(days: 7, claude: false), .week, unreadable: ["claude"])
        #expect(h.unreadable == [.claude] && h.days.allSatisfy { $0.claudeTokens == 0 } && h.models.allSatisfy { $0.provider == .codex })
    }

    @Test func historyStills() throws {
        try snap("t3-usage-history-empty", width: 520) { screen(history([], .week), .tokens) }
        try snap("t3-usage-history-today", width: 520) { screen(history(rows(days: 1), .day), .tokens) }
        try snap("t3-usage-history-today-cost", width: 520) { screen(history(rows(days: 1), .day), .cost) }
        try snap("t3-usage-history-90days", width: 520) { screen(history(rows(days: 90), .quarter), .tokens) }
        try snap("t3-usage-history-90days-cost", width: 520) { screen(history(rows(days: 90), .quarter), .cost) }
        try snap("t3-usage-history-unpriced", width: 520) { screen(history(rows(days: 30, unpriced: true), .month), .cost) }
        try snap("t3-usage-history-skipped", width: 520) {
            screen(history(rows(days: 7), .week, skipped: ["claude: corrupt": 12, "codex: bad_time": 3]), .tokens)
        }
        try snap("t3-usage-history-unreadable", width: 520) {
            screen(history(rows(days: 7, claude: false), .week, unreadable: ["claude"]), .tokens)
        }
        try snap("t3-usage-history-unreadable-both", width: 520) { screen(history([], .week, unreadable: ["claude", "codex"]), .tokens) }
        try snap("t3-usage-history-limits", width: 520) { screen(history(rows(days: 30), .month, resets: true), .limits) }
    }

    func seat(_ n: String, _ activity: String, _ used: Int?, model: String = "claude-opus-5-5") -> ActivityRow {
        var r = ActivityRow(kind: .seat, id: n, name: n, status: "working", activity: activity, project: "true", provider: "Claude",
                            model: "Opus", effort: nil, browser: nil, needsYou: false, since: Self.today)
        r.context = used.flatMap { ContextReading(used: $0, size: ModelPrices.contextTokens(for: model)) }
        return r
    }

    @Test func contextMeterStills() throws {
        func tile(_ rows: [ActivityRow]) -> some View {
            AgentsTile(rows: rows).frame(width: 280).background(Theme.Token.bg3, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.Token.line, lineWidth: 1)).padding(8)
        }
        try snap("t3-context-meter-10", width: 296) { tile([seat("Main", "Editing a file", 100_000)]) }
        try snap("t3-context-meter-60", width: 296) { tile([seat("Main", "Editing a file", 600_000)]) }
        try snap("t3-context-meter-95", width: 296) { tile([seat("Main", "Editing a file", 950_000)]) }
        try snap("t3-context-meter-unknown", width: 296) { tile([seat("Main", "Editing a file", 120_000, model: "claude-sonnet-4-6")]) }
        try snap("t3-context-meter-mixed", width: 296) {
            tile([seat("Main", "Editing a file", 100_000), seat("Docs", "Reading a file", 600_000), seat("Review", "Running tests", 950_000),
                  seat("Codex seat", "Waiting", nil)])
        }
        try snap("t3-context-meter-long-name", width: 296) {
            tile([seat("A very long agent name that keeps going and going", "Reading a very long file name here", 600_000)])
        }
    }
}
