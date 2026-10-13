import Testing
import Foundation
@testable import True

private func tmp() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("true-restore-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite struct ResumeRecordTests {
    @Test func v1FileWithoutResumeFieldDecodes() throws {
        // Build the v1 fixture from a real encode with the new field stripped (SplitTree's shape is its own).
        let s = WorkspaceState.fresh(cwd: "/tmp")
        let data = try JSONEncoder().encode(s)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var tabs = obj["tabs"] as! [[String: Any]]
        #expect(tabs[0]["resume"] == nil)          // nil optional is omitted: identical to a v1 file
        tabs[0].removeValue(forKey: "resume")
        obj["tabs"] = tabs
        let v1 = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(WorkspaceState.self, from: v1)
        #expect(back.isConsistent && back.version == 1 && back.tabs[0].resume == nil)
    }

    @Test func roundTripWithRecords() throws {
        var s = WorkspaceState.fresh(cwd: "/tmp")
        let p = s.tabs[0].focusedPane
        s.tabs[0].resume = [p: .claude(sessionID: "9176169f-0000-4000-8000-000000000001", cwd: "/tmp")]
        let store = WorkspaceStore(url: tmp().appendingPathComponent("w.json"))
        store.save(s)
        #expect(store.load() == s)
        s.tabs[0].resume = [p: .agent(name: "hub-lead")]
        store.save(s)
        #expect(store.load() == s)
    }

    @Test func closePanePrunesRecord() {
        var s = WorkspaceState.fresh(cwd: "/tmp")
        let a = s.tabs[0].focusedPane
        let b = UUID()
        s.tabs[0].tree = s.tabs[0].tree.inserting(b, beside: a, axis: .horizontal)
        s.tabs[0].cwds[b] = "/usr"
        s.tabs[0].resume = [a: .agent(name: "x"), b: .agent(name: "y")]
        s.closePane(b, inTab: s.tabs[0].id)
        #expect(s.tabs[0].resume?[b] == nil && s.tabs[0].resume?[a] == .agent(name: "x"))
    }
}

@Suite struct ClaudeSessionsTests {
    func write(_ dir: URL, _ pid: pid_t, kind: String = "interactive", id: String = "sid") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"/work","kind":"\#(kind)"}"#.utf8)
            .write(to: dir.appendingPathComponent("\(pid).json"))
    }
    let tree: [pid_t: [pid_t]] = [1: [2], 2: [3, 4], 3: [5], 4: []]

    @Test func nestedFound() throws {
        let d = tmp()
        try write(d, 5, id: "deep")
        let f = ClaudeSessions.find(under: 1, sessionsDir: d) { self.tree[$0] ?? [] }
        #expect(f == .init(sessionID: "deep", cwd: "/work", pid: 5))
    }

    @Test func shallowestWins() throws {
        let d = tmp()
        try write(d, 5, id: "deep"); try write(d, 4, id: "shallow")
        #expect(ClaudeSessions.find(under: 1, sessionsDir: d) { self.tree[$0] ?? [] }?.sessionID == "shallow")
    }

    @Test func nonInteractiveMissingAndGarbageIgnored() throws {
        let d = tmp()
        try write(d, 2, kind: "sdk", id: "a")
        try Data("not json".utf8).write(to: d.appendingPathComponent("3.json"))
        #expect(ClaudeSessions.find(under: 1, sessionsDir: d) { self.tree[$0] ?? [] } == nil)
        try write(d, 5, id: "ok")
        #expect(ClaudeSessions.find(under: 1, sessionsDir: d) { self.tree[$0] ?? [] }?.sessionID == "ok")
    }

    @Test func depthLimit() throws {
        let d = tmp()
        try write(d, 7)
        let chain: [pid_t: [pid_t]] = [1: [2], 2: [3], 3: [4], 4: [5], 5: [6], 6: [7]]
        #expect(ClaudeSessions.find(under: 1, sessionsDir: d) { chain[$0] ?? [] } == nil)   // depth 6 > 5
    }
}

@Suite @MainActor struct ResumeStartupTests {
    let id = "9176169f-0000-4000-8000-000000000001"

    @Test func commandStringAndQuoting() {
        #expect(PaneStartup.resumeCommand(sessionID: id, settings: "/a b/it's.json")
                == "claude --resume \(id) --settings '/a b/it'\\''s.json'; exec \"${SHELL:-/bin/zsh}\" -l")
        #expect(PaneStartup.resumeCommand(sessionID: "x; rm -rf /", settings: "/s") == nil)
    }

    func workspace(resume: PaneResume, cwd: String) -> (WorkspaceState, UUID) {
        var s = WorkspaceState.fresh(cwd: "/tmp")
        let p = s.tabs[0].focusedPane
        s.tabs[0].resume = [p: resume]
        return (s, p)
    }

    @Test func transcriptPresentResumesInRecordedCwd() throws {
        let claude = tmp()
        let proj = claude.appendingPathComponent("projects/-work-a-b")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try Data().write(to: proj.appendingPathComponent("\(id).jsonl"))
        let (s, p) = workspace(resume: .claude(sessionID: id, cwd: "/work/a.b"), cwd: "/tmp")
        let r = ResumePlan.apply(s, claudeDir: claude, settings: "/s.json")
        #expect(r.startups[p] == PaneStartup.resumeCommand(sessionID: id, settings: "/s.json"))
        #expect(r.state.tabs[0].cwds[p] == "/work/a.b")
    }

    @Test func transcriptMissingMeansPlainShellAndRecordDropped() {
        let (s, p) = workspace(resume: .claude(sessionID: id, cwd: "/work"), cwd: "/tmp")
        let r = ResumePlan.apply(s, claudeDir: tmp(), settings: "/s.json")
        #expect(r.startups.isEmpty && r.state.tabs[0].resume == nil && r.state.tabs[0].cwds[p] == "/tmp")
    }

    @Test func dropReasonsAreNamed() throws {
        let (s, p) = workspace(resume: .claude(sessionID: id, cwd: "/work"), cwd: "/tmp")
        let missing = ResumePlan.apply(s, claudeDir: tmp(), settings: "/s.json")
        #expect(missing.dropped == [.init(pane: p, sessionID: id, reason: .transcriptMissing)] && missing.records == 1)
        let (b, q) = workspace(resume: .claude(sessionID: "not-a-uuid", cwd: "/work"), cwd: "/tmp")
        let bad = ResumePlan.apply(b, claudeDir: tmp(), settings: "/s.json")
        #expect(bad.dropped == [.init(pane: q, sessionID: "not-a-uuid", reason: .invalidSessionID)])
        let none = ResumePlan.apply(.fresh(cwd: "/tmp"), claudeDir: tmp(), settings: "/s.json")
        #expect(none.records == 0 && none.dropped.isEmpty)
    }

    @Test func quitSummaryListsShortIds() {
        let (s, _) = workspace(resume: .claude(sessionID: id, cwd: "/work"), cwd: "/tmp")
        #expect(SessionSnapshot.quitSummary(s).hasPrefix("quit snapshot: recorded 1 session(s) across 1 tab(s): \(id.prefix(8))"))
        #expect(SessionSnapshot.quitSummary(.fresh(cwd: "/tmp")).contains("recorded 0 session(s)"))
    }

    @Test func modelRegistersStartupBeforeAnyView() throws {
        let claude = tmp()
        let proj = claude.appendingPathComponent("projects/-work")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try Data().write(to: proj.appendingPathComponent("\(id).jsonl"))
        let (s, p) = workspace(resume: .claude(sessionID: id, cwd: "/work"), cwd: "/tmp")
        let store = WorkspaceStore(url: tmp().appendingPathComponent("w.json"))
        store.save(s)
        let startup = PaneStartup()
        _ = WorkspaceModel(store: store, claudeDir: claude, settings: "/s.json", startup: startup)
        #expect(startup.take(p)?.hasPrefix("claude --resume \(id) --settings '/s.json'") == true)
        #expect(startup.take(p) == nil)
    }

    @Test func snapshotKeepsRecordWhenViewGoneAndClearsWhenClaudeExited() {
        let ws = WorkspaceModel(store: WorkspaceStore(url: tmp().appendingPathComponent("w.json")),
                                claudeDir: tmp(), startup: PaneStartup())
        let p = ws.selectedTab.focusedPane
        let rec = PaneResume.claude(sessionID: id, cwd: "/work")
        ws.setResume(rec, pane: p)
        ws.recordResume { _ in (false, nil) }                 // view gone: keep
        #expect(ws.selectedTab.resume?[p] == rec)
        ws.recordResume { _ in (true, .init(sessionID: self.id, cwd: "/w2", pid: 9)) }
        #expect(ws.selectedTab.resume?[p] == .claude(sessionID: id, cwd: "/w2"))
        ws.recordResume { _ in (true, nil) }                  // shell alive, no Claude: clear
        #expect(ws.selectedTab.resume == nil)
    }
}

@Suite @MainActor struct AgentRestoreTests {
    @Test func awakeAgentsComeBackInTheSamePaneAndUnknownAreDropped() throws {
        let dir = tmp()
        let sid = "9176169f-0000-4000-8000-000000000002"
        let proj = dir.appendingPathComponent("projects/-tmp-app")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try Data().write(to: proj.appendingPathComponent("\(sid).jsonl"))
        var a = Agent(name: "lead-app", role: .lead, repo: "/tmp/app")
        a.lastSessionID = sid
        let store = AgentStore(url: dir.appendingPathComponent("agents.json"))
        store.save([a])

        var s = WorkspaceState.fresh(cwd: "/tmp")
        let p1 = s.tabs[0].focusedPane
        let p2 = UUID()
        s.tabs[0].tree = s.tabs[0].tree.inserting(p2, beside: p1, axis: .horizontal)
        s.tabs[0].cwds[p2] = "/tmp"
        s.tabs[0].resume = [p1: .agent(name: "lead-app"), p2: .agent(name: "ghost")]
        let ws = WorkspaceModel(store: WorkspaceStore(url: dir.appendingPathComponent("w.json")),
                                claudeDir: dir, startup: PaneStartup())
        ws.state = s
        let paths = AgentPaths(root: dir)
        let reg = AgentRegistry(store: store, paths: paths, workspace: ws, claudeDir: dir)
        #expect(reg.panes["lead-app"] == p1 && reg.isAwake("lead-app") && reg.statusOf("lead-app") == .idle)
        let spec = try #require(reg.launchSpecs[p1])
        #expect(spec.argv.suffix(2) == ["--resume", sid])
        #expect(reg.panes["ghost"] == nil && reg.launchSpecs[p2] == nil)
        #expect(ws.state.tabs.count == 1 && ws.state.tabs[0].tree.leafIDs == [p1, p2])
        #expect(ws.state.tabs[0].resume?[p2] == nil)
        #expect(ws.state.tabs[0].resume?[p1] == .agent(name: "lead-app"))
    }
}
