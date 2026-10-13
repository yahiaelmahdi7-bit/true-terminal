import Foundation
import os

/// `~/.true/commandbar/routes.jsonl` (one line per Jev read and per run: the calibration set for the floors) and
/// `history.json` (the last 50 lines typed, for ↑/↓). Directory 0700, files 0600, text redacted before it is written.
/// Over 5 MB routes.jsonl becomes `routes.1.jsonl` (one old file kept). Plain file IO: call it off the main actor.
struct CommandBarLog: Sendable {
    static let maxBytes = 5 << 20
    static let historyLimit = 50
    static let logger = Logger(subsystem: "io.github.true-terminal.True", category: "commandbar")
    static let standard = CommandBarLog(dir: URL(fileURLWithPath: NSHomeDirectory() + "/.true/commandbar"))

    let dir: URL
    var file: URL { dir.appendingPathComponent("routes.jsonl") }
    var rotated: URL { dir.appendingPathComponent("routes.1.jsonl") }
    var historyFile: URL { dir.appendingPathComponent("history.json") }

    enum Event: String, Sendable { case read, run, cancelled }

    struct Record: Sendable {
        var event: Event
        var at = Date()
        var text: String                 // raw: redacted on the way out
        var reply: JevReply?
        var latencyMs: Int?
        var route: Route?                // the route shown (read) or run (run)
        var door: String?                // run: the plan's door
        var background = false
    }

    /// The os.Logger line: event, kind@confidence, project, target, destructive, ms. No text.
    static func line(_ r: Record) -> String {
        func p(_ d: Double?) -> String { d.map { String(format: "%.2f", $0) } ?? "-" }
        let rt = r.route
        return "event=\(r.event.rawValue) kind=\(rt?.kind.rawValue ?? "-")@\(p(rt?.kindConfidence)) "
            + "project=\(rt?.project?.name ?? "current") target=\(rt?.target.id ?? "-") action=\(rt?.action.rawValue ?? "-") "
            + "destructive=\(p(rt?.destructive)) rule=\(rt?.viaRule == true) ms=\(r.latencyMs ?? -1) door=\(r.door ?? "-")"
    }

    static func json(_ r: Record) -> [String: Any] {
        var answers: [String: Any] = [:]
        for (id, a) in r.reply?.answers ?? [:] {
            var o: [String: Any] = [:]
            if let c = a.choice { o["choice"] = c }
            if let c = a.confidence { o["confidence"] = c }
            if let p = a.probabilities { o["probabilities"] = p }
            if let n = a.noul { o["noul"] = n }
            if let s = a.score { o["score"] = s }
            answers[id] = o
        }
        var route: Any = NSNull()
        if let rt = r.route {
            route = ["kind": rt.kind.rawValue, "project": rt.project?.name ?? NSNull(), "target": rt.target.id,
                     "action": rt.action.rawValue, "destructive": rt.destructive ?? NSNull(),
                     "model": rt.model?.rawValue ?? NSNull(), "effort": rt.effort?.rawValue ?? NSNull(),
                     "uncertain": rt.uncertain.map(\.rawValue).sorted(), "twoChoice": rt.twoChoice,
                     "viaRule": rt.viaRule] as [String: Any]
        }
        return ["event": r.event.rawValue, "at": ISO8601DateFormatter().string(from: r.at),
                "text": Redact.secrets(r.text), "answers": answers, "latencyMs": r.latencyMs ?? NSNull(),
                "route": route, "door": r.door ?? NSNull(), "background": r.background]
    }

    private func prepare() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
    }

    func append(_ r: Record) {
        Self.logger.info("\(Self.line(r), privacy: .public)")
        let fm = FileManager.default
        prepare()
        let obj = Self.json(r)
        guard JSONSerialization.isValidJSONObject(obj),
              var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        data.append(10)
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > Self.maxBytes {
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: file, to: rotated)
        }
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        chmod(file.path, 0o600)
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    // MARK: History

    func loadHistory() -> [String] {
        guard let d = try? Data(contentsOf: historyFile), let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return Array(a.prefix(Self.historyLimit))
    }

    /// Newest first, no adjacent duplicate, redacted, capped at 50.
    static func pushed(_ text: String, onto h: [String]) -> [String] {
        let t = Redact.secrets(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !t.isEmpty else { return h }
        return Array(([t] + h.filter { $0 != t }).prefix(historyLimit))
    }

    func saveHistory(_ h: [String]) {
        prepare()
        guard let d = try? JSONEncoder().encode(h) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: historyFile.path) {
            fm.createFile(atPath: historyFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? d.write(to: historyFile)
        chmod(historyFile.path, 0o600)
    }
}
