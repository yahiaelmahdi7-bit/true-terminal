import Foundation
import Observation

enum UsageProvider: String, Codable, CaseIterable { case claude, codex }
enum UsageKind: String, Codable { case fiveHour, weekly }
/// fresh = read in the last 30 minutes. old = older read, window not over. pastReset = the window has since
/// reset, so the old percent is no longer true. none = never read.
enum UsageFreshness: String, Codable { case fresh, old, pastReset, none }

struct UsageWindow: Codable, Equatable {
    var provider: UsageProvider
    var kind: UsageKind
    /// 0 to 100; nil when never read, or dropped because the window reset.
    var usedPercent: Double?
    var resetsAt: Date?
    var windowMins: Int?
    var readAt: Date?
    var state: UsageFreshness

    static let freshFor: TimeInterval = 30 * 60

    /// Recompute the state against the clock. A past reset drops the percent; the reset time stays for the text.
    func classified(now: Date) -> UsageWindow {
        var w = self
        guard let read = readAt, usedPercent != nil || resetsAt != nil else {
            w.state = .none; w.usedPercent = nil; return w
        }
        if let r = resetsAt, r <= now { w.state = .pastReset; w.usedPercent = nil }
        else if now.timeIntervalSince(read) < Self.freshFor { w.state = .fresh }
        else { w.state = .old }
        return w
    }

    static func empty(_ p: UsageProvider, _ k: UsageKind) -> UsageWindow {
        UsageWindow(provider: p, kind: k, usedPercent: nil, resetsAt: nil, windowMins: nil, readAt: nil, state: .none)
    }
}

/// Pure readers for the two sources. No network: Claude comes from `allowance_reader.py read`, Codex from rollout tails.
enum UsageParsing {
    /// `allowance_reader.py read` output: `windows.five` / `windows.seven` = {util 0-1, resets_at, seen_at}.
    static func claude(_ json: Data, now: Date) -> [UsageWindow] {
        guard let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let wins = obj["windows"] as? [String: Any] else { return [] }
        func one(_ key: String, _ kind: UsageKind, mins: Int) -> UsageWindow {
            guard let w = wins[key] as? [String: Any], let util = w["util"] as? Double else { return .empty(.claude, kind) }
            let reset = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let seen = (w["seen_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return UsageWindow(provider: .claude, kind: kind, usedPercent: min(100, max(0, util * 100)), resetsAt: reset,
                               windowMins: mins, readAt: seen, state: .none).classified(now: now)
        }
        return [one("five", .fiveHour, mins: 300), one("seven", .weekly, mins: 10080)]
    }

    /// The last `token_count` event of a rollout tail that has a primary or secondary window (null ones are skipped).
    static func codex(tail text: String, now: Date) -> [UsageWindow]? {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for line in text.split(separator: "\n").reversed() where line.contains("token_count") {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let p = o["payload"] as? [String: Any], p["type"] as? String == "token_count",
                  let rl = p["rate_limits"] as? [String: Any] else { continue }
            let stamp = (o["timestamp"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
            func one(_ key: String, _ kind: UsageKind) -> UsageWindow? {
                guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { return nil }
                return UsageWindow(provider: .codex, kind: kind, usedPercent: min(100, max(0, used)),
                                   resetsAt: (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
                                   windowMins: w["window_minutes"] as? Int, readAt: stamp, state: .none).classified(now: now)
            }
            let five = one("primary", .fiveHour), week = one("secondary", .weekly)
            if five == nil && week == nil { continue }
            return [five ?? .empty(.codex, .fiveHour), week ?? .empty(.codex, .weekly)]
        }
        return nil
    }

    /// Newest rollouts under `sessions` first (paths sort by date), at most `days` back, newest reading wins.
    static func codexLatest(sessions: URL, now: Date, days: Int = 7, maxFiles: Int = 40) -> [UsageWindow]? {
        codexLatestWithSource(sessions: sessions, now: now, days: days, maxFiles: maxFiles)?.windows
    }

    /// Same read, plus the rollout file the reading came from (the live harness reports it).
    static func codexLatestWithSource(sessions: URL, now: Date, days: Int = 7, maxFiles: Int = 40) -> (windows: [UsageWindow], file: URL)? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var files: [(URL, Date)] = []
        for case let u as URL in en where u.pathExtension == "jsonl" {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(m) <= Double(days) * 86_400 { files.append((u, m)) }
        }
        for (u, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(maxFiles) {
            guard let h = try? FileHandle(forReadingFrom: u) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
            if let r = codex(tail: text, now: now) { return (r, u) }
        }
        return nil
    }
}

/// Words for a window row. Plain and short.
enum UsageText {
    static func resets(_ w: UsageWindow, calendar: Calendar = .current) -> String? {
        guard let r = w.resetsAt else { return nil }
        return clock(r, timeOnly: w.kind == .fiveHour, calendar: calendar)
    }

    /// True's one clock for usage times, in the Mac's own 12 h / 24 h setting: "2:20 PM" or "14:20" today,
    /// "Mon 2:20 PM" or "Mon 14:20" on another day. Used by every reset, limit and read line.
    static func clock(_ r: Date, timeOnly: Bool = false, now: Date = Date(), calendar: Calendar = .current,
                      locale: Locale = .autoupdatingCurrent) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = locale
        f.setLocalizedDateFormatFromTemplate(timeOnly || calendar.isDate(r, inSameDayAs: now) ? "jmm" : "EEEjmm")
        return f.string(from: r)
    }

    /// "resets 14:20" for a live window.
    static func line(_ w: UsageWindow) -> String {
        guard let r = resets(w) else { return "" }
        return w.state == .pastReset ? "Reset at \(r) · not read since" : "resets \(r)"
    }

    /// One short line, never long enough to wrap: "resets 14:00", or "reset 14:00" once the window is over.
    static func resetShort(_ w: UsageWindow) -> String? {
        guard let r = resets(w) else { return nil }
        return w.state == .pastReset ? "reset \(r)" : "resets \(r)"
    }

    /// "Read 12:00" (with the weekday when it was not today).
    static func readStamp(_ at: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        "Read " + clock(at, now: now, calendar: calendar)
    }

    static func freshness(_ w: UsageWindow) -> String? {
        switch w.state {
        case .fresh: return nil
        case .old:
            guard let at = w.readAt else { return nil }
            return "Read at \(clock(at))"
        case .pastReset: return line(w)
        case .none: return "No reading yet"
        }
    }
}

/// Live store. Reads only on refresh; "Check now" is the one place a probe may run, and only on a click.
@MainActor @Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var windows: [UsageWindow] = []
    private(set) var codexInstalled = true
    private(set) var checking = false
    var showsUsageAlert: Bool { windows.contains { ($0.usedPercent ?? 0) >= 80 } }

    @ObservationIgnored var resetLog = ResetLog.shared
    @ObservationIgnored var codexSessions = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    @ObservationIgnored var scriptPath = AllowanceReader.scriptPath(.standard)
    @ObservationIgnored var codexResolver: () -> Bool = { ProgramFinder.shared.resolve("codex") != nil }
    /// Runs `python3 <script> <verb>`; returns stdout. Injected in tests.
    @ObservationIgnored var runner: @Sendable (String, String) -> Data? = { script, verb in UsageStore.run(script, verb) }

    var providers: [UsageProvider] { codexInstalled ? [.claude, .codex] : [.claude] }
    func window(_ p: UsageProvider, _ k: UsageKind) -> UsageWindow {
        windows.first { $0.provider == p && $0.kind == k } ?? .empty(p, k)
    }

    func refresh(now: Date = Date()) {
        codexInstalled = codexResolver()
        let script = scriptPath, sessions = codexSessions, run = runner, wantCodex = codexInstalled
        Task.detached {
            let claude = run(script, "read").map { UsageParsing.claude($0, now: now) } ?? []
            let codex = wantCodex ? UsageParsing.codexLatest(sessions: sessions, now: now) : nil
            await MainActor.run { UsageStore.shared.apply(claude: claude, codex: codex, now: now) }
        }
    }

    /// Keep-last-good: a failed or empty read never replaces a better old one; old ones are re-aged against the clock.
    func apply(claude: [UsageWindow], codex: [UsageWindow]?, now: Date) {
        var out: [UsageWindow] = []
        for (p, fresh) in [(UsageProvider.claude, claude), (.codex, codex ?? [])] {
            for k in [UsageKind.fiveHour, .weekly] {
                let old = windows.first { $0.provider == p && $0.kind == k }
                let new = fresh.first { $0.kind == k && $0.state != .none }
                if let new { out.append(new) }
                else if let old, old.readAt != nil { out.append(old.classified(now: now)) }
                else { out.append(.empty(p, k)) }
            }
        }
        windows = out
        UsageSharing.publish(out)
        let readings = claude + (codex ?? [])
        let log = resetLog
        Task.detached(priority: .utility) { log.record(readings, now: now) }
    }

    /// The one probe. Only ever called from the "Check now" button.
    func checkNow() {
        guard !checking else { return }
        checking = true
        let script = scriptPath, run = runner
        Task.detached {
            _ = run(script, "probe")
            await MainActor.run { UsageStore.shared.checking = false; UsageStore.shared.refresh() }
        }
    }

    nonisolated static func run(_ script: String, _ verb: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script, verb]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}
