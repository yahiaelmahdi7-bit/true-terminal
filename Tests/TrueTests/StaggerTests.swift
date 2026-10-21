import Testing
import Foundation
@testable import True

private func tmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("true-stagger-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// One tab whose leaves are chained into horizontal splits; focus on the first leaf.
private func tab(_ leaves: [UUID]) -> TabState {
    var t = TabState(pane: leaves[0], cwd: "/w")
    t.tree = leaves.dropFirst().reduce(SplitTree.leaf(leaves[0])) {
        .split(id: UUID(), axis: .horizontal, fraction: 0.5, first: $0, second: .leaf($1))
    }
    return t
}

@Suite @MainActor struct StaggerTests {
    @Test func frontPaneFirstThenTwoLanes() {
        let (a, b, c, d, e) = (UUID(), UUID(), UUID(), UUID(), UUID())
        var s = WorkspaceState(tabs: [tab([a, b]), tab([c, d, e])], selectedTab: UUID())
        s.selectedTab = s.tabs[1].id
        s.tabs[1].focusedPane = d
        let cmds = Dictionary(uniqueKeysWithValues: [a, b, c, d, e].map { ($0, "x") })
        let delay = ResumePlan.stagger(cmds, continued: [b, c, e], state: s)
        // Selected tab first with its focused pane in front: quiet lane d now, then a.
        #expect(delay[d] == 0 && delay[a] == ResumePlan.quietGap)
        // Continued lane c, e (selected tab), then b: a minute apart.
        #expect(delay[c] == 0 && delay[e] == ResumePlan.continueGap && delay[b] == 2 * ResumePlan.continueGap)
        #expect(delay.values.filter { $0 == 0 }.count == 2)   // never more than two at once
    }

    @Test func staggeredCommandWaitsAndCtrlCSkips() {
        let cmd = "claude --resume x; exec zsh -l"
        #expect(PaneStartup.staggered(cmd, after: 0) == cmd)
        let s = PaneStartup.staggered(cmd, after: 60)
        #expect(s.hasPrefix("trap 'true' INT; "))
        #expect(s.hasSuffix("sleep 60; trap - INT; " + cmd))
    }

    @Test func launchRegistersStaggeredCommands() throws {
        let claude = tmpDir()
        let proj = claude.appendingPathComponent("projects/-w")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let ids = (1...3).map { "9176169f-0000-4000-8000-00000000000\($0)" }
        for i in ids { try Data().write(to: proj.appendingPathComponent("\(i).jsonl")) }
        let (a, b, c) = (UUID(), UUID(), UUID())
        var s = WorkspaceState(tabs: [tab([a, b, c])], selectedTab: UUID())
        s.selectedTab = s.tabs[0].id
        s.tabs[0].resume = [a: .claude(sessionID: ids[0], cwd: "/w"), b: .claude(sessionID: ids[1], cwd: "/w"),
                            c: .claude(sessionID: ids[2], cwd: "/w")]
        s.tabs[0].interrupted = [b, c]
        let store = WorkspaceStore(url: tmpDir().appendingPathComponent("w.json"))
        store.save(s)
        let startup = PaneStartup()
        let m = WorkspaceModel(store: store, claudeDir: claude, settings: "/s.json", startup: startup)
        // a (front, quiet) and b (first continued) start now; c continues a minute later.
        #expect(startup.take(a) == PaneStartup.resumeCommand(sessionID: ids[0], settings: "/s.json"))
        #expect(startup.take(b) == PaneStartup.resumeCommand(sessionID: ids[1], settings: "/s.json", prompt: ResumePlan.continuePrompt))
        #expect(startup.take(c)?.contains("sleep \(ResumePlan.continueGap); trap - INT; claude --resume \(ids[2])") == true)
        #expect(!m.isWaking(a) && !m.isWaking(b) && m.isWaking(c))
        #expect(m.wakingContinued == [c])
    }

    @Test func waitingPaneKeepsRecordAndOwedContinue() {
        let m = WorkspaceModel(store: WorkspaceStore(url: tmpDir().appendingPathComponent("w.json")), claudeDir: tmpDir())
        let a = m.state.tabs[0].focusedPane, b = UUID()
        m.state.tabs[0].tree = .split(id: UUID(), axis: .horizontal, fraction: 0.5, first: .leaf(a), second: .leaf(b))
        let r = PaneResume.claude(sessionID: "9176169f-0000-4000-8000-000000000001", cwd: "/w")
        m.state.tabs[0].resume = [a: r, b: r]
        m.wakeDeadlines = [a: Date().addingTimeInterval(60)]
        m.wakingContinued = [a]
        // Shells alive, no Claude yet: the waiting pane keeps its record and still owes its continue.
        m.recordResume(probe: { _ in (true, nil) })
        #expect(m.state.tabs[0].resume == [a: r])
        #expect(m.markInterrupted(probe: { _ in (true, nil) }, hook: { _ in nil }) == [a])
        // Its turn has passed: back to the normal rule (no Claude under a live shell = plain shell).
        m.wakeDeadlines = [a: Date().addingTimeInterval(-1)]
        m.recordResume(probe: { _ in (true, nil) })
        #expect(m.state.tabs[0].resume == nil)
    }
}
