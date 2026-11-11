import Foundation

/// The work queue's `next.json` (written by `workq`, read-only here). Decoding is tolerant: unknown fields
/// are ignored and a missing optional field is just absent.
struct WorkItem: Equatable, Identifiable {
    var id: String
    var title: String
    /// Plain-words title when the queue has one; the row shows this, else `title`.
    var plain: String?
    var why: String?
    var waitsOn: [String] = []
    var source: String?

    var headline: String { (plain?.isEmpty == false ? plain : nil) ?? title }
}

/// One open decision for the user. Shown in the needs-you tray, one entry per id.
struct WorkCall: Equatable, Identifiable {
    var id: String
    var title: String
    var what: String?
    var question: String?
}

struct WorkQueueSnapshot: Equatable {
    var writtenAt: Date?
    var top: [WorkItem] = []
    var calls: [WorkCall] = []

    /// Older than this and the file is called stale.
    static let staleAfter: TimeInterval = 15 * 60
    static let rowLimit = 5

    func isStale(now: Date) -> Bool {
        guard let writtenAt else { return true }
        return now.timeIntervalSince(writtenAt) > Self.staleAfter
    }
}

enum WorkQueueLoad: Equatable {
    case missing
    case unreadable
    case snapshot(WorkQueueSnapshot)

    var calls: [WorkCall] { if case .snapshot(let s) = self { return s.calls } else { return [] } }
}

enum WorkQueue {
    /// `WORKQ_HOME` wins; else `<claudeDir>/workq`.
    static func directory(claudeDir: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = env["WORKQ_HOME"], !h.isEmpty { return URL(fileURLWithPath: (h as NSString).expandingTildeInPath) }
        return claudeDir.appendingPathComponent("workq")
    }

    static func load(dir: URL) -> WorkQueueLoad {
        let file = dir.appendingPathComponent("next.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        guard let data = try? Data(contentsOf: file) else { return .unreadable }
        return parse(data)
    }

    static func parse(_ data: Data) -> WorkQueueLoad {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        func str(_ o: [String: Any], _ k: String) -> String? {
            guard let s = o[k] as? String, !s.isEmpty else { return nil }
            return s
        }
        let top: [WorkItem] = ((root["top"] as? [Any]) ?? []).compactMap { raw in
            guard let o = raw as? [String: Any], let id = str(o, "id") ?? str(o, "title") else { return nil }
            return WorkItem(id: id, title: str(o, "title") ?? id, plain: str(o, "plain"), why: str(o, "why"),
                            waitsOn: ((o["waits_on"] as? [Any]) ?? []).compactMap { $0 as? String }, source: str(o, "source"))
        }
        let calls: [WorkCall] = ((root["calls"] as? [Any]) ?? []).compactMap { raw in
            guard let o = raw as? [String: Any], let id = str(o, "id") else { return nil }
            return WorkCall(id: id, title: str(o, "title") ?? id, what: str(o, "what"), question: str(o, "question"))
        }
        return .snapshot(WorkQueueSnapshot(writtenAt: str(root, "written_at").flatMap(date), top: top, calls: calls))
    }

    static func date(_ s: String) -> Date? {
        let a = ISO8601DateFormatter()
        if let d = a.date(from: s) { return d }
        a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return a.date(from: s)
    }

    /// `ledger:` / `true:` / `true-cloud:` + a repo-relative path (an `#anchor` is dropped). Anything else: nil.
    static func sourceURL(_ source: String, home: String = NSHomeDirectory()) -> URL? {
        let roots = ["ledger": "ledger-app", "true": "true", "true-cloud": "true-cloud"]
        guard let colon = source.firstIndex(of: ":") else { return nil }
        let prefix = String(source[..<colon])
        guard let repo = roots[prefix] else { return nil }
        var path = String(source[source.index(after: colon)...])
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        path = path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else { return nil }
        return URL(fileURLWithPath: home).appendingPathComponent("Projects/\(repo)/\(path)")
    }
}

/// What the Next up section draws, decided from the load and the clock (pure).
struct NextUpPresentation: Equatable {
    var notice: String?      // "Work queue not set up" / "No ready work" / unreadable
    var staleLine: String?   // "Stale since 14:05", above the rows
    var rows: [WorkItem]

    static func make(_ load: WorkQueueLoad, now: Date, timeZone: TimeZone = .current) -> NextUpPresentation {
        switch load {
        case .missing: return .init(notice: "Work queue not set up", staleLine: nil, rows: [])
        case .unreadable: return .init(notice: "Work queue unreadable", staleLine: nil, rows: [])
        case .snapshot(let s):
            var stale: String?
            if s.isStale(now: now) {
                if let w = s.writtenAt {
                    let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = timeZone
                    stale = "Stale since \(f.string(from: w))"
                } else { stale = "Stale, no timestamp" }
            }
            let rows = Array(s.top.prefix(WorkQueueSnapshot.rowLimit))
            return .init(notice: rows.isEmpty ? "No ready work" : nil, staleLine: stale, rows: rows)
        }
    }
}
