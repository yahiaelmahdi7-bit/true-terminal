import Foundation

/// What `truectl usage` gets back: day totals (per day, provider, model) plus honesty fields.
struct UsageReply: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable {
        let day: String, provider: String, model: String
        let input: Int, output: Int, cacheRead: Int, cacheWrite: Int
        /// nil = unpriced.
        let dollars: Double?
    }
    var days: [Row]
    /// Models seen with no price row, so a dollar total is never read as complete when it is not.
    var unpriced: [String]
    /// "provider: reason" -> count.
    var skipped: [String: Int]
    /// Providers whose history folder could not be read.
    var unreadable: [String]
    var windows: [UsageWindow] = []

    /// The last `days` local days up to and including `today`.
    static func make(buckets: [UsageBucket], stats: UsageScanStats, days: Int, today: Date = Date(),
                     timeZone: TimeZone = .current) -> UsageReply {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let first = cal.date(byAdding: .day, value: -(max(1, days) - 1), to: cal.startOfDay(for: today)) ?? today
        var keyer = DayKeyer(timeZone: timeZone)
        let firstKey = keyer.day(for: first.timeIntervalSince1970)
        let rows = buckets.filter { $0.day >= firstKey }.map {
            Row(day: $0.day, provider: $0.provider.rawValue, model: $0.model, input: $0.tokens.input,
                output: $0.tokens.output, cacheRead: $0.tokens.cacheRead, cacheWrite: $0.tokens.cacheWrite,
                dollars: $0.dollars)
        }
        var skipped: [String: Int] = [:]
        for (p, reasons) in stats.skipped { for (r, n) in reasons { skipped["\(p.rawValue): \(r)"] = n } }
        return UsageReply(days: rows, unpriced: Array(Set(rows.filter { $0.dollars == nil }.map(\.model))).sorted(),
                          skipped: skipped,
                          unreadable: stats.folders.filter { $0.value == .unreadable }.map { $0.key.rawValue }.sorted())
    }
}

/// The app's one scanner. Only the app scans (one writer); `truectl usage` asks the app over the control socket.
final class UsageService: @unchecked Sendable {
    static let shared = UsageService(scanner: .standard())
    let scanner: UsageScanner
    init(scanner: UsageScanner) { self.scanner = scanner }

    /// Scan at utility priority (new bytes only), then answer. Never blocks the caller's thread.
    func reply(days: Int) async -> UsageReply {
        await Task.detached(priority: .utility) { [scanner] in
            let stats = scanner.scan()
            return UsageReply.make(buckets: scanner.buckets(), stats: stats, days: days, timeZone: scanner.timeZone)
        }.value
    }
}
