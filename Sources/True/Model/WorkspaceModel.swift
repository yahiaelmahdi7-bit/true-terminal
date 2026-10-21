import Foundation
import AppKit
import Observation
import os

/// The single source of truth for the window: tabs, splits, focus. Views read it; commands and
/// terminal callbacks mutate it. Every mutation autosaves, debounced (a cancelled Task, not a timer).
@MainActor
@Observable
final class WorkspaceModel {
    static let shared = WorkspaceModel()

    var state: WorkspaceState {
        didSet { if state != oldValue { scheduleSave() } }
    }
    /// Tab currently being renamed inline (double-click), if any.
    var renamingTab: UUID?

    /// Set by `AgentRegistry`: told when a pane goes away so it can forget the agent that owned it.
    @ObservationIgnored var onPaneClosed: ((UUID) -> Void)?
    /// Set by `AgentRegistry`: is this pane an agent's? Sleeping the only tab must not quit True.
    @ObservationIgnored var isAgentPane: ((UUID) -> Bool)?

    /// Set by `AgentRegistry`: the permission mode this pane's Claude last reported, if any.
    @ObservationIgnored var paneMode: ((UUID) -> String?)?

    /// Set by `AgentRegistry`: the awake agent that owns this pane, if any.
    @ObservationIgnored var agentName: ((UUID) -> String?)?

    @ObservationIgnored private let store: WorkspaceStore
    /// After the quit-time snapshot the shells die and each one's exit would close its pane; a frozen model
    /// ignores those, so the final workspace.json is the one that gets restored.
    @ObservationIgnored private var frozen = false
    /// Agent panes that were interrupted at the last quit; read once by `AgentRegistry.restore`.
    @ObservationIgnored private(set) var interruptedAgentPanes: Set<UUID> = []
    /// Restored panes still waiting their staggered turn, until when (wake time + `wakeGrace` for Claude to
    /// start). Until then a snapshot keeps their record and continue mark: no Claude under the shell is expected.
    @ObservationIgnored var wakeDeadlines: [UUID: Date] = [:]
    @ObservationIgnored var wakingContinued: Set<UUID> = []
    static let wakeGrace: TimeInterval = 30
    @ObservationIgnored private let settings: String
    @ObservationIgnored private let startup: PaneStartup
    /// "Start Claude in new tabs" switch, read at each new tab / fresh launch.
    @ObservationIgnored private let claudeAutostart: () -> Bool
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(store: WorkspaceStore = WorkspaceStore(), claudeDir: URL = AgentLaunch.claudeConfigDir,
         settings: String = AgentPaths.standard.paneSettingsPath, startup: PaneStartup = .shared,
         claudeAutostart: @escaping () -> Bool = { TerminalSettings.claudeAutostart }) {
        self.store = store
        self.settings = settings
        self.startup = startup
        self.claudeAutostart = claudeAutostart
        // Panes that had a Claude conversation restart it with --resume: register their one-shot startup
        // commands now, before any view exists.
        let plan = ResumePlan.apply(store.load(), claudeDir: claudeDir, settings: settings)
        self.state = plan.state
        let delays = ResumePlan.stagger(plan.startups, continued: plan.continued, state: plan.state)
        for (pane, cmd) in plan.startups {
            let d = delays[pane] ?? 0
            startup.set(PaneStartup.staggered(cmd, after: d), for: pane)
            if d > 0 { wakeDeadlines[pane] = Date().addingTimeInterval(TimeInterval(d) + Self.wakeGrace) }
        }
        wakingContinued = Set(plan.continued.filter { wakeDeadlines[$0] != nil })
        // Nothing restored (no workspace.json, or a corrupt one just moved aside): the first pane boots Claude.
        // A restored workspace keeps its own panes: resumed ones above, the rest plain shells.
        if !FileManager.default.fileExists(atPath: store.url.path), claudeAutostart(),
           let first = plan.state.tabs.first?.focusedPane {
            startup.set(PaneStartup.claudeCommand(settings: settings), for: first)
        }
        self.interruptedAgentPanes = plan.interruptedAgents
        Self.logRestore(plan)
        // Marks are consumed: write the cleared state now so a crash before the next save cannot replay "continue".
        // One file write at launch, only when the file carried marks.
        if plan.consumedMarks { store.save(plan.state) }
    }

    private static let log = Logger(subsystem: "True", category: "restore")

    /// One-shot at launch: the "True booted empty" diagnosis. Ids are short and public (not secrets); no paths.
    private static func logRestore(_ plan: ResumePlan.Result) {
        if plan.records == 0 { log.notice("restore: no resume records in workspace.json"); return }
        log.notice("restore: resumed \(plan.startups.count, privacy: .public), dropped \(plan.dropped.count, privacy: .public)")
        let n = plan.continued.count + plan.interruptedAgents.count
        if n > 0 { log.notice("restore: continuing \(n, privacy: .public) interrupted session(s)") }
        for d in plan.dropped {
            log.notice("restore: dropped \(d.sessionID.prefix(8), privacy: .public): \(d.reason.rawValue, privacy: .public)")
        }
    }

    // MARK: Queries

    var selectedTab: TabState { state.tabs[state.selectedIndex] }

    private func index(of tab: UUID) -> Int? { state.tabs.firstIndex { $0.id == tab } }

    private func tabIndex(containing pane: UUID) -> Int? {
        state.tabs.firstIndex { $0.tree.contains(pane) }
    }

    // MARK: Tabs

    func newTab() {
        let cwd = selectedTab.cwds[selectedTab.focusedPane] ?? NSHomeDirectory()
        let tab = state.addTab(cwd: cwd)
        if claudeAutostart() { startup.set(PaneStartup.claudeCommand(settings: settings), for: tab.focusedPane) }
    }

    /// Open Project: a new pane beside the selected tab's focused pane (Split Right), in `path`, focused.
    /// The tab count and its custom name are untouched. `startupCommand` runs once in the new pane
    /// instead of a bare shell; it is never persisted.
    @discardableResult
    func openProjectBeside(path: String, startupCommand: String?) -> UUID {
        let new = split(.horizontal, cwd: path)
        if let c = startupCommand { PaneStartup.shared.set(c, for: new) }
        return new
    }

    /// A new tab with one shell pane in `cwd` (never a split of the tab the Mac is using). Returns that pane.
    @discardableResult
    func openShellTab(cwd: String) -> UUID { state.addTab(cwd: cwd).focusedPane }

    /// Every pane id in every tab.
    var allPanes: Set<UUID> { Set(state.tabs.flatMap { $0.cwds.keys }) }

    /// An ordinary tab, named after the agent, that the registry then starts `claude` in.
    /// Returns the tab's (only) pane.
    @discardableResult
    func openAgentTab(name: String, cwd: String) -> UUID {
        let t = state.addTab(cwd: cwd)
        state.tabs[state.selectedIndex].customName = name
        return t.focusedPane
    }

    func select(tab: UUID) { if index(of: tab) != nil { state.selectedTab = tab } }
    func selectTab(number n: Int) { state.selectTab(number: n) }
    func cycleTab(by d: Int) { state.cycleTab(by: d) }
    func move(tab: UUID, onto target: UUID) { state.moveTab(tab, onto: target) }

    func rename(tab: UUID, to name: String) {
        guard let i = index(of: tab) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.tabs[i].customName = n.isEmpty ? nil : n
        renamingTab = nil
    }

    // MARK: Panes

    func focus(pane: UUID) {
        guard let i = tabIndex(containing: pane) else { return }
        if state.tabs[i].focusedPane != pane { state.tabs[i].focusedPane = pane }
        if state.selectedTab != state.tabs[i].id { state.selectedTab = state.tabs[i].id }
    }

    func splitFocused(_ axis: SplitTree.Axis) { split(axis, cwd: nil) }

    /// The one split path: a new leaf beside the selected tab's focused pane, focused. `cwd` nil = inherit
    /// the focused pane's current directory.
    @discardableResult
    func split(_ axis: SplitTree.Axis, cwd: String?) -> UUID {
        let i = state.selectedIndex
        let tab = state.tabs[i]
        let new = UUID()
        refreshCwd(pane: tab.focusedPane)
        let dir = cwd ?? state.tabs[i].cwds[tab.focusedPane] ?? NSHomeDirectory()
        state.tabs[i].tree = tab.tree.insertingEvened(new, beside: tab.focusedPane, axis: axis)
        state.tabs[i].cwds[new] = dir
        state.tabs[i].focusedPane = new
        return new
    }

    func moveFocus(_ dir: SplitTree.Direction) {
        let i = state.selectedIndex
        let tab = state.tabs[i]
        if let n = tab.tree.neighbor(of: tab.focusedPane, dir) { state.tabs[i].focusedPane = n }
    }

    func closeFocusedPane() {
        let tab = selectedTab
        close(pane: tab.focusedPane)
    }

    func paneExited(_ pane: UUID) { close(pane: pane) }

    private func close(pane: UUID) {
        guard !frozen else { return }
        guard let i = tabIndex(containing: pane) else { return }
        // Putting the last agent to sleep closes the last tab; keep a plain shell so that never quits True.
        if state.tabs.count == 1, state.tabs[i].tree.leafIDs.count == 1, isAgentPane?(pane) == true {
            _ = state.addTab(cwd: NSHomeDirectory())
        }
        onPaneClosed?(pane)
        guard let i = tabIndex(containing: pane) else { return }
        if !state.closePane(pane, inTab: state.tabs[i].id) {
            saveNow()
            NSApp.terminate(nil)
        }
    }

    func setFraction(_ f: Double, split: UUID, tab: UUID) {
        guard let i = index(of: tab) else { return }
        state.tabs[i].tree = state.tabs[i].tree.settingFraction(f, forSplit: split)
    }

    /// Drag-and-drop inside one tab: move `pane` to `zone` of `target`, or swap with it (`.center`).
    /// Only the tree changes — pane UUIDs, cwds and resume records are untouched, and `TerminalArea`
    /// keys terminals by UUID, so the running process and scrollback ride along. The mover is focused.
    func movePane(_ pane: UUID, onto target: UUID, zone: SplitTree.DropZone) {
        guard !frozen, pane != target, let i = tabIndex(containing: pane), tabIndex(containing: target) == i else { return }
        let moved = state.tabs[i].tree.moving(pane, onto: target, zone: zone)
        if moved != state.tabs[i].tree { state.tabs[i].tree = moved }
        state.tabs[i].focusedPane = pane
    }

    /// Even out the row or column a divider belongs to (double-click on it).
    func equalize(split: UUID, tab: UUID) {
        guard let i = index(of: tab) else { return }
        state.tabs[i].tree = state.tabs[i].tree.equalizing(split: split)
    }

    // MARK: Working directories

    func updateCwd(pane: UUID, _ path: String) {
        guard let i = tabIndex(containing: pane), state.tabs[i].cwds[pane] != path else { return }
        state.tabs[i].cwds[pane] = path
    }

    func refreshCwd(pane: UUID) {
        if let p = TerminalRegistry.shared.cwd(of: pane) { updateCwd(pane: pane, p) }
    }

    func syncCwdsFromLivePids() {
        for t in state.tabs { for p in t.tree.leafIDs { refreshCwd(pane: p) } }
    }

    // MARK: Resume records

    /// One pane's record, replaced or cleared. Saves only when something changed.
    func setResume(_ r: PaneResume?, pane: UUID) {
        guard let i = tabIndex(containing: pane), state.tabs[i].resume?[pane] != r else { return }
        var m = state.tabs[i].resume ?? [:]
        m[pane] = r
        state.tabs[i].resume = m.isEmpty ? nil : m
    }

    /// Record what every pane is running. `probe` says whether a pane's shell is alive and which Claude
    /// (if any) runs under it; a pane whose shell is gone keeps its previous record.
    func recordResume(probe: (UUID) -> (alive: Bool, found: ClaudeSessions.Found?)) {
        for t in state.tabs {
            for p in t.tree.leafIDs {
                let (alive, found) = probe(p)
                if found == nil, isWaking(p) { continue }   // not woken yet: keep its record
                setResume(SessionRecorder.decide(previous: t.resume?[p], agent: agentName?(p), alive: alive, found: found,
                                                   mode: paneMode?(p)),
                          pane: p)
            }
        }
    }

    /// Still waiting its staggered turn at launch (see `wakeDeadlines`).
    func isWaking(_ pane: UUID, now: Date = Date()) -> Bool { wakeDeadlines[pane].map { now < $0 } ?? false }

    /// Quit time, after `recordResume`: mark each recorded pane whose Claude was mid-task. Returns the
    /// marked panes. Stale marks are replaced, so only what is interrupted NOW survives.
    @discardableResult
    func markInterrupted(probe: (UUID) -> (alive: Bool, found: ClaudeSessions.Found?),
                         hook: (UUID) -> AgentStatus?) -> [UUID] {
        var marked: [UUID] = []
        for i in state.tabs.indices {
            var set = Set<UUID>()
            for p in state.tabs[i].tree.leafIDs where state.tabs[i].resume?[p] != nil {
                let (alive, found) = probe(p)
                // Quit before a continued pane's turn: it never got to continue, so it still owes it.
                let owed = found == nil && wakingContinued.contains(p) && isWaking(p)
                if alive, owed || SessionRecorder.isInterrupted(found: found, hook: hook(p)) { set.insert(p); marked.append(p) }
            }
            state.tabs[i].interrupted = set.isEmpty ? nil : set
        }
        return marked
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard !frozen else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.store.save(self?.state ?? .fresh())
        }
    }

    /// Quit / window close: record what each pane runs, write the file, then ignore everything after.
    /// Returns false when it was already frozen (nothing ran).
    @discardableResult
    func freeze(record: () -> Void) -> Bool {
        guard !frozen else { return false }
        record()
        saveNow()
        frozen = true
        Self.log.notice("workspace frozen: later saves blocked")
        return true
    }

    func saveNow() {
        guard !frozen else { return }
        saveTask?.cancel()
        syncCwdsFromLivePids()
        store.save(state)
    }
}
