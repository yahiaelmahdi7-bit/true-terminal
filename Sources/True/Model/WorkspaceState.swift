import Foundation

/// One tab: a split tree plus what the user has named/focused. Pure data, `Codable`.
struct TabState: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// User's custom name (double-click to rename). Empty/nil means "use the cwd basename".
    var customName: String?
    var tree: SplitTree
    var focusedPane: UUID
    /// Last known working directory per pane. Drives the tab title and where a restored shell starts.
    var cwds: [UUID: String]
    /// What to bring back in a pane on the next launch (a Claude conversation, or an awake agent).
    /// Optional so a workspace.json written before this field existed still decodes.
    var resume: [UUID: PaneResume]?
    /// Panes whose Claude was working or waiting on the user when True quit: the next launch resumes
    /// them with a "continue" prompt, once. Optional so older files decode.
    var interrupted: Set<UUID>?

    init(id: UUID = UUID(), customName: String? = nil, pane: UUID = UUID(), cwd: String) {
        self.id = id
        self.customName = customName
        self.tree = .leaf(pane)
        self.focusedPane = pane
        self.cwds = [pane: cwd]
    }

    /// Tab title = custom name, else the focused pane's cwd basename.
    var title: String {
        if let n = customName?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        let path = cwds[focusedPane] ?? cwds.values.first ?? "~"
        let base = Self.basename(path)
        if let peer = cwds.keys.compactMap({ PeerOrigin.shared.label(for: $0) }).first { return base + " · from \(peer)" }
        return cwds.keys.contains(where: { RemoteOrigin.shared.isRecent($0) }) ? base + " · from iPhone" : base
    }

    static func basename(_ path: String) -> String {
        if path == NSHomeDirectory() || path == "~" { return "~" }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? "/" : last
    }
}

/// The whole window's content: ordered tabs + which one is selected. This is what gets autosaved.
struct WorkspaceState: Codable, Equatable, Sendable {
    /// Bump when the on-disk shape changes incompatibly.
    static let currentVersion = 1
    var version: Int = WorkspaceState.currentVersion
    var tabs: [TabState]
    var selectedTab: UUID

    static func fresh(cwd: String = NSHomeDirectory()) -> WorkspaceState {
        let t = TabState(cwd: cwd)
        return WorkspaceState(tabs: [t], selectedTab: t.id)
    }

    // MARK: Validity

    /// A decoded file is only trusted if it is internally consistent: at least one tab, the
    /// selection exists, every tab's focus is one of its leaves, and no pane id repeats. Anything
    /// else falls back to a fresh workspace rather than crashing or showing a half-broken window.
    var isConsistent: Bool {
        guard version == Self.currentVersion, !tabs.isEmpty,
              tabs.contains(where: { $0.id == selectedTab }) else { return false }
        var seen = Set<UUID>()
        for t in tabs {
            let leaves = t.tree.leafIDs
            guard t.tree.leafIDs.contains(t.focusedPane) else { return false }
            for l in leaves where !seen.insert(l).inserted { return false }
        }
        return true
    }

    // MARK: Tab ordering

    var selectedIndex: Int { tabs.firstIndex { $0.id == selectedTab } ?? 0 }

    /// ⌘1–9: jump to the nth tab (1-based). ⌘9 is NOT "last" here — the spec says 1–9 jump.
    mutating func selectTab(number n: Int) {
        guard n >= 1, n <= tabs.count else { return }
        selectedTab = tabs[n - 1].id
    }

    /// ⌃Tab / ⌃⇧Tab / ⌘⇧[ ⌘⇧]: cycle with wraparound.
    mutating func cycleTab(by delta: Int) {
        guard !tabs.isEmpty else { return }
        let n = tabs.count
        selectedTab = tabs[((selectedIndex + delta) % n + n) % n].id
    }

    /// Drag-to-reorder: move `tab` so it sits at `index` (index into the array AFTER removal).
    mutating func moveTab(_ tab: UUID, toIndex index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tab }) else { return }
        let t = tabs.remove(at: from)
        tabs.insert(t, at: min(max(0, index), tabs.count))
    }

    /// Drop `tab` onto the slot currently held by `target` (what a drag-over gesture reports).
    mutating func moveTab(_ tab: UUID, onto target: UUID) {
        guard tab != target, let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        moveTab(tab, toIndex: to)
    }

    // MARK: Mutation used by the model

    mutating func addTab(cwd: String) -> TabState {
        let t = TabState(cwd: cwd)
        // New tab opens right after the current one, like every Mac tabbed app.
        tabs.insert(t, at: selectedIndex + 1)
        selectedTab = t.id
        return t
    }

    /// Close one pane. Removes the tab when it was the last pane; returns false when the
    /// workspace became empty (caller decides — True quits, like Terminal.app, when the last tab goes).
    @discardableResult
    mutating func closePane(_ pane: UUID, inTab tabID: UUID) -> Bool {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return !tabs.isEmpty }
        let tab = tabs[i]
        if let newTree = tab.tree.removingEvened(pane) {
            var t = tab
            // Focus the pane that took the space — the previous leaf in reading order.
            let old = tab.tree.leafIDs
            t.tree = newTree
            t.cwds[pane] = nil
            t.resume?[pane] = nil
            t.interrupted?.remove(pane)
            if t.focusedPane == pane {
                let idx = old.firstIndex(of: pane) ?? 0
                let remaining = newTree.leafIDs
                t.focusedPane = remaining[min(max(0, idx - 1), remaining.count - 1)]
            }
            tabs[i] = t
        } else {
            tabs.remove(at: i)
            if selectedTab == tabID, !tabs.isEmpty {
                selectedTab = tabs[min(i, tabs.count - 1)].id
            }
        }
        return !tabs.isEmpty
    }
}
