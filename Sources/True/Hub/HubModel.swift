import Foundation
import Darwin

/// The Hub's pure core (SPEC Run 7): what a session record looks like, which project it belongs to,
/// which records are the same session, and how they group. No IO here except the two injectable
/// probes (`hasGit`, `alive`), so the tables are testable without touching ~/.claude.

// MARK: Project key

enum HubProject {
    /// `<X>.builders/<id>` → `<X>`; `<repo>/.claude/worktrees/<n>` → `<repo>`; else the nearest ancestor
    /// holding a `.git` (file or folder — a worktree's is a file); else the path itself. The search stops
    /// before `home`, so a dotfiles repo in ~ can't swallow every folder under it.
    static func key(forCwd cwd: String, home: String = NSHomeDirectory(),
                    hasGit: (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/.git") }) -> String {
        var base = (cwd as NSString).standardizingPath
        if let r = base.range(of: ".builders/") ?? (base.hasSuffix(".builders") ? base.range(of: ".builders") : nil) {
            base = String(base[..<r.lowerBound])
        } else if let r = base.range(of: "/.claude/worktrees/") {
            base = String(base[..<r.lowerBound])
        }
        guard !base.isEmpty else { return cwd }
        var dir = base
        while dir != "/" && !dir.isEmpty && dir != home {
            if hasGit(dir) { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return base
    }

    static func title(_ key: String) -> String { key.isEmpty ? "Global" : (key as NSString).lastPathComponent }
}

// MARK: Records

/// One `~/.claude/sessions/<pid>.json`. Only the fields the Hub shows; anything else is ignored.
struct PeerSession: Equatable, Sendable, Identifiable {
    var pid: Int32
    var sessionID: String
    var cwd: String
    var name: String
    var kind: String
    var busy: Bool
    /// Seconds since 1970 (the file stores milliseconds).
    var updatedAt: Double
    var id: Int32 { pid }

    /// Missing pid or cwd → nil (nothing to show or probe). Everything else falls back to a blank.
    static func parse(_ data: Data) -> PeerSession? {
        struct Wire: Decodable {
            let pid: Int32?, sessionId: String?, cwd: String?, name: String?, kind: String?, entrypoint: String?
            let status: String?, updatedAt: Double?, startedAt: Double?
        }
        guard let w = try? JSONDecoder().decode(Wire.self, from: data), let pid = w.pid, pid > 0,
              let cwd = w.cwd, !cwd.isEmpty else { return nil }
        let stamp = w.updatedAt ?? w.startedAt ?? 0
        return PeerSession(pid: pid, sessionID: w.sessionId ?? "", cwd: cwd,
                           name: w.name ?? "", kind: w.kind ?? w.entrypoint ?? "session",
                           busy: w.status == "busy", updatedAt: stamp / 1000)
    }

    /// `kill(pid, 0)` succeeds, or fails with EPERM (alive, just not ours). `probe` returns 0 or an errno.
    static func isAlive(_ pid: Int32, probe: (Int32) -> Int32 = { Darwin.kill($0, 0) == 0 ? 0 : errno }) -> Bool {
        guard pid > 0 else { return false }
        let err = probe(pid)
        return err == 0 || err == EPERM
    }

    var displayName: String { name.isEmpty ? (cwd as NSString).lastPathComponent : name }
}

enum BuilderState: String, Sendable {
    /// `paused`: the builder hit its absolute ceiling (or made no progress twice) and waits for `builder resume <id>`.
    case running, done, failed, killed, died, paused
}

/// One `~/.claude/builders/<id>/meta.json`.
struct BuilderRecord: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var cwd: String
    var originCwd: String
    var model: String
    var sessionID: String
    var claudePID: Int32
    var started: Double
    var ended: Double?
    var state: BuilderState
    var acked: Bool
    var parent: String?
    var branch: String?
    var worktree: String?
    var cost: Double?
    var budget: Double?
    /// Where the files live (result.md, stream.jsonl); nil for a record built in a test.
    var dir: String?
    /// mtime of stream.jsonl, stat'ed for running builders only (the Watcher's stuck rule).
    var lastWrite: Double? = nil

    /// `alive` is the builder's own `is_running`: a `running` record whose pids are gone is `died`.
    static func parse(_ data: Data, dir: String? = nil, alive: (Int32) -> Bool = { PeerSession.isAlive($0) }) -> BuilderRecord? {
        struct Wire: Decodable {
            let id: String?, name: String?, cwd: String?, origin_cwd: String?, model: String?, session_id: String?
            let claude_pid: Int32?, supervisor_pid: Int32?, started: Double?, ended: Double?, status: String?
            let acked: Bool?, parent: String?, branch: String?, worktree: String?, cost_usd: Double?, budget_usd: Double?
        }
        guard let w = try? JSONDecoder().decode(Wire.self, from: data), let id = w.id, !id.isEmpty,
              let started = w.started else { return nil }
        var state = BuilderState(rawValue: w.status ?? "") ?? .failed
        if state == .running {
            // builder's is_running(): no pids yet = launch in progress; else either pid alive.
            let pids = [w.claude_pid, w.supervisor_pid].compactMap { $0 }.filter { $0 > 0 }
            if !pids.isEmpty && !pids.contains(where: alive) { state = .died }
        }
        let cwd = w.cwd ?? ""
        return BuilderRecord(id: id, name: w.name ?? id, cwd: cwd, originCwd: w.origin_cwd ?? cwd,
                             model: w.model ?? "", sessionID: w.session_id ?? "", claudePID: w.claude_pid ?? 0,
                             started: started, ended: w.ended, state: state, acked: w.acked ?? false,
                             parent: (w.parent?.isEmpty ?? true) ? nil : w.parent, branch: w.branch,
                             worktree: w.worktree, cost: w.cost_usd, budget: w.budget_usd, dir: dir)
    }

    /// Running, finished-and-not-acked, or anything finished under 24 h ago. A `died` record never
    /// finalised, so its age is measured from the start.
    func isVisible(now: Double) -> Bool {
        switch state {
        case .running: return true
        case .died: return !acked && now - started < 86_400
        case .done, .failed, .killed, .paused: return !acked || now - (ended ?? started) < 86_400
        }
    }

    var status: AgentStatus {
        switch state {
        case .running: return .working
        case .done: return .done
        case .paused: return .needsYou
        case .failed, .killed, .died: return .failed
        }
    }

    /// The Hub's word for the row: a paused builder is not "Needs you" in general, it is waiting for a go-ahead.
    var statusLabel: String { state == .paused ? "Paused" : status.label }

    /// Seconds since the start (running) or the whole run (finished).
    func elapsed(now: Double) -> Double { max(0, (state == .running ? now : (ended ?? now)) - started) }

    var project: String { HubProject.key(forCwd: originCwd.isEmpty ? cwd : originCwd) }
}

// MARK: Snapshot

struct HubProjectGroup: Equatable, Identifiable {
    var key: String
    var seats: [Agent]
    var background: [BuilderRecord]
    var others: [PeerSession]
    /// Seconds since 1970; an awake seat counts as "now" so the project you are in floats up.
    var latest: Double
    var working: Int
    var needsYou: Int
    var failed: Int
    var id: String { key }
    var title: String { HubProject.title(key) }

    /// "3 working · 1 needs you"; empty when nothing is happening.
    var summary: String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if needsYou > 0 { parts.append("\(needsYou) needs you") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
enum HubModel {
    /// Everything the Hub shows, grouped by project. Seat ↔ registry dedupe by session id;
    /// builder ↔ registry by session_id / claude_pid — one row per real session. Empty projects vanish;
    /// `seatsOnly` drops Background and Other sessions (the "Seats" toggle).
    static func build(seats: [Agent], seatStatus: (String) -> AgentStatus, seatAwake: (String) -> Bool,
                      peers: [PeerSession], builders: [BuilderRecord], now: Double,
                      seatsOnly: Bool = false,
                      hasGit: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/.git") }) -> [HubProjectGroup] {
        let seatSessions = Set(seats.compactMap(\.lastSessionID).filter { !$0.isEmpty })
        let shown = builders.filter { $0.isVisible(now: now) }
        let builderSessions = Set(shown.map(\.sessionID).filter { !$0.isEmpty })
        let builderPIDs = Set(shown.map(\.claudePID).filter { $0 > 0 })

        var groups: [String: HubProjectGroup] = [:]
        func slot(_ key: String) -> HubProjectGroup {
            groups[key] ?? HubProjectGroup(key: key, seats: [], background: [], others: [], latest: 0,
                                           working: 0, needsYou: 0, failed: 0)
        }
        for a in seats {
            // A global belongs to no repo (even with a folder), like the old panel.
            let key = a.role == .global || a.repo.isEmpty ? "" : HubProject.key(forCwd: a.repo, hasGit: hasGit)
            var g = slot(key)
            g.seats.append(a)
            switch seatStatus(a.name) {
            case .working: g.working += 1
            case .needsYou: g.needsYou += 1
            default: break
            }
            if seatAwake(a.name) { g.latest = max(g.latest, now) }
            groups[key] = g
        }
        if !seatsOnly {
            for b in shown {
                var g = slot(HubProject.key(forCwd: b.originCwd.isEmpty ? b.cwd : b.originCwd, hasGit: hasGit))
                g.background.append(b)
                if b.state == .running { g.working += 1 } else if b.state == .paused { g.needsYou += 1 } else if b.status == .failed { g.failed += 1 }
                g.latest = max(g.latest, b.state == .running ? now : (b.ended ?? b.started))
                groups[g.key] = g
            }
            for p in peers where PeerSession.isAlive(p.pid) {
                if !p.sessionID.isEmpty, seatSessions.contains(p.sessionID) || builderSessions.contains(p.sessionID) { continue }
                if builderPIDs.contains(p.pid) { continue }
                var g = slot(HubProject.key(forCwd: p.cwd, hasGit: hasGit))
                g.others.append(p)
                if p.busy { g.working += 1 }
                g.latest = max(g.latest, p.updatedAt)
                groups[g.key] = g
            }
        }
        var out = Array(groups.values)
        for i in out.indices {
            out[i].seats = AgentRegistry.grouped(out[i].seats).flatMap(\.agents)
            out[i].background.sort { $0.started > $1.started }
            out[i].others.sort { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.displayName < $1.displayName }
        }
        // Latest activity first; the title breaks ties so equal projects never swap places between refreshes.
        return out.sorted { a, b in
            a.latest != b.latest ? a.latest > b.latest : a.title.lowercased() < b.title.lowercased()
        }
    }
}

// MARK: JSON view (truectl status)

struct HubRow: Encodable, Equatable, Sendable {
    let project: String, kind: String, name: String, status: String
    /// Overseer verdict raw value (seat and other rows); nil = none.
    var verdict: String? = nil
}

extension HubModel {
    /// project → sessions, flattened for `truectl status`. `kind` is seat | background | other.
    static func rows(_ groups: [HubProjectGroup], seatStatus: (String) -> AgentStatus,
                     seatVerdict: (Agent) -> String? = { _ in nil },
                     peerVerdict: (PeerSession) -> String? = { _ in nil }) -> [HubRow] {
        groups.flatMap { g in
            g.seats.map { HubRow(project: g.title, kind: "seat", name: $0.name, status: seatStatus($0.name).rawValue, verdict: seatVerdict($0)) }
            + g.background.map { HubRow(project: g.title, kind: "background", name: $0.name, status: $0.status.rawValue) }
            + g.others.map { HubRow(project: g.title, kind: "other", name: $0.displayName, status: $0.busy ? "working" : "idle", verdict: peerVerdict($0)) }
        }
    }
}
