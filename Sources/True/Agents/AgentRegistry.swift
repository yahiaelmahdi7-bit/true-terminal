import Foundation
import Observation
import Darwin

/// What an agent card's pill shows. Derived from hook events (what the agent SAYS), never from
/// watching output.
enum AgentStatus: String, Sendable {
    case asleep, idle, working, needsYou, done
    /// Hub only: a background builder that failed, was killed or died. No hook event leads here.
    case failed

    var label: String {
        switch self {
        case .asleep: return "Asleep"
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    /// Pure transition table. `notification` and `session` are not state changes; an error ends the
    /// turn without completing it, so it falls back to idle rather than "done".
    static func next(after kind: PaneEventKind, from current: AgentStatus) -> AgentStatus {
        switch kind {
        case .progress: return .working
        case .need: return .needsYou
        case .stop, .done: return .done
        case .idle, .error: return .idle
        case .notification, .session: return current
        }
    }
}

/// How an awake agent's pane starts: read by `EmbeddedTerminal` when the pane's view is created.
struct PaneLaunch: Equatable, Sendable {
    var agent: String
    var argv: [String]
    var shellCommand: String
}

/// name → agent config + pane + status. The one small object the tabs, the panel, the needs-you
/// tray and PaneDelivery share (Axon spread this across DeskModel, SleepCenter and the crew store).
@MainActor
@Observable
final class AgentRegistry {
    static let shared = AgentRegistry()

    private(set) var agents: [Agent]
    private(set) var panes: [String: UUID] = [:]
    private(set) var status: [String: AgentStatus] = [:]
    private(set) var latest: [UUID: PaneEvent] = [:]
    /// The latest permission mode each pane's Claude reported (any hook event); recorded for `--resume` at quit.
    @ObservationIgnored private(set) var modes: [UUID: String] = [:]
    @ObservationIgnored private(set) var launchSpecs: [UUID: PaneLaunch] = [:]
    var panelOpen = false
    /// The builder sheet's draft; non-nil = sheet showing.
    var builder: BuilderDraft?

    @ObservationIgnored private let store: AgentStore
    @ObservationIgnored let paths: AgentPaths
    @ObservationIgnored private let workspace: WorkspaceModel
    @ObservationIgnored private let claudeDir: URL
    @ObservationIgnored private var sessionWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]

    init(store: AgentStore = AgentStore(), paths: AgentPaths = .standard,
         workspace: WorkspaceModel = .shared, claudeDir: URL = AgentLaunch.claudeConfigDir) {
        self.store = store
        self.paths = paths
        self.workspace = workspace
        self.claudeDir = claudeDir
        self.agents = store.load()
        workspace.onPaneClosed = { [weak self] pane in self?.paneClosed(pane) }
        workspace.agentName = { [weak self] pane in self?.name(for: pane) }
        workspace.paneMode = { [weak self] pane in self?.modes[pane] }
        workspace.isAgentPane = { [weak self] pane in self?.name(for: pane) != nil }
        restore()
    }

    /// Agents that were awake when True quit come back awake, in the SAME pane (same tab, same split
    /// position), resuming their session. Runs before the first render, so the pane's view is made with
    /// its launch spec already set. An agent that no longer exists loses its record: a plain shell.
    private func restore() {
        for t in workspace.state.tabs {
            for (pane, r) in t.resume ?? [:] {
                guard case let .agent(name) = r else { continue }
                guard panes[name] == nil, let a = agent(named: name) else {
                    workspace.setResume(nil, pane: pane)
                    continue
                }
                AgentHooks.install(for: a, all: agents, paths: paths)
                let resumeID = AgentLaunch.resumeID(for: a, claudeDir: claudeDir)
                // Interrupted at quit (marks were consumed by ResumePlan): continue, but only if we really resume.
                let prompt = resumeID != nil && workspace.interruptedAgentPanes.contains(pane) ? ResumePlan.continuePrompt : nil
                let argv = AgentLaunch.argv(a, paths: paths, resumeID: resumeID, initialPrompt: prompt)
                launchSpecs[pane] = PaneLaunch(agent: a.name, argv: argv, shellCommand: AgentLaunch.shellCommand(argv: argv))
                panes[name] = pane
                status[name] = .idle
            }
        }
    }

    // MARK: Queries

    /// Everyone you can talk to: the Watcher lives in the Hub, never in a pane list.
    var crew: [Agent] { agents.filter { $0.role != .watcher } }
    func agent(named name: String) -> Agent? { agents.first { $0.name == name } }
    func name(for pane: UUID) -> String? { panes.first { $0.value == pane }?.key }
    func isAwake(_ name: String) -> Bool { panes[name] != nil }
    func statusOf(_ name: String) -> AgentStatus { status[name] ?? .asleep }

    /// The status of the agent owning any leaf of `tab`, for the tab's dot.
    func tabStatus(_ tab: TabState) -> AgentStatus? {
        for leaf in tab.tree.leafIDs { if let n = name(for: leaf) { return statusOf(n) } }
        return nil
    }

    /// Globals first as ONE group (key "", title "Global", sorted by name) — even a global with a
    /// folder belongs to no repo. Then by repo (sorted by name), lead first, then helpers by slot number.
    static func grouped(_ agents: [Agent]) -> [(key: String, title: String, agents: [Agent])] {
        let globals = agents.filter { $0.role == .global }.sorted { $0.name < $1.name }
        let repos = Dictionary(grouping: agents.filter { $0.role != .global && $0.role != .watcher }, by: \.repo)
            .map { repo, members in
                (key: repo, title: (repo as NSString).lastPathComponent, agents: members.sorted { a, b in
                    let ka = (a.role == .lead ? 0 : 1, AgentNaming.parse(a.name)?.helper ?? 0, a.name)
                    let kb = (b.role == .lead ? 0 : 1, AgentNaming.parse(b.name)?.helper ?? 0, b.name)
                    return ka < kb
                })
            }
            .sorted { $0.title.lowercased() < $1.title.lowercased() }
        return (globals.isEmpty ? [] : [(key: "", title: "Global", agents: globals)]) + repos
    }

    // MARK: Events

    func handle(_ e: PaneEvent) {
        if let m = e.mode { modes[e.pane] = m }
        if PeerOrigin.shared.label(for: e.pane) != nil { PeerService.engine.paneEvent(pane: e.pane, kind: Self.peerKind(e.kind)) }
        if e.kind == .session {
            // Any pane's Claude (⌘↩ or typed by hand) reports its session id: that is the resume record.
            let sid = e.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if name(for: e.pane) == nil, UUID(uuidString: sid) != nil,
               let cwd = workspace.state.tabs.compactMap({ $0.cwds[e.pane] }).first {
                workspace.setResume(.claude(sessionID: sid, cwd: cwd, mode: modes[e.pane]), pane: e.pane)
            }
            guard let name = name(for: e.pane), let i = agents.firstIndex(where: { $0.name == name }) else { return }
            let id = e.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if UUID(uuidString: id) != nil, agents[i].lastSessionID != id {
                agents[i].lastSessionID = id
                store.save(agents)
            }
            let waiting = sessionWaiters.removeValue(forKey: name) ?? []
            for w in waiting { w.resume(returning: true) }
            return
        }
        latest[e.pane] = e
        if let name = name(for: e.pane) {
            status[name] = AgentStatus.next(after: e.kind, from: statusOf(name))
        }
    }

    // MARK: Wake / sleep

    /// Open a tab in the agent's repo and run claude there. Idempotent: an awake agent just gets focus.
    @discardableResult
    func wake(_ name: String) -> UUID? {
        if let pane = panes[name] { workspace.focus(pane: pane); return pane }
        guard let a = agent(named: name) else { return nil }
        AgentHooks.install(for: a, all: agents, paths: paths)
        let argv = AgentLaunch.argv(a, paths: paths, resumeID: AgentLaunch.resumeID(for: a, claudeDir: claudeDir))
        let cwd = !a.repo.isEmpty && FileManager.default.fileExists(atPath: a.repo) ? a.repo : NSHomeDirectory()
        let pane = workspace.openAgentTab(name: a.name, cwd: cwd)
        launchSpecs[pane] = PaneLaunch(agent: a.name, argv: argv, shellCommand: AgentLaunch.shellCommand(argv: argv))
        panes[name] = pane
        status[name] = .idle
        workspace.setResume(.agent(name: a.name), pane: pane)   // survives a crash, not just a clean quit
        return pane
    }

    /// End the process (SIGTERM; SIGKILL after 3 s if the pane is still there — a stopped or
    /// stubborn child ignores TERM). The tab closes through the normal pane-exit path; the session
    /// id stays in agents.json so the next wake resumes.
    func sleep(_ name: String) {
        guard let pane = panes[name] else { return }
        guard let view = TerminalRegistry.shared.view(for: pane) else { workspace.paneExited(pane); return }
        view.resumeChild()
        let pid = view.process.shellPid
        guard pid > 0 else { workspace.paneExited(pane); return }
        // The pane's pid is claude-burn with claude as its child (same process group): signal the group,
        // or TERM would end the launcher alone and orphan claude in the pane.
        if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if TerminalRegistry.shared.view(for: pane) != nil, kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
        }
    }

    private static func peerKind(_ k: PaneEventKind) -> PeerEventMap.Kind {
        switch k {
        case .progress: return .progress
        case .need: return .need
        case .stop, .done: return .stop
        case .error: return .error
        case .notification, .idle, .session: return .other
        }
    }

    func paneClosed(_ pane: UUID) {
        if PeerOrigin.shared.label(for: pane) != nil { PeerService.engine.paneClosed(pane: pane) }
        OverseerStore.shared.paneClosed(pane)
        launchSpecs[pane] = nil
        latest[pane] = nil
        modes[pane] = nil
        if let n = name(for: pane) {
            panes[n] = nil
            status[n] = nil
            for w in sessionWaiters.removeValue(forKey: n) ?? [] { w.resume(returning: false) }
        }
    }

    // MARK: Talk

    /// Deliver `text` to the agent's pane, waking it first when asleep (waits for its SessionStart).
    func talk(_ name: String, _ text: String, onOutcome: ((PaneDelivery.Outcome) -> Void)? = nil) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if let pane = panes[name] {
            PaneDelivery.write(body, intent: .prompt, to: pane, onOutcome: onOutcome)
            return
        }
        guard wake(name) != nil else { onOutcome?(.noPane); return }
        Task { @MainActor in
            if await self.waitForSession(name), let pane = self.panes[name] {
                PaneDelivery.write(body, intent: .prompt, to: pane, onOutcome: onOutcome)
            } else {
                onOutcome?(.noPane)
            }
        }
    }

    private func waitForSession(_ name: String) async -> Bool {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            for w in self?.sessionWaiters.removeValue(forKey: name) ?? [] { w.resume(returning: false) }
        }
        return await withCheckedContinuation { c in sessionWaiters[name, default: []].append(c) }
    }

    // MARK: Editing

    func save(_ a: Agent) {
        if let i = agents.firstIndex(where: { $0.name == a.name }) {
            var merged = a
            merged.lastSessionID = agents[i].lastSessionID
            agents[i] = merged
        } else {
            agents.append(a)
        }
        store.save(agents)
    }

    func delete(_ name: String) {
        sleep(name)
        agents.removeAll { $0.name == name }
        store.save(agents)
    }
}
