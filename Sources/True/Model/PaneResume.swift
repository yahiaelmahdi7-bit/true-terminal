import Foundation
import Darwin

/// What a pane was running when True last looked, so the next launch can put it back.
enum PaneResume: Codable, Equatable, Sendable {
    /// A Claude conversation (`claude --resume <sessionID>` in `cwd`). `mode` is the permission mode it
    /// was in (hook `permission_mode`); nil in records saved before it was tracked.
    case claude(sessionID: String, cwd: String, mode: String? = nil)
    /// A named agent that was awake; re-woken into this same pane.
    case agent(name: String)
}

/// Finds the Claude Code process under a pane's shell. Every live Claude writes
/// `<claudeConfigDir>/sessions/<pid>.json`; the pane's Claude is a descendant of its shell, often
/// 2–3 levels down (shell → claude-burn loop → claude).
enum ClaudeSessions {
    struct Found: Equatable, Sendable {
        var sessionID: String; var cwd: String; var pid: pid_t
        /// The session file said `"status": "busy"` (mid-turn). Missing or anything else = not busy.
        var busy = false
        /// The session file said `"status": "idle"` (at its prompt). Beats a stale hook: Esc fires no Stop.
        var idle = false
    }

    private struct File: Decodable { var sessionId: String?; var cwd: String?; var kind: String?; var status: String? }

    /// Breadth-first, so the shallowest match wins. `children` is injected so tests use a fake tree.
    static func find(under root: pid_t, sessionsDir: URL, maxDepth: Int = 5,
                     children: (pid_t) -> [pid_t]) -> Found? {
        var level = children(root)
        var seen: Set<pid_t> = [root]
        var depth = 1
        while !level.isEmpty, depth <= maxDepth {
            for pid in level where seen.insert(pid).inserted {
                if let f = read(pid, sessionsDir) { return f }
            }
            level = level.flatMap { children($0) }.filter { !seen.contains($0) }
            depth += 1
        }
        return nil
    }

    static func read(_ pid: pid_t, _ dir: URL) -> Found? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(pid).json")),
              let f = try? JSONDecoder().decode(File.self, from: data),
              f.kind == "interactive",
              let id = f.sessionId, !id.isEmpty, let cwd = f.cwd, !cwd.isEmpty else { return nil }
        return Found(sessionID: id, cwd: cwd, pid: pid, busy: f.status == "busy", idle: f.status == "idle")
    }

    /// Direct children of `pid` from the kernel.
    static func liveChildren(_ pid: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 256)
        _ = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return buf.filter { $0 > 0 }
    }
}

/// Which panes come back running what. Pure: `WorkspaceModel.init` applies the result.
enum ResumePlan {
    /// Why a `.claude` record did not come back; logged by name at launch.
    enum DropReason: String, Equatable, Sendable {
        case invalidSessionID = "session id is not a UUID"
        case transcriptMissing = "transcript missing"
    }
    struct Dropped: Equatable, Sendable { var pane: UUID; var sessionID: String; var reason: DropReason }
    /// `records` counts every resume record found (claude + agent), so "none at all" is distinguishable.
    struct Result {
        var state: WorkspaceState; var startups: [UUID: String]
        var dropped: [Dropped] = []; var records = 0
        /// `.claude` panes that start with `continuePrompt` (were interrupted at quit).
        var continued: [UUID] = []
        /// Agent panes that were interrupted at quit; `AgentRegistry.restore` wakes them with the prompt.
        var interruptedAgents: Set<UUID> = []
        /// True when the stored file carried interrupted marks, which the returned state has cleared.
        var consumedMarks = false
    }

    /// The one-time first message for a session that True's quit cut off mid-task.
    static let continuePrompt = "True restarted while you were working, which interrupted your last step. Continue the task from where you left off. First check whether the interrupted step (a command, build or edit) actually finished before redoing it."

    /// For each `.claude` record with a UUID id and a transcript on disk: a startup command and the
    /// pane's cwd set to the record's. Anything invalid is dropped, so the pane is a plain shell.
    /// `.agent` records are left for `AgentRegistry.restore`.
    static func apply(_ state: WorkspaceState, claudeDir: URL, settings: String) -> Result {
        var s = state
        var out: [UUID: String] = [:]
        var dropped: [Dropped] = []
        var records = 0
        var continued: [UUID] = []
        var agents: Set<UUID> = []
        var consumed = false
        for ti in s.tabs.indices {
            let marks = s.tabs[ti].interrupted ?? []
            if s.tabs[ti].interrupted != nil { consumed = true; s.tabs[ti].interrupted = nil }   // consume once
            guard let map = s.tabs[ti].resume else { continue }
            for (pane, r) in map {
                records += 1
                if case .agent = r { if marks.contains(pane) { agents.insert(pane) }; continue }
                guard case let .claude(id, cwd, mode) = r else { continue }
                let prompt = marks.contains(pane) ? continuePrompt : nil
                if let cmd = PaneStartup.resumeCommand(sessionID: id, settings: settings, mode: mode, prompt: prompt) {
                    if AgentLaunch.transcriptExists(id: id, cwd: cwd, claudeDir: claudeDir) {
                        out[pane] = cmd
                        if prompt != nil { continued.append(pane) }
                        s.tabs[ti].cwds[pane] = cwd
                        continue
                    }
                    dropped.append(Dropped(pane: pane, sessionID: id, reason: .transcriptMissing))
                } else {
                    dropped.append(Dropped(pane: pane, sessionID: id, reason: .invalidSessionID))
                }
                s.tabs[ti].resume?[pane] = nil
            }
            if s.tabs[ti].resume?.isEmpty == true { s.tabs[ti].resume = nil }
        }
        return Result(state: s, startups: out, dropped: dropped, records: records,
                      continued: continued, interruptedAgents: agents, consumedMarks: consumed)
    }
}

/// Decides what to store for one pane at snapshot time.
enum SessionRecorder {
    /// Was this pane cut off mid-task? Working or waiting on the user, by the session file's `busy` or by
    /// True's hook tracking (`hook`: the pane's status from its last hook event, or the seat's status).
    static func isInterrupted(found: ClaudeSessions.Found?, hook: AgentStatus?) -> Bool {
        if found?.busy == true { return true }
        // At its prompt: a hook still saying 'working' is stale (Esc mid-turn fires no Stop). Missing a mark
        // only costs a quiet resume; a false one restarts work the user stopped.
        if found?.idle == true { return false }
        return hook == .working || hook == .needsYou
    }

    /// - `agent`: the pane belongs to an awake agent → always `.agent`.
    /// - `alive`: the pane's view and shell still exist. A late snapshot must not wipe a good record.
    /// - `found`: the Claude under the shell, if any (only meaningful when `alive`).
    static func decide(previous: PaneResume?, agent: String?, alive: Bool,
                       found: ClaudeSessions.Found?, mode: String? = nil) -> PaneResume? {
        if let a = agent { return .agent(name: a) }
        guard alive else { return previous }
        if let f = found {
            // No hook has reported a mode this run: keep the one recorded for the same conversation.
            var kept: String?
            if case let .claude(id, _, m)? = previous, id == f.sessionID { kept = m }
            return .claude(sessionID: f.sessionID, cwd: f.cwd, mode: mode ?? kept)
        }
        if case .claude = previous { return nil }
        return previous
    }
}
