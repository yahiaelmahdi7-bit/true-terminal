import AppKit

/// Click on a crew agent: stage `Use the <name> agent to ` in the focused pane when a Claude session
/// runs there (PaneDelivery is the one door), else copy it. Returns the notice to show, nil on success.
@MainActor
enum CrewDelivery {
    static let copiedNotice = "Copied. Paste it into a Claude pane."

    static func pick(_ agent: CrewAgent, workspace: WorkspaceModel = .shared) -> String? {
        let text = CrewStarter.text(for: agent)
        let pane = workspace.selectedTab.focusedPane
        // Claude in this pane = an awake seat, or an interactive Claude found under the pane's shell
        // (the same probe session resume uses).
        let runsClaude = AgentRegistry.shared.name(for: pane) != nil || SessionSnapshot.probe(pane).found != nil
        var staged = false
        if runsClaude {
            // `.stage` calls back synchronously (PaneDelivery.write), so `staged` is final on the next line.
            PaneDelivery.write(text, intent: .stage, to: pane) { staged = ($0 == .staged) }
        }
        if staged {
            // Hand the keyboard back so the user can keep typing the task.
            workspace.focus(pane: pane)
            if let v = TerminalRegistry.shared.view(for: pane) { v.window?.makeFirstResponder(v) }
            return nil
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return copiedNotice
    }
}
