import Testing
import Foundation
@testable import True

private func tmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("true-interrupted-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite @MainActor struct InterruptedTests {
    let id = "9176169f-0000-4000-8000-000000000001"

    private func writeSession(_ dir: URL, pid: Int, status: String?) throws {
        let st = status.map { ",\"status\":\"\($0)\"" } ?? ""
        let json = "{\"sessionId\":\"\(id)\",\"cwd\":\"/w\",\"kind\":\"interactive\"\(st)}"
        try json.write(to: dir.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
    }

    @Test func readParsesStatus() throws {
        let d = tmpDir()
        try writeSession(d, pid: 1, status: "busy")
        try writeSession(d, pid: 2, status: "idle")
        try writeSession(d, pid: 3, status: nil)
        #expect(ClaudeSessions.read(1, d)?.busy == true)
        #expect(ClaudeSessions.read(2, d)?.busy == false)
        #expect(ClaudeSessions.read(3, d)?.busy == false)
    }

    @Test func isInterruptedSignals() {
        let busy = ClaudeSessions.Found(sessionID: id, cwd: "/w", pid: 1, busy: true)
        let unknown = ClaudeSessions.Found(sessionID: id, cwd: "/w", pid: 1)
        let idle = ClaudeSessions.Found(sessionID: id, cwd: "/w", pid: 1, idle: true)
        #expect(SessionRecorder.isInterrupted(found: busy, hook: nil))
        #expect(SessionRecorder.isInterrupted(found: unknown, hook: .working))
        #expect(SessionRecorder.isInterrupted(found: nil, hook: .needsYou))
        #expect(!SessionRecorder.isInterrupted(found: unknown, hook: .idle))
        #expect(!SessionRecorder.isInterrupted(found: unknown, hook: .done))
        #expect(!SessionRecorder.isInterrupted(found: nil, hook: nil))
        // Esc mid-turn: no Stop hook, so the hook still says working; the session file's "idle" wins.
        #expect(!SessionRecorder.isInterrupted(found: idle, hook: .working))
        #expect(!SessionRecorder.isInterrupted(found: idle, hook: .needsYou))
    }

    @Test func modelMarksBusyAndNeedsYouNotIdle() {
        let m = WorkspaceModel(store: WorkspaceStore(url: tmpDir().appendingPathComponent("w.json")), claudeDir: tmpDir())
        let a = m.state.tabs[0].focusedPane, b = UUID(), c = UUID()
        m.state.tabs[0].tree = .split(id: UUID(), axis: .horizontal, fraction: 0.5, first: .leaf(a),
                                      second: .split(id: UUID(), axis: .vertical, fraction: 0.5, first: .leaf(b), second: .leaf(c)))
        let r = PaneResume.claude(sessionID: id, cwd: "/w")
        m.state.tabs[0].resume = [a: r, b: r, c: r]
        let busy = ClaudeSessions.Found(sessionID: id, cwd: "/w", pid: 1, busy: true)
        let idle = ClaudeSessions.Found(sessionID: id, cwd: "/w", pid: 2)
        // a: busy json; b: idle json but hook says needs-you; c: idle everywhere.
        let marked = m.markInterrupted(probe: { $0 == a ? (true, busy) : (true, idle) },
                                       hook: { $0 == b ? .needsYou : .idle })
        #expect(Set(marked) == [a, b])
        #expect(m.state.tabs[0].interrupted == [a, b])
        // A later snapshot with nothing working clears stale marks; a dead shell is never marked.
        #expect(m.markInterrupted(probe: { _ in (true, idle) }, hook: { _ in .idle }).isEmpty)
        #expect(m.state.tabs[0].interrupted == nil)
        #expect(m.markInterrupted(probe: { _ in (false, nil) }, hook: { _ in .working }).isEmpty)
    }

    @Test func applyAddsPromptOnlyToMarkedPaneAndClearsMarks() throws {
        let claude = tmpDir()
        let proj = claude.appendingPathComponent("projects/-w")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let id2 = "9176169f-0000-4000-8000-000000000002"
        for i in [id, id2] { try Data().write(to: proj.appendingPathComponent("\(i).jsonl")) }
        var s = WorkspaceState.fresh(cwd: "/tmp")
        let p1 = s.tabs[0].focusedPane
        let p2 = UUID()
        s.tabs[0].tree = .split(id: UUID(), axis: .horizontal, fraction: 0.5, first: .leaf(p1), second: .leaf(p2))
        s.tabs[0].resume = [p1: .claude(sessionID: id, cwd: "/w"), p2: .claude(sessionID: id2, cwd: "/w")]
        s.tabs[0].interrupted = [p1]
        let r = ResumePlan.apply(s, claudeDir: claude, settings: "/s.json")
        #expect(r.startups[p1] == PaneStartup.resumeCommand(sessionID: id, settings: "/s.json", prompt: ResumePlan.continuePrompt))
        #expect(r.startups[p2] == PaneStartup.resumeCommand(sessionID: id2, settings: "/s.json"))
        #expect(r.startups[p2] == "claude --resume \(id2) --dangerously-skip-permissions --settings '/s.json'; exec \"${SHELL:-/bin/zsh}\" -l")
        #expect(r.continued == [p1] && r.consumedMarks)
        #expect(r.state.tabs[0].interrupted == nil)
    }

    @Test func applyReportsInterruptedAgentPanes() {
        var s = WorkspaceState.fresh(cwd: "/tmp")
        let p = s.tabs[0].focusedPane
        s.tabs[0].resume = [p: .agent(name: "lead-app")]
        s.tabs[0].interrupted = [p]
        let r = ResumePlan.apply(s, claudeDir: tmpDir(), settings: "/s.json")
        #expect(r.interruptedAgents == [p] && r.state.tabs[0].interrupted == nil)
    }

    @Test func resumeCommandQuotesPrompt() {
        let c = PaneStartup.resumeCommand(sessionID: id, settings: "/s", prompt: "it's done")
        #expect(c == "claude --resume \(id) --dangerously-skip-permissions --settings '/s' 'it'\\''s done'; exec \"${SHELL:-/bin/zsh}\" -l")
        #expect(PaneStartup.resumeCommand(sessionID: id, settings: "/s", prompt: nil)
                == PaneStartup.resumeCommand(sessionID: id, settings: "/s"))
    }

    @Test func seatArgvPromptLastOnlyWhenGiven() {
        let paths = AgentPaths(root: URL(fileURLWithPath: "/tmp/tr"))
        let a = Agent(name: "lead-app", role: .lead, repo: "/p/app")
        let plain = AgentLaunch.argv(a, paths: paths, resumeID: "abc")
        let with = AgentLaunch.argv(a, paths: paths, resumeID: "abc", initialPrompt: ResumePlan.continuePrompt)
        #expect(with == plain + [ResumePlan.continuePrompt])
        #expect(plain.last == "abc")
    }

    @Test func oldWorkspaceJSONWithoutFieldDecodes() throws {
        let data = try JSONEncoder().encode(WorkspaceState.fresh(cwd: "/tmp"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((obj["tabs"] as! [[String: Any]])[0]["interrupted"] == nil)
        let back = try JSONDecoder().decode(WorkspaceState.self, from: data)
        #expect(back.tabs[0].interrupted == nil)
        var s = back; let p = s.tabs[0].focusedPane; s.tabs[0].interrupted = [p]
        let rt = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        #expect(rt.tabs[0].interrupted == [p])
    }

    @Test func summaryLine() {
        #expect(SessionSnapshot.interruptedSummary([]) == "quit snapshot: 0 interrupted (will continue)")
        #expect(SessionSnapshot.interruptedSummary(["b", "a"]) == "quit snapshot: 2 interrupted (will continue): a, b")
    }
}
