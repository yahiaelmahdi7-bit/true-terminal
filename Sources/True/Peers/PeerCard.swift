import Foundation

/// T3 Group G1: the optional Card fields `folders` and `agents`, how they are cleaned on the way out and on the way in.
/// Pure rules, no I/O. The only egress for any of it is `PeerEngine.sealAndQueue` (sealed, to one paired Mac).

/// One teammate-visible agent line. Plain words only: no question text, full command, path or id.
struct AgentShare: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case seat, builder, mission }
    enum Status: String, Codable, Sendable { case working, waiting, needsYou, done }
    /// `PeerRepo.hash(url)` of the shared repo this agent works in.
    var repo: String
    var name: String
    var kind: Kind
    var status: Status
    /// The already-cleaned phrase ("Editing PeerEngine.swift"). Empty for a needs-you row.
    var activity: String
    var provider: String
    var model: String
}

/// What a Mac publishes about its own plan use, in the Card every paired peer already gets. Percent only (0-100, nil =
/// unreadable); no prompts, no tokens. `readAt` = epoch seconds of the newest window read included here.
struct UsageShare: Codable, Equatable, Sendable {
    var claudeWeekly: Double?
    var claudeFiveH: Double?
    var codexWeekly: Double?
    var codexFiveH: Double?
    var readAt: Double
    /// The weekly figure a Team line shows: Claude's, else Codex's.
    var weekly: Double? { claudeWeekly ?? codexWeekly }
    /// A weekly reading older than this is unknown (builder's weekly staleness).
    static let staleAfter: TimeInterval = 6 * 3600
    func isStale(at now: Date) -> Bool { now.timeIntervalSince1970 - readAt > Self.staleAfter }
}

enum CardLimits {
    static let maxDirs = 20, maxAgents = 20, maxFolderRepos = 30, maxFolderPaths = 3
    static let maxName = 60, maxActivity = 80, maxProviderModel = 40, maxPath = 200
    /// LAN frames over 8 KB are dropped (`PeerLanTransport`); the sender keeps a Card under half of that.
    static let budget = 4096

    static func clean(_ s: String, _ limit: Int) -> String {
        let t = String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return String(t.prefix(limit))
    }
    static func isHash(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { $0.isHexDigit } }

    /// A path under home goes `~`-relative; any other path goes as its last component only.
    static func wirePath(_ path: String, home: String) -> String {
        let p = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if !home.isEmpty, p == home { return "~" }
        if !home.isEmpty, p.hasPrefix(home + "/") { return clean("~" + p.dropFirst(home.count), maxPath) }
        return clean((p as NSString).lastPathComponent, maxPath)
    }

    /// Build one sendable row from a Wedge 1 activity row. Needs-you loses its question text; failed shows as done.
    static func share(from row: ActivityRow, repoHash: String) -> AgentShare? {
        guard isHash(repoHash) else { return nil }
        let kind = AgentShare.Kind(rawValue: row.kind.rawValue) ?? .seat
        let status: AgentShare.Status
        switch row.status {
        case "working": status = .working
        case "waiting": status = .waiting
        case "needs-you": status = .needsYou
        default: status = .done
        }
        return AgentShare(repo: repoHash, name: clean(row.name, maxName), kind: kind, status: status,
                          activity: status == .needsYou ? "" : clean(row.activity, maxActivity),
                          provider: clean(row.provider, maxProviderModel), model: clean(row.model, maxProviderModel))
    }

    // MARK: receive (trusts nothing; over a limit = truncate or drop the row, never reject the Card)

    static func parseFolders(_ any: Any?) -> [String: [String]] {
        guard let d = any as? [String: Any] else { return [:] }
        var out: [String: [String]] = [:]
        for (k, v) in d.sorted(by: { $0.key < $1.key }) where isHash(k) {
            guard out.count < maxFolderRepos, let ps = v as? [String] else { continue }
            let paths = ps.prefix(maxFolderPaths).map { clean($0, maxPath) }.filter { !$0.isEmpty }
            if !paths.isEmpty { out[k] = paths }
        }
        return out
    }

    static func parseAgents(_ any: Any?) -> [AgentShare] {
        guard let rows = any as? [[String: Any]] else { return [] }
        var out: [AgentShare] = []
        for r in rows.prefix(maxAgents) {
            guard let repo = r["repo"] as? String, isHash(repo),
                  let k = (r["kind"] as? String).flatMap(AgentShare.Kind.init(rawValue:)),
                  let s = (r["status"] as? String).flatMap(AgentShare.Status.init(rawValue:)) else { continue }
            out.append(AgentShare(repo: repo, name: clean(r["name"] as? String ?? "", maxName), kind: k, status: s,
                                  activity: clean(r["activity"] as? String ?? "", maxActivity),
                                  provider: clean(r["provider"] as? String ?? "", maxProviderModel),
                                  model: clean(r["model"] as? String ?? "", maxProviderModel)))
        }
        return out
    }

    static func parseUsage(_ any: Any?) -> UsageShare? {
        guard let d = any as? [String: Any], let r = (d["readAt"] as? NSNumber)?.doubleValue, r.isFinite, r > 0 else { return nil }
        func pct(_ k: String) -> Double? { (d[k] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? min(100, max(0, $0)) : nil } }
        let u = UsageShare(claudeWeekly: pct("claudeWeekly"), claudeFiveH: pct("claudeFiveH"), codexWeekly: pct("codexWeekly"), codexFiveH: pct("codexFiveH"), readAt: r)
        return u.weekly == nil && u.claudeFiveH == nil && u.codexFiveH == nil ? nil : u
    }

    static func wire(_ u: UsageShare) -> [String: Any] {
        var o: [String: Any] = ["readAt": u.readAt]
        if let v = u.claudeWeekly { o["claudeWeekly"] = v }
        if let v = u.claudeFiveH { o["claudeFiveH"] = v }
        if let v = u.codexWeekly { o["codexWeekly"] = v }
        if let v = u.codexFiveH { o["codexFiveH"] = v }
        return o
    }

    // MARK: send

    static func wire(_ a: AgentShare) -> [String: Any] {
        ["repo": a.repo, "name": a.name, "kind": a.kind.rawValue, "status": a.status.rawValue,
         "activity": a.activity, "provider": a.provider, "model": a.model]
    }

    /// Add `folders` / `agents` to `card` (already holding the base fields) and keep it under the budget:
    /// drop `agents` rows from the end first (needs-you rows last), then extra `folders` paths, then whole repos.
    static func fit(_ card: [String: Any], folders: [String: [String]], agents: [AgentShare], dirs: [String] = [], usage: UsageShare? = nil) -> [String: Any] {
        var f = folders, a = agents, d = dirs
        if a.count > maxAgents {   // over 20: needs-you rows stay, then the first others; original order kept
            let need = a.indices.filter { a[$0].status == .needsYou }.prefix(maxAgents)
            let rest = a.indices.filter { a[$0].status != .needsYou }.prefix(maxAgents - need.count)
            a = Set(need).union(rest).sorted().map { a[$0] }
        }
        func build() -> [String: Any] {
            var c = card
            if !f.isEmpty { c["folders"] = f }
            if !d.isEmpty { c["dirs"] = d }
            if !a.isEmpty { c["agents"] = a.map(wire) }
            if let usage { c["usage"] = wire(usage) }
            return c
        }
        func size(_ c: [String: Any]) -> Int { ((try? JSONSerialization.data(withJSONObject: c))?.count ?? Int.max) + 64 }   // + sentAt/seq
        var c = build()
        if size(c) > budget, !d.isEmpty { d = []; c = build() }   // a cut list would refuse good dirs: all or nothing
        while size(c) > budget, !a.isEmpty {
            if let i = a.lastIndex(where: { $0.status != .needsYou }) { a.remove(at: i) } else { a.removeLast() }
            c = build()
        }
        while size(c) > budget, let k = f.keys.sorted().last(where: { (f[$0]?.count ?? 0) > 1 }) {
            f[k]?.removeLast(); c = build()
        }
        while size(c) > budget, let k = f.keys.sorted().last { f[k] = nil; c = build() }
        return c
    }
}
