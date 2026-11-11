import Foundation

/// Plain names for model ids, so the screen never shows "claude-opus-5-5". Unknown ids still get a readable name.
enum ModelLabel {
    static func human(_ id: String) -> String {
        var parts = id.lowercased().split(separator: "-").map(String.init)
        if parts.last.map({ $0.count == 8 && $0.allSatisfy(\.isNumber) }) == true { parts.removeLast() }   // date suffix
        if parts.last == "latest" { parts.removeLast() }
        guard !parts.isEmpty else { return id }
        func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        if parts[0] == "claude" {
            let rest = parts.dropFirst()
            let version = rest.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            let words = rest.filter { !$0.allSatisfy(\.isNumber) }.map(cap).joined(separator: " ")
            return [words, version].filter { !$0.isEmpty }.joined(separator: " ")
        }
        if parts[0] == "gpt", parts.count > 1 {
            return (["GPT-" + parts[1]] + parts.dropFirst(2).map(cap)).joined(separator: " ")
        }
        return parts.map(cap).joined(separator: " ")
    }
}

enum UsagePeriod: Int, CaseIterable, Identifiable {
    case day = 1, week = 7, month = 30, quarter = 90
    var id: Int { rawValue }
    /// Whole local calendar days: today (since local midnight) plus the days before it.
    var days: Int { rawValue }
    var label: String { self == .day ? "Today" : "\(rawValue) days" }
}

enum UsageSegment: String, CaseIterable, Identifiable {
    case tokens = "Tokens", cost = "Est. cost", limits = "Limits"
    var id: String { rawValue }
}

/// Everything the Usage history screen draws, computed from the scanner's day buckets. Pure: no clock, no files.
struct UsageHistory: Equatable {
    struct Day: Equatable, Identifiable {
        let day: String
        var tokens = 0
        /// Priced requests only; unpriced models are left out and flagged.
        var dollars = 0.0
        var claudeTokens = 0, codexTokens = 0
        var claudeDollars = 0.0, codexDollars = 0.0
        var id: String { day }
    }
    struct ModelRow: Equatable, Identifiable {
        let provider: UsageProvider
        let model: String
        var tokens = 0
        /// nil = unpriced: the model has no price row, so it has no cost and is never guessed.
        var dollars: Double?
        var id: String { provider.rawValue + "/" + model }
        var name: String { ModelLabel.human(model) }
        var unpriced: Bool { dollars == nil }
    }
    /// Reset times seen in the period, per provider, oldest first.
    struct Resets: Equatable { let provider: UsageProvider; let times: [Date] }

    var period: UsagePeriod
    /// One entry per local day of the period, oldest first, empty days included.
    var days: [Day]
    /// Biggest spender first (tokens, or dollars on the cost segment via `models(for:)`).
    var models: [ModelRow]
    var totalTokens: Int
    /// Sum over priced models only. Shown with "est."; the unpriced list says what it leaves out.
    var totalDollars: Double
    var unpriced: [String]
    var skippedLines: Int
    var unreadable: [UsageProvider]
    var windows: [UsageWindow]
    var resets: [Resets]

    var isEmpty: Bool { totalTokens == 0 }
    /// Every dollar amount on the screen follows the total's precision.
    var wholeDollars: Bool { UsageHistoryCopy.wholeDollars(total: totalDollars) }
    func money(_ d: Double) -> String { UsageHistoryCopy.dollars(d, whole: wholeDollars) }
    var maxDayTokens: Int { days.map(\.tokens).max() ?? 0 }
    var maxDayDollars: Double { days.map(\.dollars).max() ?? 0 }

    /// Models in the order the segment wants: cost puts priced models by dollars first, unpriced last.
    func models(for segment: UsageSegment) -> [ModelRow] {
        guard segment == .cost else { return models }
        return models.sorted {
            switch ($0.dollars, $1.dollars) {
            case let (a?, b?): return a == b ? $0.tokens > $1.tokens : a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.tokens > $1.tokens
            }
        }
    }

    /// Day keys ("2026-11-09") for the last `period.days` local days up to and including `today`.
    static func dayKeys(period: UsagePeriod, today: Date, timeZone: TimeZone) -> [String] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let start = cal.startOfDay(for: today)
        return (0..<period.days).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: start) else { return nil }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
    }

    /// `reply` may hold more days than the period (the screen asks once for 90); rows outside it are ignored.
    /// `resetsSeen` = reset times recorded per provider; only those inside the period and not in the future are kept.
    static func make(reply: UsageReply, period: UsagePeriod, today: Date, timeZone: TimeZone = .current,
                     resetsSeen: [UsageProvider: [Date]] = [:]) -> UsageHistory {
        let keys = dayKeys(period: period, today: today, timeZone: timeZone)
        var byDay: [String: Day] = Dictionary(uniqueKeysWithValues: keys.map { ($0, Day(day: $0)) })
        var models: [String: ModelRow] = [:]
        var unpriced = Set<String>()
        for r in reply.days {
            guard var d = byDay[r.day], let provider = UsageProvider(rawValue: r.provider) else { continue }
            let t = r.input + r.output + r.cacheRead + r.cacheWrite
            d.tokens += t
            if provider == .claude { d.claudeTokens += t } else { d.codexTokens += t }
            if let dollars = r.dollars {
                d.dollars += dollars
                if provider == .claude { d.claudeDollars += dollars } else { d.codexDollars += dollars }
            }
            byDay[r.day] = d
            let k = provider.rawValue + "/" + r.model
            var m = models[k] ?? ModelRow(provider: provider, model: r.model, tokens: 0, dollars: 0)
            m.tokens += t
            if let dollars = r.dollars { m.dollars = m.dollars.map { $0 + dollars } } else { m.dollars = nil; unpriced.insert(r.model) }
            models[k] = m
        }
        let days = keys.compactMap { byDay[$0] }
        let lo = keys.first.flatMap { startOfDay($0, timeZone) } ?? today
        let resets = UsageProvider.allCases.compactMap { p -> Resets? in
            let ts = (resetsSeen[p] ?? []).filter { $0 >= lo && $0 <= today }.sorted()
            return ts.isEmpty ? nil : Resets(provider: p, times: ts)
        }
        // "n lines skipped" counts every provider; the reply's keys are "provider: reason".
        let skipped = reply.skipped.filter { !$0.key.hasSuffix("unreadable_folder") }.values.reduce(0, +)
        return UsageHistory(
            period: period, days: days,
            models: models.values.sorted { ($0.tokens, $1.id) > ($1.tokens, $0.id) },
            totalTokens: days.reduce(0) { $0 + $1.tokens }, totalDollars: days.reduce(0) { $0 + $1.dollars },
            unpriced: unpriced.map(ModelLabel.human).sorted(), skippedLines: skipped,
            unreadable: reply.unreadable.compactMap(UsageProvider.init(rawValue:)),
            windows: reply.windows, resets: resets)
    }

    private static func startOfDay(_ key: String, _ tz: TimeZone) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

/// The words on the screen, in one place.
enum UsageHistoryCopy {
    static let title = "Usage history", empty = "No usage in this period", est = "est. at API prices", unpricedTag = "unpriced"
    static let link = "Usage history", done = "Done", menu = "Usage"
    static func unreadable(_ p: UsageProvider) -> String { "Can't read \(AgentsCopy.provider(p))'s history folder" }
    /// "Resets seen" cell: newest first, at most 6 then "+N more". Today "08:00", 7 days "Sat 08:00", longer "Nov 3 08:00".
    static func resetsSeen(_ times: [Date], period: UsagePeriod, calendar: Calendar) -> String {
        guard !times.isEmpty else { return "None in this period" }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = period == .day ? "HH:mm" : period == .week ? "EEE HH:mm" : "MMM d HH:mm"
        let sorted = times.sorted(by: >)
        // Non-breaking spaces inside a time, so a long row wraps between resets, never inside one.
        var parts = sorted.prefix(6).map { f.string(from: $0).replacingOccurrences(of: " ", with: "\u{00A0}") }
        if sorted.count > 6 { parts.append("+\(sorted.count - 6) more") }
        return parts.joined(separator: "  ")
    }
    static func skipped(_ n: Int) -> String { "\(n) \(n == 1 ? "line" : "lines") skipped" }
    static func unpricedNote(_ names: [String]) -> String { "Not priced: " + names.joined(separator: ", ") }
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: return "\(Int((Double(n) / 1000).rounded()))K"
        case 1000...: return String(format: "%.1fK", Double(n) / 1000)
        default: return "\(n)"
        }
    }
    /// One precision per screen: a total of $100 or more puts every amount in whole dollars, otherwise in cents.
    static func wholeDollars(total: Double) -> Bool { (total * 100).rounded() / 100 >= 100 }
    static func dollars(_ d: Double, whole: Bool) -> String { String(format: whole ? "$%.0f" : "$%.2f", d) }
}
