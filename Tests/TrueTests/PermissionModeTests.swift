import Testing
import Foundation
@testable import True

@Suite @MainActor struct PermissionModeTests {
    let id = "9176169f-0000-4000-8000-000000000001"
    let tail = "; exec \"${SHELL:-/bin/zsh}\" -l"

    @Test func commandPerMode() {
        func cmd(_ m: String?, prompt: String? = nil) -> String? {
            PaneStartup.resumeCommand(sessionID: id, settings: "/s.json", mode: m, prompt: prompt)
        }
        #expect(cmd("bypassPermissions") == "claude --resume \(id) --dangerously-skip-permissions --settings '/s.json'\(tail)")
        for m in ["manual", "acceptEdits", "plan", "auto", "dontAsk"] {
            #expect(cmd(m) == "claude --resume \(id) --permission-mode \(m) --settings '/s.json'\(tail)")
        }
        // The CLI rejects `--permission-mode default` (it boots nothing); hooks' `default` replays as `manual`.
        #expect(cmd("default") == "claude --resume \(id) --permission-mode manual --settings '/s.json'\(tail)")
        #expect(cmd(nil) == "claude --resume \(id) --settings '/s.json'\(tail)")
        #expect(cmd("bogus") == cmd(nil))
        #expect(cmd("plan; rm -rf ~") == cmd(nil))
        #expect(cmd("$(evil)") == cmd(nil))
    }

    @Test func promptStaysLast() throws {
        let c = try #require(PaneStartup.resumeCommand(sessionID: id, settings: "/s.json", mode: "bypassPermissions",
                                                        prompt: ResumePlan.continuePrompt))
        #expect(c.hasPrefix("claude --resume \(id) --dangerously-skip-permissions --settings '/s.json' '"))
        #expect(c.hasSuffix("'" + tail))
    }

    @Test func oldRecordDecodesWithoutMode() throws {
        let old = #"{"claude":{"sessionID":"\#(id)","cwd":"/w"}}"#
        let r = try JSONDecoder().decode(PaneResume.self, from: Data(old.utf8))
        #expect(r == .claude(sessionID: id, cwd: "/w", mode: nil))
        let new = try JSONEncoder().encode(PaneResume.claude(sessionID: id, cwd: "/w", mode: "plan"))
        #expect(try JSONDecoder().decode(PaneResume.self, from: new) == .claude(sessionID: id, cwd: "/w", mode: "plan"))
    }

    @Test func applyReplaysRecordedMode() throws {
        let claude = FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(UUID().uuidString)")
        let proj = claude.appendingPathComponent("projects/-w")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try Data().write(to: proj.appendingPathComponent("\(id).jsonl"))
        var s = WorkspaceState.fresh(cwd: "/tmp")
        let p = s.tabs[0].focusedPane
        s.tabs[0].resume = [p: .claude(sessionID: id, cwd: "/w", mode: "bypassPermissions")]
        let r = ResumePlan.apply(s, claudeDir: claude, settings: "/s.json")
        #expect(r.startups[p]?.contains("--dangerously-skip-permissions") == true)
    }

    @Test func decideKeepsOrUpdatesMode() {
        let f = ClaudeSessions.Found(sessionID: id, cwd: "/w", pid: 1)
        #expect(SessionRecorder.decide(previous: nil, agent: nil, alive: true, found: f, mode: "plan")
                == .claude(sessionID: id, cwd: "/w", mode: "plan"))
        // no hook this run: keep the recorded mode for the same conversation; a different one starts clean
        let prev = PaneResume.claude(sessionID: id, cwd: "/w", mode: "bypassPermissions")
        #expect(SessionRecorder.decide(previous: prev, agent: nil, alive: true, found: f, mode: nil) == prev)
        let other = ClaudeSessions.Found(sessionID: "9176169f-0000-4000-8000-000000000002", cwd: "/w", pid: 1)
        #expect(SessionRecorder.decide(previous: prev, agent: nil, alive: true, found: other, mode: nil)
                == .claude(sessionID: other.sessionID, cwd: "/w", mode: nil))
        // Shift+Tab changed it: the newest wins
        #expect(SessionRecorder.decide(previous: prev, agent: nil, alive: true, found: f, mode: "auto")
                == .claude(sessionID: id, cwd: "/w", mode: "auto"))
    }

    @Test func wireCarriesMode() {
        let pane = UUID()
        let line = #"{"pane":"\#(pane.uuidString)","event":"progress","message":"x","mode":"bypassPermissions"}"#
        #expect(PaneEvent.parse(line: Data(line.utf8))?.mode == "bypassPermissions")
        let none = #"{"pane":"\#(pane.uuidString)","event":"progress","message":"x"}"#
        #expect(PaneEvent.parse(line: Data(none.utf8))?.mode == nil)
    }

    @Test func forwarderAddsModeAndStaysSilent() throws {
        let pane = UUID()
        let root = URL(fileURLWithPath: "/tmp/pm-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(root: root)
        AgentHooks.installPaneHooks(paths: paths)
        let sock = "/tmp/pm-\(UUID().uuidString.prefix(8)).sock"
        let got = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var event: PaneEvent? }
        let box = Box()
        let listener = AgentEventSocket(path: sock) { box.event = $0; got.signal() }
        #expect(listener.start())
        defer { listener.stop() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", paths.forwarderPath]
        p.environment = ["TRUE_PANE_ID": pane.uuidString, "TRUE_EVENTS_SOCK": sock, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
        let stdin = Pipe(); p.standardInput = stdin
        p.standardOutput = Pipe()
        try p.run()
        stdin.fileHandleForWriting.write(Data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","permission_mode":"bypassPermissions"}"#.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(got.wait(timeout: .now() + 3) == .success)
        #expect(box.event?.pane == pane && box.event?.mode == "bypassPermissions")
        #expect(((p.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()).isEmpty)
    }
}
