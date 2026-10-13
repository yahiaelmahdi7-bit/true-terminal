import Testing
import Foundation
@testable import True

@Suite struct WorkspaceTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("true-test-\(UUID().uuidString)").appendingPathComponent("workspace.json")
    }

    func threeTabs() -> WorkspaceState {
        var s = WorkspaceState.fresh(cwd: "/tmp")
        _ = s.addTab(cwd: "/usr"); _ = s.addTab(cwd: "/var")
        return s
    }

    @Test func roundTrip() throws {
        var s = threeTabs()
        let t = s.tabs[0]
        let new = UUID()
        s.tabs[0].tree = t.tree.inserting(new, beside: t.focusedPane, axis: .horizontal, fraction: 0.3)
        s.tabs[0].cwds[new] = "/etc"
        s.tabs[0].customName = "build"
        let url = tempURL()
        let store = WorkspaceStore(url: url)
        store.save(s)
        #expect(store.load() == s)
    }

    @Test func corruptFileFallsBackAndIsKeptAside() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json {{".utf8).write(to: url)
        let s = WorkspaceStore(url: url).load()
        #expect(s.tabs.count == 1 && s.isConsistent)
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("workspace.corrupt.json").path))
    }

    @Test func missingFileIsFresh() {
        #expect(WorkspaceStore(url: tempURL()).load().tabs.count == 1)
    }

    @Test func inconsistentStateFallsBack() {
        var s = threeTabs()
        s.selectedTab = UUID()                 // selection points nowhere
        #expect(!s.isConsistent)
        var s2 = threeTabs()
        s2.tabs[0].focusedPane = UUID()        // focus not a leaf
        #expect(!s2.isConsistent)
        var s3 = threeTabs()
        s3.tabs[1].tree = s3.tabs[0].tree      // pane ids repeat across tabs
        s3.tabs[1].focusedPane = s3.tabs[0].focusedPane
        #expect(!s3.isConsistent)
        let url = tempURL()
        let store = WorkspaceStore(url: url)
        store.save(s)
        let loaded = store.load()
        #expect(loaded.isConsistent && loaded != s)
    }

    @Test func tabSelectionAndCycling() {
        var s = threeTabs()
        let ids = s.tabs.map(\.id)
        s.selectTab(number: 1); #expect(s.selectedTab == ids[0])
        s.selectTab(number: 3); #expect(s.selectedTab == ids[2])
        s.selectTab(number: 9); #expect(s.selectedTab == ids[2])   // out of range: unchanged
        s.cycleTab(by: 1);      #expect(s.selectedTab == ids[0])   // wraps forward
        s.cycleTab(by: -1);     #expect(s.selectedTab == ids[2])   // wraps back
    }

    @Test func newTabOpensAfterCurrent() {
        var s = threeTabs()
        s.selectTab(number: 1)
        let t = s.addTab(cwd: "/x")
        #expect(s.tabs[1].id == t.id && s.selectedTab == t.id)
    }

    @Test func moveTab() {
        var s = threeTabs()
        let ids = s.tabs.map(\.id)
        s.moveTab(ids[2], onto: ids[0])
        #expect(s.tabs.map(\.id) == [ids[2], ids[0], ids[1]])
        s.moveTab(ids[2], toIndex: 99)
        #expect(s.tabs.map(\.id) == [ids[0], ids[1], ids[2]])
    }

    @Test func closePaneMovesFocusAndSelection() {
        var s = WorkspaceState.fresh(cwd: "/tmp")
        let t = s.tabs[0]
        let p2 = UUID()
        s.tabs[0].tree = t.tree.inserting(p2, beside: t.focusedPane, axis: .horizontal)
        s.tabs[0].focusedPane = p2
        let alive = s.closePane(p2, inTab: t.id)
        #expect(alive)
        #expect(s.tabs[0].focusedPane == t.focusedPane && s.isConsistent)

        var m = threeTabs()
        let ids = m.tabs.map(\.id)
        m.selectTab(number: 2)
        let mAlive = m.closePane(m.tabs[1].focusedPane, inTab: ids[1])
        #expect(mAlive)
        #expect(m.tabs.count == 2 && m.selectedTab == ids[2] && m.isConsistent)

        var one = WorkspaceState.fresh()
        let oneAlive = one.closePane(one.tabs[0].focusedPane, inTab: one.tabs[0].id)
        #expect(!oneAlive) // last pane: empty → app quits
    }

    @Test func tabTitle() {
        var t = TabState(cwd: NSHomeDirectory())
        #expect(t.title == "~")
        t.cwds[t.focusedPane] = "/Users/x/Projects/true"
        #expect(t.title == "true")
        t.customName = "  api "
        #expect(t.title == "api")
    }

    // MARK: Open Project as a split (⌘O)

    @MainActor @Test func openProjectSplitsBesideFocusedPaneInSelectedTab() {
        let m = WorkspaceModel(store: WorkspaceStore(url: tempURL()))
        _ = m.state.addTab(cwd: "/usr")          // two tabs; the new one is selected
        let before = m.state.tabs.count
        let tab = m.selectedTab
        let name = "keep me"
        m.rename(tab: tab.id, to: name)
        let new = m.openProjectBeside(path: "/tmp/proj", startupCommand: "echo hi")
        let after = m.selectedTab
        #expect(m.state.tabs.count == before)                       // no new tab
        #expect(after.id == tab.id && after.customName == name)     // same tab, name untouched
        #expect(after.tree.leafIDs == [tab.focusedPane, new])       // beside the focused pane
        #expect(after.focusedPane == new && after.cwds[new] == "/tmp/proj")
        #expect(PaneStartup.shared.take(new) == "echo hi")          // startup on the NEW pane only
        #expect(PaneStartup.shared.take(tab.focusedPane) == nil)
        let plain = m.openProjectBeside(path: "/tmp/other", startupCommand: nil)
        #expect(PaneStartup.shared.take(plain) == nil)
    }

    @MainActor @Test func splitFocusedInheritsCwd() {
        let m = WorkspaceModel(store: WorkspaceStore(url: tempURL()))
        let first = m.selectedTab.focusedPane
        m.updateCwd(pane: first, "/var")
        m.splitFocused(.vertical)
        let t = m.selectedTab
        #expect(t.tree.leafIDs.count == 2 && t.cwds[t.focusedPane] == "/var")
    }
}
