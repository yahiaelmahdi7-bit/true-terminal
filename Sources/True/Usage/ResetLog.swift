import Foundation

/// Reset times seen in usage-window readings, kept for the Limits tab. One small file; the app is its only writer.
final class ResetLog: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        var provider: UsageProvider
        var kind: UsageKind
        /// Epoch seconds.
        var at: Double
    }

    static let retention: TimeInterval = 92 * 86_400
    /// Readings of one window wobble by seconds; two resets this close are the same reset.
    static let dedupeWindow: TimeInterval = 10 * 60

    static let shared = ResetLog(url: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".true/usage/resets.json"))

    private let url: URL
    private let lock = NSLock()
    init(url: URL) { self.url = url }

    func entries() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    /// Records every `resetsAt` of the given readings, then writes via temp file and rename.
    func record(_ windows: [UsageWindow], now: Date = Date()) {
        let seen = windows.compactMap { w in w.resetsAt.map { Entry(provider: w.provider, kind: w.kind, at: $0.timeIntervalSince1970) } }
        guard !seen.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let old = load()
        let merged = Self.merged(old, adding: seen, now: now)
        guard merged != old else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(merged) else { return }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".resets-\(UUID().uuidString).tmp")
        do { try data.write(to: tmp); _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) }
        catch { try? FileManager.default.removeItem(at: tmp) }
    }

    /// Pure: older than 92 days dropped, a new entry within 10 minutes of a kept one of the same provider and kind skipped.
    static func merged(_ existing: [Entry], adding new: [Entry], now: Date) -> [Entry] {
        let floor = now.timeIntervalSince1970 - retention
        var out = existing.filter { $0.at >= floor }
        for e in new where e.at >= floor {
            let dup = out.contains { $0.provider == e.provider && $0.kind == e.kind && abs($0.at - e.at) <= dedupeWindow }
            if !dup { out.append(e) }
        }
        return out.sorted { $0.at < $1.at }
    }

    /// Per provider, the times (oldest first) of every recorded reset.
    func seen() -> [UsageProvider: [Date]] {
        Dictionary(grouping: entries(), by: \.provider).mapValues { $0.map { Date(timeIntervalSince1970: $0.at) }.sorted() }
    }

    private func load() -> [Entry] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }
}
