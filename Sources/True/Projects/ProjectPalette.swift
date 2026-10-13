import Foundation
import AppKit
import Observation

/// State behind the Open Project palette (⌘O). The list is rebuilt off the main actor every time the
/// palette opens — nothing watches disk, so it costs nothing while closed.
@MainActor
@Observable
final class ProjectPalette {
    static let shared = ProjectPalette()

    /// What one row shows besides its name: read from plain files (never a git process).
    struct Detail: Equatable, Sendable {
        var branch: String?
        var handoff: Bool
    }

    private struct Snapshot: Sendable {
        var config: ProjectConfig
        var projects: [Project]
        var details: [String: Detail]
    }

    var isOpen = false
    var query = "" { didSet { highlight = 0 } }
    var highlight = 0
    private(set) var projects: [Project] = []
    private(set) var details: [String: Detail] = [:]
    private(set) var loading = false

    @ObservationIgnored private var config = ProjectConfig.defaults
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let workspace: WorkspaceModel
    @ObservationIgnored private var generation = 0

    init(store: ProjectStore = ProjectStore(), workspace: WorkspaceModel = .shared) {
        self.store = store
        self.workspace = workspace
    }

    /// The rows in display order for the current query.
    var visible: [Project] {
        ProjectMatcher.rank(projects, query: query, recent: config.recent.map(\.path))
    }

    // MARK: Open / close

    func toggle() { isOpen ? close() : show() }

    func show() {
        query = ""
        highlight = 0
        isOpen = true
        reload()
    }

    /// Closes and hands the keyboard back to the focused terminal.
    func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1   // a load still in flight must not repopulate a closed palette
        refocusTerminal()
    }

    private func reload() {
        generation += 1
        let mine = generation
        loading = true
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let cfg = store.load()
            let list = ProjectList.build(cfg)
            var details: [String: Detail] = [:]
            for p in list {
                details[p.path] = Detail(branch: ProjectList.branch(of: p.path), handoff: ProjectList.hasHandoff(at: p.path))
            }
            let snap = Snapshot(config: cfg, projects: list, details: details)
            await MainActor.run { [weak self] in self?.apply(snap, generation: mine) }
        }
    }

    private func apply(_ s: Snapshot, generation g: Int) {
        guard g == generation else { return }
        config = s.config
        projects = s.projects
        details = s.details
        loading = false
    }

    // MARK: Keys

    /// ↑/↓ with wrap-around.
    func move(by delta: Int) {
        let n = visible.count
        guard n > 0 else { return }
        highlight = ((highlight + delta) % n + n) % n
    }

    func openHighlighted(withClaude: Bool) {
        let rows = visible
        guard rows.indices.contains(highlight) else { return }
        open(rows[highlight], withClaude: withClaude)
    }

    /// A split beside the focused pane, in the project's folder; with Claude, the pane boots into `claude` and falls back to a shell.
    func open(_ p: Project, withClaude: Bool) {
        config.recordOpen(p.path)
        store.save(config)
        isOpen = false
        generation += 1
        workspace.openProjectBeside(path: p.path, startupCommand: withClaude ? PaneStartup.claudeCommand(settings: AgentPaths.standard.paneSettingsPath) : nil)
        refocusTerminal()
    }

    // MARK: Add Folder…

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.config.pin(url.path)
                self.store.save(self.config)
                if self.isOpen { self.reload() }
            }
        }
    }

    // MARK: Focus

    /// Focus lands on the (new) pane's terminal. The NSView may not be in the window yet on the same
    /// turn, so this is one short deferred hop — not a poll.
    private func refocusTerminal() {
        Task { @MainActor [workspace] in
            try? await Task.sleep(for: .milliseconds(80))
            let pane = workspace.selectedTab.focusedPane
            if let v = TerminalRegistry.shared.view(for: pane), let w = v.window { w.makeFirstResponder(v) }
        }
    }
}
