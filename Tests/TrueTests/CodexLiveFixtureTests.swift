import Foundation
import Testing
@testable import True

/// Explicit opt-in foreground PTY bridge. Normal suite runs never launch Codex or write its profile.
@Suite struct CodexLiveFixtureTests {
    @Test func exportLaunchAndCheckScreen() throws {
        let env = ProcessInfo.processInfo.environment
        guard let requested = env["TRUE_SEAT_LIVE_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: requested).standardizedFileURL
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(directory.path.hasPrefix(project.appendingPathComponent(".out/").path + "/"))
        guard directory.path.hasPrefix(project.appendingPathComponent(".out/").path + "/") else { return }
        let paths = AgentPaths(root: directory.appendingPathComponent("true"))
        var agent = Agent(name: "helper-1-spike", role: .helper, repo: directory.path, effort: .low,
                          charter: "This is a small diagnostic. End every answer with ROLE_CARD_OK.", provider: .codex)
        let resumeFile = directory.appendingPathComponent("resume-id.txt")
        if let id = try? String(contentsOf: resumeFile, encoding: .utf8) { agent.sessionID = id.trimmingCharacters(in: .whitespacesAndNewlines) }
        let provider = CodexSeat()
        provider.install(for: agent, all: [agent], paths: paths)
        let prompt = try String(contentsOf: directory.appendingPathComponent("prompt.txt"), encoding: .utf8)
        let argv = provider.argv(for: agent, paths: paths, resumeID: provider.resumeID(for: agent), initialPrompt: prompt)
        let launch: [String: Any] = ["argv": argv, "shellCommand": provider.shellCommand(argv: argv),
                                    "forwarder": paths.forwarderPath, "profile": CodexSeat.profile(all: [agent], paths: paths)]
        try JSONSerialization.data(withJSONObject: launch, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("launch.json"))
        if let screen = try? String(contentsOf: directory.appendingPathComponent("screen.txt"), encoding: .utf8) {
            let facts = provider.screen
            let result: [String: Any] = ["dialog": facts.dialogVisible(screen), "busy": facts.isBusy(screen),
                                         "approve": facts.answerKeys.approve, "deny": facts.answerKeys.deny, "interrupt": facts.interruptKey]
            try JSONSerialization.data(withJSONObject: result).write(to: directory.appendingPathComponent("screen-result.json"))
        }
    }
}
