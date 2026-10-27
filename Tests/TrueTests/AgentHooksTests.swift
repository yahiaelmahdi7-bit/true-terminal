import Testing
import Foundation
@testable import True

/// Run 36a step 3 (A3): the real forwarder sends PreToolUse input; the summary keeps it to a line of ≤ 1 KB.
@Suite struct AgentHooksTests {
    func forward(_ json: String) throws -> PaneEvent? {
        let root = URL(fileURLWithPath: "/tmp/tr-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(root: root)
        let a = Agent(name: "lead-app", role: .lead, repo: "/tmp")
        AgentHooks.install(for: a, all: [a], paths: paths)
        let sock = "/tmp/t-\(UUID().uuidString.prefix(8)).sock"
        let got = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var event: PaneEvent? }
        let box = Box()
        let listener = AgentEventSocket(path: sock) { box.event = $0; got.signal() }
        #expect(listener.start())
        defer { listener.stop() }
        let pane = UUID()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", paths.forwarderPath]
        p.environment = ["TRUE_PANE_ID": pane.uuidString, "TRUE_EVENTS_SOCK": sock, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
        let stdin = Pipe(); p.standardInput = stdin; p.standardOutput = Pipe()
        try p.run()
        stdin.fileHandleForWriting.write(Data(json.utf8)); try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(got.wait(timeout: .now() + 3) == .success)
        return box.event
    }

    @Test func preToolUseBashCarriesTheCommand() throws {
        let e = try #require(try forward(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test\nsecond line"}}"#))
        #expect(e.kind == .progress && e.message == "Bash" && e.detail == "npm test")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func text(_ level: PeerShare) -> String? {
            PeerEngine.items(kind: .progress, message: e.message, tool: e.tool, detail: e.detail, at: at, level: level).first?.text
        }
        #expect(text(.everything) == "Bash · npm test")
        #expect(text(.activity) == "Bash")
    }

    @Test func longInputIsClippedToOneKB() throws {
        let long = String(repeating: "x", count: 5_000)
        let e = try #require(try forward(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"\#(long)"}}"#))
        #expect(e.detail?.count == 1024)
    }

    @Test func grepUsesThePattern() {
        let s = ToolSummary.summarize(tool: "Grep", input: ["path": "/src", "pattern": "TODO"])
        #expect(s.detail == "TODO")
    }
}
