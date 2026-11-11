import Foundation

/// G4+ — the words for `true-peer doctor` and `true-peer mesh`. Pure functions: the engine hands in facts, this prints
/// plain lines. Copy talks about people and their Macs, never routes or ids.

/// Which True this is: a short commit and its date. Written into Info.plist by `scripts/package.sh`; a `swift run` build has none.
struct TrueBuild: Equatable, Sendable {
    var commit: String
    var date: String
    static var current: TrueBuild? {
        let d = Bundle.main.infoDictionary
        guard let c = d?["TrueCommit"] as? String, !c.isEmpty, let t = d?["TrueBuildDate"] as? String, !t.isEmpty else { return nil }
        return TrueBuild(commit: c, date: t)
    }
    var words: String { "\(commit), \(date)" }
}

/// One drop from drops.log: `<unix seconds> dropped: <reason>`.
struct PeerDrop: Equatable {
    var at: Date
    var reason: String
    var isUnknownKind: Bool { reason.hasPrefix("unknown kind") }
    static func parse(_ line: String) -> PeerDrop? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let t = TimeInterval(parts[0]), parts[1] == "dropped:" else { return nil }
        return PeerDrop(at: Date(timeIntervalSince1970: t), reason: String(parts[2]))
    }
}

struct PeerDoctorPeer: Equatable {
    var label: String
    var paired: Bool
    var lastHeard: Date?
    var outbox: Int
    var buildCommit: String?
    var buildDate: String?
    var sentCard: Bool
    var linkAge: TimeInterval
}

enum PeerDoctor {
    static func ago(_ d: Date?, now: Date) -> String {
        guard let d else { return "never" }
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }

    /// The doctor's lines. `drops` is the whole log, oldest first.
    static func lines(ownBuild: TrueBuild?, relayUp: Bool, lastFetch: Date?, peers: [PeerDoctorPeer], drops: [PeerDrop], now: Date) -> [String] {
        var out: [String] = []
        let me = ownBuild.map { "This Mac's True: \($0.words)." } ?? "This Mac's True: a development build."
        out.append("\(me) \(relayUp ? "Connected" : "Not connected") to the relay, last fetch \(ago(lastFetch, now: now)).")
        if peers.isEmpty { out.append("Nobody is paired with this Mac yet. Run: true-peer invite") }
        for p in peers {
            if !p.paired {
                out.append("\(p.label): waiting for the other side. They haven't joined with the code yet (sent \(ago(now.addingTimeInterval(-p.linkAge), now: now))). Waiting to send: \(p.outbox).")
                continue
            }
            var line = "\(p.label): paired. "
            if let c = p.buildCommit, let d = p.buildDate { line += "Their True: \(c), \(d). " }
            else if p.sentCard { line += "Their True doesn't say which build it is. " }
            else { line += "Their True hasn't sent a status card. " }
            line += "Last heard from them \(ago(p.lastHeard, now: now)). Waiting to send: \(p.outbox)."
            out.append(line)
            if !p.sentCard && p.linkAge > 600 {
                out.append("  \(p.label) may be running a True from before 27 Oct, which drops our status cards. Ask them to install the latest kit.")
            }
        }
        let unknown = drops.filter { $0.isUnknownKind }
        if drops.isEmpty {
            out.append("Nothing dropped on this Mac.")
        } else {
            out.append("Last \(min(5, drops.count)) things this Mac dropped (of \(drops.count)):")
            let df = DateFormatter(); df.dateFormat = "d MMM HH:mm"
            for d in drops.suffix(5).reversed() { out.append("  \(df.string(from: d.at))  \(d.reason)") }
        }
        if !unknown.isEmpty {
            out.append("Dropped for an unknown kind of message: \(unknown.count).")
            let older = peers.filter { p in
                guard let theirs = p.buildDate else { return false }
                return ownBuild.map { theirs > $0.date } ?? true
            }
            for p in older { out.append("This Mac's True is older than \(p.label)'s. Install the latest kit.") }
            if older.isEmpty { out.append("This Mac's True may be older than a peer's. Install the latest kit.") }
        }
        return out
    }
}

/// One `true-peer mesh` run, kept by the Mac that started it (and a quieter "leaf" copy on each Mac that is asked).
struct MeshRun {
    struct Node: Equatable { var mailbox: String; var label: String }
    struct Reply { var ms: Double; var name: String; var build: String; var peers: [(mailbox: String, label: String, paired: Bool)] }
    var id: String
    var reportTo: String?                               // set on a leaf run: send the times here when done
    var sentAt: [String: Double] = [:]                  // mailbox → monotonic ms
    var replies: [String: Reply] = [:]                  // direct answers to our own ask
    var times: [String: [String: Double?]] = [:]        // peer mailbox → (their peer mailbox → ms; nil = no answer)
    var started: Double
    var reported = false
}

enum MeshGrid {
    static func cell(_ ms: Double?) -> String { ms.map { $0 < 10 ? String(format: "%.1f ms", $0) : String(format: "%.0f ms", $0) } ?? "no answer" }

    /// `nodes[0]` is this Mac. `ms[row][col]` is how long `row` took to ask `col` and hear back. Pairs that aren't paired show "–".
    static func render(nodes: [MeshRun.Node], ms: [String: [String: Double?]], paired: Set<String>, ownMailbox: String) -> [String] {
        func key(_ a: String, _ b: String) -> String { a < b ? "\(a)|\(b)" : "\(b)|\(a)" }
        let w = max(12, (nodes.map { $0.label.count + 13 }.max() ?? 0))
        func pad(_ s: String) -> String { s + String(repeating: " ", count: max(0, w - s.count)) }
        var out = [pad("") + nodes.map { pad($0.label) }.joined()]
        for r in nodes {
            var row = pad(r.mailbox == ownMailbox ? "\(r.label) (this Mac)" : r.label)
            for c in nodes {
                if r.mailbox == c.mailbox { row += pad("–"); continue }
                if !paired.contains(key(r.mailbox, c.mailbox)) { row += pad("not paired"); continue }
                if let v = ms[r.mailbox]?[c.mailbox] { row += pad(cell(v)) } else { row += pad("no answer") }
            }
            out.append(row.trimmingCharacters(in: .whitespaces))
        }
        return out
    }
}
