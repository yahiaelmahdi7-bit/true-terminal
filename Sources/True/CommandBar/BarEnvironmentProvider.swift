import Foundation
import AppKit

/// Reads the live app (workspace, registry, project config) into the plain values the router takes.
enum BarEnvironmentProvider {
    @MainActor
    static func live(workspace: WorkspaceModel = .shared, registry: AgentRegistry = .shared) -> BarEnvironment {
        let cfg = ProjectStore().load()
        let projects = ProjectList.build(cfg)
        let tab = workspace.selectedTab
        let pane = tab.focusedPane
        let cwd = TerminalRegistry.shared.cwd(of: pane) ?? tab.cwds[pane]
        let project = cwd.flatMap { c in
            projects.filter { c == $0.path || c.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
        }
        let seat = registry.name(for: pane)
        let kind: PaneKind = seat != nil ? .seat : (registry.latest[pane] != nil ? .claude : .shell)
        let seats = registry.crew.map { a in
            BarSeat(name: a.name, project: (a.repo as NSString).lastPathComponent, awake: registry.panes[a.name] != nil)
        }
        return BarEnvironment(focused: FocusedPane(kind: kind, project: project?.name, seat: seat, cwd: cwd),
                              projects: projects, recent: cfg.recent.map(\.path), seats: seats)
    }

    /// Is `name` an executable on the login PATH (plus the usual Homebrew folders)? Plain file checks, no process.
    static func onPath(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/") else { return false }
        let home = NSHomeDirectory()
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "\(home)/.local/bin"]
        return dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }
}

enum TerminalFocus {
    /// Hands the keyboard back to the focused terminal after an overlay closes (one short hop: the view may be new).
    @MainActor
    static func refocus(workspace: WorkspaceModel = .shared) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            let pane = workspace.selectedTab.focusedPane
            if let v = TerminalRegistry.shared.view(for: pane), let w = v.window { w.makeFirstResponder(v) }
        }
    }
}
