import Foundation
import Testing
@testable import True

/// Opt-in, never in the default suite. Scans THIS Mac's real ~/.claude and ~/.codex, read-only, with the shipped
/// scanner, and writes one local day's totals:
///
///     TRUE_USAGE_DAY=2026-11-08 TRUE_USAGE_OUT=/tmp/day.json swift test --filter UsageRealDay
///
/// Nothing is written under ~/.claude or ~/.codex (no cache either: the scan is in memory). Files whose last change
/// is older than the day cannot hold it, so they are not opened; "files_read" counts the files actually opened.
@Suite struct UsageRealDay {
    static let env = ProcessInfo.processInfo.environment
    static let on = env["TRUE_USAGE_DAY"] != nil && env["TRUE_USAGE_OUT"] != nil

    @Test(.enabled(if: UsageRealDay.on))
    func writesTheDayTotals() throws {
        let day = Self.env["TRUE_USAGE_DAY"]!, out = URL(fileURLWithPath: Self.env["TRUE_USAGE_OUT"]!)
        let tz = TimeZone.current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let parts = day.split(separator: "-").compactMap { Int($0) }
        try #require(parts.count == 3, "TRUE_USAGE_DAY must look like 2026-11-08")
        let start = try #require(cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])))
        let home = URL(fileURLWithPath: NSHomeDirectory())
        // The out file must not be inside the folders being read.
        try #require(!out.path.hasPrefix(home.appendingPathComponent(".claude").path) && !out.path.hasPrefix(home.appendingPathComponent(".codex").path))

        let scanner = UsageScanner(claudeRoot: home.appendingPathComponent(".claude/projects"),
                                   codexRoot: home.appendingPathComponent(".codex/sessions"),
                                   cacheDir: nil, timeZone: tz, cutoffOverride: start)
        let stats = scanner.scan()
        let buckets = scanner.buckets().filter { $0.day == day }

        var providers: [String: Any] = [:]
        for p in UsageProvider.allCases {
            var models: [String: Any] = [:]
            var total = UsageTokens(); var dollars = 0.0; var unpriced = false
            for b in buckets where b.provider == p {
                var m: [String: Any] = ["input": b.tokens.input, "output": b.tokens.output,
                                        "cache_read": b.tokens.cacheRead, "cache_write": b.tokens.cacheWrite,
                                        "priced": b.dollars != nil]
                m["est_dollars"] = b.dollars.map { ($0 * 10_000).rounded() / 10_000 } ?? NSNull()
                models[b.model] = m
                total += b.tokens
                if let d = b.dollars { dollars += d } else { unpriced = true }
            }
            providers[p.rawValue] = [
                "models": models,
                "total": ["input": total.input, "output": total.output, "cache_read": total.cacheRead, "cache_write": total.cacheWrite,
                          "est_dollars_priced_models_only": (dollars * 10_000).rounded() / 10_000, "has_unpriced_models": unpriced],
                "files_read": stats.filesRead[p] ?? 0,
                "lines_skipped": stats.skipped[p] ?? [:],
                "folder": (stats.folders[p] ?? .absent).rawValue,
            ] as [String: Any]
        }
        let doc: [String: Any] = ["day": day, "time_zone": tz.identifier, "providers": providers,
                                  "price_table_checked": ModelPrices.checkedOn, "scan_seconds": stats.seconds]
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out)
        print("usage real day \(day): wrote \(out.path)")
        #expect(FileManager.default.fileExists(atPath: out.path))
    }
}
