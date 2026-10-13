import SwiftUI
import UniformTypeIdentifiers

/// Tabs as plain numbers — 1 2 3, matching ⌘1…⌘9 — drawn INSIDE the title-bar zone (see
/// `WindowChrome.installTabs`), so there is no second strip under it. Numbers appear only with two
/// or more tabs; the needs-you badge only when an agent is blocked. A tab shows a name only if you
/// gave it one (double-click). Empty space drags the window and double-click zooms —
/// `windowChromeArea()` supplies both, since this view covers the whole title bar.
struct TabBar: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 18) {
            if model.state.tabs.count > 1 {
                ForEach(Array(model.state.tabs.enumerated()), id: \.element.id) { i, tab in
                    TabChip(model: model, tab: tab, number: i + 1,
                            selected: tab.id == model.state.selectedTab)
                }
            }
            Spacer(minLength: 0)
            RestartPill(watcher: .shared)
            NeedsYouTray()
        }
        // Numbers start where the terminal's text does, so "1" sits over the prompt's first column.
        .padding(.leading, Theme.paneInsets.leading)
        .padding(.trailing, Theme.paneInsets.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .windowChromeArea()
    }
}

private struct TabChip: View {
    let model: WorkspaceModel
    let tab: TabState
    let number: Int
    let selected: Bool
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if model.renamingTab == tab.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .frame(width: 110)
                    .focused($fieldFocused)
                    .onSubmit { model.rename(tab: tab.id, to: draft) }
                    .onExitCommand { model.renamingTab = nil }
                    .onAppear { draft = tab.customName ?? ""; fieldFocused = true }
            } else {
                Text(label).lineLimit(1).fixedSize().monospacedDigit()
            }
            if let v = OverseerStore.shared.verdict(in: tab), v.kind == .unverified || v.kind == .blocked || v.kind == .asksYou {
                // A tinted pane verdict wins over the seat status, and shows on plain panes too.
                Circle().fill(v.kind.tint).frame(width: 6, height: 6).help("\(v.kind.label) — \(v.reason)")
            } else if let status = AgentRegistry.shared.tabStatus(tab) {
                Circle().fill(status.tint).frame(width: 6, height: 6).help(status.label)
            }
            if hovering {
                Button { closeTab() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .help("Close Tab")
            }
        }
        .font(.system(size: 14, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected || hovering ? Theme.text : Theme.dimText)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.renamingTab = tab.id }
        .onTapGesture { model.select(tab: tab.id) }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let src = UUID(uuidString: s) else { return false }
            model.move(tab: src, onto: tab.id)
            return true
        }
    }

    /// The number, unless the tab was deliberately named.
    private var label: String {
        guard let n = tab.customName?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return "\(number)" }
        return n.count > 28 ? n.prefix(27) + "…" : n
    }

    private func closeTab() {
        // Close every pane of this tab through the model so the last-tab rule applies.
        model.select(tab: tab.id)
        for p in tab.tree.leafIDs { model.paneExited(p) }
    }
}
