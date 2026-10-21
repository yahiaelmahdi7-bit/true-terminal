import Foundation
import AppKit
import Darwin
import os

/// Glue between the live terminals and the workspace's resume records. All calls are event-driven:
/// quit, window close, a one-shot after Return, and a Claude `session` hook.
@MainActor
enum SessionSnapshot {
    static var sessionsDir: URL { AgentLaunch.claudeConfigDir.appendingPathComponent("sessions") }

    /// Look at the pane's live shell: alive?, and which interactive Claude runs beneath it.
    static func probe(_ pane: UUID) -> (alive: Bool, found: ClaudeSessions.Found?) {
        guard let v = TerminalRegistry.shared.view(for: pane), v.process.running, v.process.shellPid > 0 else {
            return (false, nil)
        }
        let found = ClaudeSessions.find(under: v.process.shellPid, sessionsDir: sessionsDir,
                                        children: ClaudeSessions.liveChildren)
        return (true, found)
    }

    static func record(_ model: WorkspaceModel = .shared) { model.recordResume(probe: probe) }

    /// Quit or window close: record, save, then stop reacting to the shells dying.
    static func atQuit(_ model: WorkspaceModel = .shared, scrollback: ScrollbackStore = .standard) {
        let ran = model.freeze {
            record(model)
            let marked = model.markInterrupted(probe: probe, hook: hookStatus)
            log.notice("\(interruptedSummary(marked.map { shortName($0, model) }), privacy: .public)")
            saveScreens(model, scrollback)
            log.notice("\(quitSummary(model.state), privacy: .public)")
        }
        if !ran { log.notice("quit snapshot skipped: workspace already frozen") }
    }

    /// The pane's status from hook tracking: the seat's status, else its last hook event folded from idle.
    static func hookStatus(_ pane: UUID) -> AgentStatus? {
        let reg = AgentRegistry.shared
        if let n = reg.name(for: pane) { return reg.statusOf(n) }
        return reg.latest[pane].map { AgentStatus.next(after: $0.kind, from: .idle) }
    }

    private static func shortName(_ pane: UUID, _ model: WorkspaceModel) -> String {
        if let n = AgentRegistry.shared.name(for: pane) { return "agent \(n)" }
        for t in model.state.tabs { if case let .claude(id, _, _)? = t.resume?[pane] { return String(id.prefix(8)) } }
        return "pane"
    }

    static func interruptedSummary(_ names: [String]) -> String {
        "quit snapshot: \(names.count) interrupted (will continue)" + (names.isEmpty ? "" : ": " + names.sorted().joined(separator: ", "))
    }

    private static let log = Logger(subsystem: "True", category: "restore")

    /// "quit snapshot: recorded N session(s) across T tab(s)" + short ids, or an explicit "nothing to record".
    static func quitSummary(_ state: WorkspaceState) -> String {
        var ids: [String] = []
        for t in state.tabs {
            for r in (t.resume ?? [:]).values {
                switch r {
                case let .claude(id, _, _): ids.append(String(id.prefix(8)))
                case let .agent(name): ids.append("agent \(name)")
                }
            }
        }
        let head = "quit snapshot: recorded \(ids.count) session(s) across \(state.tabs.count) tab(s)"
        return ids.isEmpty ? head + " (nothing to record: no live Claude or agent panes)" : head + ": " + ids.sorted().joined(separator: ", ")
    }

    /// Plain shells (no Claude, no agent) keep their screen: serialize the normal buffer to disk. A pane whose
    /// view is already gone is left alone (an earlier file, if any, stays); files of closed panes are pruned.
    static func saveScreens(_ model: WorkspaceModel, _ store: ScrollbackStore) {
        var all = Set<UUID>()
        for t in model.state.tabs {
            for p in t.tree.leafIDs {
                all.insert(p)
                guard let v = TerminalRegistry.shared.view(for: p), v.process.running, v.process.shellPid > 0 else { continue }
                if t.resume?[p] != nil { store.remove(p); continue }
                let term = v.getTerminal()
                if term.isCurrentBufferAlternate { term.feed(text: "\u{1b}[?1049l") }   // vim etc: save the shell's own screen
                let text = ScrollbackSerializer.serialize(term)
                guard !text.isEmpty else { store.remove(p); continue }
                store.save(pane: p, text: text, header: .init(cols: term.cols, rows: term.rows, savedAt: Date(),
                                                              wasRunning: foregroundName(v)))
            }
        }
        store.prune(keeping: all)
    }

    /// The command in the foreground of this pane's tty (e.g. "npm"), if it is not the shell itself.
    static func foregroundName(_ v: TrueTerminalView) -> String? {
        let fg = tcgetpgrp(v.process.childfd)
        guard fg > 0, fg != v.process.shellPid else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(fg, &buf, UInt32(buf.count)) > 0 else { return nil }
        let n = String(cString: buf)
        return n.isEmpty ? nil : n
    }

    private static var pending: [UUID: Task<Void, Never>] = [:]

    /// ~2.5 s after Return in `pane` (debounced per pane): the crash / force-quit safety net.
    static func scheduleAfterReturn(pane: UUID) {
        pending[pane]?.cancel()
        pending[pane] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled else { return }
            pending[pane] = nil
            let (alive, found) = probe(pane)
            let m = WorkspaceModel.shared
            if found == nil, m.isWaking(pane) { return }   // Return typed while waiting its turn: keep the record
            guard let t = m.state.tabs.first(where: { $0.tree.contains(pane) }) else { return }
            m.setResume(SessionRecorder.decide(previous: t.resume?[pane], agent: m.agentName?(pane),
                                               alive: alive, found: found, mode: m.paneMode?(pane)), pane: pane)
        }
    }
}
