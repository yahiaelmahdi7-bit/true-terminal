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
    /// Each Claude pane's last context reading, taken when its Stop hook reports the transcript.
    private(set) var contexts: [UUID: ContextReading] = [:]
    /// The latest permission mode each pane's Claude reported (any hook event); recorded for `--resume` at quit.
    @ObservationIgnored private(set) var modes: [UUID: String] = [:]
    @ObservationIgnored private(set) var launchSpecs: [UUID: PaneLaunch] = [:]
    var panelOpen = false
    /// The builder sheet's draft; non-nil = sheet showing.
    var builder: BuilderDraft?

    @ObservationIgnored private let turns: AgentTurnStore
    /// Turn records hash files with git, so they never run on the main thread. One serial queue keeps
    /// open, question and close in order; results come back on main in the same order.
    @ObservationIgnored private let turnQueue = DispatchQueue(label: "true.turns", qos: .utility)
    private(set) var turnRecords: [String: AgentTurn] = [:]
    @ObservationIgnored private let store: AgentStore
    @ObservationIgnored let paths: AgentPaths
    @ObservationIgnored private let workspace: WorkspaceModel
    @ObservationIgnored private let claudeDir: URL
    @ObservationIgnored private let codexDir: URL
    private(set) var startupIssues: [String: SeatStartupIssue] = [:]
    /// A seat woken on its fallback provider (Wedge 3): the card text for the later UI. Cleared when the pane closes.
    private(set) var fallbackCards: [String: FallbackCard] = [:]
    /// The saved agent as it was before a fallback wake changed its provider in memory only. Never persisted.
    @ObservationIgnored private var beforeFallback: [String: Agent] = [:]
    /// Seats whose card said "Use <provider>": their next wake skips the fallback once.
    @ObservationIgnored private var declinedFallback: Set<String> = []
    @ObservationIgnored var routingStore: RoutingStore
    /// Usage windows as the routing rule reads them. Injected in tests.
    @ObservationIgnored var usageWindows: () -> [UsageWindow] = { UsageStore.shared.windows }
    @ObservationIgnored var providerFacts: (SeatProvider) -> (installed: Bool, signIn: SeatSignIn) = { p in
        (ProgramFinder.shared.resolve(p.rawValue) != nil, ProgramFinder.shared.cachedResult(p.rawValue)?.signIn ?? .unknown)
    }
    @ObservationIgnored var clock: () -> Date = { Date() }
    @ObservationIgnored private var startedSeats: Set<String> = []
    @ObservationIgnored private var sessionWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]

    init(store: AgentStore = AgentStore(), paths: AgentPaths = .standard,
         workspace: WorkspaceModel = .shared, claudeDir: URL = AgentLaunch.claudeConfigDir, codexDir: URL = CodexSeat.codexDir) {
        self.turns = AgentTurnStore(directory: paths.root.appendingPathComponent("turns"))
        self.store = store
        self.paths = paths
        self.routingStore = RoutingStore(url: paths.root.appendingPathComponent("routing.json"))
        self.workspace = workspace
        self.claudeDir = claudeDir
        self.codexDir = codexDir
        _ = SeatProviders.codexRuntime
        self.agents = store.load()
        workspace.onPaneClosed = { [weak self] pane in self?.paneClosed(pane) }
        workspace.agentName = { [weak self] pane in self?.name(for: pane) }
        workspace.paneMode = { [weak self] pane in self?.modes[pane] }
        workspace.isAgentPane = { [weak self] pane in self?.name(for: pane) != nil }
        restore()
        let store = turns
        turnQueue.async {
            guard (try? store.recover()) != nil else { return }
            let records = store.allRecords()
            DispatchQueue.main.async { MainActor.assumeIsolated {
                for turn in records {
                    self.turnRecords[turn.seat] = turn
                    // A hook may have reported since launch; only lift the status restore() set.
                    if turn.isOpen, [nil, .idle].contains(self.status[turn.seat]) { self.status[turn.seat] = .working }
                }
            } }
        }
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
                let provider = seatProvider(for: a)
                provider.install(for: a, all: agents, paths: paths)
                let resumeID = provider.resumeID(for: a)
                let interrupted = workspace.interruptedAgentPanes.contains(pane)
                let prompt = Self.restorePrompt(resumes: resumeID != nil, interrupted: interrupted,
                                                allowed: interrupted && turns.autoContinueAllowed(seat: a.name))
                let argv = provider.argv(for: a, paths: paths, resumeID: resumeID, initialPrompt: prompt)
                launchSpecs[pane] = PaneLaunch(agent: a.name, argv: argv, shellCommand: provider.shellCommand(argv: argv))
                panes[name] = pane
                status[name] = .idle
                if provider.startsOnFirstPrompt, prompt != nil { watchCodexStartup(name, pane: pane) }
            }
        }
    }

    /// A restored seat that was mid-turn when True quit continues by itself (the user 2026-11-08: "auto it"),
    /// but only when its conversation really resumes and within the auto-continue cap; otherwise it waits.
    nonisolated static func restorePrompt(resumes: Bool, interrupted: Bool, allowed: Bool) -> String? {
        resumes && interrupted && allowed ? ResumePlan.continuePrompt(.restart) : nil
    }

    private func seatProvider(for agent: Agent) -> any SeatProviding {
        SeatProviders.for(agent, claudeDir: claudeDir, codexDir: codexDir)
    }
    func provider(for pane: UUID) -> any SeatProviding {
        guard let name = name(for: pane), let agent = agent(named: name) else { return ClaudeSeat() }
        return seatProvider(for: agent)
    }
    func isWorking(_ pane: UUID) -> Bool {
        if let name = name(for: pane) { return statusOf(name) == .working }
        return latest[pane]?.kind == .progress
    }
    func canStopTurn(_ name: String) -> Bool { statusOf(name) == .working && capabilities(for: name)?.supports(.stopTurn) == true }
    func canAnswer(_ name: String) -> Bool { capabilities(for: name)?.supports(.answer) == true }
    func stopTurn(_ name: String, onOutcome: ((PaneDelivery.Outcome) -> Void)? = nil) {
        guard let pane = panes[name] else { onOutcome?(.noPane); return }
        guard canStopTurn(name) else { onOutcome?(.promptGone); return }
        let generation = PaneDelivery.interrupts.generation(pane)
        PaneDelivery.write("", intent: .interrupt, to: pane) { [weak self] outcome in
            if outcome == .landed, PaneDelivery.interrupts.generation(pane) == generation,
               self?.panes[name] == pane { self?.status[name] = .idle }
            onOutcome?(outcome)
        }
    }
    func capabilities(for name: String) -> SeatCapabilities? { agent(named: name).map { seatProvider(for: $0).capabilities } }
    func providerSwitchReason(_ provider: SeatProvider, for name: String) -> String? {
        guard let agent = agent(named: name) else { return nil }
        return SeatProviders.codexRuntime.disabledReason(for: provider, agent: agent, awake: isAwake(name))
    }
    func startupIssue(for name: String, screen: String = "") -> SeatStartupIssue? {
        guard agent(named: name)?.seatProvider == .codex else { return nil }
        if let issue = SeatStartupIssue.detect(screen) { return issue }
        if ProgramFinder.shared.cachedResult("codex")?.state == .notSignedIn { return .signIn }
        return startupIssues[name]
    }
    /// Called after the first Codex prompt, not after an empty launch.
    func startupTimedOut(_ name: String, pane: UUID) {
        guard panes[name] == pane, !startedSeats.contains(name), agent(named: name)?.seatProvider == .codex else { return }
        startupIssues[name] = .hooksApproval
        status[name] = .needsYou
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

    private func recordTurn(_ e: PaneEvent, seat: String, folder: String) {
        let store = turns, kind = e.kind, at = e.at
        let prompt = kind == .progress && e.message == "prompt"
        let end: AgentTurn.End? = kind == .session ? .session : kind == .error ? .failure : kind == .stop || kind == .done ? .stop : nil
        guard kind == .progress || kind == .need || end != nil else { return }
        let pid = prompt ? TerminalRegistry.shared.view(for: e.pane)?.process.shellPid ?? 0 : 0
        turnQueue.async {
            let record: AgentTurn?
            do {
                if prompt { record = try store.open(seat: seat, folder: folder, pid: pid, at: at) }
                else if let end { record = try store.close(seat: seat, end: end, at: at) }
                else if kind == .need { try store.markQuestion(seat: seat); record = store.records(seat).last }
                else {
                    guard store.records(seat).last?.questionPending == true else { return }
                    try store.markQuestion(seat: seat, pending: false); record = store.records(seat).last
                }
            } catch { NSLog("True: turn record could not be saved"); return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.turnRecords[seat] = record } }
        }
    }

    func handle(_ e: PaneEvent) {
        if e.kind == .progress, e.message == "prompt" { PaneDelivery.interrupts.reset(e.pane) }
        if let name = name(for: e.pane), let agent = agent(named: name) { recordTurn(e, seat: name, folder: agent.repo) }
        if let m = e.mode { modes[e.pane] = m }
        if PeerOrigin.shared.label(for: e.pane) != nil { PeerService.engine.paneEvent(pane: e.pane, kind: Self.peerKind(e.kind), message: e.message, tool: e.tool, detail: e.detail) }
        if let seat = name(for: e.pane) { PeerService.engine.chat?.release(seat) }   // a pane event = it's past any permission dialog
        if e.kind == .session {
            // Any pane's Claude (⌘↩ or typed by hand) reports its session id: that is the resume record.
            let sid = e.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if name(for: e.pane) == nil, UUID(uuidString: sid) != nil,
               let cwd = workspace.state.tabs.compactMap({ $0.cwds[e.pane] }).first {
                workspace.setResume(.claude(sessionID: sid, cwd: cwd, mode: modes[e.pane]), pane: e.pane)
            }
            guard let name = name(for: e.pane), let i = agents.firstIndex(where: { $0.name == name }) else { return }
            let id = e.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: id) != nil else { return }
            startedSeats.insert(name)
            startupIssues[name] = nil
            if agents[i].sessionID != id {
                agents[i].sessionID = id
                store.save(agents)
            }
            let waiting = sessionWaiters.removeValue(forKey: name) ?? []
            for w in waiting { w.resume(returning: true) }
            return
        }
        latest[e.pane] = e
        if let t = e.transcript { Task { await readContext(pane: e.pane, transcript: t) } }
        if let name = name(for: e.pane) {
            status[name] = AgentStatus.next(after: e.kind, from: statusOf(name))
        }
    }

    /// Reads the tail of the transcript off the main thread, only when a hook event names it. An unreadable file or an
    /// unknown model size keeps the last reading.
    func readContext(pane: UUID, transcript: String) async {
        let r = await Task.detached(priority: .utility) { ContextMeter.claude(transcript: URL(fileURLWithPath: transcript)) }.value
        if let r, contexts[pane] != r { contexts[pane] = r }
    }

    // MARK: Wake / sleep

    /// Open a tab in the agent's repo and run claude there. Idempotent: an awake agent just gets focus.
    @discardableResult
    func wake(_ name: String, initialPrompt: String? = nil, explicitModel: Bool = false) -> UUID? {
        if let pane = panes[name] { workspace.focus(pane: pane); return pane }
        guard var a = agent(named: name) else { return nil }
        if let switched = applyFallback(a, explicitModel: explicitModel) { a = switched }
        let provider = seatProvider(for: a)
        provider.install(for: a, all: agents, paths: paths)
        let argv = provider.argv(for: a, paths: paths, resumeID: provider.resumeID(for: a), initialPrompt: initialPrompt)
        let cwd = !a.repo.isEmpty && FileManager.default.fileExists(atPath: a.repo) ? a.repo : NSHomeDirectory()
        let pane = workspace.openAgentTab(name: a.name, cwd: cwd)
        launchSpecs[pane] = PaneLaunch(agent: a.name, argv: argv, shellCommand: provider.shellCommand(argv: argv))
        panes[name] = pane
        status[name] = .idle
        workspace.setResume(.agent(name: a.name), pane: pane)   // survives a crash, not just a clean quit
        return pane
    }

    /// Fresh wake only (a running seat returned above and never gets here). Applies T3's fallback rule over the
    /// routing file, usage windows and provider facts. The change is in memory for this pane's life; persist() undoes it.
    private func applyFallback(_ a: Agent, explicitModel: Bool) -> Agent? {
        guard a.duty == nil, a.role != .watcher, let i = agents.firstIndex(where: { $0.name == a.name }) else { return nil }
        if declinedFallback.remove(a.name) != nil { return nil }
        let routing = routingStore.load()
        let project = routing.projects[a.repo]
        guard let fallback = project?.fallbackModel else { return nil }
        let chosen = a.provider ?? project?.defaultModel?.provider ?? .claude
        let now = clock()
        let windows = UsageTestSwitch.apply(usageWindows(), on: UsageTestSwitch.isOn(), now: now)
        func facts(_ p: SeatProvider) -> ProviderFacts {
            let f = providerFacts(p)
            return ProviderFacts(installed: f.installed, enabled: !routing.disabledProviders.contains(p), signIn: f.signIn,
                                 windows: windows.filter { $0.provider.rawValue == p.rawValue })
        }
        guard case let .useFallback(card) = FallbackOnWake.decide(
            chosen: chosen, chosenFacts: facts(chosen), fallback: fallback, fallbackFacts: facts(fallback.provider),
            explicitModel: explicitModel, isFreshWake: true, now: now) else { return nil }
        var changed = a
        changed.provider = fallback.provider
        if fallback.provider == .claude, let m = fallback.model.flatMap(AgentModel.init(rawValue:)) { changed.model = m }
        beforeFallback[a.name] = a
        fallbackCards[a.name] = card
        agents[i] = changed
        return changed
    }

    /// What goes to agents.json: a fallback wake's in-memory provider/model are put back to the saved ones.
    private func persist() {
        store.save(agents.map { a in
            guard let saved = beforeFallback[a.name] else { return a }
            var x = a; x.provider = saved.provider; x.model = saved.model; return x
        })
    }
    /// The card's "Use Claude" button: end the fallback pane; the seat wakes again on its own provider, and that
    /// one wake does not fall back again. A running turn is never switched in place.
    func useOriginal(_ name: String) {
        guard fallbackCards[name] != nil else { return }
        declinedFallback.insert(name)
        sleep(name)
    }
    private func revertFallback(_ name: String) {
        fallbackCards[name] = nil
        guard let saved = beforeFallback.removeValue(forKey: name), let i = agents.firstIndex(where: { $0.name == name }) else { return }
        agents[i].provider = saved.provider; agents[i].model = saved.model
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
        PaneDelivery.interrupts.reset(pane)
        launchSpecs[pane] = nil
        latest[pane] = nil
        contexts[pane] = nil
        modes[pane] = nil
        if let n = name(for: pane) {
            panes[n] = nil
            revertFallback(n)
            startedSeats.remove(n)
            startupIssues[n] = nil
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
            if agent(named: name).map({ seatProvider(for: $0).startsOnFirstPrompt }) == true { watchCodexStartup(name, pane: pane) }
            PaneDelivery.write(body, intent: .prompt, to: pane, onOutcome: onOutcome)
            return
        }
        if let agent = agent(named: name), seatProvider(for: agent).startsOnFirstPrompt {
            guard let pane = wake(name, initialPrompt: body) else { onOutcome?(.noPane); return }
            watchCodexStartup(name, pane: pane)
            onOutcome?(.unverified) // submitted by argv; session hook, not launch, proves acceptance
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

    private func watchCodexStartup(_ name: String, pane: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.startupTimedOut(name, pane: pane)
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
            merged.sessions = agents[i].sessions
            if isAwake(a.name) { merged.provider = agents[i].provider }
            agents[i] = merged
        } else {
            agents.append(a)
        }
        persist()
    }

    func delete(_ name: String) {
        sleep(name)
        agents.removeAll { $0.name == name }
        beforeFallback[name] = nil; fallbackCards[name] = nil; declinedFallback.remove(name)
        persist()
    }
}
