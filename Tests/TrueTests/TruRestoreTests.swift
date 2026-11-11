import Testing
import Foundation
@testable import True

private func tmp() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("true-tru-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// The pre-change PaneResume (no `tru` field): what an older True decodes with.
private enum OldPaneResume: Codable, Equatable {
    case claude(sessionID: String, cwd: String, mode: String?)
    case agent(name: String)
}

private func marker(_ dir: URL, pid: Int, session: String? = "1700000000-3", status: String = "idle",
                    cmd: String = "tru", provider: String = "claude", v: Int = 1, filePid: Int? = nil) throws {
    let s = session.map { "\"\($0)\"" } ?? "null"
    let json = #"{"v":\#(v),"pid":\#(filePid ?? pid),"cmd":"\#(cmd)","exe":"/opt/bin/tru","provider":"\#(provider)","session":\#(s),"cwd":"/work","status":"\#(status)","mode":"default","updated":1}"#
    try Data(json.utf8).write(to: dir.appendingPathComponent("\(pid).json"))
}

@Suite @MainActor struct TruRestoreTests {
    let tree: [pid_t: [pid_t]] = [1: [2], 2: [3, 4], 3: [5], 4: []]
    let tru = TruInfo(cmd: "tru-next", provider: "claude", exe: "/opt/bin/tru")

    func find(_ claude: URL, _ truDir: URL) -> ClaudeSessions.Found? {
        ClaudeSessions.find(under: 1, sessionsDir: claude, truDir: truDir) { self.tree[$0] ?? [] }
    }

    @Test func markerBeatsChildClaudeSessionFile() throws {
        let c = tmp(), t = tmp()
        try Data(#"{"pid":5,"sessionId":"child-uuid","cwd":"/work","kind":"interactive"}"#.utf8).write(to: c.appendingPathComponent("5.json"))
        try marker(t, pid: 3, cmd: "tru-next")
        let f = find(c, t)
        #expect(f?.tru?.cmd == "tru-next" && f?.sessionID == "1700000000-3" && f?.pid == 3)
        // and without the marker the child is a plain Claude
        #expect(find(c, tmp())?.sessionID == "child-uuid" && find(c, tmp())?.tru == nil)
    }

    @Test func claudeRunningTruAsSubprocessStaysClaude() throws {
        // a Claude pane that runs tru below it (a test, a smoke run) is still a Claude pane
        let c = tmp(), t = tmp()
        try Data(#"{"pid":3,"sessionId":"outer-uuid","cwd":"/work","kind":"interactive"}"#.utf8).write(to: c.appendingPathComponent("3.json"))
        try marker(t, pid: 5)
        let f = find(c, t)
        #expect(f?.sessionID == "outer-uuid" && f?.tru == nil && f?.pid == 3)
    }

    @Test func idleTruWithNoChildKeepsItsRecord() throws {
        let c = tmp(), t = tmp()
        try marker(t, pid: 4, session: nil)
        let f = find(c, t)
        let r = SessionRecorder.decide(previous: nil, agent: nil, alive: true, found: f)
        #expect(r == .claude(sessionID: "", cwd: "/work", mode: nil, tru: TruInfo(cmd: "tru", provider: "claude", exe: "/opt/bin/tru")))
        try marker(t, pid: 4, session: "1700000000-3")
        let r2 = SessionRecorder.decide(previous: r, agent: nil, alive: true, found: find(c, t))
        if case let .claude(id, _, _, tru)? = r2 { #expect(id == "1700000000-3" && tru != nil) } else { Issue.record("no record") }
    }

    @Test func malformedMarkersIgnored() throws {
        let c = tmp(), t = tmp()
        try marker(t, pid: 3, filePid: 99)
        try marker(t, pid: 4, v: 2)
        #expect(find(c, t) == nil)
        try marker(t, pid: 2, provider: "gemini")
        #expect(find(c, t) == nil)
    }

    @Test func interruptedFollowsMarkerStatus() throws {
        let c = tmp(), t = tmp()
        for (st, want) in [("busy", true), ("needs_you", true), ("idle", false)] {
            try marker(t, pid: 3, status: st)
            #expect(SessionRecorder.isInterrupted(found: find(c, t), hook: nil) == want)
        }
    }

    @Test func startupStrings() {
        let q = "exec \"${SHELL:-/bin/zsh}\" -l"
        #expect(PaneStartup.truCommand(TruInfo(cmd: "tru", provider: "claude"), sessionID: "1-2") == "'tru' --resume '1-2'; \(q)")
        #expect(PaneStartup.truCommand(TruInfo(cmd: "tru-next", provider: "claude"), sessionID: "1-2") == "'tru-next' --resume '1-2'; \(q)")
        #expect(PaneStartup.truCommand(TruInfo(cmd: "tru", provider: "codex"), sessionID: "1-2") == "'tru' --codex --resume '1-2'; \(q)")
        #expect(PaneStartup.truCommand(TruInfo(cmd: "tru", provider: "claude"), sessionID: "") == "'tru'; \(q)")
        let p = ResumePlan.continuePrompt(.restart)
        let c = PaneStartup.truCommand(tru, sessionID: "1-2", prompt: p)
        #expect(c == "if command -v 'tru-next' >/dev/null 2>&1; then 'tru-next' --resume '1-2' --prompt \(AgentLaunch.shellQuote(p)); else '/opt/bin/tru' --resume '1-2' --prompt \(AgentLaunch.shellQuote(p)); fi; \(q)")
        #expect(PaneStartup.truCommand(tru, sessionID: "x;rm") == nil)
        #expect(PaneStartup.truCommand(TruInfo(cmd: "tru", provider: "gemini"), sessionID: "1-2") == nil)
        #expect(PaneStartup.truCommand(tru, sessionID: "../etc") == nil)
    }

    func workspace(_ r: PaneResume, marked: Bool = false) -> (WorkspaceState, UUID) {
        var s = WorkspaceState.fresh(cwd: "/tmp")
        let p = s.tabs[0].focusedPane
        s.tabs[0].resume = [p: r]
        if marked { s.tabs[0].interrupted = [p] }
        return (s, p)
    }

    @Test func applyFreshIdleAndInterrupted() throws {
        let sess = tmp()
        // fresh tru: no session file needed, no --resume
        let (a, pa) = workspace(.claude(sessionID: "", cwd: "/work", tru: tru))
        let ra = ResumePlan.apply(a, claudeDir: tmp(), settings: "/s", truSessionsDir: sess)
        #expect(ra.startups[pa]?.contains("--resume") == false && ra.startups[pa]?.contains("'tru-next'") == true)
        #expect(ra.state.tabs[0].cwds[pa] == "/work")
        // missing session file -> dropped
        let (b, pb) = workspace(.claude(sessionID: "1-2", cwd: "/work", tru: tru))
        let rb = ResumePlan.apply(b, claudeDir: tmp(), settings: "/s", truSessionsDir: sess)
        #expect(rb.startups.isEmpty && rb.dropped == [.init(pane: pb, sessionID: "1-2", reason: .transcriptMissing)])
        #expect(rb.state.tabs[0].resume == nil && rb.state.tabs[0].cwds[pb] == "/tmp")
        // present: idle comes back quiet, interrupted continues
        try Data().write(to: sess.appendingPathComponent("1-2.jsonl"))
        let (c, pc) = workspace(.claude(sessionID: "1-2", cwd: "/work", tru: tru))
        let rc = ResumePlan.apply(c, claudeDir: tmp(), settings: "/s", truSessionsDir: sess)
        #expect(rc.startups[pc]?.contains("--prompt") == false && rc.continued.isEmpty)
        let (d, pd) = workspace(.claude(sessionID: "1-2", cwd: "/work", tru: tru), marked: true)
        let rd = ResumePlan.apply(d, claudeDir: tmp(), settings: "/s", truSessionsDir: sess)
        #expect(rd.startups[pd]?.contains("--prompt") == true && rd.continued == [pd])
        // bad id
        let (e, _) = workspace(.claude(sessionID: "x;rm", cwd: "/work", tru: tru))
        let re = ResumePlan.apply(e, claudeDir: tmp(), settings: "/s", truSessionsDir: sess)
        #expect(re.startups.isEmpty && re.dropped.first?.reason == .invalidSessionID)
    }

    @Test func schemaCompatibility() throws {
        let old = Data(#"{"claude":{"sessionID":"9176169f-0000-4000-8000-000000000001","cwd":"/w"}}"#.utf8)
        let n = try JSONDecoder().decode(PaneResume.self, from: old)
        #expect(n == .claude(sessionID: "9176169f-0000-4000-8000-000000000001", cwd: "/w", mode: nil, tru: nil))
        // new JSON with a tru payload decodes in the pre-change type, payload ignored
        let new = try JSONEncoder().encode(PaneResume.claude(sessionID: "1-2", cwd: "/w", mode: "default", tru: tru))
        #expect(String(data: new, encoding: .utf8)!.contains("tru-next"))
        let o = try JSONDecoder().decode(OldPaneResume.self, from: new)
        #expect(o == .claude(sessionID: "1-2", cwd: "/w", mode: "default"))
        // and round trips in the new type
        #expect(try JSONDecoder().decode(PaneResume.self, from: new) == .claude(sessionID: "1-2", cwd: "/w", mode: "default", tru: tru))
    }
}
