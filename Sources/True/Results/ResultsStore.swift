import AppKit
import Observation
import SwiftTerm

/// The Results sheet's state. One load each time the sheet opens; no watcher, no timer.
@MainActor @Observable
final class ResultsStore {
    static let shared = ResultsStore()

    enum Phase: Equatable {
        case loading, noSession, notFound, empty
        case loaded([TurnResult])
    }

    var isOpen = false
    var phase: Phase = .loading
    /// Folder name of the session's cwd, for the sheet title.
    var folder = ""
    /// Result id whose "Show in Terminal" found nothing.
    var notInScrollback: Int?
    private var pane: UUID?
    private var loadTask: Task<Void, Never>?

    /// A Claude session id and the folder it runs in.
    struct Session: Equatable { var id: String; var cwd: String }

    /// An awake seat's last session id (AgentRegistry), else the interactive Claude under the pane's shell
    /// (the same signal the Crew tab uses).
    static func session(for pane: UUID, registry: AgentRegistry = .shared) -> Session? {
        if let name = registry.name(for: pane), let a = registry.agents.first(where: { $0.name == name }),
           let id = a.lastSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           UUID(uuidString: id) != nil {
            return Session(id: id, cwd: a.repo.isEmpty ? NSHomeDirectory() : a.repo)
        }
        if let f = SessionSnapshot.probe(pane).found { return Session(id: f.sessionID, cwd: f.cwd) }
        return nil
    }

    func open(workspace: WorkspaceModel = .shared) {
        let pane = workspace.selectedTab.focusedPane
        self.pane = pane
        notInScrollback = nil
        loadTask?.cancel()
        isOpen = true
        guard let s = Self.session(for: pane) else { folder = ""; phase = .noSession; return }
        folder = (s.cwd as NSString).lastPathComponent
        let url = AgentLaunch.transcriptURL(id: s.id, cwd: s.cwd)
        guard FileManager.default.fileExists(atPath: url.path) else { phase = .notFound; return }
        phase = .loading
        // Launch-adjacent side effect justified: one off-main tail read when the sheet opens (user action);
        // nothing watches the file and nothing repeats.
        loadTask = Task {
            let results = await Task.detached(priority: .userInitiated) { ResultsLoader.load(url: url) }.value
            guard !Task.isCancelled else { return }
            switch results {
            case nil: phase = .notFound
            case let r? where r.isEmpty: phase = .empty
            case let r?: phase = .loaded(r)
            }
        }
    }

    func close() { loadTask?.cancel(); isOpen = false }

    /// Best effort: find the result in the pane's buffer and scroll/select it. False = not found (the sheet
    /// stays open). Never writes to the PTY.
    @discardableResult
    func showInTerminal(_ r: TurnResult, workspace: WorkspaceModel = .shared) -> Bool {
        guard let pane, let view = TerminalRegistry.shared.view(for: pane),
              let probe = ResultsProbe.build(r.markdown) else { notInScrollback = r.id; return false }
        let term = view.getTerminal()
        let text = String(decoding: term.getBufferAsData(kind: .normal), as: UTF8.self)
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let hit = ResultsProbe.find(probe, in: rows) else { notInScrollback = r.id; return false }
        notInScrollback = nil
        close()
        // Match rows to the top (a little context above), then select them: the selection is the highlight.
        view.scrollTo(row: max(0, hit.first - 1))
        view.selection.setSelection(start: Position(col: 0, row: hit.first),
                                    end: Position(col: max(0, term.cols - 1), row: hit.last))
        // Focus after the sheet has gone, or its dismissal takes the keyboard back.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            workspace.focus(pane: pane)
            view.window?.makeFirstResponder(view)
        }
        return true
    }
}
