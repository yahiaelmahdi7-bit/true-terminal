import Foundation

/// Token sums for one turn or one bucket. Claude's `input` excludes cache; Codex's input has its cached part
/// moved into `cacheRead`, so the four numbers mean the same thing for both providers.
struct UsageTokens: Codable, Equatable, Sendable {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    var total: Int { input + output + cacheRead + cacheWrite }
    static func += (a: inout UsageTokens, b: UsageTokens) {
        a.input += b.input; a.output += b.output; a.cacheRead += b.cacheRead; a.cacheWrite += b.cacheWrite
    }
}

/// What is kept from one assistant turn: when, which model, how many tokens, and an id for dedupe.
/// Never any prompt or reply text.
struct UsageEntry: Equatable, Sendable {
    var id: String
    var ts: Double
    var model: String
    var tokens: UsageTokens
    /// Part of `tokens.cacheWrite` that went to the 1 hour cache (Claude only); the rest is the 5 minute cache.
    var cacheWrite1h = 0
}

extension UsageEntry: Codable {
    // One compact array per turn, so a cache of a few hundred thousand turns stays small.
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        id = try c.decode(String.self); ts = try c.decode(Double.self); model = try c.decode(String.self)
        tokens = UsageTokens(input: try c.decode(Int.self), output: try c.decode(Int.self),
                             cacheRead: try c.decode(Int.self), cacheWrite: try c.decode(Int.self))
        cacheWrite1h = c.isAtEnd ? 0 : try c.decode(Int.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(id); try c.encode(ts); try c.encode(model)
        try c.encode(tokens.input); try c.encode(tokens.output); try c.encode(tokens.cacheRead); try c.encode(tokens.cacheWrite)
        try c.encode(cacheWrite1h)
    }
}

/// One day, one provider, one model.
struct UsageBucket: Equatable, Sendable {
    var day: String            // "2026-11-09", local calendar day
    var provider: UsageProvider
    var model: String
    var tokens: UsageTokens
    /// nil = unpriced (no row in ModelPrices).
    var dollars: Double?
}

enum UsageFolderState: String, Codable, Sendable { case ok, absent, unreadable }

/// Why a line was left out. Shown to the user as "n lines skipped" so a format change after a CLI update is visible.
enum UsageSkip {
    static let corrupt = "corrupt"            // a line with a usage field that is not valid JSON
    static let missingFields = "missing_fields" // valid JSON, usage present, but no id/model/time
    static let badTime = "bad_time"
    static let unreadableFile = "unreadable_file"
    static let unreadableFolder = "unreadable_folder"
}

struct UsageScanStats: Equatable, Sendable {
    var filesSeen: [UsageProvider: Int] = [:]
    /// Files opened during THIS scan (a rescan with nothing new opens none).
    var filesRead: [UsageProvider: Int] = [:]
    var bytesRead: Int64 = 0
    /// Lines skipped, summed over every file now in the cache, by provider and reason.
    var skipped: [UsageProvider: [String: Int]] = [:]
    var folders: [UsageProvider: UsageFolderState] = [:]
    var seconds: Double = 0
    var peakMemoryBytes: Int64 = 0
}

/// Reads Claude's and Codex's history files, line by line, never whole. Read-only: it opens files for reading
/// and writes only its own cache (`cacheDir`, temp file then rename). Safe to call from one thread at a time.
final class UsageScanner: @unchecked Sendable {
    struct FileState: Codable {
        var provider: UsageProvider
        var inode: UInt64
        var size: Int64
        var mtime: Double
        /// The byte after the last complete line. A half-written last line is read again next time.
        var offset: Int64
        var entries: [UsageEntry] = []
        var skipped: [String: Int] = [:]
        // Codex only: the running total seen last and the model of the latest turn.
        var codexPrev: UsageTokens?
        var codexModel: String?
    }
    struct Cache: Codable { var version = 2; var files: [String: FileState] = [:] }

    let claudeRoot: URL?
    let codexRoot: URL?
    let cacheDir: URL?
    let timeZone: TimeZone
    let retentionDays: Int
    /// When set, replaces the retention cutoff (the real-data harness uses the start of the asked-for day).
    let cutoffOverride: Date?
    let now: @Sendable () -> Date
    let logURL: URL?

    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    private var folderStates: [UsageProvider: UsageFolderState] = [:]
    private var loaded = false
    private var dirty = false

    static let retentionDefault = 92
    static let chunk = 4 * 1024 * 1024

    init(claudeRoot: URL?, codexRoot: URL?, cacheDir: URL?, timeZone: TimeZone = .current,
         retentionDays: Int = UsageScanner.retentionDefault, cutoffOverride: Date? = nil,
         logURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.claudeRoot = claudeRoot; self.codexRoot = codexRoot; self.cacheDir = cacheDir
        self.timeZone = timeZone; self.retentionDays = retentionDays; self.cutoffOverride = cutoffOverride
        self.logURL = logURL; self.now = now
    }

    static func standard(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> UsageScanner {
        UsageScanner(claudeRoot: home.appendingPathComponent(".claude/projects"),
                     codexRoot: home.appendingPathComponent(".codex/sessions"),
                     cacheDir: home.appendingPathComponent(".true/usage"),
                     logURL: home.appendingPathComponent(".true/usage/scan.log"))
    }

    // MARK: scan

    @discardableResult
    func scan() -> UsageScanStats {
        lock.lock(); defer { lock.unlock() }
        let t0 = Date()
        loadCacheIfNeeded()
        var stats = UsageScanStats()
        let cutoff = cutoffOverride ?? now().addingTimeInterval(-Double(retentionDays) * 86_400)
        var seen = Set<String>()
        for (provider, root) in [(UsageProvider.claude, claudeRoot), (.codex, codexRoot)] {
            guard let root else { continue }
            scanProvider(provider, root: root, cutoff: cutoff, seen: &seen, stats: &stats)
        }
        // A file that vanished (or aged out of retention) takes its entries with it.
        for key in files.keys where !seen.contains(key) {
            // A provider whose folder could not be listed keeps what it had: unknown is not gone.
            if let p = files[key]?.provider, folderStates[p] == .unreadable { continue }
            files[key] = nil; dirty = true
        }
        // Entries past retention are dropped as they age.
        let cutTs = cutoff.timeIntervalSince1970
        for key in files.keys where files[key]!.entries.contains(where: { $0.ts < cutTs }) {
            files[key]!.entries.removeAll { $0.ts < cutTs }; dirty = true
        }
        for (_, f) in files {
            for (reason, n) in f.skipped { stats.skipped[f.provider, default: [:]][reason, default: 0] += n }
        }
        stats.folders = folderStates
        saveCache()
        stats.seconds = Date().timeIntervalSince(t0)
        stats.peakMemoryBytes = Self.peakMemory()
        writeLog(start: t0, stats)
        return stats
    }

    private func scanProvider(_ p: UsageProvider, root: URL, cutoff: Date, seen: inout Set<String>, stats: inout UsageScanStats) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            folderStates[p] = .absent; return
        }
        guard (try? fm.contentsOfDirectory(atPath: root.path)) != nil else {
            folderStates[p] = .unreadable
            bump(&stats, p, UsageSkip.unreadableFolder); return
        }
        folderStates[p] = .ok
        var unreadableDirs = 0
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [],
                                     errorHandler: { _, _ in unreadableDirs += 1; return true }) else { return }
        let cutTs = cutoff.timeIntervalSince1970
        for case let url as URL in en where url.pathExtension == "jsonl" {
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            if mtime < cutTs { continue }   // cannot hold a turn newer than the cutoff
            let key = Self.fileKey(p, url.path)
            seen.insert(key)
            stats.filesSeen[p, default: 0] += 1
            let inode = UInt64(st.st_ino), size = Int64(st.st_size)
            var state = files[key]
            if let s = state {
                let replaced = s.inode != inode || size < s.size || (size == s.size && mtime != s.mtime)
                if replaced { state = nil; files[key] = nil; dirty = true }
                else if size == s.size { continue }      // nothing new
            }
            var fresh = state ?? FileState(provider: p, inode: inode, size: size, mtime: mtime, offset: 0)
            do {
                stats.filesRead[p, default: 0] += 1
                try read(url, to: size, state: &fresh, stats: &stats)
                fresh.size = size; fresh.mtime = mtime; fresh.inode = inode
                files[key] = fresh; dirty = true
            } catch {
                // Unreadable: skipped and counted; whatever it had before is gone with it.
                files[key] = nil; dirty = true
                stats.filesRead[p, default: 0] -= 1
                bump(&stats, p, UsageSkip.unreadableFile)
            }
        }
        if unreadableDirs > 0 { bump(&stats, p, UsageSkip.unreadableFolder, unreadableDirs) }
    }

    private func bump(_ stats: inout UsageScanStats, _ p: UsageProvider, _ reason: String, _ n: Int = 1) {
        stats.skipped[p, default: [:]][reason, default: 0] += n
    }

    static func fileKey(_ p: UsageProvider, _ path: String) -> String {
        // FNV-1a over the path: the cache can find a file again without storing any folder name.
        var h: UInt64 = 0xcbf29ce484222325
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return p.rawValue + String(h, radix: 16)
    }

    // MARK: reading

    private struct ClaudeLine: Decodable {
        struct Msg: Decodable {
            struct U: Decodable { let input_tokens: Int?; let cache_creation_input_tokens: Int?
                                  let cache_read_input_tokens: Int?; let output_tokens: Int?
                                  struct CC: Decodable { let ephemeral_1h_input_tokens: Int? }
                                  let cache_creation: CC? }
            let id: String?; let model: String?; let usage: U?
        }
        let timestamp: String?
        let message: Msg?
        enum K: String, CodingKey { case timestamp, message }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            timestamp = try? c.decode(String.self, forKey: .timestamp)
            message = try? c.decode(Msg.self, forKey: .message)   // a string-valued message is just "not a turn"
        }
    }
    private struct CodexLine: Decodable {
        struct Raw: Decodable { let input_tokens: Int?; let cached_input_tokens: Int?
                                let cache_write_input_tokens: Int?; let output_tokens: Int? }
        struct Info: Decodable { let total_token_usage: Raw? }
        struct Payload: Decodable { let type: String?; let model: String?; let info: Info? }
        let timestamp: String?; let type: String?; let payload: Payload?
        enum K: String, CodingKey { case timestamp, type, payload }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            timestamp = try? c.decode(String.self, forKey: .timestamp)
            type = try? c.decode(String.self, forKey: .type)
            payload = try? c.decode(Payload.self, forKey: .payload)
        }
    }

    private static let usageMarker = Array("\"usage\"".utf8)
    private static let codexMarkers = [Array("\"total_token_usage\"".utf8), Array("\"turn_context\"".utf8)]

    private func read(_ url: URL, to size: Int64, state: inout FileState, stats: inout UsageScanStats) throws {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func parseTime(_ s: String?) -> Double? {
            guard let s, let d = iso.date(from: s) ?? plain.date(from: s) else { return nil }
            return d.timeIntervalSince1970
        }
        var byID: [String: Int] = [:]
        if state.provider == .claude { for (i, e) in state.entries.enumerated() { byID[e.id] = i } }
        let decoder = JSONDecoder()
        var pos = state.offset
        try h.seek(toOffset: UInt64(pos))
        var carry = Data()
        while pos < size {
            // Each chunk is released before the next: without the pool a 2 GB scan would hold 2 GB of dead buffers.
            let more: Bool = try autoreleasepool {
                let want = Int(min(Int64(Self.chunk), size - pos))
                guard let d = try h.read(upToCount: want), !d.isEmpty else { return false }
                pos += Int64(d.count); stats.bytesRead += Int64(d.count)
                let buf = carry.isEmpty ? d : carry + d
                var consumed = 0
                buf.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    let n = raw.count
                    var start = 0
                    while start < n, let nl = memchr(base + start, 10, n - start) {
                        let end = base.distance(to: UnsafeRawPointer(nl))
                        let line = UnsafeRawBufferPointer(start: base + start, count: end - start)
                        handle(line, &state, &byID, decoder, parseTime)
                        start = end + 1
                    }
                    consumed = start
                }
                carry = consumed >= buf.count ? Data() : buf.subdata(in: consumed..<buf.count)
                return true
            }
            if !more { break }
        }
        state.offset = pos - Int64(carry.count)
    }

    private func has(_ line: UnsafeRawBufferPointer, _ marker: [UInt8]) -> Bool {
        guard let b = line.baseAddress, line.count >= marker.count else { return false }
        return marker.withUnsafeBytes { memmem(b, line.count, $0.baseAddress!, marker.count) != nil }
    }

    private func handle(_ line: UnsafeRawBufferPointer, _ state: inout FileState, _ byID: inout [String: Int],
                        _ decoder: JSONDecoder, _ parseTime: (String?) -> Double?) {
        func skip(_ why: String) { state.skipped[why, default: 0] += 1 }
        switch state.provider {
        case .claude:
            // The cheap text check: most lines (tool output, prompts) never get decoded.
            guard has(line, Self.usageMarker) else { return }
            guard let l = try? decoder.decode(ClaudeLine.self, from: Data(line)) else { return skip(UsageSkip.corrupt) }
            guard let m = l.message, let u = m.usage else { return }   // the word "usage" in ordinary text
            guard let id = m.id, let model = m.model else { return skip(UsageSkip.missingFields) }
            guard let ts = parseTime(l.timestamp) else { return skip(UsageSkip.badTime) }
            let e = UsageEntry(id: id, ts: ts, model: model,
                               tokens: UsageTokens(input: u.input_tokens ?? 0, output: u.output_tokens ?? 0,
                                                   cacheRead: u.cache_read_input_tokens ?? 0,
                                                   cacheWrite: u.cache_creation_input_tokens ?? 0),
                               cacheWrite1h: u.cache_creation?.ephemeral_1h_input_tokens ?? 0)
            // One message streams as several lines sharing an id: the last one wins.
            if let i = byID[id] { state.entries[i] = e } else { byID[id] = state.entries.count; state.entries.append(e) }
        case .codex:
            guard Self.codexMarkers.contains(where: { has(line, $0) }) else { return }
            guard let l = try? decoder.decode(CodexLine.self, from: Data(line)) else { return skip(UsageSkip.corrupt) }
            if l.type == "turn_context" { if let m = l.payload?.model { state.codexModel = m }; return }
            guard l.type == "event_msg", l.payload?.type == "token_count", let raw = l.payload?.info?.total_token_usage else { return }
            guard let ts = parseTime(l.timestamp) else { return skip(UsageSkip.badTime) }
            let cached = raw.cached_input_tokens ?? 0
            let total = UsageTokens(input: max(0, (raw.input_tokens ?? 0) - cached), output: raw.output_tokens ?? 0,
                                    cacheRead: cached, cacheWrite: raw.cache_write_input_tokens ?? 0)
            // `total_token_usage` is a running total, repeated by every event: the turn is the step up from the last one.
            var delta = total
            if let p = state.codexPrev {
                let d = UsageTokens(input: total.input - p.input, output: total.output - p.output,
                                    cacheRead: total.cacheRead - p.cacheRead, cacheWrite: total.cacheWrite - p.cacheWrite)
                let anyNegative = d.input < 0 || d.output < 0 || d.cacheRead < 0 || d.cacheWrite < 0
                delta = anyNegative ? total : d      // a counter that went down restarted
            }
            state.codexPrev = total
            if delta.total == 0 { return }
            // No file name in the id: a resumed copy of the same rollout replays the same events and counts once.
            let id = "cx|\(ts)|\(total.input)|\(total.cacheRead)|\(total.output)"
            state.entries.append(UsageEntry(id: id, ts: ts, model: state.codexModel ?? "unknown", tokens: delta))
        }
    }

    // MARK: results

    /// Every turn once: the same id in two files (resume, sub-agent copy) counts once, keeping the fuller copy.
    func uniqueEntries() -> [(provider: UsageProvider, entry: UsageEntry)] {
        lock.lock(); defer { lock.unlock() }
        var best: [String: (UsageProvider, UsageEntry)] = [:]
        for key in files.keys.sorted() {
            let f = files[key]!
            for e in f.entries {
                let k = f.provider.rawValue + "|" + e.id
                if let old = best[k], old.1.tokens.output >= e.tokens.output { continue }
                best[k] = (f.provider, e)
            }
        }
        return best.values.map { ($0.0, $0.1) }
    }

    /// Buckets per local day, provider and model, sorted by day.
    func buckets() -> [UsageBucket] {
        var keyer = DayKeyer(timeZone: timeZone)
        var acc: [String: UsageBucket] = [:]
        for (p, e) in uniqueEntries() {
            let day = keyer.day(for: e.ts)
            let k = "\(day)|\(p.rawValue)|\(e.model)"
            if acc[k] == nil { acc[k] = UsageBucket(day: day, provider: p, model: e.model, tokens: UsageTokens(), dollars: nil) }
            acc[k]!.tokens += e.tokens
            // Dollars per request, then summed: tiers and the 5m/1h write split only exist per request.
            // Unpriced models stay nil for the whole bucket.
            if let d = ModelPrices.dollars(model: e.model, tokens: e.tokens, cacheWrite1h: e.cacheWrite1h) {
                acc[k]!.dollars = (acc[k]!.dollars ?? 0) + d
            }
        }
        return acc.values.sorted { ($0.day, $0.provider.rawValue, $0.model) < ($1.day, $1.provider.rawValue, $1.model) }
    }

    // MARK: cache

    private var cacheFile: URL? { cacheDir?.appendingPathComponent("cache.json") }

    private func loadCacheIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let f = cacheFile, let data = try? Data(contentsOf: f),
              let c = try? JSONDecoder().decode(Cache.self, from: data), c.version == 2 else { return }
        files = c.files
    }

    private func saveCache() {
        guard dirty, let dir = cacheDir, let f = cacheFile else { return }
        dirty = false
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Cache(files: files))
            let tmp = dir.appendingPathComponent("cache.json.tmp")
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(f, withItemAt: tmp)
        } catch { /* the cache is a speed-up; the next scan re-reads */ }
    }

    private func writeLog(start: Date, _ s: UsageScanStats) {
        guard let url = logURL else { return }
        let f = ISO8601DateFormatter()
        let line = "\(f.string(from: start)) -> \(f.string(from: Date())) bytes=\(s.bytesRead) "
            + "files_read=\(s.filesRead.values.reduce(0, +)) peak_mb=\(s.peakMemoryBytes / 1_048_576)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close()
        } else { try? Data(line.utf8).write(to: url) }
    }

    static func peakMemory() -> Int64 {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        return Int64(r.ru_maxrss)   // bytes on macOS
    }
}

/// Local calendar day for a timestamp, DST-correct: the day is the calendar's own day interval, so a spring-forward
/// day is 23 hours long and a turn just before midnight stays on its day.
struct DayKeyer {
    private var calendar: Calendar
    private var lo = 0.0, hi = 0.0
    private var cached = ""

    init(timeZone: TimeZone) {
        var c = Calendar(identifier: .gregorian); c.timeZone = timeZone
        calendar = c
    }

    mutating func day(for ts: Double) -> String {
        if ts >= lo && ts < hi { return cached }
        let date = Date(timeIntervalSince1970: ts)
        let iv = calendar.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 86_400)
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        cached = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        lo = iv.start.timeIntervalSince1970; hi = iv.end.timeIntervalSince1970
        return cached
    }
}
