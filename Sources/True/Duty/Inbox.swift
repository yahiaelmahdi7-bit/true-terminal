import Foundation

/// An investigation's answer on an item (SPEC Run 15 §3 step 6). Tolerant decode.
struct ItemReport: Codable, Equatable, Sendable {
    struct Evidence: Codable, Equatable, Sendable { var path: String; var lines: String; var quote: String }
    struct Fix: Codable, Equatable, Sendable {
        var summary: String; var steps: [String]; var commands: [String]; var files: [String]
        /// The text the permission gate reads: summary + steps + commands + files.
        var text: String {
            var parts = ["Fix summary: \(summary)."]
            if !steps.isEmpty { parts.append("Steps: " + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ") + ".") }
            if !commands.isEmpty { parts.append("Commands: " + commands.joined(separator: "; ")) }
            if !files.isEmpty { parts.append("Files: " + files.joined(separator: ", ")) }
            return parts.joined(separator: " ")
        }
    }
    var title: String
    var what: String
    var cause: String
    var sure: String
    var evidence: [Evidence]
    var fix: Fix
    var checked: [String]
    var unknowns: [String]

    /// Every free-text field passed through `transform` (the re-redaction before `reported` is written).
    func mapped(_ t: (String) -> String) -> ItemReport {
        ItemReport(title: t(title), what: t(what), cause: t(cause), sure: sure,
                   evidence: evidence.map { .init(path: t($0.path), lines: $0.lines, quote: t($0.quote)) },
                   fix: .init(summary: t(fix.summary), steps: fix.steps.map(t), commands: fix.commands.map(t), files: fix.files.map(t)),
                   checked: checked.map(t), unknowns: unknowns.map(t))
    }
}

enum ItemState: String, Codable, Sendable { case open, approved, rejected, snoozed, resolved }

struct InboxItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var agent: String
    var source: String          // builders | git | abandonedFailures
    var kind: String
    var subject: String
    var repo: String
    var fingerprint: String
    var title: String
    var evidence: String
    var report: ItemReport?
    var level: PermissionLevel?
    var state: ItemState
    var seen: Int
    var at: Double
    var cost: Double
    var note: String?           // "Budget reached at 14:10", "Contains instructions: not sent to the agent"…
    var builderID: String?
    var lookedFixed: Bool
    var snoozeUntil: Double?
    var canInvestigate: Bool
    /// A claude session parked at a cap or the daily budget; the next investigation resumes it. Absent in old logs.
    var resumeSession: String? = nil

    static func fingerprint(source: String, kind: String, subject: String) -> String { "\(source)|\(kind)|\(subject)" }
}

struct InboxEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case created, merged, reported, levelled, approved, rejected, snoozed, lookedFixed, resolved, reopened
    }
    var kind: Kind
    var id: String
    var at: Double
    var item: InboxItem?        // created
    var report: ItemReport?     // reported
    var level: PermissionLevel? // levelled
    var cost: Double?
    var evidence: String?       // merged: refreshed evidence
    var reason: String?         // rejected / resolved
    var until: Double?          // snoozed
    var builder: String?        // approved
    var note: String?
    var resumeSession: String?  // reported: the session to continue next time (nil clears it)

    init(_ kind: Kind, id: String, at: Double, item: InboxItem? = nil, report: ItemReport? = nil, level: PermissionLevel? = nil,
         cost: Double? = nil, evidence: String? = nil, reason: String? = nil, until: Double? = nil, builder: String? = nil,
         note: String? = nil, resumeSession: String? = nil) {
        self.kind = kind; self.id = id; self.at = at; self.item = item; self.report = report; self.level = level
        self.cost = cost; self.evidence = evidence; self.reason = reason; self.until = until; self.builder = builder; self.note = note
        self.resumeSession = resumeSession
    }
}

enum Inbox {
    /// Pure: replay append-only events into the current items, oldest first. Unknown ids are ignored.
    static func fold(_ events: [InboxEvent]) -> [InboxItem] {
        var items: [InboxItem] = []
        func idx(_ id: String) -> Int? { items.firstIndex { $0.id == id } }
        for e in events {
            switch e.kind {
            case .created:
                if var it = e.item, idx(it.id) == nil { it.state = .open; items.append(it) }
            case .merged:
                if let i = idx(e.id) { items[i].seen += 1; if let ev = e.evidence { items[i].evidence = ev }
                    if let n = e.note { items[i].note = n; items[i].canInvestigate = false } }
            case .reported:
                if let i = idx(e.id) {
                    items[i].report = e.report; items[i].cost += e.cost ?? 0
                    if let t = e.report?.title, !t.isEmpty { items[i].title = t }
                    if let n = e.note { items[i].note = n } else { items[i].note = nil }
                    items[i].resumeSession = e.resumeSession
                }
            case .levelled:
                if let i = idx(e.id) { items[i].level = e.level }
            case .approved:
                if let i = idx(e.id) { items[i].state = .approved; items[i].builderID = e.builder; items[i].cost += e.cost ?? 0 }
            case .rejected:
                if let i = idx(e.id) { items[i].state = .rejected; items[i].note = e.reason }
            case .snoozed:
                if let i = idx(e.id) { items[i].state = .snoozed; items[i].snoozeUntil = e.until }
            case .lookedFixed:
                if let i = idx(e.id) { items[i].lookedFixed = true }
            case .resolved:
                if let i = idx(e.id) { items[i].state = .resolved; items[i].lookedFixed = false }
            case .reopened:
                if let i = idx(e.id) { items[i].state = .open; items[i].snoozeUntil = nil; items[i].lookedFixed = false }
            }
        }
        return items
    }

    /// Open (or snoozed past its time) items with this fingerprint.
    static func openItem(_ items: [InboxItem], fingerprint: String, now: Double) -> InboxItem? {
        items.first { $0.fingerprint == fingerprint && ($0.state == .open || $0.state == .approved
                        || ($0.state == .snoozed && ($0.snoozeUntil ?? 0) > now)) }
    }

    /// Items that need the user (open and not snoozed).
    static func needsYou(_ items: [InboxItem], now: Double) -> [InboxItem] {
        items.filter { $0.state == .open || ($0.state == .snoozed && ($0.snoozeUntil ?? 0) <= now) }
    }

    /// Replay with snoozes that ran out reopened (pure, no event needed for display).
    static func wake(_ items: [InboxItem], now: Double) -> [InboxItem] {
        items.map { var i = $0; if i.state == .snoozed, (i.snoozeUntil ?? 0) <= now { i.state = .open }; return i }
    }

    /// Compact: one `created` per item carrying its folded state, so the log stays small.
    static func compact(_ items: [InboxItem], at: Double) -> [InboxEvent] {
        items.map { InboxEvent(.created, id: $0.id, at: at, item: $0) }
    }
}

/// `~/.true/agents/<name>/inbox.jsonl` — append-only, dir 0700, files 0600, compacted over 1 MB.
struct InboxFile {
    let dir: URL
    var url: URL { dir.appendingPathComponent("inbox.jsonl") }
    static let compactBytes = 1024 * 1024

    static func home(agent: String, root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".true/agents")) -> URL {
        root.appendingPathComponent(agent)
    }

    func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func append(_ e: InboxEvent) {
        ensureDir()
        guard var data = try? JSONEncoder().encode(e) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    func events() -> [InboxEvent] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return s.split(separator: "\n").compactMap { try? dec.decode(InboxEvent.self, from: Data($0.utf8)) }
    }

    func items() -> [InboxItem] { Inbox.fold(events()) }

    /// Rewrites the log from the folded state when over `limit` bytes. Returns true when it compacted.
    @discardableResult
    func compactIfNeeded(limit: Int = InboxFile.compactBytes, now: Double = Date().timeIntervalSince1970) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > limit else { return false }
        let lines = Inbox.compact(items(), at: now).compactMap { try? JSONEncoder().encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        try? lines.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}
